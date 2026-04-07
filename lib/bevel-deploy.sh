#!/usr/bin/env bash
# =============================================================================
# bevel-deploy.sh - Run Ansible playbooks to deploy the Fabric network
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"
# shellcheck disable=SC1091
[[ "$(type -t recover_all_clusters)" != "function" ]] && source "${_LIB_DIR}/health-recovery.sh"

activate_ansible_venv() {
    local venv="${HOME}/bevel-venv"
    if [[ -f "${venv}/bin/activate" ]]; then
        # shellcheck disable=SC1091
        source "${venv}/bin/activate"
        # Ansible requires UTF-8 locale
        export LC_ALL=en_US.UTF-8
        export LANG=en_US.UTF-8
        export LANGUAGE=en_US.UTF-8
        # Set KUBECONFIG so kubectl tests pass
        # (avoids stale minikube/other default configs in ~/.kube/config)
        local role kc_path
        role=$(load_config_var "ROLE")
        kc_path=$(load_config_var "KUBECONFIG_${role^^}")
        if [[ -n "$kc_path" ]] && [[ -f "$kc_path" ]]; then
            export KUBECONFIG="$kc_path"
        elif [[ -f "/etc/rancher/k3s/k3s.yaml" ]] && [[ -r "/etc/rancher/k3s/k3s.yaml" ]]; then
            export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
        fi
        log_info "Ansible venv activated."
    else
        log_error "Ansible venv not found at ${venv}. Run prerequisites first."
        return 1
    fi
}

ensure_ansible_collections() {
    # Check if community.general is installed (needed for npm, helm, k8s modules)
    if ! ansible-galaxy collection list 2>/dev/null | grep -q "community.general"; then
        log_info "Installing required Ansible collections..."
        ansible-galaxy collection install community.general kubernetes.core --force
    fi

    # Install Bevel requirements if available
    local bevel_dir
    bevel_dir=$(load_config_var "BEVEL_DIR" "${HOME}/bevel")
    if [[ -f "${bevel_dir}/platforms/shared/configuration/requirements.yaml" ]]; then
        ansible-galaxy install -r "${bevel_dir}/platforms/shared/configuration/requirements.yaml" 2>/dev/null || true
    fi
}

