#!/usr/bin/env bash
# =============================================================================
# cleanup.sh - Clear and full-reset functions for Bevel network
#
# --clear:     Remove all deployments and state, keep prerequisites
# --clear-all: Remove deployments, state, AND most tools
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Helper: Clean K8s resources on a single cluster
# ---------------------------------------------------------------------------
_clean_k8s_cluster() {
    local kubeconfig="$1"
    local cluster_name="$2"

    if [[ -z "$kubeconfig" ]] || [[ ! -f "$kubeconfig" ]]; then
        log_warning "Kubeconfig not found for ${cluster_name}, skipping."
        return 0
    fi

    # Test connectivity
    if ! kubectl --kubeconfig "$kubeconfig" cluster-info &>/dev/null; then
        log_warning "Cannot reach ${cluster_name}, skipping K8s cleanup."
        return 0
    fi

    log_step "Cleaning K8s resources on ${cluster_name}..."

    # 1. Uninstall monitoring helm releases BEFORE deleting namespaces
    #    (helm uninstall cleans up ClusterRoles, CRDs, webhooks that survive ns deletion)
    for mon_ns in "monitoring" "central-monitoring"; do
        local mon_releases
        mon_releases=$(helm --kubeconfig "$kubeconfig" list -n "$mon_ns" --short 2>/dev/null || true)
        for rel in $mon_releases; do
            log_info "  Uninstalling helm release: ${rel} (ns: ${mon_ns})"
            helm --kubeconfig "$kubeconfig" uninstall "$rel" -n "$mon_ns" --timeout=120s 2>/dev/null || true
        done
    done

    # 1a. Delete Fabric, Vault, and monitoring namespaces (cascades to all resources within)
    local fabric_namespaces=("ordererorg-net" "org1-net" "org2-net" "vault" "ingress-nginx" "monitoring" "central-monitoring")
    for ns in "${fabric_namespaces[@]}"; do
        if kubectl --kubeconfig "$kubeconfig" get ns "$ns" &>/dev/null; then
            log_info "  Deleting namespace: ${ns}"
            kubectl --kubeconfig "$kubeconfig" delete ns "$ns" --ignore-not-found --timeout=120s 2>/dev/null || {
                log_warning "  Namespace ${ns} deletion timed out. Force removing finalizers..."
                kubectl --kubeconfig "$kubeconfig" get ns "$ns" -o json 2>/dev/null | \
                    jq '.spec.finalizers = []' | \
                    kubectl --kubeconfig "$kubeconfig" replace --raw "/api/v1/namespaces/${ns}/finalize" -f - 2>/dev/null || true
            }
        fi
    done

    # 1b. Delete stale ValidatingWebhookConfigurations (ingress-nginx, prometheus, etc.)
    #     These are cluster-scoped and survive namespace deletion, blocking resource admission
    local stale_webhooks
    stale_webhooks=$(kubectl --kubeconfig "$kubeconfig" get validatingwebhookconfiguration --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "ingress-nginx|monitoring|prometheus" || true)
    for wh in $stale_webhooks; do
        log_info "  Deleting stale webhook: ${wh}"
        kubectl --kubeconfig "$kubeconfig" delete validatingwebhookconfiguration "$wh" --ignore-not-found 2>/dev/null || true
    done
    # Also clean MutatingWebhookConfigurations from monitoring
    local stale_mwhooks
    stale_mwhooks=$(kubectl --kubeconfig "$kubeconfig" get mutatingwebhookconfiguration --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "monitoring|prometheus" || true)
    for mwh in $stale_mwhooks; do
        log_info "  Deleting stale mutating webhook: ${mwh}"
        kubectl --kubeconfig "$kubeconfig" delete mutatingwebhookconfiguration "$mwh" --ignore-not-found 2>/dev/null || true
    done

    # 2. Uninstall HAProxy helm release
    if helm --kubeconfig "$kubeconfig" list -n ingress-controller 2>/dev/null | grep -q haproxy; then
        log_info "  Uninstalling HAProxy helm release..."
        helm --kubeconfig "$kubeconfig" uninstall haproxy -n ingress-controller 2>/dev/null || true
    fi
    kubectl --kubeconfig "$kubeconfig" delete ns ingress-controller --ignore-not-found --timeout=60s 2>/dev/null || true

    # 3. Delete Flux: resources, RBAC, CRDs, namespace
    local flux_ns
    flux_ns=$(kubectl --kubeconfig "$kubeconfig" get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "^flux" || true)

    local flux_crds="helmreleases.helm.toolkit.fluxcd.io gitrepositories.source.toolkit.fluxcd.io kustomizations.kustomize.toolkit.fluxcd.io helmcharts.source.toolkit.fluxcd.io helmrepositories.source.toolkit.fluxcd.io buckets.source.toolkit.fluxcd.io ocirepositories.source.toolkit.fluxcd.io receivers.notification.toolkit.fluxcd.io providers.notification.toolkit.fluxcd.io alerts.notification.toolkit.fluxcd.io"

    # 3a. Strip finalizers from ALL Flux custom resources to prevent hanging deletes
    for kind in helmrelease gitrepository kustomization helmchart helmrepository bucket ocirepository receiver provider alert; do
        local items
        items=$(kubectl --kubeconfig "$kubeconfig" get "$kind" -A -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null || true)
        while IFS=' ' read -r rns rname; do
            [[ -z "$rns" ]] && continue
            kubectl --kubeconfig "$kubeconfig" patch "$kind" "$rname" -n "$rns" --type=json \
                -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
        done <<< "$items"
    done

    # 3b. Delete all Flux custom resources
    kubectl --kubeconfig "$kubeconfig" delete helmrelease --all -A --ignore-not-found --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig "$kubeconfig" delete gitrepository --all -A --ignore-not-found --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig "$kubeconfig" delete kustomization --all -A --ignore-not-found --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig "$kubeconfig" delete helmchart --all -A --ignore-not-found --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig "$kubeconfig" delete helmrepository --all -A --ignore-not-found --timeout=30s 2>/dev/null || true

    # 3c. Strip finalizers from CRDs, then delete them
    for crd in $flux_crds; do
        kubectl --kubeconfig "$kubeconfig" patch crd "$crd" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    done
    kubectl --kubeconfig "$kubeconfig" delete crd $flux_crds --ignore-not-found --timeout=60s 2>/dev/null || true

    # 3d. Delete Flux ClusterRoles and ClusterRoleBindings
    local flux_crbs
    flux_crbs=$(kubectl --kubeconfig "$kubeconfig" get clusterrolebinding --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "flux" || true)
    for crb in $flux_crbs; do
        kubectl --kubeconfig "$kubeconfig" delete clusterrolebinding "$crb" --ignore-not-found 2>/dev/null || true
    done
    local flux_crs
    flux_crs=$(kubectl --kubeconfig "$kubeconfig" get clusterrole --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "flux" || true)
    for cr in $flux_crs; do
        kubectl --kubeconfig "$kubeconfig" delete clusterrole "$cr" --ignore-not-found 2>/dev/null || true
    done

    # 3e. Delete Flux namespace(s) last
    for ns in $flux_ns; do
        log_info "  Deleting Flux namespace: ${ns}"
        kubectl --kubeconfig "$kubeconfig" delete ns "$ns" --ignore-not-found --timeout=120s 2>/dev/null || true
    done

    # 4. Delete Bevel StorageClasses
    local scs
    scs=$(kubectl --kubeconfig "$kubeconfig" get sc --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep "^storage-" || true)
    for sc in $scs; do
        log_info "  Deleting StorageClass: ${sc}"
        kubectl --kubeconfig "$kubeconfig" delete sc "$sc" --ignore-not-found 2>/dev/null || true
    done

    # 5. Delete Bevel and monitoring ClusterRoleBindings / ClusterRoles
    local crbs
    crbs=$(kubectl --kubeconfig "$kubeconfig" get clusterrolebinding --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "ordererorg|org1|org2|bevel|vault|monitoring|prometheus|kube-state-metrics|grafana" || true)
    for crb in $crbs; do
        log_info "  Deleting ClusterRoleBinding: ${crb}"
        kubectl --kubeconfig "$kubeconfig" delete clusterrolebinding "$crb" --ignore-not-found 2>/dev/null || true
    done
    local mon_crs
    mon_crs=$(kubectl --kubeconfig "$kubeconfig" get clusterrole --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "monitoring|prometheus|kube-state-metrics|grafana" || true)
    for cr in $mon_crs; do
        log_info "  Deleting ClusterRole: ${cr}"
        kubectl --kubeconfig "$kubeconfig" delete clusterrole "$cr" --ignore-not-found 2>/dev/null || true
    done

    # 5b. Delete Prometheus CRDs (survive namespace deletion)
    local prom_crds
    prom_crds=$(kubectl --kubeconfig "$kubeconfig" get crd --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "monitoring\.coreos\.com" || true)
    for crd in $prom_crds; do
        log_info "  Deleting Prometheus CRD: ${crd}"
        kubectl --kubeconfig "$kubeconfig" delete crd "$crd" --ignore-not-found --timeout=30s 2>/dev/null || true
    done

    # 6. Delete Released and Failed PVs
    kubectl --kubeconfig "$kubeconfig" delete pv --field-selector=status.phase=Released --ignore-not-found 2>/dev/null || true
    kubectl --kubeconfig "$kubeconfig" delete pv --field-selector=status.phase=Failed --ignore-not-found 2>/dev/null || true

    # 7. Delete IngressClass
    kubectl --kubeconfig "$kubeconfig" delete ingressclass haproxy --ignore-not-found 2>/dev/null || true

    log_success "K8s cleanup done on ${cluster_name}."
}

