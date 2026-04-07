#!/usr/bin/env bash
# =============================================================================
# firewall.sh - Configure UFW firewall rules
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

setup_firewall() {
    log_header "PHASE 2: Firewall Configuration"

    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    log_info "Configuring UFW firewall rules..."
    log_info "PC1=${pc1_ip}, PC2=${pc2_ip}, PC3=${pc3_ip}"

    local fw_mode
    fw_mode=$(ask_choice "Firewall policy?" \
        "Open ports (allow from any source - easier for dev)" \
        "Restrictive (only allow from the other 2 PCs - more secure)")

    # Enable UFW
    echo "y" | sudo ufw enable 2>/dev/null || true

    # Allow SSH first
    sudo ufw allow 22/tcp comment "SSH" 2>/dev/null || true

    if [[ "$fw_mode" == "0" ]]; then
        # Open mode
        sudo ufw allow 6443/tcp comment "Kubernetes API"
        sudo ufw allow 80/tcp comment "HAProxy HTTP"
        sudo ufw allow 443/tcp comment "HAProxy HTTPS - Fabric gRPC"
        sudo ufw allow 30000:32767/tcp comment "Kubernetes NodePort range"
        sudo ufw allow 8200/tcp comment "HashiCorp Vault API"
        sudo ufw allow 10250/tcp comment "Kubelet API"
        sudo ufw allow 8472/udp comment "K3s Flannel VXLAN"
        sudo ufw allow 51820/udp comment "K3s Wireguard"
        sudo ufw allow 51821/udp comment "K3s Wireguard IPv6"
        # Monitoring ports
        sudo ufw allow 30090/tcp comment "Prometheus NodePort"
        sudo ufw allow 30300/tcp comment "Grafana NodePort"
        sudo ufw allow 31090/tcp comment "Central Prometheus"
        sudo ufw allow 31300/tcp comment "Central Grafana"
    else
        # Restrictive mode - only allow from other PCs
        local this_ip
        this_ip=$(load_config_var "THIS_PC_IP")
        local other_ips=()

        for ip in "$pc1_ip" "$pc2_ip" "$pc3_ip"; do
            if [[ "$ip" != "$this_ip" ]]; then
                other_ips+=("$ip")
            fi
        done

        for ip in "${other_ips[@]}"; do
            sudo ufw allow from "$ip" comment "Allow all from ${ip}"
        done

        # Still need NodePort range for local access
        sudo ufw allow 6443/tcp comment "Kubernetes API"
        sudo ufw allow 30000:32767/tcp comment "Kubernetes NodePort range"
    fi

    log_info "Current firewall status:"
    sudo ufw status verbose

    log_success "Firewall configured."
}

verify_firewall() {
    log_step "Verifying firewall rules..."
    local status
    status=$(sudo ufw status 2>/dev/null)
    if echo "$status" | grep -q "Status: active"; then
        log_success "UFW is active."
    else
        log_warning "UFW is not active."
    fi

    # Check key ports
    for port in 22 443 6443 8200; do
        if echo "$status" | grep -q "${port}/tcp"; then
            log_success "Port ${port}/tcp is allowed."
        else
            log_warning "Port ${port}/tcp may not be allowed."
        fi
    done
}
