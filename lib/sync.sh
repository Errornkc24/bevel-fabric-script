#!/usr/bin/env bash
# =============================================================================
# sync.sh - Cross-PC synchronization (auto-check + manual fallback)
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

# Wait for a TCP port to be reachable on a remote host
wait_for_port() {
    local host="$1"
    local port="$2"
    local service_name="${3:-service}"
    local timeout="${4:-120}"

    log_info "Checking ${service_name} at ${host}:${port}..."

    local elapsed=0
    while (( elapsed < timeout )); do
        if nc -z -w 2 "$host" "$port" 2>/dev/null; then
            log_success "${service_name} is reachable at ${host}:${port}"
            return 0
        fi
        sleep 5
        ((elapsed += 5))
        echo -ne "\r  Waiting... ${elapsed}s/${timeout}s"
    done
    echo ""

    log_warning "${service_name} not reachable at ${host}:${port} after ${timeout}s"
    return 1
}

# Wait for K8s API on a remote PC
wait_for_k8s_api() {
    local host="$1"
    local pc_name="${2:-PC}"
    wait_for_port "$host" 6443 "Kubernetes API on ${pc_name}" 120
}

# Wait for Vault on a remote PC
wait_for_vault() {
    local host="$1"
    local pc_name="${2:-PC}"

    log_info "Checking Vault on ${pc_name} (${host})..."
    local elapsed=0
    local timeout=120

    while (( elapsed < timeout )); do
        local health
        health=$(curl -s --connect-timeout 3 "http://${host}:8200/v1/sys/health" 2>/dev/null || echo "")
        if echo "$health" | grep -q '"initialized":true'; then
            log_success "Vault is running on ${pc_name} (${host})"
            return 0
        fi
        sleep 5
        ((elapsed += 5))
        echo -ne "\r  Waiting for Vault... ${elapsed}s/${timeout}s"
    done
    echo ""

    log_warning "Vault not ready on ${pc_name} after ${timeout}s"
    return 1
}

# Wait for HAProxy Ingress on a remote cluster
wait_for_haproxy() {
    local host="$1"
    local pc_name="${2:-PC}"
    wait_for_port "$host" 443 "HAProxy on ${pc_name}" 120
}

# Combined: auto-check then manual fallback
wait_for_pc_ready() {
    local host="$1"
    local pc_name="$2"
    local phase_name="$3"

    log_separator
    log_info "Waiting for ${pc_name} (${host}) to complete: ${phase_name}"

    # Try auto-check first
    case "$phase_name" in
        "prerequisites"|"k3s")
            if wait_for_k8s_api "$host" "$pc_name"; then
                return 0
            fi
            ;;
        "vault")
            if wait_for_vault "$host" "$pc_name"; then
                return 0
            fi
            ;;
        "haproxy")
            if wait_for_haproxy "$host" "$pc_name"; then
                return 0
            fi
            ;;
        "firewall")
            if wait_for_port "$host" 22 "SSH on ${pc_name}" 30; then
                return 0
            fi
            ;;
        *)
            # Generic - just check SSH
            if wait_for_port "$host" 22 "SSH on ${pc_name}" 10; then
                log_info "SSH reachable but cannot verify ${phase_name} automatically."
            fi
            ;;
    esac

    # Manual fallback
    if [[ "${BEVEL_NONINTERACTIVE:-0}" == "1" ]]; then
        log_warning "Non-interactive mode: NOT blocking on ${pc_name} '${phase_name}'."
        log_warning "Driver must orchestrate phase ordering across PCs externally."
        return 0
    fi
    echo ""
    echo -e "${YELLOW}${BOLD}================================================================${NC}"
    echo -e "${YELLOW}${BOLD}  WAITING: Please ensure ${pc_name} has completed '${phase_name}'${NC}"
    echo -e "${YELLOW}${BOLD}================================================================${NC}"
    echo ""
    read -rp "$(echo -e "${YELLOW}Press Enter when ${pc_name} is ready...${NC}")"
    log_info "User confirmed ${pc_name} is ready."
    return 0
}

# Wait for all other PCs to be ready for a phase
wait_for_other_pcs() {
    local phase_name="$1"
    local this_ip
    this_ip=$(load_config_var "THIS_PC_IP")
    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    local pcs=()
    local names=()
    if [[ "$this_ip" != "$pc1_ip" ]]; then
        pcs+=("$pc1_ip"); names+=("PC1-Orderer")
    fi
    if [[ "$this_ip" != "$pc2_ip" ]]; then
        pcs+=("$pc2_ip"); names+=("PC2-Org1")
    fi
    if [[ "$this_ip" != "$pc3_ip" ]]; then
        pcs+=("$pc3_ip"); names+=("PC3-Org2")
    fi

    for i in "${!pcs[@]}"; do
        wait_for_pc_ready "${pcs[$i]}" "${names[$i]}" "$phase_name"
    done
}

# Verify connectivity between all 3 PCs
verify_cross_pc_connectivity() {
    log_step "Verifying connectivity between all PCs..."

    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    local all_ok=true

    for ip in "$pc1_ip" "$pc2_ip" "$pc3_ip"; do
        # TCP check K8s API
        if nc -z -w 3 "$ip" 6443 2>/dev/null; then
            log_success "  ${ip}:6443 (K8s API) - reachable"
        else
            log_warning "  ${ip}:6443 (K8s API) - NOT reachable"
            all_ok=false
        fi
    done

    if $all_ok; then
        log_success "All PCs are reachable on K8s API port."
    else
        log_warning "Some PCs are not reachable. Check firewall rules and network."
        if ! ask_confirm "Continue anyway?"; then
            exit 1
        fi
    fi
}

# Verify kubectl access to all clusters (from controller)
verify_kubectl_access() {
    log_step "Verifying kubectl access to all clusters..."

    local configs=(
        "$(load_config_var KUBECONFIG_ORDERER)"
        "$(load_config_var KUBECONFIG_ORG1)"
        "$(load_config_var KUBECONFIG_ORG2)"
    )
    local names=("Orderer Cluster" "Org1 Cluster" "Org2 Cluster")
    local all_ok=true

    for i in "${!configs[@]}"; do
        if [[ -z "${configs[$i]}" ]]; then
            log_warning "Kubeconfig not set for ${names[$i]}"
            all_ok=false
            continue
        fi
        if kubectl --kubeconfig "${configs[$i]}" get nodes &>/dev/null; then
            log_success "  ${names[$i]} - kubectl access OK"
        else
            log_error "  ${names[$i]} - kubectl access FAILED"
            all_ok=false
        fi
    done

    if ! $all_ok; then
        log_error "Cannot access all clusters. Fix kubeconfig issues before proceeding."
        return 1
    fi
    log_success "kubectl access verified for all clusters."
}