# ---------------------------------------------------------------------------
# Helper: Clean firewall rules added by Bevel setup
# ---------------------------------------------------------------------------
_clean_firewall() {
    local mode="${1:-soft}"  # "soft" = remove Bevel rules, keep SSH; "hard" = reset UFW

    if ! command -v ufw &>/dev/null; then
        return 0
    fi

    log_step "Cleaning firewall rules..."

    if [[ "$mode" == "hard" ]]; then
        # Full reset - disable UFW entirely
        log_info "  Resetting UFW to defaults..."
        echo "y" | sudo ufw reset 2>/dev/null || true
        sudo ufw disable 2>/dev/null || true
        log_success "UFW reset and disabled."
        return 0
    fi

    # Soft mode: remove Bevel-specific rules, keep SSH
    # Delete rules by comment matching Bevel-related services
    local bevel_comments=(
        "Kubernetes API"
        "HAProxy HTTP"
        "HAProxy HTTPS"
        "Fabric gRPC"
        "Kubernetes NodePort"
        "HashiCorp Vault"
        "Kubelet API"
        "K3s Flannel"
        "K3s Wireguard"
        "Prometheus"
        "Grafana"
        "Central Prometheus"
        "Central Grafana"
    )

    # Get numbered rules and delete Bevel-related ones (delete from bottom to top to preserve numbers)
    local rules_to_delete=()
    local rule_num=0
    while IFS= read -r line; do
        rule_num=$((rule_num + 1))
        for comment in "${bevel_comments[@]}"; do
            if echo "$line" | grep -qi "$comment"; then
                rules_to_delete+=("$rule_num")
                break
            fi
        done
    done < <(sudo ufw status numbered 2>/dev/null | grep -E "^\[" | sed 's/\[//;s/\]//')

    # Also delete rules that allow from specific PC IPs
    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP" "")
    pc2_ip=$(load_config_var "PC2_IP" "")
    pc3_ip=$(load_config_var "PC3_IP" "")

    # Delete in reverse order to preserve rule numbers
    for (( i=${#rules_to_delete[@]}-1; i>=0; i-- )); do
        echo "y" | sudo ufw delete "${rules_to_delete[$i]}" 2>/dev/null || true
    done

    # Delete IP-based allow rules for other PCs
    for ip in "$pc1_ip" "$pc2_ip" "$pc3_ip"; do
        if [[ -n "$ip" ]]; then
            sudo ufw delete allow from "$ip" 2>/dev/null || true
        fi
    done

    # Delete by port (in case comments don't match)
    local bevel_ports=("6443/tcp" "80/tcp" "443/tcp" "8200/tcp" "10250/tcp" "8472/udp" "51820/udp" "51821/udp" "30090/tcp" "30300/tcp" "31090/tcp" "31300/tcp")
    for port in "${bevel_ports[@]}"; do
        sudo ufw delete allow "$port" 2>/dev/null || true
    done
    # NodePort range
    sudo ufw delete allow 30000:32767/tcp 2>/dev/null || true

    log_success "Bevel firewall rules removed. SSH (port 22) preserved."
}

# ---------------------------------------------------------------------------
# Helper: Clean DNS entries
# ---------------------------------------------------------------------------
_clean_dns() {
    log_step "Cleaning DNS entries..."

    # Remove Bevel entries from /etc/hosts
    if grep -q "# Bevel" /etc/hosts 2>/dev/null || grep -q "nirav.com\|jigs.com\|rashmi.com" /etc/hosts 2>/dev/null; then
        log_info "  Removing Bevel entries from /etc/hosts..."
        sudo sed -i '/# Bevel/d; /# Added by bevel/d' /etc/hosts 2>/dev/null || true
        sudo sed -i '/nirav\.com/d; /jigs\.com/d; /rashmi\.com/d' /etc/hosts 2>/dev/null || true
        sudo sed -i '/ordererorg-net/d; /org1-net/d; /org2-net/d' /etc/hosts 2>/dev/null || true
    fi

    # Revert CoreDNS on local cluster
    local local_kc
    local_kc=$(load_config_var "KUBECONFIG_LOCAL" "")
    if [[ -z "$local_kc" ]]; then
        # Try to find local kubeconfig
        local role
        role=$(load_config_var "ROLE" "")
        local_kc=$(load_config_var "KUBECONFIG_${role^^}" "")
    fi

    if [[ -n "$local_kc" ]] && [[ -f "$local_kc" ]]; then
        log_info "  Resetting CoreDNS to default..."
        kubectl --kubeconfig "$local_kc" -n kube-system rollout restart deployment coredns 2>/dev/null || true
    fi

    log_success "DNS cleanup done."
}

# ---------------------------------------------------------------------------
# Helper: Clean local files
# ---------------------------------------------------------------------------
_clean_local_files() {
    log_step "Cleaning local files..."

    # Bevel setup directory
    if [[ -d "${HOME}/.bevel-setup" ]]; then
        log_info "  Removing ~/.bevel-setup/"
        rm -rf "${HOME}/.bevel-setup"
    fi

    # Bevel git repo
    if [[ -d "${HOME}/bevel" ]]; then
        log_info "  Removing ~/bevel/"
        rm -rf "${HOME}/bevel"
    fi

    # Kubeconfigs for remote clusters
    for kc in orderer-cluster.yaml org1-cluster.yaml org2-cluster.yaml; do
        if [[ -f "${HOME}/.kube/${kc}" ]]; then
            log_info "  Removing ~/.kube/${kc}"
            rm -f "${HOME}/.kube/${kc}"
        fi
    done

    # SSH keys created for GitOps
    for key in gitops gitops.pub block-git block-git.pub; do
        if [[ -f "${HOME}/.ssh/${key}" ]]; then
            log_info "  Removing ~/.ssh/${key}"
            rm -f "${HOME}/.ssh/${key}"
        fi
    done

    # Chaincode package and Explorer config temp files
    rm -f /tmp/asset-transfer.tar.gz 2>/dev/null || true
    rm -rf /tmp/explorer-certs /tmp/explorer-config 2>/dev/null || true

    log_success "Local files cleanup done."
}

# ---------------------------------------------------------------------------
# run_clear: Soft reset - remove deployments/state, keep prerequisites
# ---------------------------------------------------------------------------
run_clear() {
    log_header "CLEAR: Remove All Deployments & State"
    echo -e "${YELLOW}This will:${NC}"
    echo "  - Delete all Fabric K8s namespaces and resources"
    echo "  - Uninstall monitoring (Prometheus/Grafana) from clusters"
    echo "  - Delete Flux and HAProxy from clusters"
    echo "  - Stop Vault dev server"
    echo "  - Remove ~/.bevel-setup/, ~/bevel/, kubeconfigs, SSH keys"
    echo "  - Clean /etc/hosts entries"
    echo ""
    echo -e "${GREEN}Preserved:${NC} K3s, Docker, Helm, kubectl, Vault binary, jq, yq, git, Node.js, ansible venv"
    echo ""

    if ! ask_confirm "Proceed with clearing all deployments?" "n"; then
        log_info "Clear cancelled."
        return 0
    fi

    # Ask scope
    local scope
    scope=$(ask_choice "What to clean?" \
        "This PC only" \
        "All clusters (if kubeconfigs available)")

    # Load config before deleting it
    local kc_orderer="" kc_org1="" kc_org2="" role=""
    local vault_url_orderer="" vault_token_orderer=""
    local vault_url_org1="" vault_token_org1="" vault_url_org2="" vault_token_org2=""
    if [[ -f "${HOME}/.bevel-setup/config.env" ]]; then
        role=$(load_config_var "ROLE" "")                             || true
        kc_orderer=$(load_config_var "KUBECONFIG_ORDERER" "")        || true
        kc_org1=$(load_config_var "KUBECONFIG_ORG1" "")              || true
        kc_org2=$(load_config_var "KUBECONFIG_ORG2" "")              || true
        vault_url_orderer=$(load_config_var "VAULT_URL_ORDERER" "")  || true
        vault_token_orderer=$(load_config_var "VAULT_TOKEN_ORDERER" "") || true
        vault_url_org1=$(load_config_var "VAULT_URL_ORG1" "")        || true
        vault_token_org1=$(load_config_var "VAULT_TOKEN_ORG1" "")    || true
        vault_url_org2=$(load_config_var "VAULT_URL_ORG2" "")        || true
        vault_token_org2=$(load_config_var "VAULT_TOKEN_ORG2" "")    || true
    fi

    # Step 1: Clear ALL org Vaults then stop local Vault.
    # ordererorg Vault is local (PC1) — must be cleared BEFORE stopping the process.
    # org1/org2 Vaults are remote (PC2/PC3) — cleared after local Vault is stopped.
    log_step "Clearing all Vault data (ordererorg, org1, org2)..."
    _clear_org_vault "ordererorg" "$vault_url_orderer" "$vault_token_orderer"
    _clear_org_vault "org1"       "$vault_url_org1"    "$vault_token_org1"
    _clear_org_vault "org2"       "$vault_url_org2"    "$vault_token_org2"

    log_step "Stopping local Vault dev server..."
    pkill -f "vault server" 2>/dev/null || true
    sleep 1
    log_success "Local Vault stopped."

    # Step 2: Clean K8s
    if [[ "$scope" == "1" ]]; then
        # All clusters
        [[ -n "$kc_orderer" ]] && _clean_k8s_cluster "$kc_orderer" "orderer-cluster"
        [[ -n "$kc_org1" ]] && _clean_k8s_cluster "$kc_org1" "org1-cluster"
        [[ -n "$kc_org2" ]] && _clean_k8s_cluster "$kc_org2" "org2-cluster"
    else
        # Local only - find local kubeconfig
        local local_kc=""
        case "$role" in
            orderer) local_kc="$kc_orderer" ;;
            org1)    local_kc="$kc_org1" ;;
            org2)    local_kc="$kc_org2" ;;
        esac
        if [[ -z "$local_kc" ]]; then
            # Fallback: try default K3s kubeconfig
            local_kc="/etc/rancher/k3s/k3s.yaml"
        fi
        [[ -n "$local_kc" ]] && _clean_k8s_cluster "$local_kc" "local-cluster"
    fi

    # Step 3: Clean firewall rules (soft - remove Bevel rules, keep SSH)
    _clean_firewall "soft"

    # Step 4: Clean DNS
    _clean_dns

    # Step 5: Clean local files
    _clean_local_files

    log_header "CLEAR COMPLETE"
    echo -e "${GREEN}${BOLD}All deployments and state have been removed.${NC}"
    echo ""
    if [[ "$scope" == "1" ]]; then
        echo -e "${YELLOW}${BOLD}IMPORTANT:${NC} K8s resources were cleaned on all clusters, but local"
        echo "state files (~/.bevel-setup/) were only removed on THIS PC."
        echo ""
        echo "You MUST also run on each other PC:"
        echo "  ./1-per-pc-setup.sh --clear    (select 'This PC only')"
        echo ""
        echo "Or at minimum, remove stale state:"
        echo "  rm -rf ~/.bevel-setup/"
        echo ""
    fi
    echo "Prerequisites are still installed. To redeploy, run:"
    echo "  ./1-per-pc-setup.sh"
    echo ""
    echo "To remove ALL tools too, use: ./1-per-pc-setup.sh --clear-all"
}

