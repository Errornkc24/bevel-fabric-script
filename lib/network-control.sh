#!/usr/bin/env bash
# =============================================================================
# network-control.sh - Pause and restart the Fabric network
#
# --pause:           Gracefully stop all Fabric components (data persists)
# --restart-network: Resume after pause or PC reboot
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

PAUSE_STATE_FILE="${HOME}/.bevel-setup/pause-state.json"

# ---------------------------------------------------------------------------
# Helper: Scale all Fabric workloads in a namespace
# ---------------------------------------------------------------------------
_scale_namespace_workloads() {
    local kubeconfig="$1"
    local namespace="$2"
    local replicas="$3"    # 0 to pause, or original count to resume
    local cluster_name="$4"

    if ! kubectl --kubeconfig "$kubeconfig" get ns "$namespace" &>/dev/null; then
        return 0
    fi

    # Scale StatefulSets
    local sts_list
    sts_list=$(kubectl --kubeconfig "$kubeconfig" get statefulset -n "$namespace" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
    for sts in $sts_list; do
        local current
        current=$(kubectl --kubeconfig "$kubeconfig" get statefulset "$sts" -n "$namespace" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [[ "$replicas" == "0" ]]; then
            log_info "  Scaling down ${sts} in ${namespace} (${cluster_name})"
        else
            log_info "  Scaling up ${sts} in ${namespace} (${cluster_name})"
        fi
        kubectl --kubeconfig "$kubeconfig" scale statefulset "$sts" -n "$namespace" \
            --replicas="$replicas" 2>/dev/null || true
    done

    # Scale Deployments
    local dep_list
    dep_list=$(kubectl --kubeconfig "$kubeconfig" get deployment -n "$namespace" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
    for dep in $dep_list; do
        if [[ "$replicas" == "0" ]]; then
            log_info "  Scaling down ${dep} in ${namespace} (${cluster_name})"
        else
            log_info "  Scaling up ${dep} in ${namespace} (${cluster_name})"
        fi
        kubectl --kubeconfig "$kubeconfig" scale deployment "$dep" -n "$namespace" \
            --replicas="$replicas" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Helper: Suspend/resume Flux HelmReleases in a namespace
# ---------------------------------------------------------------------------
_flux_control_namespace() {
    local kubeconfig="$1"
    local namespace="$2"
    local action="$3"  # "suspend" or "resume"

    if ! kubectl --kubeconfig "$kubeconfig" get ns "$namespace" &>/dev/null; then
        return 0
    fi

    local hr_list
    hr_list=$(kubectl --kubeconfig "$kubeconfig" get helmrelease -n "$namespace" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
    for hr in $hr_list; do
        local suspend_val="true"
        [[ "$action" == "resume" ]] && suspend_val="false"
        kubectl --kubeconfig "$kubeconfig" patch helmrelease "$hr" -n "$namespace" \
            --type merge -p "{\"spec\":{\"suspend\":${suspend_val}}}" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Helper: Save current replica counts before pausing
# ---------------------------------------------------------------------------
_save_replica_state() {
    local kubeconfig="$1"
    local namespace="$2"
    local cluster_name="$3"

    mkdir -p "$(dirname "$PAUSE_STATE_FILE")"

    # Skip saving if state already exists for this namespace+cluster (prevents overwriting with 0s on double-pause)
    if [[ -f "$PAUSE_STATE_FILE" ]]; then
        local already_saved
        already_saved=$(jq -r --arg ns "$namespace" --arg cl "$cluster_name" \
            '[.[] | select(.namespace == $ns and .cluster == $cl)] | length' \
            "$PAUSE_STATE_FILE" 2>/dev/null || echo "0")
        if [[ "$already_saved" -gt 0 ]]; then
            return 0
        fi
    fi

    # Get StatefulSet replica counts (only those with replicas > 0)
    local sts_json
    sts_json=$(kubectl --kubeconfig "$kubeconfig" get statefulset -n "$namespace" \
        -o json 2>/dev/null | jq -c '[.items[] | {name: .metadata.name, replicas: (.spec.replicas // 1), type: "statefulset"} | select(.replicas > 0)]' 2>/dev/null || echo "[]")

    # Get Deployment replica counts (only those with replicas > 0)
    local dep_json
    dep_json=$(kubectl --kubeconfig "$kubeconfig" get deployment -n "$namespace" \
        -o json 2>/dev/null | jq -c '[.items[] | {name: .metadata.name, replicas: (.spec.replicas // 1), type: "deployment"} | select(.replicas > 0)]' 2>/dev/null || echo "[]")

    # Merge and save
    local combined
    combined=$(echo "$sts_json $dep_json" | jq -s 'add')

    # Append to state file using jq
    if [[ -f "$PAUSE_STATE_FILE" ]]; then
        local existing
        existing=$(cat "$PAUSE_STATE_FILE")
        echo "$existing" | jq --arg ns "$namespace" --arg cl "$cluster_name" --argjson workloads "$combined" \
            '. + [{namespace: $ns, cluster: $cl, workloads: $workloads}]' > "$PAUSE_STATE_FILE"
    else
        echo "[{\"namespace\": \"${namespace}\", \"cluster\": \"${cluster_name}\", \"workloads\": ${combined}}]" > "$PAUSE_STATE_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Helper: Pause one cluster
# ---------------------------------------------------------------------------
_pause_cluster() {
    local kubeconfig="$1"
    local cluster_name="$2"

    if [[ -z "$kubeconfig" ]] || [[ ! -f "$kubeconfig" ]]; then
        log_warning "Kubeconfig not found for ${cluster_name}, skipping."
        return 0
    fi

    if ! kubectl --kubeconfig "$kubeconfig" cluster-info &>/dev/null; then
        log_warning "Cannot reach ${cluster_name}, skipping."
        return 0
    fi

    log_step "Pausing ${cluster_name}..."

    local namespaces=("ordererorg-net" "org1-net" "org2-net")
    for ns in "${namespaces[@]}"; do
        if kubectl --kubeconfig "$kubeconfig" get ns "$ns" &>/dev/null; then
            # Save state before scaling down
            _save_replica_state "$kubeconfig" "$ns" "$cluster_name"
            # Suspend Flux first (so it doesn't restart pods)
            _flux_control_namespace "$kubeconfig" "$ns" "suspend"
            # Scale down
            _scale_namespace_workloads "$kubeconfig" "$ns" "0" "$cluster_name"
        fi
    done

    log_success "${cluster_name} paused."
}

# ---------------------------------------------------------------------------
# Helper: Resume one cluster
# ---------------------------------------------------------------------------
_resume_cluster() {
    local kubeconfig="$1"
    local cluster_name="$2"

    if [[ -z "$kubeconfig" ]] || [[ ! -f "$kubeconfig" ]]; then
        log_warning "Kubeconfig not found for ${cluster_name}, skipping."
        return 0
    fi

    if ! kubectl --kubeconfig "$kubeconfig" cluster-info &>/dev/null; then
        log_warning "Cannot reach ${cluster_name}, skipping."
        return 0
    fi

    log_step "Resuming ${cluster_name}..."

    local namespaces=("ordererorg-net" "org1-net" "org2-net")
    for ns in "${namespaces[@]}"; do
        if kubectl --kubeconfig "$kubeconfig" get ns "$ns" &>/dev/null; then
            # Resume Flux HelmReleases
            _flux_control_namespace "$kubeconfig" "$ns" "resume"

            # Restore replica counts from saved state
            if [[ -f "$PAUSE_STATE_FILE" ]]; then
                local workloads
                workloads=$(jq -r --arg ns "$ns" --arg cl "$cluster_name" \
                    '.[] | select(.namespace == $ns and .cluster == $cl) | .workloads[]' \
                    "$PAUSE_STATE_FILE" 2>/dev/null || true)

                if [[ -n "$workloads" ]]; then
                    echo "$workloads" | jq -c '.' | while IFS= read -r wl; do
                        local name type reps
                        name=$(echo "$wl" | jq -r '.name')
                        type=$(echo "$wl" | jq -r '.type')
                        reps=$(echo "$wl" | jq -r '.replicas')
                        [[ "$reps" == "null" || -z "$reps" || "$reps" == "0" ]] && reps=1

                        log_info "  Scaling up ${type}/${name} to ${reps} in ${ns}"
                        kubectl --kubeconfig "$kubeconfig" scale "$type" "$name" -n "$ns" \
                            --replicas="$reps" 2>/dev/null || true
                    done
                else
                    # No saved state - scale everything to 1
                    _scale_namespace_workloads "$kubeconfig" "$ns" "1" "$cluster_name"
                fi
            else
                # No pause state file - scale everything to 1
                _scale_namespace_workloads "$kubeconfig" "$ns" "1" "$cluster_name"
            fi
        fi
    done

    log_success "${cluster_name} resumed."
}

# ---------------------------------------------------------------------------
# Helper: Wait for pods to be ready
# ---------------------------------------------------------------------------
_wait_for_pods() {
    local kubeconfig="$1"
    local namespace="$2"
    local cluster_name="$3"
    local timeout="${4:-120}"

    if ! kubectl --kubeconfig "$kubeconfig" get ns "$namespace" &>/dev/null; then
        return 0
    fi

    log_info "  Waiting for pods in ${namespace} on ${cluster_name}..."

    local start_time
    start_time=$(date +%s)

    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if (( elapsed > timeout )); then
            log_warning "  Timeout waiting for pods in ${namespace} on ${cluster_name}"
            kubectl --kubeconfig "$kubeconfig" get pods -n "$namespace" --no-headers 2>/dev/null
            return 0
        fi

        local not_ready
        not_ready=$(kubectl --kubeconfig "$kubeconfig" get pods -n "$namespace" --no-headers 2>/dev/null \
            | grep -v "Running\|Completed\|Succeeded" | grep -v "^$" | wc -l)

        if (( not_ready == 0 )); then
            local running
            running=$(kubectl --kubeconfig "$kubeconfig" get pods -n "$namespace" --no-headers 2>/dev/null \
                | grep "Running" | wc -l)
            if (( running > 0 )); then
                log_success "  All ${running} pods running in ${namespace} on ${cluster_name}"
                return 0
            fi
        fi

        sleep 5
    done
}

# ---------------------------------------------------------------------------
# run_pause: Gracefully pause the Fabric network
# ---------------------------------------------------------------------------
run_pause() {
    log_header "PAUSE: Stopping Fabric Network"
    echo "This will scale down all Fabric pods and suspend Flux reconciliation."
    echo "Data is preserved in PVCs and Vault. Resume with: ./1-per-pc-setup.sh --restart-network"
    echo ""

    if ! ask_confirm "Pause the network?"; then
        log_info "Pause cancelled."
        return 0
    fi

    # Ask scope
    local scope
    scope=$(ask_choice "What to pause?" \
        "This PC only" \
        "All clusters (if kubeconfigs available)")

    # Load kubeconfigs and role
    local kc_orderer kc_org1 kc_org2 role
    role=$(load_config_var "ROLE" "")
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER" "")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1" "")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2" "")

    # Clear previous pause state
    rm -f "$PAUSE_STATE_FILE"

    if [[ "$scope" == "0" ]]; then
        # This PC only - find local kubeconfig
        local local_kc=""
        case "$role" in
            orderer) local_kc="$kc_orderer" ;;
            org1)    local_kc="$kc_org1" ;;
            org2)    local_kc="$kc_org2" ;;
        esac
        if [[ -z "$local_kc" ]]; then
            local_kc="/etc/rancher/k3s/k3s.yaml"
        fi
        [[ -n "$local_kc" ]] && _pause_cluster "$local_kc" "local-cluster"
    else
        # All clusters
        [[ -n "$kc_orderer" ]] && _pause_cluster "$kc_orderer" "orderer-cluster"
        [[ -n "$kc_org1" ]] && _pause_cluster "$kc_org1" "org1-cluster"
        [[ -n "$kc_org2" ]] && _pause_cluster "$kc_org2" "org2-cluster"
    fi

    # Stop Vault (save info for restart)
    log_step "Stopping Vault dev server..."
    pkill -f "vault server" 2>/dev/null || true

    # Save pause timestamp
    save_config_var "NETWORK_PAUSED" "true"
    save_config_var "PAUSE_TIMESTAMP" "$(date -Iseconds)"

    log_header "NETWORK PAUSED"
    echo -e "${GREEN}${BOLD}Fabric network is paused. All data is preserved.${NC}"
    echo ""
    echo "To resume: ./1-per-pc-setup.sh --restart-network"
    echo "To fully clear: ./1-per-pc-setup.sh --clear"
}

# ---------------------------------------------------------------------------
# run_restart_network: Resume network after pause or PC reboot
# ---------------------------------------------------------------------------
run_restart_network() {
    log_header "RESTART: Resuming Fabric Network"

    # Check config exists
    if [[ ! -f "${HOME}/.bevel-setup/config.env" ]]; then
        log_error "No Bevel configuration found at ~/.bevel-setup/config.env"
        log_error "Cannot restart - no network was previously deployed."
        return 1
    fi

    # Load all config
    load_all_config

    local role kc_orderer kc_org1 kc_org2
    role=$(load_config_var "ROLE" "")
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER" "")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1" "")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2" "")

    # Ask scope
    local scope
    scope=$(ask_choice "What to restart?" \
        "This PC only" \
        "All clusters (if kubeconfigs available)")

    # Determine which clusters to operate on
    local clusters=()
    if [[ "$scope" == "0" ]]; then
        # This PC only
        local local_kc="" local_ns="" local_name=""
        case "$role" in
            orderer) local_kc="$kc_orderer"; local_ns="ordererorg-net"; local_name="orderer" ;;
            org1)    local_kc="$kc_org1";    local_ns="org1-net";       local_name="org1" ;;
            org2)    local_kc="$kc_org2";    local_ns="org2-net";       local_name="org2" ;;
        esac
        if [[ -z "$local_kc" ]]; then
            local_kc="/etc/rancher/k3s/k3s.yaml"
        fi
        clusters+=("${local_kc}:${local_ns}:${local_name}")
    else
        # All clusters
        [[ -n "$kc_orderer" ]] && clusters+=("${kc_orderer}:ordererorg-net:orderer")
        [[ -n "$kc_org1" ]] && clusters+=("${kc_org1}:org1-net:org1")
        [[ -n "$kc_org2" ]] && clusters+=("${kc_org2}:org2-net:org2")
    fi

    # Step 1: Ensure Vault is running and accessible with the correct token
    log_step "Step 1: Ensuring Vault is running..."
    local this_ip
    this_ip=$(load_config_var "IP_${role^^}" "0.0.0.0")
    local vault_token
    vault_token=$(load_config_var "VAULT_TOKEN_${role^^}" "")
    if [[ -z "$vault_token" ]]; then
        vault_token=$(load_config_var "VAULT_ROOT_TOKEN" "")
    fi

    # Check if Vault is actually accessible (not just a process match - K3s vault containers give false positives)
    local vault_healthy=false
    if curl -s --connect-timeout 3 "http://${this_ip}:8200/v1/sys/health" 2>/dev/null | grep -q '"initialized":true'; then
        # Vault is reachable - verify we can authenticate with our token
        export VAULT_ADDR="http://127.0.0.1:8200"
        export VAULT_TOKEN="$vault_token"
        if vault token lookup &>/dev/null; then
            vault_healthy=true
        else
            log_warning "Vault is running but token is invalid. Killing stale Vault..."
            # Kill any standalone vault process (not K3s containers)
            pkill -x vault 2>/dev/null || true
            sleep 2
        fi
    fi

    if [[ "$vault_healthy" == "false" ]]; then
        if [[ -n "$vault_token" ]]; then
            log_info "Starting Vault dev server with saved token..."
            nohup vault server -dev \
                -dev-root-token-id="$vault_token" \
                -dev-listen-address="0.0.0.0:8200" \
                > "${HOME}/.bevel-setup/vault.log" 2>&1 &

            sleep 3
            export VAULT_ADDR="http://127.0.0.1:8200"
            export VAULT_TOKEN="$vault_token"

            if vault status &>/dev/null; then
                log_success "Vault started successfully."

                # Re-enable secrets engine if needed
                if ! vault secrets list 2>/dev/null | grep -q "secretsv2/"; then
                    vault secrets enable -path=secretsv2 kv-v2 2>/dev/null || true
                fi

                # Re-configure Vault K8s auth for relevant clusters
                log_info "Re-configuring Vault auth backends..."
                for pair in "${clusters[@]}"; do
                    IFS=':' read -r kc ns name <<< "$pair"
                    local org_name
                    case "$name" in
                        orderer) org_name="ordererorg" ;;
                        *)       org_name="$name" ;;
                    esac
                    _reconfigure_vault_auth "$kc" "$org_name" "$this_ip" "$vault_token"
                done
            else
                log_error "Vault failed to start. Check ~/.bevel-setup/vault.log"
                return 1
            fi
        else
            log_warning "No Vault token found in config. Vault needs manual restart."
        fi
    else
        log_success "Vault is already running."
    fi

    # Step 2: Check K3s is running
    log_step "Step 2: Checking K3s..."
    if sudo systemctl is-active --quiet k3s 2>/dev/null; then
        log_success "K3s is running."
    else
        log_info "Starting K3s..."
        sudo systemctl start k3s
        sleep 5
        if sudo systemctl is-active --quiet k3s; then
            log_success "K3s started."
        else
            log_error "K3s failed to start."
            return 1
        fi
    fi

    # Step 3: Resume workloads
    log_step "Step 3: Resuming Fabric workloads..."
    for pair in "${clusters[@]}"; do
        IFS=':' read -r kc ns name <<< "$pair"
        _resume_cluster "$kc" "${name}-cluster"
    done

    # Step 4: Wait for pods
    log_step "Step 4: Waiting for pods to be ready..."
    for pair in "${clusters[@]}"; do
        IFS=':' read -r kc ns name <<< "$pair"
        _wait_for_pods "$kc" "$ns" "${name}-cluster" 180
    done

    # Clean pause state
    rm -f "$PAUSE_STATE_FILE"
    save_config_var "NETWORK_PAUSED" "false"

    # Step 5: Show status
    log_header "NETWORK RESTARTED"
    echo -e "${GREEN}${BOLD}Fabric network is running!${NC}"
    echo ""

    for pair in "${clusters[@]}"; do
        IFS=':' read -r kc ns name <<< "$pair"
        if [[ -n "$kc" ]] && [[ -f "$kc" ]]; then
            echo -e "${CYAN}=== ${name} cluster ===${NC}"
            kubectl --kubeconfig "$kc" get pods -n "$ns" --no-headers 2>/dev/null | grep -v "Completed" || echo "  (no running pods)"
            echo ""
        fi
    done
}

