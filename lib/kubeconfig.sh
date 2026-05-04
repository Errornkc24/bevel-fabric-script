#!/usr/bin/env bash
# =============================================================================
# kubeconfig.sh - Export and configure kubeconfigs for multi-cluster access
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

# Export kubeconfig from local K3s and fix the server IP
export_local_kubeconfig() {
    log_step "Exporting kubeconfig from local K3s..."

    local role
    role=$(load_config_var "ROLE")
    local this_ip
    this_ip=$(load_config_var "THIS_PC_IP")

    local kube_dir="${HOME}/.kube"
    mkdir -p "$kube_dir"

    local filename=""
    case "$role" in
        orderer) filename="orderer-cluster.yaml" ;;
        org1)    filename="org1-cluster.yaml" ;;
        org2)    filename="org2-cluster.yaml" ;;
        *)
            log_error "Unknown role '${role}'. Cannot export kubeconfig."
            return 1
            ;;
    esac

    local kubeconfig_path="${kube_dir}/${filename}"

    sudo cp /etc/rancher/k3s/k3s.yaml "$kubeconfig_path"
    sudo chown "$(whoami):$(whoami)" "$kubeconfig_path"
    chmod 600 "$kubeconfig_path"

    # Replace 127.0.0.1 with actual IP
    sed -i "s|server: https://127.0.0.1:6443|server: https://${this_ip}:6443|" "$kubeconfig_path"

    # Rename cluster/context/user to be unique (replace all references)
    local cluster_name="${role}-cluster"
    sed -i "s/: default$/: ${cluster_name}/g" "$kubeconfig_path"

    # Verify
    if kubectl --kubeconfig "$kubeconfig_path" get nodes &>/dev/null; then
        log_success "Kubeconfig exported: ${kubeconfig_path}"
        log_info "Context name: ${cluster_name}"
    else
        log_warning "Kubeconfig rename may have broken references. Trying with original names..."
        # Re-copy and only fix the IP, skip rename
        sudo cp /etc/rancher/k3s/k3s.yaml "$kubeconfig_path"
        sudo chown "$(whoami):$(whoami)" "$kubeconfig_path"
        chmod 600 "$kubeconfig_path"
        sed -i "s|server: https://127.0.0.1:6443|server: https://${this_ip}:6443|" "$kubeconfig_path"
        cluster_name="default"

        if kubectl --kubeconfig "$kubeconfig_path" get nodes &>/dev/null; then
            log_success "Kubeconfig exported (with default context name): ${kubeconfig_path}"
        else
            log_error "Kubeconfig verification failed. Check K3s status: sudo systemctl status k3s"
            return 1
        fi
    fi

    save_config_var "KUBECONFIG_${role^^}" "$kubeconfig_path"
    save_config_var "K8S_CONTEXT_${role^^}" "$cluster_name"
}

