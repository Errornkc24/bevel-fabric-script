#!/usr/bin/env bash
# =============================================================================
# dns.sh - Configure /etc/hosts and CoreDNS for cross-cluster resolution
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

setup_etc_hosts() {
    log_header "PHASE 3: DNS / Host Resolution"

    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    # Ask for domain suffix or use defaults
    local pc1_domain pc2_domain pc3_domain
    log_info "Domain suffixes are used in Fabric URIs (e.g., orderer1.ordererorg-net.pc1.example.com)"
    pc1_domain=$(ask_input "Domain suffix for PC1 (Orderer)" "pc1.example.com")
    pc2_domain=$(ask_input "Domain suffix for PC2 (Org1)" "pc2.example.com")
    pc3_domain=$(ask_input "Domain suffix for PC3 (Org2)" "pc3.example.com")

    save_config_var "PC1_DOMAIN" "$pc1_domain"
    save_config_var "PC2_DOMAIN" "$pc2_domain"
    save_config_var "PC3_DOMAIN" "$pc3_domain"

    # BFT consensus requires 4 orderers
    local consensus
    consensus=$(load_config_var "CONSENSUS" "raft")
    local orderer4_hosts=""
    if [[ "$consensus" == "bft" ]]; then
        orderer4_hosts="${pc1_ip}   orderer4.ordererorg-net.${pc1_domain}"
    fi

    local hosts_block
    hosts_block=$(cat <<EOF

# ---- Hyperledger Fabric Bevel Network ----
# PC1 - Orderer Org
${pc1_ip}   orderer1.ordererorg-net.${pc1_domain}
${pc1_ip}   orderer2.ordererorg-net.${pc1_domain}
${pc1_ip}   orderer3.ordererorg-net.${pc1_domain}
${orderer4_hosts:+${orderer4_hosts}
}${pc1_ip}   ca.ordererorg-net.${pc1_domain}
${pc1_ip}   ${pc1_domain}

# PC2 - Org1
${pc2_ip}   peer0.org1-net.${pc2_domain}
${pc2_ip}   ca.org1-net.${pc2_domain}
${pc2_ip}   ${pc2_domain}

# PC3 - Org2
${pc3_ip}   peer0.org2-net.${pc3_domain}
${pc3_ip}   ca.org2-net.${pc3_domain}
${pc3_ip}   ${pc3_domain}
# ---- End Bevel Network ----
EOF
    )

    log_info "The following will be added to /etc/hosts:"
    echo "$hosts_block"

    if ask_confirm "Add these entries to /etc/hosts?"; then
        # Remove old bevel entries if present
        sudo sed -i '/# ---- Hyperledger Fabric Bevel Network ----/,/# ---- End Bevel Network ----/d' /etc/hosts 2>/dev/null || true
        echo "$hosts_block" | sudo tee -a /etc/hosts > /dev/null
        log_success "/etc/hosts updated."
    else
        log_warning "Skipped /etc/hosts update. You must configure DNS manually."
    fi
}

setup_coredns() {
    log_step "Configuring CoreDNS in K3s cluster..."

    # Get local kubeconfig
    local kubeconfig
    local role
    role=$(load_config_var "ROLE")
    kubeconfig=$(load_config_var "KUBECONFIG_${role^^}")
    if [[ -z "$kubeconfig" ]] || [[ ! -f "$kubeconfig" ]]; then
        kubeconfig="/etc/rancher/k3s/k3s.yaml"
    fi
    log_info "Using kubeconfig: ${kubeconfig}"

    local pc1_ip pc2_ip pc3_ip pc1_domain pc2_domain pc3_domain consensus
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")
    pc1_domain=$(load_config_var "PC1_DOMAIN" "pc1.example.com")
    pc2_domain=$(load_config_var "PC2_DOMAIN" "pc2.example.com")
    pc3_domain=$(load_config_var "PC3_DOMAIN" "pc3.example.com")
    consensus=$(load_config_var "CONSENSUS" "raft")

    # BFT consensus requires 4 orderers
    local orderer4_coredns=""
    if [[ "$consensus" == "bft" ]]; then
        orderer4_coredns="
            ${pc1_ip} orderer4.ordererorg-net.${pc1_domain}"
    fi

    # Get current CoreDNS configmap
    local current_cm
    current_cm=$(kubectl --kubeconfig "$kubeconfig" get configmap coredns -n kube-system -o yaml 2>/dev/null)

    if [[ -z "$current_cm" ]]; then
        log_warning "Could not read CoreDNS configmap. K3s might not be ready yet."
        return 1
    fi

    # Check if hosts block already exists
    if echo "$current_cm" | grep -q "Hyperledger Fabric Bevel"; then
        log_info "CoreDNS already has Bevel host entries. Updating..."
    fi

    # Create a patch file for CoreDNS
    local coredns_patch="/tmp/coredns-patch.yaml"
    cat > "$coredns_patch" <<EOFPATCH
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        hosts {
            # Hyperledger Fabric Bevel Network
            ${pc1_ip} orderer1.ordererorg-net.${pc1_domain}
            ${pc1_ip} orderer2.ordererorg-net.${pc1_domain}
            ${pc1_ip} orderer3.ordererorg-net.${pc1_domain}${orderer4_coredns}
            ${pc1_ip} ca.ordererorg-net.${pc1_domain}
            ${pc2_ip} peer0.org1-net.${pc2_domain}
            ${pc2_ip} ca.org1-net.${pc2_domain}
            ${pc3_ip} peer0.org2-net.${pc3_domain}
            ${pc3_ip} ca.org2-net.${pc3_domain}
            fallthrough
        }
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
            max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
EOFPATCH

    log_info "Applying CoreDNS configuration..."
    kubectl --kubeconfig "$kubeconfig" apply -f "$coredns_patch"

    # Restart CoreDNS
    kubectl --kubeconfig "$kubeconfig" rollout restart deployment coredns -n kube-system
    sleep 5

    log_success "CoreDNS configured with Bevel host entries."
    rm -f "$coredns_patch"
}