# ---------------------------------------------------------------------------
# run_clear_all: Full reset - remove everything except Docker, K3s, Node.js,
#                kubectl, jq, yq, git, python3
# ---------------------------------------------------------------------------
run_clear_all() {
    log_header "CLEAR ALL: Full System Reset"
    echo -e "${RED}${BOLD}WARNING: This will remove almost everything!${NC}"
    echo ""
    echo -e "${YELLOW}Will REMOVE:${NC}"
    echo "  - All Fabric K8s namespaces, Flux, HAProxy"
    echo "  - Helm binary"
    echo "  - Vault binary and configuration"
    echo "  - Ansible virtual environment (~/bevel-venv/)"
    echo "  - All Bevel state, config, git repo"
    echo ""
    echo -e "${GREEN}Will KEEP:${NC} Docker, K3s, Node.js, kubectl, jq, yq, git, python3"
    echo ""

    if ! ask_confirm "This is IRREVERSIBLE. Proceed with full cleanup?" "n"; then
        log_info "Clear-all cancelled."
        return 0
    fi

    # Load config before deleting it
    local kc_orderer="" kc_org1="" kc_org2=""
    local vault_url_orderer="" vault_token_orderer=""
    local vault_url_org1="" vault_token_org1="" vault_url_org2="" vault_token_org2=""
    if [[ -f "${HOME}/.bevel-setup/config.env" ]]; then
        kc_orderer=$(load_config_var "KUBECONFIG_ORDERER" "")          || true
        kc_org1=$(load_config_var "KUBECONFIG_ORG1" "")                || true
        kc_org2=$(load_config_var "KUBECONFIG_ORG2" "")                || true
        vault_url_orderer=$(load_config_var "VAULT_URL_ORDERER" "")    || true
        vault_token_orderer=$(load_config_var "VAULT_TOKEN_ORDERER" "") || true
        vault_url_org1=$(load_config_var "VAULT_URL_ORG1" "")          || true
        vault_token_org1=$(load_config_var "VAULT_TOKEN_ORG1" "")      || true
        vault_url_org2=$(load_config_var "VAULT_URL_ORG2" "")          || true
        vault_token_org2=$(load_config_var "VAULT_TOKEN_ORG2" "")      || true
    fi

    # Step 1: Clear ALL org Vaults then stop local Vault.
    # ordererorg Vault is local (PC1) — must be cleared BEFORE stopping the process.
    # org1/org2 Vaults are remote (PC2/PC3) — can be cleared at any point.
    log_step "Clearing all Vault data (ordererorg, org1, org2)..."
    _clear_org_vault "ordererorg" "$vault_url_orderer" "$vault_token_orderer"
    _clear_org_vault "org1"       "$vault_url_org1"    "$vault_token_org1"
    _clear_org_vault "org2"       "$vault_url_org2"    "$vault_token_org2"

    log_step "Stopping local Vault dev server..."
    pkill -f "vault server" 2>/dev/null || true
    sudo systemctl stop vault 2>/dev/null || true
    sudo systemctl disable vault 2>/dev/null || true
    sleep 1
    log_success "Local Vault stopped."

    # Step 2: Clean all reachable K8s clusters
    [[ -n "$kc_orderer" ]] && _clean_k8s_cluster "$kc_orderer" "orderer-cluster"
    [[ -n "$kc_org1" ]] && _clean_k8s_cluster "$kc_org1" "org1-cluster"
    [[ -n "$kc_org2" ]] && _clean_k8s_cluster "$kc_org2" "org2-cluster"

    # Step 3: Clean firewall rules (soft - remove Bevel rules, keep SSH)
    _clean_firewall "soft"

    # Step 4: Clean DNS
    _clean_dns

    # Step 5: Clean local files
    _clean_local_files

    # Step 6: Remove Helm
    log_step "Removing Helm..."
    if command -v helm &>/dev/null; then
        sudo rm -f "$(which helm)"
        log_success "Helm removed."
    else
        log_info "Helm not found, skipping."
    fi

    # Step 7: Remove Vault binary and config
    log_step "Removing Vault..."
    sudo rm -f /usr/local/bin/vault
    sudo rm -rf /etc/vault.d/ /opt/vault/
    sudo rm -f /etc/systemd/system/vault.service
    sudo systemctl daemon-reload 2>/dev/null || true
    log_success "Vault removed."

    # Step 8: Remove Ansible venv
    log_step "Removing Ansible virtual environment..."
    if [[ -d "${HOME}/bevel-venv" ]]; then
        rm -rf "${HOME}/bevel-venv"
        log_success "Ansible venv removed."
    else
        log_info "Ansible venv not found, skipping."
    fi

    log_header "CLEAR ALL COMPLETE"
    echo -e "${GREEN}${BOLD}Full cleanup done.${NC}"
    echo ""
    echo -e "${GREEN}Still installed:${NC} Docker, K3s, Node.js, kubectl, jq, yq, git, python3"
    echo ""
    echo "To start fresh, run: ./1-per-pc-setup.sh"
}