# ---------------------------------------------------------------------------
# Helper: Reconfigure Vault K8s auth after restart
# ---------------------------------------------------------------------------
_reconfigure_vault_auth() {
    local kubeconfig="$1"
    local org_name="$2"
    local vault_ip="$3"
    local vault_token="$4"

    if [[ -z "$kubeconfig" ]] || [[ ! -f "$kubeconfig" ]]; then
        return 0
    fi

    if ! kubectl --kubeconfig "$kubeconfig" cluster-info &>/dev/null; then
        return 0
    fi

    local namespace="${org_name}-net"
    local auth_path="dev${org_name}"

    # Check if auth backend exists
    if vault auth list 2>/dev/null | grep -q "${auth_path}/"; then
        log_info "  Vault auth ${auth_path} already configured."
        return 0
    fi

    # Re-enable kubernetes auth
    vault auth enable -path="${auth_path}" kubernetes 2>/dev/null || true

    # Get SA token and CA cert from cluster
    local sa_secret sa_token k8s_host ca_cert
    sa_secret=$(kubectl --kubeconfig "$kubeconfig" get sa vault-auth -n "$namespace" \
        -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)

    if [[ -n "$sa_secret" ]]; then
        sa_token=$(kubectl --kubeconfig "$kubeconfig" get secret "$sa_secret" -n "$namespace" \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
        ca_cert=$(kubectl --kubeconfig "$kubeconfig" get secret "$sa_secret" -n "$namespace" \
            -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi

    k8s_host=$(kubectl --kubeconfig "$kubeconfig" config view --minify \
        -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)

    if [[ -n "$sa_token" ]] && [[ -n "$k8s_host" ]]; then
        vault write "auth/${auth_path}/config" \
            token_reviewer_jwt="$sa_token" \
            kubernetes_host="$k8s_host" \
            kubernetes_ca_cert="$ca_cert" 2>/dev/null || true
        log_info "  Vault auth ${auth_path} reconfigured."
    fi
}