# Setup CoreDNS on a remote cluster via kubeconfig
setup_coredns_remote() {
    local kubeconfig="$1"
    local cluster_name="$2"

    log_step "Configuring CoreDNS on ${cluster_name}..."

    local pc1_ip pc2_ip pc3_ip pc1_domain pc2_domain pc3_domain
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")
    pc1_domain=$(load_config_var "PC1_DOMAIN" "pc1.example.com")
    pc2_domain=$(load_config_var "PC2_DOMAIN" "pc2.example.com")
    pc3_domain=$(load_config_var "PC3_DOMAIN" "pc3.example.com")

    # BFT consensus requires 4 orderers
    local consensus orderer4_coredns=""
    consensus=$(load_config_var "CONSENSUS" "raft")
    if [[ "$consensus" == "bft" ]]; then
        orderer4_coredns="
            ${pc1_ip} orderer4.ordererorg-net.${pc1_domain}"
    fi

    local coredns_patch="/tmp/coredns-patch-${cluster_name}.yaml"
    cat > "$coredns_patch" <<EOFPATCH
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        hosts {
            ${pc1_ip} orderer1.ordererorg-net.${pc1_domain}
            ${pc1_ip} orderer2.ordererorg-net.${pc1_domain}
            ${pc1_ip} orderer3.ordererorg-net.${pc1_domain}${orderer4_coredns}
            ${pc1_ip} ca.ordererorg-net.${pc1_domain}
            ${pc2_ip} peer0.org1-net.${pc2_domain}
            ${pc2_ip} ca.org1-net.${pc2_domain}
            ${pc3_ip} peer0.org2-net.${pc3_domain}
            ${pc3_ip} ca.org2-net.${pc3_domain}
            fallthrough
        }
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
            max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
EOFPATCH

    kubectl --kubeconfig "$kubeconfig" apply -f "$coredns_patch"
    kubectl --kubeconfig "$kubeconfig" rollout restart deployment coredns -n kube-system
    sleep 3

    log_success "CoreDNS configured on ${cluster_name}."
    rm -f "$coredns_patch"
}

verify_dns() {
    log_step "Verifying DNS resolution..."

    local pc1_ip pc2_ip pc3_ip pc1_domain pc2_domain pc3_domain
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")
    pc1_domain=$(load_config_var "PC1_DOMAIN" "pc1.example.com")
    pc2_domain=$(load_config_var "PC2_DOMAIN" "pc2.example.com")
    pc3_domain=$(load_config_var "PC3_DOMAIN" "pc3.example.com")

    local consensus
    consensus=$(load_config_var "CONSENSUS" "raft")

    local hosts=(
        "orderer1.ordererorg-net.${pc1_domain}"
        "peer0.org1-net.${pc2_domain}"
        "peer0.org2-net.${pc3_domain}"
    )
    local expected_ips=("$pc1_ip" "$pc2_ip" "$pc3_ip")

    # BFT has orderer4
    if [[ "$consensus" == "bft" ]]; then
        hosts+=("orderer4.ordererorg-net.${pc1_domain}")
        expected_ips+=("$pc1_ip")
    fi
    local all_ok=true

    for i in "${!hosts[@]}"; do
        local host="${hosts[$i]}"
        local expected="${expected_ips[$i]}"
        if ping -c 1 -W 2 "$host" &>/dev/null; then
            log_success "  ${host} -> resolves OK"
        else
            log_warning "  ${host} -> cannot resolve or ping"
            all_ok=false
        fi
    done

    if $all_ok; then
        log_success "DNS resolution verified."
    else
        log_warning "Some DNS entries could not be verified. Check /etc/hosts and CoreDNS."
    fi
}