run_k8s_environment_setup() {
    log_header "PHASE 9.1: K8s Environment Setup (Flux + Ingress)"

    activate_ansible_venv || return 1
    ensure_ansible_collections

    # Ensure npm is installed (Bevel uses it for schema validation via ajv-cli)
    if ! command -v npm &>/dev/null; then
        log_info "Installing Node.js and npm (required for Bevel schema validation)..."
        sudo apt-get install -y nodejs npm 2>/dev/null || {
            curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - && sudo apt-get install -y nodejs
        }
    fi

    local bevel_dir network_yaml
    bevel_dir=$(load_config_var "BEVEL_DIR" "${HOME}/bevel")
    network_yaml=$(load_config_var "NETWORK_YAML")

    if [[ -z "$network_yaml" ]] || [[ ! -f "$network_yaml" ]]; then
        log_error "network.yaml not found. Generate it first."
        return 1
    fi

    log_info "Bevel directory: ${bevel_dir}"
    log_info "network.yaml:    ${network_yaml}"
    log_info "This will install Flux v2, configure namespaces, and set up ingress."
    echo ""

    if ! ask_confirm "Proceed with K8s environment setup?"; then
        log_warning "Skipped K8s environment setup."
        return 0
    fi

    log_info "Running setup-k8s-environment.yaml playbook..."
    log_info "This may take several minutes..."

    cd "$bevel_dir" || { log_error "Cannot cd to ${bevel_dir}"; return 1; }

    # Run with tee for live output
    if ansible-playbook platforms/shared/configuration/setup-k8s-environment.yaml \
        -i platforms/shared/inventory/ansible_provisioners \
        -e "@${network_yaml}" 2>&1 | tee -a "$BEVEL_LOG_FILE"; then
        log_success "K8s environment setup completed successfully!"
    else
        log_error "K8s environment setup failed. Check logs."
        log_info "Log file: ${BEVEL_LOG_FILE}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# _ensure_ca_domain_matches: Detect and clear stale CA certs if domains changed.
#
# Problem: When a user changes external_url_suffix in network.yaml and redeploys
# WITHOUT running --clear, the fabric-ca-server-certs K8s secret persists from
# the previous run (with old domain CN). The ca-certs-init container reuses it
# instead of generating a new cert, causing x509 hostname mismatch in certs-jobs.
#
# Fix: Before running Ansible, compare each org's expected CA CN (from network.yaml)
# against the actual cert CN in the K8s secret. If they differ, delete the stale
# K8s secret AND clear the Vault CA path so the CA regenerates with the right cert.
# ---------------------------------------------------------------------------
_ensure_ca_domain_matches() {
    local network_yaml="$1"

    log_info "Checking for stale CA certs (domain change guard)..."

    local orgs_json
    orgs_json=$(python3 -c "
import yaml, json, sys
try:
    with open('${network_yaml}') as f:
        net = yaml.safe_load(f)
    orgs = []
    for org in net.get('network', {}).get('organizations', []):
        # Include ALL orgs with a CA: orderer orgs (type: orderer) AND peer orgs
        org_type = org.get('type', '').lower()
        is_orderer = (org_type == 'orderer') or ('orderer_org' not in org and org_type == 'orderer')
        is_peer = (org_type == 'peer') or ('orderer_org' in org)
        if is_orderer or is_peer:
            orgs.append({
                'name': org.get('name','').lower(),
                'ext_suffix': org.get('external_url_suffix','')
            })
    print(json.dumps(orgs))
except Exception as e:
    print('[]')
" 2>/dev/null)

    if [[ -z "$orgs_json" ]] || [[ "$orgs_json" == "[]" ]]; then
        log_info "  No orgs found in network.yaml, skipping CA cert check."
        return 0
    fi

    # Parse org list (name and ext_suffix pairs)
    local org_count
    org_count=$(echo "$orgs_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

    for i in $(seq 0 $((org_count - 1))); do
        local org_name ext_suffix
        org_name=$(echo "$orgs_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[${i}]['name'])")
        ext_suffix=$(echo "$orgs_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[${i}]['ext_suffix'])")

        if [[ -z "$org_name" ]] || [[ -z "$ext_suffix" ]]; then
            continue
        fi

        local namespace="${org_name}-net"
        local kubeconfig
        # ordererorg → KUBECONFIG_ORDERER; org1/org2 → KUBECONFIG_ORG1/ORG2
        local kc_key="KUBECONFIG_${org_name^^}"
        [[ -z "$(load_config_var "$kc_key")" ]] && kc_key="KUBECONFIG_ORDERER"
        kubeconfig=$(load_config_var "$kc_key" "")
        local vault_url
        vault_url=$(load_config_var "VAULT_URL_${org_name^^}" "")
        [[ -z "$vault_url" ]] && vault_url=$(load_config_var "VAULT_URL_ORDERER" "")
        local vault_token
        vault_token=$(load_config_var "VAULT_TOKEN_${org_name^^}" "")
        [[ -z "$vault_token" ]] && vault_token=$(load_config_var "VAULT_TOKEN_ORDERER" "")
        local vault_prefix="dev${org_name}"

        if [[ -z "$kubeconfig" ]] || [[ ! -f "$kubeconfig" ]]; then
            log_info "  ${org_name}: kubeconfig not available, skipping."
            continue
        fi

        if ! kubectl --kubeconfig "$kubeconfig" cluster-info &>/dev/null; then
            log_info "  ${org_name}: cluster not reachable, skipping."
            continue
        fi

        # Check if K8s CA cert secret exists
        if ! kubectl --kubeconfig "$kubeconfig" get secret fabric-ca-server-certs \
                -n "$namespace" &>/dev/null; then
            log_info "  ${org_name}: No existing CA cert secret — fresh deployment, OK."
            continue
        fi

        # Extract actual CN from existing K8s secret
        local actual_cn
        actual_cn=$(kubectl --kubeconfig "$kubeconfig" get secret fabric-ca-server-certs \
            -n "$namespace" \
            -o go-template='{{index .data "tls.crt"}}' 2>/dev/null | \
            base64 -d 2>/dev/null | \
            openssl x509 -noout -subject 2>/dev/null | \
            sed 's/.*CN = //' | sed 's/,.*//' || echo "")

        local expected_cn="ca.${namespace}.${ext_suffix}"

        if [[ -z "$actual_cn" ]]; then
            log_info "  ${org_name}: Cannot read CA cert CN (secret may be malformed), skipping."
            continue
        fi

        if [[ "$actual_cn" == "$expected_cn" ]]; then
            log_success "  ${org_name}: CA cert CN matches (${expected_cn}) ✓"
            continue
        fi

        log_warning "  ${org_name}: CA cert domain MISMATCH detected!"
        log_warning "    Expected CN : ${expected_cn}"
        log_warning "    Actual CN   : ${actual_cn}"
        log_info "  Auto-fixing: clearing stale CA cert for ${org_name}..."

        # 1. Delete stale K8s secret so ca-certs-init regenerates it
        kubectl --kubeconfig "$kubeconfig" delete secret fabric-ca-server-certs \
            -n "$namespace" --ignore-not-found 2>/dev/null && \
            log_info "    Deleted stale fabric-ca-server-certs K8s secret on ${org_name}." || true

        # 2. Clear stale CA cert from org Vault (remote PC Vault)
        if [[ -n "$vault_url" ]] && [[ -n "$vault_token" ]]; then
            if VAULT_ADDR="$vault_url" VAULT_TOKEN="$vault_token" vault status &>/dev/null; then
                VAULT_ADDR="$vault_url" VAULT_TOKEN="$vault_token" \
                    vault kv metadata delete secretsv2/${vault_prefix}/ca 2>/dev/null && \
                    log_info "    Cleared stale CA cert from Vault (${vault_url})." || true
            else
                log_info "    Vault at ${vault_url} not reachable yet (expected before CA deploy)."
            fi
        fi

        log_success "  ${org_name}: Stale CA cert cleared. CA will regenerate with '${expected_cn}'."

        # 3. Force-restart CA server pod to ensure it picks up the new domain
        local ca_pod
        ca_pod=$(kubectl --kubeconfig "$kubeconfig" get pods -n "$namespace" \
            -l app=ca --no-headers 2>/dev/null | head -1 | awk '{print $1}')
        if [[ -n "$ca_pod" ]]; then
            kubectl --kubeconfig "$kubeconfig" delete pod "$ca_pod" -n "$namespace" 2>/dev/null && \
                log_info "    Restarted CA server pod (${ca_pod}) to force cert regeneration." || true
        fi
    done

    log_info "CA cert domain check complete."
}

run_site_deployment() {
    log_header "PHASE 9.2: Deploy Fabric Network (site.yaml)"

    activate_ansible_venv || return 1
    ensure_ansible_collections

    local bevel_dir network_yaml
    bevel_dir=$(load_config_var "BEVEL_DIR" "${HOME}/bevel")
    network_yaml=$(load_config_var "NETWORK_YAML")

    if [[ -z "$network_yaml" ]] || [[ ! -f "$network_yaml" ]]; then
        log_error "network.yaml not found."
        return 1
    fi

    log_info "This is the MAIN deployment. It will:"
    echo -e "  1. Generate crypto material (MSP, TLS certs)"
    echo -e "  2. Store crypto in Vault"
    echo -e "  3. Create K8s namespaces"
    echo -e "  4. Deploy CA on each cluster"
    echo -e "  5. Deploy orderers on PC1"
    echo -e "  6. Deploy peers on PC2 and PC3"
    echo -e "  7. Create genesis block"
    echo -e "  8. Create channel"
    echo -e "  9. Join peers to channel"
    echo -e "  10. Set anchor peers"
    echo ""

    if ! ask_confirm "Proceed with full network deployment?"; then
        log_warning "Skipped network deployment."
        return 0
    fi

    # Pre-deployment checks: detect and fix stale resources from IP/domain changes.
    # Order matters: IP change → clear Vault first, then check CA domain, then Vault-mgmt jobs.
    _track_pc_ip_changes
    _ensure_ca_domain_matches "$network_yaml"
    _detect_and_fix_stale_vault_resources

    log_info "Running site.yaml playbook..."
    log_warning "This will take 15-30+ minutes. Monitor pods in another terminal:"
    echo -e "  kubectl --kubeconfig ~/.kube/orderer-cluster.yaml get pods -A --watch"
    echo -e "  kubectl --kubeconfig ~/.kube/org1-cluster.yaml get pods -A --watch"
    echo -e "  kubectl --kubeconfig ~/.kube/org2-cluster.yaml get pods -A --watch"
    echo ""

    cd "$bevel_dir" || { log_error "Cannot cd to ${bevel_dir}"; return 1; }

    # Step 1: Deploy network (CAs, orderers, peers, genesis)
    log_info "Step 1/2: Running deploy-network.yaml (CAs, orderers, peers, genesis)..."

    local _deploy_ok=false
    if ansible-playbook platforms/hyperledger-fabric/configuration/deploy-network.yaml \
        -i platforms/shared/inventory/ansible_provisioners \
        -e "@${network_yaml}" \
        -e "privilege_escalate=false" \
        -e "ansible_become=false" 2>&1 | tee -a "$BEVEL_LOG_FILE"; then
        _deploy_ok=true
        log_success "Network infrastructure deployed successfully!"
    else
        log_warning "Network deployment failed. Running pod health recovery before deciding to retry..."
    fi

    # === Pod Health Recovery ===
    # Run after every Step 1 attempt (success OR failure).
    # - On failure: if recovery fixes pod issues (race conditions, etc.) → auto-retry once
    # - On success: ensure no silent pod failures that would block genesis/channel steps
    local _recovery_ok=true
    if type recover_all_clusters &>/dev/null; then
        recover_all_clusters || _recovery_ok=false
    fi

    # If Step 1 failed → always retry once after recovery.
    # Recovery is best-effort: CLI pods in Init are expected (they wait for
    # orderer-tls-cacert which is created in create-join-channel.yaml) and
    # should never block the retry. Only fail if the retry itself fails.
    if ! $_deploy_ok; then
        if ! $_recovery_ok; then
            log_warning "Recovery could not fix all pods (CLI pods in Init are expected — they self-resolve at channel join)."
        fi
        log_info "Retrying deploy-network.yaml after recovery..."
        if ansible-playbook platforms/hyperledger-fabric/configuration/deploy-network.yaml \
            -i platforms/shared/inventory/ansible_provisioners \
            -e "@${network_yaml}" \
            -e "privilege_escalate=false" \
            -e "ansible_become=false" 2>&1 | tee -a "$BEVEL_LOG_FILE"; then
            log_success "Network infrastructure deployed successfully (after recovery)!"
        else
            log_error "Network deployment failed even after pod recovery."
            log_error "Log file: ${BEVEL_LOG_FILE}"
            log_error "Check remaining pod issues above and fix manually, then --resume."
            return 1
        fi
    fi

    # === Post-deployment K3s fixes ===
    log_info "Applying post-deployment K3s fixes..."
    if type patch_helmrelease_storage &>/dev/null; then
        patch_helmrelease_storage "$bevel_dir"
    fi
    if type post_deploy_ingress_fixes &>/dev/null; then
        post_deploy_ingress_fixes
    fi

    # Step 2: Create channel, join peers, set anchor peers
    log_info "Step 2/2: Running create-join-channel.yaml (channel create, join, anchor peers)..."
    if ansible-playbook platforms/hyperledger-fabric/configuration/create-join-channel.yaml \
        -i platforms/shared/inventory/ansible_provisioners \
        -e "@${network_yaml}" \
        -e "privilege_escalate=false" \
        -e "ansible_become=false" 2>&1 | tee -a "$BEVEL_LOG_FILE"; then

        log_success "Channel creation and peer join completed!"
    else
        log_error "Channel creation failed. Check logs."
        log_info "Log file: ${BEVEL_LOG_FILE}"
        return 1
    fi

    log_success "Fabric network deployment completed! All components deployed."

    # Save current IPs as the new baseline for next deployment's change detection
    _track_pc_ip_changes
}

run_network_reset() {
    log_header "NETWORK TEARDOWN"

    log_warning "This will DESTROY the entire Fabric network!"

    if ! ask_confirm "Are you absolutely sure you want to tear down the network?" "n"; then
        log_info "Teardown cancelled."
        return 0
    fi

    activate_ansible_venv || return 1

    local bevel_dir network_yaml
    bevel_dir=$(load_config_var "BEVEL_DIR" "${HOME}/bevel")
    network_yaml=$(load_config_var "NETWORK_YAML")

    cd "$bevel_dir" || { log_error "Cannot cd to ${bevel_dir}"; return 1; }

    if ansible-playbook platforms/shared/configuration/reset.yaml \
        -i platforms/shared/inventory/ansible_provisioners \
        -e "@${network_yaml}" \
        -e "privilege_escalate=false" \
        -e "ansible_become=false" 2>&1 | tee -a "$BEVEL_LOG_FILE"; then
        log_success "Network teardown completed."
    else
        log_error "Network teardown encountered errors."
        return 1
    fi
}