# Setup controller with all 3 kubeconfigs
setup_controller_kubeconfigs() {
    log_header "Setting up Kubeconfigs on Controller"

    local kube_dir="${HOME}/.kube"
    mkdir -p "$kube_dir"

    local role
    role=$(load_config_var "ROLE")
    local this_ip
    this_ip=$(load_config_var "THIS_PC_IP")
    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    # If this is the controller PC, we already have our own kubeconfig
    # Now collect the others

    local orderer_kc="${kube_dir}/orderer-cluster.yaml"
    local org1_kc="${kube_dir}/org1-cluster.yaml"
    local org2_kc="${kube_dir}/org2-cluster.yaml"

    # Handle local kubeconfig
    if [[ "$this_ip" == "$pc1_ip" ]]; then
        if [[ ! -f "$orderer_kc" ]]; then
            sudo cp /etc/rancher/k3s/k3s.yaml "$orderer_kc"
            sudo chown "$(whoami):$(whoami)" "$orderer_kc"
            chmod 600 "$orderer_kc"
            sed -i "s|server: https://127.0.0.1:6443|server: https://${pc1_ip}:6443|" "$orderer_kc"
            sed -i "s/: default$/: orderer-cluster/g" "$orderer_kc"
        fi
    fi

    # Get remote kubeconfigs
    local remote_pcs=()
    local remote_ips=()
    local remote_files=()

    if [[ "$this_ip" != "$pc1_ip" ]]; then
        remote_pcs+=("PC1-Orderer")
        remote_ips+=("$pc1_ip")
        remote_files+=("$orderer_kc")
    fi
    if [[ "$this_ip" != "$pc2_ip" ]]; then
        remote_pcs+=("PC2-Org1")
        remote_ips+=("$pc2_ip")
        remote_files+=("$org1_kc")
    fi
    if [[ "$this_ip" != "$pc3_ip" ]]; then
        remote_pcs+=("PC3-Org2")
        remote_ips+=("$pc3_ip")
        remote_files+=("$org2_kc")
    fi

    for i in "${!remote_pcs[@]}"; do
        if [[ -f "${remote_files[$i]}" ]]; then
            log_info "Kubeconfig for ${remote_pcs[$i]} already exists."
            if ! ask_confirm "Re-fetch from ${remote_ips[$i]}?" "n"; then
                continue
            fi
        fi

        local ssh_user
        ssh_user=$(ask_input "SSH username for ${remote_pcs[$i]} (${remote_ips[$i]})" "$(whoami)")

        log_info "Fetching kubeconfig from ${remote_pcs[$i]} (${remote_ips[$i]})..."
        if scp "${ssh_user}@${remote_ips[$i]}:/etc/rancher/k3s/k3s.yaml" "${remote_files[$i]}" 2>/dev/null; then
            chmod 600 "${remote_files[$i]}"
            log_success "Kubeconfig fetched from ${remote_pcs[$i]}."
        else
            log_warning "SCP failed. You may need to copy manually."
            log_info "On ${remote_pcs[$i]}, run: sudo cat /etc/rancher/k3s/k3s.yaml"
            log_info "Then paste the content or copy the file to: ${remote_files[$i]}"
            read -rp "$(echo -e "${YELLOW}Press Enter after copying the file...${NC}")"
        fi
    done

    # Fix server addresses
    sed -i "s|server: https://127.0.0.1:6443|server: https://${pc1_ip}:6443|" "$orderer_kc" 2>/dev/null || true
    sed -i "s|server: https://127.0.0.1:6443|server: https://${pc2_ip}:6443|" "$org1_kc" 2>/dev/null || true
    sed -i "s|server: https://127.0.0.1:6443|server: https://${pc3_ip}:6443|" "$org2_kc" 2>/dev/null || true

    # Rename clusters to be unique (replace all name/reference fields)
    sed -i "s/: default$/: orderer-cluster/g" "$orderer_kc" 2>/dev/null || true
    sed -i "s/: default$/: org1-cluster/g" "$org1_kc" 2>/dev/null || true
    sed -i "s/: default$/: org2-cluster/g" "$org2_kc" 2>/dev/null || true

    save_config_var "KUBECONFIG_ORDERER" "$orderer_kc"
    save_config_var "KUBECONFIG_ORG1" "$org1_kc"
    save_config_var "KUBECONFIG_ORG2" "$org2_kc"
    save_config_var "K8S_CONTEXT_ORDERER" "orderer-cluster"
    save_config_var "K8S_CONTEXT_ORG1" "org1-cluster"
    save_config_var "K8S_CONTEXT_ORG2" "org2-cluster"

    # Verify access
    log_step "Testing kubectl access to all clusters..."
    local all_ok=true

    if kubectl --kubeconfig "$orderer_kc" get nodes &>/dev/null; then
        log_success "  Orderer cluster - OK"
    else
        log_error "  Orderer cluster - FAILED"
        all_ok=false
    fi

    if kubectl --kubeconfig "$org1_kc" get nodes &>/dev/null; then
        log_success "  Org1 cluster - OK"
    else
        log_error "  Org1 cluster - FAILED"
        all_ok=false
    fi

    if kubectl --kubeconfig "$org2_kc" get nodes &>/dev/null; then
        log_success "  Org2 cluster - OK"
    else
        log_error "  Org2 cluster - FAILED"
        all_ok=false
    fi

    if ! $all_ok; then
        log_error "Cannot access all clusters. Please fix kubeconfig issues."
        if ! ask_confirm "Continue anyway?"; then
            exit 1
        fi
    fi

    log_success "All kubeconfigs configured."

    # Show context names
    log_info "Context names for network.yaml:"
    log_info "  OrdererOrg: $(kubectl --kubeconfig "$orderer_kc" config get-contexts -o name 2>/dev/null || echo 'orderer-cluster')"
    log_info "  Org1:       $(kubectl --kubeconfig "$org1_kc" config get-contexts -o name 2>/dev/null || echo 'org1-cluster')"
    log_info "  Org2:       $(kubectl --kubeconfig "$org2_kc" config get-contexts -o name 2>/dev/null || echo 'org2-cluster')"
}
