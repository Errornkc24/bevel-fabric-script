#!/usr/bin/env bash
# =============================================================================
# k3s-fixes.sh - Automated fixes for running Bevel on K3s clusters
#
# Bevel's Helm charts assume minikube or cloud-managed K8s. On K3s (bare-metal)
# several things need patching:
#   1. Traefik (K3s default ingress) conflicts with HAProxy on port 443
#   2. No "haproxy" IngressClass exists by default
#   3. haproxy-ingress uses legacy annotation for class matching
#   4. StorageClass uses k8s.io/minikube-hostpath (doesn't exist on K3s)
#   5. Container images from ghcr.io may fail to pull without auth
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Detect K8s distribution: k3s, minikube, or unknown
# ---------------------------------------------------------------------------
detect_k8s_distro() {
    # Check for K3s
    if command -v k3s &>/dev/null || [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
        echo "k3s"
        return
    fi
    # Check for Minikube
    if command -v minikube &>/dev/null && minikube status &>/dev/null; then
        echo "minikube"
        return
    fi
    # Fallback: check kubectl version output
    local server_version
    server_version=$(kubectl version --short 2>/dev/null | grep -i "server" || true)
    if echo "$server_version" | grep -qi "k3s"; then
        echo "k3s"
        return
    fi
    echo "unknown"
}

is_k3s() {
    local distro
    distro=$(detect_k8s_distro)
    [[ "$distro" == "k3s" ]]
}

is_minikube() {
    local distro
    distro=$(detect_k8s_distro)
    [[ "$distro" == "minikube" ]]
}

# ---------------------------------------------------------------------------
# 1. Disable Traefik and promote HAProxy to LoadBalancer (K3s only)
# ---------------------------------------------------------------------------
fix_traefik_haproxy_conflict() {
    local kubeconfig="$1"
    local cluster_name="$2"

    log_step "Fixing Traefik/HAProxy conflict on ${cluster_name}..."

    # Scale down Traefik deployment if it exists
    if kubectl --kubeconfig "$kubeconfig" get deployment traefik -n kube-system &>/dev/null; then
        log_info "Scaling down Traefik on ${cluster_name}..."
        kubectl --kubeconfig "$kubeconfig" scale deployment traefik -n kube-system --replicas=0 2>/dev/null || true
    fi

    # Delete Traefik LoadBalancer service to free ports 80/443
    if kubectl --kubeconfig "$kubeconfig" get svc traefik -n kube-system &>/dev/null; then
        log_info "Removing Traefik service on ${cluster_name} to free ports 80/443..."
        kubectl --kubeconfig "$kubeconfig" delete svc traefik -n kube-system 2>/dev/null || true
        sleep 3
    fi

    # Switch HAProxy from NodePort to LoadBalancer
    local svc_type
    svc_type=$(kubectl --kubeconfig "$kubeconfig" get svc haproxy-haproxy-ingress -n ingress-controller -o jsonpath='{.spec.type}' 2>/dev/null)
    if [[ "$svc_type" != "LoadBalancer" ]]; then
        log_info "Switching HAProxy to LoadBalancer on ${cluster_name}..."
        kubectl --kubeconfig "$kubeconfig" patch svc haproxy-haproxy-ingress -n ingress-controller \
            --type merge -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true
    fi

    # Wait for external IP assignment
    local attempts=0
    while (( attempts < 15 )); do
        local ext_ip
        ext_ip=$(kubectl --kubeconfig "$kubeconfig" get svc haproxy-haproxy-ingress -n ingress-controller \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [[ -n "$ext_ip" ]]; then
            log_success "HAProxy on ${cluster_name} has external IP: ${ext_ip}"
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    log_warning "HAProxy external IP not yet assigned on ${cluster_name} (may need a moment)"
}

# ---------------------------------------------------------------------------
# 2. Create haproxy IngressClass if missing
# ---------------------------------------------------------------------------
ensure_haproxy_ingressclass() {
    local kubeconfig="$1"
    local cluster_name="$2"

    if kubectl --kubeconfig "$kubeconfig" get ingressclass haproxy &>/dev/null; then
        return 0
    fi

    log_info "Creating haproxy IngressClass on ${cluster_name}..."
    cat <<'EOF' | kubectl --kubeconfig "$kubeconfig" apply -f -
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: haproxy
spec:
  controller: haproxy-ingress.github.io/controller
EOF
    log_success "haproxy IngressClass created on ${cluster_name}."
}

# ---------------------------------------------------------------------------
# 3. Add legacy ingress class annotation to all Bevel ingresses
#    haproxy-ingress (jcmoraisjr) requires kubernetes.io/ingress.class
#    annotation for matching, not just spec.ingressClassName
# ---------------------------------------------------------------------------
fix_ingress_annotations() {
    local kubeconfig="$1"
    local cluster_name="$2"

    log_step "Fixing ingress annotations on ${cluster_name}..."

    local namespaces
    namespaces=$(kubectl --kubeconfig "$kubeconfig" get ingress -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)

    for ns in $namespaces; do
        local ingresses
        ingresses=$(kubectl --kubeconfig "$kubeconfig" get ingress -n "$ns" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        for ing in $ingresses; do
            # Add legacy class annotation
            kubectl --kubeconfig "$kubeconfig" annotate ingress "$ing" -n "$ns" \
                kubernetes.io/ingress.class=haproxy --overwrite 2>/dev/null || true

            # Add correct ssl-passthrough annotation for haproxy-ingress
            local has_ssl
            has_ssl=$(kubectl --kubeconfig "$kubeconfig" get ingress "$ing" -n "$ns" \
                -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/ssl-passthrough}' 2>/dev/null)
            if [[ "$has_ssl" == "true" ]]; then
                kubectl --kubeconfig "$kubeconfig" annotate ingress "$ing" -n "$ns" \
                    haproxy-ingress.github.io/ssl-passthrough=true --overwrite 2>/dev/null || true
            fi
        done
    done
    log_success "Ingress annotations fixed on ${cluster_name}."
}

# ---------------------------------------------------------------------------
# 4. Patch Bevel HelmRelease files for K3s StorageClass
#    Bevel charts use k8s.io/minikube-hostpath provisioner when
#    cloud_provider=minikube. K3s needs rancher.io/local-path with
#    WaitForFirstConsumer volumeBindingMode.
# ---------------------------------------------------------------------------
patch_helmrelease_storage() {
    local bevel_dir="$1"

    # Skip on minikube - Bevel's defaults are correct
    if is_minikube; then
        log_info "Minikube detected - skipping StorageClass patches (Bevel defaults are correct)."
        return 0
    fi

    log_step "Patching HelmRelease files for K3s storage..."

    local releases_dir="${bevel_dir}/platforms/hyperledger-fabric/releases"
    if [[ ! -d "$releases_dir" ]]; then
        log_info "No releases directory found yet. Will patch after Ansible generates them."
        return 0
    fi

    local changed=0
    # Find all HelmRelease YAML files that have a storage: section
    while IFS= read -r -d '' yaml_file; do
        # Add provisioner if not present
        if grep -q "^    storage:" "$yaml_file" && ! grep -q 'provisioner:' "$yaml_file"; then
            sed -i '/^    storage:$/a\      provisioner: "rancher.io/local-path"' "$yaml_file"
            changed=1
            log_info "  Added provisioner to: $(basename "$yaml_file")"
        fi
        # Fix volumeBindingMode: empty or Immediate -> WaitForFirstConsumer
        if grep -q 'volumeBindingMode: Immediate' "$yaml_file"; then
            sed -i 's/volumeBindingMode: Immediate/volumeBindingMode: WaitForFirstConsumer/' "$yaml_file"
            changed=1
            log_info "  Fixed volumeBindingMode in: $(basename "$yaml_file")"
        fi
        # Fix empty volumeBindingMode (line ends with just "volumeBindingMode: " or "volumeBindingMode:")
        if grep -qE 'volumeBindingMode:\s*$' "$yaml_file"; then
            sed -i -E 's/volumeBindingMode:\s*$/volumeBindingMode: WaitForFirstConsumer/' "$yaml_file"
            changed=1
            log_info "  Fixed empty volumeBindingMode in: $(basename "$yaml_file")"
        fi
    done < <(find "$releases_dir" -name "*.yaml" -path "*/ca/*" -o -name "*.yaml" -path "*/orderer/*" -o -name "*.yaml" -path "*/peer/*" | grep -v flux-dev | tr '\n' '\0')

    if (( changed )); then
        log_info "Committing storage patches to git..."
        cd "$bevel_dir" || return 1
        git add platforms/hyperledger-fabric/releases/ 2>/dev/null
        if git diff --cached --quiet 2>/dev/null; then
            log_info "No new changes to commit."
        else
            git commit -m "fix(k3s): use local-path provisioner and WaitForFirstConsumer for K3s" 2>/dev/null || true
            git push 2>/dev/null || true
            log_success "Storage patches committed and pushed."
        fi
    else
        log_info "HelmRelease files already patched or not yet generated."
    fi
}

# ---------------------------------------------------------------------------
# 5a. Build bevel-fabric-tools:3.0.0 for Fabric v3.0 BFT support.
#     hyperledger/fabric-tools was deprecated at v3.0; the official image does
#     not exist. We build a minimal Ubuntu image with the Fabric v3.0 binaries
#     (configtxgen, peer, osnadmin) downloaded from the GitHub release tarball.
# ---------------------------------------------------------------------------
_build_bevel_fabric_tools_v3() {
    local version="$1"
    local target_image="ghcr.io/hyperledger/bevel-fabric-tools:${version}"

    if sudo k3s ctr images check 2>/dev/null | grep -qF "${target_image}"; then
        log_info "  ${target_image} already present in containerd — skipping build"
        return 0
    fi

    if ! command -v docker &>/dev/null; then
        log_warning "  Docker not available — cannot build bevel-fabric-tools:${version}"
        log_warning "  BFT genesis block generation will fall back to configtxgen v2.5 and may fail"
        return 1
    fi

    log_step "Building ${target_image} (Fabric v${version} binaries + configtxgen)..."

    local tmpdir
    tmpdir=$(mktemp -d)

    # Write Dockerfile: Ubuntu 22.04 + Fabric v3.0 binaries from GitHub release
    # The GitHub tarball extracts bin/ -> /usr/local/bin/ and config/ -> /usr/local/config/
    # (config/ contains core.yaml, configtx.yaml, orderer.yaml)
    # FABRIC_CFG_PATH must point to /usr/local/config/ so peer/configtxlator find core.yaml.
    cat > "${tmpdir}/Dockerfile" <<DOCKERFILE
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
ARG FABRIC_VERSION
RUN apt-get update && \\
    apt-get install -y --no-install-recommends wget curl jq tar gzip ca-certificates && \\
    rm -rf /var/lib/apt/lists/*
RUN wget -q "https://github.com/hyperledger/fabric/releases/download/v\${FABRIC_VERSION}/hyperledger-fabric-linux-amd64-\${FABRIC_VERSION}.tar.gz" \\
        -O /tmp/fabric.tar.gz && \\
    tar -xzf /tmp/fabric.tar.gz -C /usr/local && \\
    rm /tmp/fabric.tar.gz
# Set FABRIC_CFG_PATH so peer/configtxlator find core.yaml at /usr/local/config/
ENV FABRIC_CFG_PATH=/usr/local/config
RUN configtxgen -version && peer version
DOCKERFILE

    local build_log="/tmp/bevel-fabric-tools-v3-build.log"
    if docker build \
        --build-arg "FABRIC_VERSION=${version}" \
        -t "${target_image}" \
        "${tmpdir}" > "${build_log}" 2>&1; then
        log_success "  Built ${target_image} successfully"
        # Import into K3s containerd so Helm charts can pull it without registry auth
        local tmptar="/tmp/bevel_fabric_tools_${version//\./_}.tar"
        docker save "${target_image}" -o "${tmptar}" 2>/dev/null
        sudo k3s ctr images import "${tmptar}" 2>/dev/null
        rm -f "${tmptar}"
        log_success "  Imported ${target_image} into K3s containerd"
    else
        log_warning "  Build FAILED — see ${build_log} for details"
        log_warning "  BFT genesis block generation will fail (configtxgen v3.0 unavailable)"
    fi

    rm -rf "${tmpdir}"
}

# ---------------------------------------------------------------------------
# 5. Pre-pull required container images into K3s containerd
#    ghcr.io may return 403 without auth. We pull via docker (which has auth)
#    then import into K3s containerd.
# ---------------------------------------------------------------------------
prepull_bevel_images() {
    local kubeconfig="$1"
    local cluster_name="$2"

    log_step "Pre-pulling Bevel images for ${cluster_name}..."

    local fabric_version docker_url
    fabric_version=$(load_config_var "FABRIC_VERSION" "2.5.4")
    # Auto-select registry: v3.x → custom (no official bevel v3 images), v2.x → official
    local docker_url_default="ghcr.io/hyperledger"
    [[ "$fabric_version" == 3.* ]] && docker_url_default="ghcr.io/niravchangelavhits-blockchain-dev"
    docker_url=$(load_config_var "DOCKER_URL" "$docker_url_default")

    local images=(
        "${docker_url}/bevel-fabric-ca:latest"
        "${docker_url}/bevel-alpine:latest"
        "${docker_url}/bevel-fabric-tools:${fabric_version}"
    )

    # Add orderer images for orderer cluster
    local role
    role=$(load_config_var "ROLE")
    if [[ "$role" == "orderer" ]] || [[ "$cluster_name" == "orderer-cluster" ]]; then
        images+=(
            "${docker_url}/bevel-fabric-orderer:${fabric_version}"
            "ghcr.io/hyperledger-labs/grpc-web:latest"
        )
    fi

    # Add peer images for org clusters
    if [[ "$role" == "org1" ]] || [[ "$role" == "org2" ]] || \
       [[ "$cluster_name" == "org1-cluster" ]] || [[ "$cluster_name" == "org2-cluster" ]]; then
        # CouchDB has no v3.x image; use 2.5.4 for all versions
        local couchdb_tag="${fabric_version}"
        [[ "${fabric_version}" == 3.* ]] && couchdb_tag="2.5.4"
        images+=(
            "${docker_url}/bevel-fabric-peer:${fabric_version}"
            "${docker_url}/bevel-fabric-couchdb:${couchdb_tag}"
            "ghcr.io/hyperledger-labs/grpc-web:latest"
        )
    fi

    for img in "${images[@]}"; do
        # Check if image already exists in K3s containerd
        if sudo k3s ctr images check 2>/dev/null | grep -q "$img"; then
            log_info "  Image already present: ${img}"
            continue
        fi

        log_info "  Pulling ${img}..."

        # Try direct K3s containerd pull first
        if sudo k3s ctr images pull "$img" &>/dev/null; then
            log_success "  Pulled via containerd: ${img}"
            continue
        fi

        # Fallback: pull via docker, export, import into K3s
        if command -v docker &>/dev/null; then
            if docker pull "$img" &>/dev/null; then
                local tmptar="/tmp/$(echo "$img" | tr '/:' '_').tar"
                docker save "$img" -o "$tmptar" 2>/dev/null
                sudo k3s ctr images import "$tmptar" 2>/dev/null
                rm -f "$tmptar"
                log_success "  Imported via docker: ${img}"
                continue
            fi
        fi

        log_warning "  Could not pull ${img} - deployment may need manual image import"
    done
}

# ---------------------------------------------------------------------------
# Master function: Apply all K3s fixes on a given cluster
# ---------------------------------------------------------------------------
apply_k3s_fixes_for_cluster() {
    local kubeconfig="$1"
    local cluster_name="$2"

    log_header "Applying K3s fixes for ${cluster_name}"

    fix_traefik_haproxy_conflict "$kubeconfig" "$cluster_name"
    ensure_haproxy_ingressclass "$kubeconfig" "$cluster_name"

    # Remove stale ingress-nginx ValidatingWebhookConfiguration
    # (blocks ALL Ingress creation if the webhook service is gone)
    if kubectl --kubeconfig "$kubeconfig" get validatingwebhookconfiguration ingress-nginx-admission &>/dev/null; then
        log_info "Removing stale ingress-nginx admission webhook..."
        kubectl --kubeconfig "$kubeconfig" delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found 2>/dev/null || true
    fi

    log_success "K3s fixes applied for ${cluster_name}."
}

# ---------------------------------------------------------------------------
# Post-deployment fix: fix ingress annotations after Bevel creates them
# ---------------------------------------------------------------------------
post_deploy_ingress_fixes() {
    # Skip on minikube - ingress works natively
    if is_minikube; then
        return 0
    fi

    log_header "Post-deployment: Fixing ingress annotations on all clusters"

    local kc_orderer kc_org1 kc_org2
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2")

    for pair in "$kc_orderer:orderer-cluster" "$kc_org1:org1-cluster" "$kc_org2:org2-cluster"; do
        local kc="${pair%%:*}"
        local name="${pair##*:}"
        if [[ -n "$kc" ]] && [[ -f "$kc" ]]; then
            fix_ingress_annotations "$kc" "$name"
        fi
    done

    # Fix: peer0-cli pods require a configmap named "peer0-orderer-tls-cacert"
    # (prefixed with the Helm release name) but Bevel only creates "orderer-tls-cacert".
    # Without this, the CLI pod's init container stays stuck in PodInitializing.
    _fix_cli_orderer_tls_cacert "$kc_org1" "org1-net"
    _fix_cli_orderer_tls_cacert "$kc_org2" "org2-net"
}

# Create peer0-orderer-tls-cacert configmap (copy of orderer-tls-cacert)
# The fabric-cli Helm chart mounts it as {{ .Release.Name }}-orderer-tls-cacert
# which equals "peer0-orderer-tls-cacert" when the release is named "peer0".
_fix_cli_orderer_tls_cacert() {
    local kubeconfig="$1"
    local namespace="$2"

    [[ -z "$kubeconfig" ]] || [[ ! -f "$kubeconfig" ]] && return 0
    ! kubectl --kubeconfig "$kubeconfig" cluster-info &>/dev/null && return 0

    # Only needed if orderer-tls-cacert exists but peer0-prefixed one doesn't
    if kubectl --kubeconfig "$kubeconfig" get configmap orderer-tls-cacert \
            -n "$namespace" &>/dev/null && \
       ! kubectl --kubeconfig "$kubeconfig" get configmap peer0-orderer-tls-cacert \
            -n "$namespace" &>/dev/null; then

        local tls_cert
        tls_cert=$(kubectl --kubeconfig "$kubeconfig" get configmap orderer-tls-cacert \
            -n "$namespace" -o jsonpath='{.data.cacert}' 2>/dev/null || true)

        if [[ -n "$tls_cert" ]]; then
            kubectl --kubeconfig "$kubeconfig" create configmap peer0-orderer-tls-cacert \
                -n "$namespace" \
                --from-literal=cacert="$tls_cert" \
                --from-literal=crt="$tls_cert" \
                --dry-run=client -o yaml | \
                kubectl --kubeconfig "$kubeconfig" apply -f - 2>/dev/null && \
            log_success "  Created peer0-orderer-tls-cacert in ${namespace}" || \
            log_warning "  Could not create peer0-orderer-tls-cacert in ${namespace}"
        fi
    else
        log_info "  peer0-orderer-tls-cacert already exists in ${namespace} or no source found"
    fi
}

# ---------------------------------------------------------------------------
# Patch Bevel source code for multi-cluster and K3s compatibility
# These fixes apply to the Bevel Ansible roles regardless of K8s distro
# ---------------------------------------------------------------------------
patch_bevel_source_bugs() {
    local bevel_dir
    bevel_dir=$(load_config_var "BEVEL_DIR" "${HOME}/bevel")

    if [[ ! -d "$bevel_dir" ]]; then
        log_warning "Bevel directory not found at ${bevel_dir}, skipping source patches."
        return 0
    fi

    log_step "Patching Bevel source for multi-cluster and K3s compatibility..."
    local patched=0

    # =========================================================================
    # Fix 1: Cross-cluster kubeconfig for orderer TLS cacert lookup in peer role
    # In multi-cluster setups, peer orgs need the orderer org's kubeconfig
    # to read the orderer-tls-cacert ConfigMap from the orderer cluster.
    # =========================================================================
    local peer_nested="${bevel_dir}/platforms/hyperledger-fabric/configuration/roles/create/peers/tasks/nested_main.yaml"
    if [[ -f "$peer_nested" ]]; then
        if grep -q 'name: "orderer-tls-cacert"' "$peer_nested" && ! grep -q "selectattr" "$peer_nested"; then
            sed -i '/name: Get orderer tls cacert from config map/,/when: org.orderer_org != org.name/{
                s|kubeconfig: "{{ kubernetes.config_file }}"|kubeconfig: "{{ (network.organizations | selectattr('\''name'\'','\''equalto'\'', org.orderer_org) | first).k8s.config_file }}"|
            }' "$peer_nested"
            if grep -q "selectattr" "$peer_nested"; then
                log_success "  [1] Fixed cross-cluster kubeconfig in peer TLS cacert lookup."
                patched=$((patched + 1))
            fi
        else
            log_info "  [1] Cross-cluster peer kubeconfig fix already applied or not needed."
        fi
    fi

    # =========================================================================
    # Fix 2: Cross-cluster kubeconfig in genesis get_peer_msp_config.yaml
    # Genesis role reads peer org ConfigMaps but used orderer's kubeconfig.
    # Must use organization.k8s.config_file (the peer org being iterated).
    # =========================================================================
    local genesis_msp="${bevel_dir}/platforms/hyperledger-fabric/configuration/roles/create/genesis/tasks/get_peer_msp_config.yaml"
    if [[ -f "$genesis_msp" ]]; then
        if grep -q 'kubeconfig: "{{ org.k8s.config_file }}"' "$genesis_msp"; then
            sed -i 's|kubeconfig: "{{ org.k8s.config_file }}"|kubeconfig: "{{ organization.k8s.config_file }}"|g' "$genesis_msp"
            log_success "  [2] Fixed cross-cluster kubeconfig in genesis get_peer_msp_config."
            patched=$((patched + 1))
        else
            log_info "  [2] Genesis get_peer_msp_config kubeconfig fix already applied."
        fi
    fi

    # =========================================================================
    # Fix 3: Cross-cluster kubeconfig in genesis get_certificates.yaml
    # Same issue as Fix 2 - admin MSP secret lookup needs peer org kubeconfig.
    # =========================================================================
    local genesis_certs="${bevel_dir}/platforms/hyperledger-fabric/configuration/roles/create/genesis/tasks/get_certificates.yaml"
    if [[ -f "$genesis_certs" ]]; then
        if grep -q 'kubeconfig: "{{ org.k8s.config_file }}"' "$genesis_certs"; then
            sed -i 's|kubeconfig: "{{ org.k8s.config_file }}"|kubeconfig: "{{ organization.k8s.config_file }}"|g' "$genesis_certs"
            log_success "  [3] Fixed cross-cluster kubeconfig in genesis get_certificates."
            patched=$((patched + 1))
        else
            log_info "  [3] Genesis get_certificates kubeconfig fix already applied."
        fi
    fi

    # =========================================================================
    # Fix 4: Duplicate register: bug in check/setup role
    # YAML allows duplicate keys but keeps only last - register: vault_result
    # was overwritten by a later register: causing 'undefined' errors.
    # =========================================================================
    local check_setup="${bevel_dir}/platforms/shared/configuration/roles/check/setup/tasks/main.yaml"
    if [[ -f "$check_setup" ]]; then
        local reg_count
        reg_count=$(grep -c "register:" "$check_setup" 2>/dev/null || echo "0")
        if (( reg_count > 2 )); then
            if grep -A1 'until: vault_result.failed' "$check_setup" | grep -q 'register:'; then
                sed -i '/until: vault_result.failed == False/{n;/register:/d}' "$check_setup"
                log_success "  [4] Fixed duplicate register bug in check/setup role."
                patched=$((patched + 1))
            fi
        else
            log_info "  [4] check/setup duplicate register fix already applied."
        fi
    fi

    # =========================================================================
    # Fix 5: Duplicate register: bug in check/k8_component role
    # Same pattern - duplicate register: overwrites component_data.
    # =========================================================================
    local check_k8="${bevel_dir}/platforms/shared/configuration/roles/check/k8_component/tasks/main.yaml"
    if [[ -f "$check_k8" ]]; then
        if grep -q 'register: retry_result' "$check_k8" || grep -q 'register: sa_retry_result' "$check_k8"; then
            sed -i '/register: retry_result/d; /register: sa_retry_result/d' "$check_k8"
            # Fix debug task references to use component_data instead
            sed -i 's/retry_result\.failed/component_data.failed/g; s/sa_retry_result\.failed/component_data.failed/g' "$check_k8"
            log_success "  [5] Fixed duplicate register bug in check/k8_component role."
            patched=$((patched + 1))
        else
            log_info "  [5] check/k8_component duplicate register fix already applied."
        fi
    fi

    # =========================================================================
    # Fix 6: Undefined variable references in check/helm_component role
    # References to non-existent job_retry_result and pod_retry_result.
    # Also add safety checks for component_data.resources.
    # =========================================================================
    local check_helm="${bevel_dir}/platforms/shared/configuration/roles/check/helm_component/tasks/main.yaml"
    if [[ -f "$check_helm" ]]; then
        if grep -q 'job_retry_result\|pod_retry_result' "$check_helm"; then
            sed -i 's/job_retry_result\.failed/component_data.failed/g; s/pod_retry_result\.failed/component_data.failed/g' "$check_helm"
            log_success "  [6] Fixed undefined variable references in check/helm_component."
            patched=$((patched + 1))
        else
            log_info "  [6] check/helm_component variable fix already applied."
        fi
        # Add safety checks for component_data.resources in status update task
        if grep -q 'component_data.resources\[0\]' "$check_helm" && ! grep -q 'component_data.resources is defined' "$check_helm"; then
            sed -i '/Status update for job/,/component_data.resources\[0\]/{
                /component_type == "Job"/a\    - component_data is defined\n    - component_data.resources is defined
            }' "$check_helm"
            log_success "  [6b] Added safety checks for component_data.resources."
            patched=$((patched + 1))
        fi
    fi

    # =========================================================================
    # Fix 7: bevel_alpine_version and fabric_tools_image nested under charts dict
    # These vars must be top-level in job_component/vars/main.yaml, not under charts:.
    # =========================================================================
    local job_vars="${bevel_dir}/platforms/shared/configuration/roles/create/job_component/vars/main.yaml"
    if [[ -f "$job_vars" ]]; then
        # Check if bevel_alpine_version is indented (under charts:)
        if grep -q '^  bevel_alpine_version:' "$job_vars" && ! grep -q '^bevel_alpine_version:' "$job_vars"; then
            # Move to top-level by removing indented version and adding at end
            local alpine_ver fabric_tools
            alpine_ver=$(grep 'bevel_alpine_version:' "$job_vars" | sed 's/.*bevel_alpine_version: *//')
            fabric_tools=$(grep 'fabric_tools_image:' "$job_vars" | sed 's/.*fabric_tools_image: *//')
            sed -i '/bevel_alpine_version:/d; /fabric_tools_image:/d' "$job_vars"
            echo "" >> "$job_vars"
            echo "bevel_alpine_version: ${alpine_ver}" >> "$job_vars"
            echo "fabric_tools_image: ${fabric_tools}" >> "$job_vars"
            log_success "  [7] Moved bevel_alpine_version and fabric_tools_image to top-level."
            patched=$((patched + 1))
        else
            log_info "  [7] job_component vars already at top-level."
        fi
    fi

    # =========================================================================
    # Fix 8: StorageClass templates - use K3s-compatible defaults
    # Templates hardcode minikube-hostpath provisioner and Immediate binding.
    # K3s needs rancher.io/local-path and WaitForFirstConsumer.
    # =========================================================================
    if is_k3s; then
        local templates=(
            "${bevel_dir}/platforms/hyperledger-fabric/configuration/roles/helm_component/templates/ca-server.tpl"
            "${bevel_dir}/platforms/hyperledger-fabric/configuration/roles/helm_component/templates/value_peer.tpl"
            "${bevel_dir}/platforms/hyperledger-fabric/configuration/roles/helm_component/templates/orderernode.tpl"
        )
        for tpl in "${templates[@]}"; do
            if [[ -f "$tpl" ]]; then
                local tpl_changed=0
                if grep -q 'volumeBindingMode:' "$tpl" && grep -q 'Immediate\|""' "$tpl"; then
                    sed -i 's/volumeBindingMode: .*/volumeBindingMode: WaitForFirstConsumer/' "$tpl"
                    tpl_changed=1
                fi
                if grep -q 'provisioner:' "$tpl"; then
                    sed -i 's|provisioner: .*|provisioner: "rancher.io/local-path"|' "$tpl"
                    tpl_changed=1
                fi
                if (( tpl_changed )); then
                    log_success "  [8] Fixed StorageClass in template: $(basename "$tpl")"
                    patched=$((patched + 1))
                fi
            fi
        done
    fi

    # =========================================================================
    # Fix 9: create-join-channel.yaml references non-existent roles
    # Remove create/crypto/orderer, create/crypto/peer, create/configtx,
    # create/channel_artifacts roles. Use create/osnchannels for Fabric 2.3+.
    # =========================================================================
    local channel_playbook="${bevel_dir}/platforms/hyperledger-fabric/configuration/create-join-channel.yaml"
    if [[ -f "$channel_playbook" ]]; then
        if grep -q 'create/crypto/orderer\|create/configtx\|create/channel_artifacts' "$channel_playbook"; then
            cat > "$channel_playbook" << 'PLAYBOOK_EOF'
##############################################################################################
#  Copyright Accenture. All Rights Reserved.
#
#  SPDX-License-Identifier: Apache-2.0
##############################################################################################

# This playbook is a subsequent playbook
##########################################################################################
# DO NOT RUN THIS IF YOU HAVE NOT RUN deploy-network.yaml and deployed the Fabric network
##########################################################################################
# This playbook can only be run after all pods and orderers are available
# Please use the same network.yaml to run this playbook as used for deploy-network.yaml
---
  # This will apply to ansible_provisioners. /etc/ansible/hosts should be configured with this group
- hosts: ansible_provisioners
  gather_facts: no
  no_log: "{{ no_ansible_log | default(false) }}"
  tasks:
    # Step 1: Create channel using OSN admin API (Fabric 2.3+)
    - name: Create channel using OSN admin
      include_role:
        name: "create/osnchannels"
      vars:
        build_path: "./build"
        docker_url: "{{ network.docker.url }}"
      loop: "{{ network['channels'] }}"
      when: item.channel_status == 'new'

    # Step 2: Join peers to the channel
    - name: Join peers to channel
      include_role:
        name: "create/channels_join"
      vars:
        build_path: "./build"
        docker_url: "{{ network.docker.url }}"
        participants: "{{ item.participants }}"
      loop: "{{ network['channels'] }}"
      when: item.channel_status == 'new'

    # delete build directory
    - name: Remove build directory
      file:
        path: "./build"
        state: absent
  vars: #These variables can be overriden from the command line
    privilege_escalate: false           #Default to NOT escalate to root privledges
    install_os: "linux"                 #Default to linux OS
    install_arch:  "amd64"              #Default to amd64 architecture
    bin_install_dir:  "~/bin"            #Default to /bin install directory for binaries
PLAYBOOK_EOF
            log_success "  [9] Fixed create-join-channel.yaml to use osnchannels for Fabric 2.3+."
            patched=$((patched + 1))
        else
            log_info "  [9] create-join-channel.yaml already fixed."
        fi
    fi

    # =========================================================================
    # Commit and push all patches
    # =========================================================================
    if (( patched > 0 )); then
        log_success "Applied ${patched} Bevel source patches."
        cd "$bevel_dir" || return 0
        if git diff --quiet 2>/dev/null; then
            log_info "No uncommitted changes to push."
        else
            git add -A
            git commit -m "Auto-fix: Bevel multi-cluster and K3s compatibility patches (${patched} fixes)" 2>/dev/null || true
            git push origin main 2>/dev/null || log_warning "Could not push Bevel patches to git."
        fi
        cd - >/dev/null 2>&1 || true
    else
        log_info "No Bevel source patches needed - all fixes already applied."
    fi
}

# ---------------------------------------------------------------------------
# Pre-pull peer images on remote org PCs (PC2/PC3) via SSH.
# This avoids ImagePullBackOff on org clusters when ghcr.io requires auth.
# Falls back gracefully: generates a helper script if SSH is not configured.
# ---------------------------------------------------------------------------
_prepull_images_on_remote_pcs() {
    local fabric_version docker_url
    fabric_version=$(load_config_var "FABRIC_VERSION" "2.5.4")
    # Auto-select registry: v3.x → custom (no official bevel v3 images), v2.x → official
    local docker_url_default="ghcr.io/hyperledger"
    [[ "$fabric_version" == 3.* ]] && docker_url_default="ghcr.io/niravchangelavhits-blockchain-dev"
    docker_url=$(load_config_var "DOCKER_URL" "$docker_url_default")
    local pc2_ip pc3_ip
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    # Build the list of images needed on org (peer) clusters
    # CouchDB has no v3.x image; use 2.5.4 for all versions
    local couchdb_tag="${fabric_version}"
    [[ "${fabric_version}" == 3.* ]] && couchdb_tag="2.5.4"

    local peer_images=(
        "${docker_url}/bevel-fabric-ca:latest"
        "${docker_url}/bevel-alpine:latest"
        "${docker_url}/bevel-fabric-peer:${fabric_version}"
        "${docker_url}/bevel-fabric-tools:${fabric_version}"
        "${docker_url}/bevel-fabric-couchdb:${couchdb_tag}"
        "ghcr.io/hyperledger-labs/grpc-web:latest"
    )

    # Write a self-contained helper script the user can copy to PC2/PC3
    local helper_script="/tmp/bevel-prepull-peer-images.sh"
    {
        echo "#!/usr/bin/env bash"
        echo "# Run on PC2 and PC3 to pre-pull Bevel peer images before deployment"
        echo "set -e"
        for img in "${peer_images[@]}"; do
            echo "echo 'Pulling ${img}...'"
            echo "sudo k3s ctr images pull '${img}' 2>/dev/null || \\"
            echo "  (docker pull '${img}' &>/dev/null && \\"
            echo "   docker save '${img}' | sudo k3s ctr images import -) || \\"
            echo "  echo 'WARNING: Could not pull ${img}'"
        done
        echo "echo 'Done.'"
    } > "$helper_script"
    chmod +x "$helper_script"

    log_step "Pre-pulling Bevel images on remote org clusters (PC2/PC3)..."

    local -a ssh_keys=()
    for key in ~/.ssh/id_ed25519 ~/.ssh/id_rsa ~/.ssh/id_ecdsa; do
        [[ -f "$key" ]] && ssh_keys+=("$key")
    done

    for host_pair in "${pc2_ip}:PC2" "${pc3_ip}:PC3"; do
        local host="${host_pair%%:*}"
        local label="${host_pair##*:}"
        [[ -z "$host" ]] && continue

        local ssh_ok=false
        for key in "${ssh_keys[@]}"; do
            if ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
               -o BatchMode=yes -o IdentitiesOnly=yes \
               "vhits@${host}" "true" 2>/dev/null; then
                log_info "  SSH reachable: ${host} (${label}) — running image pre-pull..."
                ssh -i "$key" -o StrictHostKeyChecking=no -o BatchMode=yes \
                    -o IdentitiesOnly=yes "vhits@${host}" \
                    "bash -s" < "$helper_script" 2>&1 | \
                    while IFS= read -r line; do log_info "    [${label}] ${line}"; done
                ssh_ok=true
                break
            fi
        done
        if ! $ssh_ok; then
            log_warning "  Cannot SSH to ${label} (${host}). Copy and run on ${label}:"
            log_warning "    bash ${helper_script}"
        fi
    done

    log_info "  Helper script saved: ${helper_script}"
}

# ---------------------------------------------------------------------------
# Apply all K3s fixes on all clusters (called from controller)
# ---------------------------------------------------------------------------
apply_all_k3s_fixes() {
    local distro
    distro=$(detect_k8s_distro)

    # Always patch Bevel source bugs (these are Bevel bugs, not K3s-specific)
    patch_bevel_source_bugs

    if [[ "$distro" == "minikube" ]]; then
        log_header "PHASE 9.0: K8s Compatibility Check"
        log_success "Minikube detected - no K3s fixes needed."
        log_info "Bevel natively supports minikube (StorageClass, ingress, etc.)."
        return 0
    fi

    if [[ "$distro" != "k3s" ]]; then
        log_header "PHASE 9.0: K8s Compatibility Check"
        log_warning "Unknown K8s distribution detected: ${distro}"
        log_warning "K3s fixes will be skipped. You may need to manually configure:"
        log_warning "  - StorageClass provisioner"
        log_warning "  - Ingress controller and IngressClass"
        if ! ask_confirm "Continue without K3s fixes?"; then
            return 1
        fi
        return 0
    fi

    log_header "PHASE 9.0: K3s Compatibility Fixes"
    log_info "K3s detected. Applying fixes for Bevel compatibility..."

    local kc_orderer kc_org1 kc_org2
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2")

    # Fix Traefik/HAProxy conflict + IngressClass on all clusters
    for pair in "$kc_orderer:orderer-cluster" "$kc_org1:org1-cluster" "$kc_org2:org2-cluster"; do
        local kc="${pair%%:*}"
        local name="${pair##*:}"
        if [[ -n "$kc" ]] && [[ -f "$kc" ]]; then
            apply_k3s_fixes_for_cluster "$kc" "$name"
        fi
    done

    # Pre-pull images on local machine (orderer cluster)
    prepull_bevel_images "" "local"

    # Pre-pull peer images on remote org clusters (PC2/PC3) via SSH
    _prepull_images_on_remote_pcs

    log_success "All K3s compatibility fixes applied."
}

# ---------------------------------------------------------------------------
# Monitor and auto-fix common deployment issues
# Watches for ImagePullBackOff, CrashLoopBackOff, Pending pods
# ---------------------------------------------------------------------------
monitor_and_fix_deployment() {
    local kubeconfig="$1"
    local namespace="$2"
    local cluster_name="$3"
    local max_wait="${4:-300}"  # default 5 minutes

    log_info "Monitoring ${namespace} on ${cluster_name} for issues (up to ${max_wait}s)..."

    local start_time
    start_time=$(date +%s)

    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if (( elapsed > max_wait )); then
            log_warning "Monitoring timeout reached for ${namespace} on ${cluster_name}."
            return 0
        fi

        local pod_status
        pod_status=$(kubectl --kubeconfig "$kubeconfig" get pods -n "$namespace" \
            --no-headers 2>/dev/null)

        # Check for ImagePullBackOff
        if echo "$pod_status" | grep -q "ImagePullBackOff\|ErrImagePull"; then
            local bad_images
            bad_images=$(kubectl --kubeconfig "$kubeconfig" get pods -n "$namespace" \
                -o jsonpath='{range .items[?(@.status.containerStatuses)]}{range .status.containerStatuses[?(@.state.waiting.reason=="ImagePullBackOff")]}{.image}{"\n"}{end}{end}' 2>/dev/null | sort -u)
            if [[ -n "$bad_images" ]]; then
                log_warning "ImagePullBackOff detected on ${cluster_name}. Attempting to import images..."
                while IFS= read -r img; do
                    if [[ -n "$img" ]]; then
                        log_info "  Importing: ${img}"
                        sudo k3s ctr images pull "$img" 2>/dev/null || {
                            if command -v docker &>/dev/null; then
                                docker pull "$img" 2>/dev/null && {
                                    local tmptar="/tmp/$(echo "$img" | tr '/:' '_').tar"
                                    docker save "$img" -o "$tmptar" 2>/dev/null
                                    sudo k3s ctr images import "$tmptar" 2>/dev/null
                                    rm -f "$tmptar"
                                }
                            fi
                        }
                    fi
                done <<< "$bad_images"
                # Delete the failing pods so they restart
                kubectl --kubeconfig "$kubeconfig" delete pods -n "$namespace" \
                    --field-selector=status.phase!=Running --force 2>/dev/null || true
            fi
        fi

        # Check if all pods are ready
        local not_ready
        not_ready=$(echo "$pod_status" | grep -v "Running\|Completed" | grep -v "^$" | wc -l)
        if (( not_ready == 0 )); then
            log_success "All pods in ${namespace} on ${cluster_name} are healthy."
            return 0
        fi

        sleep 10
    done
}
