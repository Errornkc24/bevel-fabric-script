#!/usr/bin/env bash
# =============================================================================
# 2-controller-setup.sh - Controller-Based Setup Script
# =============================================================================
# Run this script on ONE controller PC only.
# It SSHes into all 3 PCs to execute remote commands.
# Handles everything from a single machine.
#
# Prerequisites: SSH key-based auth to all 3 PCs must already work.
#
# Usage: ./2-controller-setup.sh [--resume] [--dry-run] [--reset]
# =============================================================================

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${BASE_DIR}/lib"

# Source all library files
# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/prerequisites.sh"
source "${LIB_DIR}/firewall.sh"
source "${LIB_DIR}/dns.sh"
source "${LIB_DIR}/haproxy.sh"
source "${LIB_DIR}/vault-setup.sh"
source "${LIB_DIR}/kubeconfig.sh"
source "${LIB_DIR}/gitops.sh"
source "${LIB_DIR}/network-yaml.sh"
source "${LIB_DIR}/bevel-deploy.sh"
source "${LIB_DIR}/monitoring.sh"
source "${LIB_DIR}/verify.sh"
source "${LIB_DIR}/sync.sh"

# ---- Parse Arguments ----
RESUME=false
DRY_RUN=false
RESET=false

for arg in "$@"; do
    case "$arg" in
        --resume)  RESUME=true ;;
        --dry-run) DRY_RUN=true ;;
        --reset)   RESET=true ;;
        --help)
            echo "Usage: ./2-controller-setup.sh [--resume] [--dry-run] [--reset]"
            echo "  --resume   Resume from last completed phase"
            echo "  --dry-run  Show what would be done without executing"
            echo "  --reset    Tear down the network"
            exit 0
            ;;
    esac
done

# ---- Cleanup trap ----
cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        echo ""
        log_error "Script exited with code ${exit_code}"
        log_info "Resume with: ./2-controller-setup.sh --resume"
        log_info "Logs: ${BEVEL_LOG_FILE}"
    fi
}
trap cleanup EXIT

# ---- SSH Helper ----
# Execute a command on a remote PC via SSH
ssh_exec() {
    local user="$1"
    local host="$2"
    shift 2
    local cmd="$*"

    log_info "  [SSH ${host}] ${cmd:0:80}..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${user}@${host}" "$cmd" 2>&1
}

# Copy a file to a remote PC
scp_to() {
    local user="$1"
    local host="$2"
    local local_file="$3"
    local remote_file="$4"
    scp -o StrictHostKeyChecking=no "$local_file" "${user}@${host}:${remote_file}"
}

# ---- Test SSH to all PCs ----
test_ssh_access() {
    log_step "Testing SSH connectivity to all PCs..."

    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")
    local ssh1 ssh2 ssh3
    ssh1=$(load_config_var "SSH_USER_PC1")
    ssh2=$(load_config_var "SSH_USER_PC2")
    ssh3=$(load_config_var "SSH_USER_PC3")

    local all_ok=true
    for pair in "${ssh1}@${pc1_ip}" "${ssh2}@${pc2_ip}" "${ssh3}@${pc3_ip}"; do
        local u="${pair%%@*}"
        local h="${pair#*@}"
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${u}@${h}" "echo ok" &>/dev/null; then
            log_success "  SSH to ${h} as ${u} - OK"
        else
            log_error "  SSH to ${h} as ${u} - FAILED"
            all_ok=false
        fi
    done

    if ! $all_ok; then
        log_error "SSH access failed for some PCs."
        log_info "Ensure SSH key-based auth is set up:"
        echo -e "  ssh-copy-id ${ssh1}@${pc1_ip}"
        echo -e "  ssh-copy-id ${ssh2}@${pc2_ip}"
        echo -e "  ssh-copy-id ${ssh3}@${pc3_ip}"
        if ! ask_confirm "Continue anyway?"; then
            exit 1
        fi
    fi
}

# ---- Remote Prerequisite Installation ----
install_prereqs_remote() {
    local user="$1"
    local host="$2"
    local pc_name="$3"
    local this_ip="$4"

    log_step "Installing prerequisites on ${pc_name} (${host})..."

    # Install Docker
    ssh_exec "$user" "$host" "
        if command -v docker &>/dev/null; then
            echo 'Docker already installed'
        else
            echo 'Installing Docker...'
            sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            sudo apt-get update -y
            sudo apt-get install -y ca-certificates curl gnupg lsb-release
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
            echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update -y
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            sudo usermod -aG docker \$USER
            echo 'Docker installed.'
        fi
    " || log_warning "Docker install on ${pc_name} may have had issues."

    # Install K3s
    ssh_exec "$user" "$host" "
        if sudo systemctl is-active --quiet k3s 2>/dev/null; then
            echo 'K3s already running'
        else
            echo 'Installing K3s with TLS SAN=${this_ip}...'
            curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--tls-san ${this_ip} --write-kubeconfig-mode 644 --disable traefik' sh -
            echo 'K3s installed.'
        fi
    " || log_warning "K3s install on ${pc_name} may have had issues."

    # Install Vault binary
    ssh_exec "$user" "$host" "
        if command -v vault &>/dev/null; then
            echo 'Vault already installed'
        else
            echo 'Installing Vault...'
            sudo apt-get install -y unzip
            wget -q 'https://releases.hashicorp.com/vault/1.15.2/vault_1.15.2_linux_amd64.zip' -O /tmp/vault.zip
            unzip -o /tmp/vault.zip -d /tmp/
            sudo mv /tmp/vault /usr/local/bin/
            rm -f /tmp/vault.zip
            echo 'Vault installed.'
        fi
    " || log_warning "Vault install on ${pc_name} may have had issues."

    # Install Helm
    ssh_exec "$user" "$host" "
        if command -v helm &>/dev/null; then
            echo 'Helm already installed'
        else
            echo 'Installing Helm...'
            curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            echo 'Helm installed.'
        fi
    " || log_warning "Helm install on ${pc_name} may have had issues."

    # Install jq, netcat
    ssh_exec "$user" "$host" "sudo apt-get install -y jq netcat-openbsd" || true

    log_success "Prerequisites installed on ${pc_name}."
}

# ---- Remote Firewall Setup ----
setup_firewall_remote() {
    local user="$1"
    local host="$2"
    local pc_name="$3"

    log_step "Configuring firewall on ${pc_name} (${host})..."

    ssh_exec "$user" "$host" "
        echo 'y' | sudo ufw enable 2>/dev/null || true
        sudo ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
        sudo ufw allow 6443/tcp comment 'Kubernetes API' 2>/dev/null || true
        sudo ufw allow 80/tcp comment 'HAProxy HTTP' 2>/dev/null || true
        sudo ufw allow 443/tcp comment 'HAProxy HTTPS' 2>/dev/null || true
        sudo ufw allow 30000:32767/tcp comment 'K8s NodePort' 2>/dev/null || true
        sudo ufw allow 8200/tcp comment 'Vault' 2>/dev/null || true
        sudo ufw allow 10250/tcp comment 'Kubelet' 2>/dev/null || true
        sudo ufw allow 8472/udp comment 'Flannel' 2>/dev/null || true
        sudo ufw allow 51820/udp comment 'Wireguard' 2>/dev/null || true
        sudo ufw allow 51821/udp comment 'Wireguard IPv6' 2>/dev/null || true
        sudo ufw allow 30090/tcp comment 'Prometheus' 2>/dev/null || true
        sudo ufw allow 30300/tcp comment 'Grafana' 2>/dev/null || true
        sudo ufw allow 31090/tcp comment 'Central Prometheus' 2>/dev/null || true
        sudo ufw allow 31300/tcp comment 'Central Grafana' 2>/dev/null || true
        echo 'Firewall configured.'
    "

    log_success "Firewall configured on ${pc_name}."
}

# ---- Remote DNS Setup ----
setup_dns_remote() {
    local user="$1"
    local host="$2"
    local pc_name="$3"

    local pc1_ip pc2_ip pc3_ip pc1_domain pc2_domain pc3_domain
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")
    pc1_domain=$(load_config_var "PC1_DOMAIN" "pc1.example.com")
    pc2_domain=$(load_config_var "PC2_DOMAIN" "pc2.example.com")
    pc3_domain=$(load_config_var "PC3_DOMAIN" "pc3.example.com")

    log_step "Configuring /etc/hosts on ${pc_name} (${host})..."

    ssh_exec "$user" "$host" "
        sudo sed -i '/# ---- Hyperledger Fabric Bevel Network ----/,/# ---- End Bevel Network ----/d' /etc/hosts 2>/dev/null || true
        sudo tee -a /etc/hosts > /dev/null <<'HOSTEOF'

# ---- Hyperledger Fabric Bevel Network ----
${pc1_ip}   orderer1.ordererorg-net.${pc1_domain}
${pc1_ip}   orderer2.ordererorg-net.${pc1_domain}
${pc1_ip}   orderer3.ordererorg-net.${pc1_domain}
${pc1_ip}   ca.ordererorg-net.${pc1_domain}
${pc1_ip}   ${pc1_domain}
${pc2_ip}   peer0.org1-net.${pc2_domain}
${pc2_ip}   ca.org1-net.${pc2_domain}
${pc2_ip}   ${pc2_domain}
${pc3_ip}   peer0.org2-net.${pc3_domain}
${pc3_ip}   ca.org2-net.${pc3_domain}
${pc3_ip}   ${pc3_domain}
# ---- End Bevel Network ----
HOSTEOF
        echo '/etc/hosts updated.'
    "

    log_success "/etc/hosts configured on ${pc_name}."
}

# ---- Remote Vault Setup ----
setup_vault_remote() {
    local user="$1"
    local host="$2"
    local pc_name="$3"
    local vault_token="$4"

    log_step "Starting Vault on ${pc_name} (${host})..."

    ssh_exec "$user" "$host" "
        if curl -s 'http://${host}:8200/v1/sys/health' 2>/dev/null | grep -q 'initialized'; then
            echo 'Vault already running.'
        else
            pkill vault 2>/dev/null || true
            sleep 1
            nohup vault server -dev -dev-root-token-id='${vault_token}' -dev-listen-address='0.0.0.0:8200' > /tmp/vault.log 2>&1 &
            sleep 5
            export VAULT_ADDR='http://${host}:8200'
            export VAULT_TOKEN='${vault_token}'
            vault secrets enable -version=2 -path=secretsv2 kv 2>/dev/null || echo 'secretsv2 may already be enabled'
            echo 'Vault started and configured.'
        fi
    "

    log_success "Vault running on ${pc_name}."
}

# ---- Main Flow ----
main() {
    init_config_dir
    init_checklist
    show_banner

    echo -e "${BOLD}Architecture: Controller-Based Setup${NC}"
    echo -e "${DIM}This script runs on one controller PC and manages all 3 PCs via SSH.${NC}\n"

    # Handle reset
    if $RESET; then
        run_network_reset
        exit 0
    fi

    # Resume or fresh start
    if $RESUME && [[ -f "$BEVEL_CONFIG_FILE" ]]; then
        log_info "Resuming from previous session..."
        load_all_config
        show_checklist
    else
        phase_collect_info
    fi

    local pc1_ip pc2_ip pc3_ip ssh1 ssh2 ssh3
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")
    ssh1=$(load_config_var "SSH_USER_PC1")
    ssh2=$(load_config_var "SSH_USER_PC2")
    ssh3=$(load_config_var "SSH_USER_PC3")

    # Test SSH
    test_ssh_access

    # ===== PHASE 1: Install Prerequisites on ALL PCs =====
    if ! is_phase_done "prerequisites"; then
        show_checklist
        log_header "PHASE 1: Installing Prerequisites on ALL PCs"

        install_prereqs_remote "$ssh1" "$pc1_ip" "PC1-Orderer" "$pc1_ip"
        install_prereqs_remote "$ssh2" "$pc2_ip" "PC2-Org1" "$pc2_ip"
        install_prereqs_remote "$ssh3" "$pc3_ip" "PC3-Org2" "$pc3_ip"

        # Also install controller prerequisites locally
        install_controller_prerequisites

        mark_phase_done "prerequisites"
    else
        log_info "Phase 1 (Prerequisites) already done. Skipping."
    fi

    # ===== PHASE 2: Firewall on ALL PCs =====
    if ! is_phase_done "firewall"; then
        show_checklist
        log_header "PHASE 2: Configuring Firewalls"

        setup_firewall_remote "$ssh1" "$pc1_ip" "PC1-Orderer"
        setup_firewall_remote "$ssh2" "$pc2_ip" "PC2-Org1"
        setup_firewall_remote "$ssh3" "$pc3_ip" "PC3-Org2"

        mark_phase_done "firewall"
    fi

    # ===== Verify connectivity =====
    verify_cross_pc_connectivity

    # ===== PHASE 3: DNS on ALL PCs =====
    if ! is_phase_done "dns"; then
        show_checklist
        log_header "PHASE 3: DNS Configuration"

        # Collect domain names if not already set
        if [[ -z "$(load_config_var PC1_DOMAIN)" ]]; then
            local pc1_domain pc2_domain pc3_domain
            pc1_domain=$(ask_input "Domain suffix for PC1" "pc1.example.com")
            pc2_domain=$(ask_input "Domain suffix for PC2" "pc2.example.com")
            pc3_domain=$(ask_input "Domain suffix for PC3" "pc3.example.com")
            save_config_var "PC1_DOMAIN" "$pc1_domain"
            save_config_var "PC2_DOMAIN" "$pc2_domain"
            save_config_var "PC3_DOMAIN" "$pc3_domain"
        fi

        setup_dns_remote "$ssh1" "$pc1_ip" "PC1-Orderer"
        setup_dns_remote "$ssh2" "$pc2_ip" "PC2-Org1"
        setup_dns_remote "$ssh3" "$pc3_ip" "PC3-Org2"

        # Also configure /etc/hosts on this controller
        setup_etc_hosts

        mark_phase_done "dns"
    fi

    # ===== Kubeconfig setup =====
    if ! is_phase_done "kubeconfig"; then
        show_checklist
        setup_controller_kubeconfigs
        verify_kubectl_access
        mark_phase_done "kubeconfig"
    fi

    # ===== Configure CoreDNS on all clusters =====
    local kc_orderer kc_org1 kc_org2
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2")

    setup_coredns_remote "$kc_orderer" "orderer-cluster"
    setup_coredns_remote "$kc_org1" "org1-cluster"
    setup_coredns_remote "$kc_org2" "org2-cluster"

    # ===== PHASE 4: HAProxy on ALL clusters =====
    if ! is_phase_done "haproxy"; then
        show_checklist
        log_header "PHASE 4: HAProxy Installation"

        install_haproxy_remote "$kc_orderer" "orderer-cluster"
        install_haproxy_remote "$kc_org1" "org1-cluster"
        install_haproxy_remote "$kc_org2" "org2-cluster"

        mark_phase_done "haproxy"
    fi

    # ===== PHASE 5: Vault on ALL PCs =====
    if ! is_phase_done "vault"; then
        show_checklist
        log_header "PHASE 5: Vault Setup"

        log_info "Setting up Vault on all PCs..."

        local vault_mode
        vault_mode=$(ask_choice "Vault mode for all PCs?" \
            "Dev mode (in-memory, for testing)" \
            "Production mode (persistent)")

        if [[ "$vault_mode" == "0" ]]; then
            local t1 t2 t3
            t1=$(ask_input "Vault token for PC1 (Orderer)" "roottoken-orderer")
            t2=$(ask_input "Vault token for PC2 (Org1)" "roottoken-org1")
            t3=$(ask_input "Vault token for PC3 (Org2)" "roottoken-org2")

            save_config_var "VAULT_TOKEN_ORDERER" "$t1"
            save_config_var "VAULT_TOKEN_ORG1" "$t2"
            save_config_var "VAULT_TOKEN_ORG2" "$t3"
            save_config_var "VAULT_URL_ORDERER" "http://${pc1_ip}:8200"
            save_config_var "VAULT_URL_ORG1" "http://${pc2_ip}:8200"
            save_config_var "VAULT_URL_ORG2" "http://${pc3_ip}:8200"

            setup_vault_remote "$ssh1" "$pc1_ip" "PC1-Orderer" "$t1"
            setup_vault_remote "$ssh2" "$pc2_ip" "PC2-Org1" "$t2"
            setup_vault_remote "$ssh3" "$pc3_ip" "PC3-Org2" "$t3"
        else
            log_warning "Production Vault setup via SSH is complex."
            log_info "Please set up Vault manually on each PC, then enter the tokens."
            collect_vault_info_for_controller
        fi

        # Verify Vault on all PCs
        for pair in "${pc1_ip}:PC1" "${pc2_ip}:PC2" "${pc3_ip}:PC3"; do
            local ip="${pair%%:*}"
            local name="${pair#*:}"
            if curl -s "http://${ip}:8200/v1/sys/health" 2>/dev/null | grep -q '"sealed":false'; then
                log_success "Vault on ${name} (${ip}) - OK"
            else
                log_warning "Vault on ${name} (${ip}) - not ready"
            fi
        done

        mark_phase_done "vault"
    fi

    # ===== PHASE 6: GitOps =====
    if ! is_phase_done "gitops"; then
        show_checklist
        setup_gitops
        mark_phase_done "gitops"
    fi

    # ===== PHASE 7: Ansible Prerequisites =====
    if ! is_phase_done "ansible_prereqs"; then
        show_checklist
        install_controller_prerequisites
        mark_phase_done "ansible_prereqs"
    fi

    # ===== PHASE 8: Generate network.yaml =====
    if ! is_phase_done "network_yaml"; then
        show_checklist
        generate_network_yaml
        mark_phase_done "network_yaml"
    fi

    # ===== PHASE 9: Deploy =====
    if ! is_phase_done "k8s_env"; then
        show_checklist
        run_k8s_environment_setup
        mark_phase_done "k8s_env"
    fi

    if ! is_phase_done "deploy_network"; then
        show_checklist
        run_site_deployment
        mark_phase_done "deploy_network"
    fi

    # ===== PHASE 10: Verify =====
    if ! is_phase_done "verify_network"; then
        show_checklist
        verify_network
        mark_phase_done "verify_network"
    fi

    # ===== PHASE 11: Monitoring =====
    if ! is_phase_done "monitoring"; then
        show_checklist
        setup_monitoring
        mark_phase_done "monitoring"
    fi

    # ===== DONE =====
    show_checklist
    log_header "SETUP COMPLETE!"
    echo -e "${GREEN}${BOLD}Your Hyperledger Fabric network is deployed and running!${NC}\n"
    show_installed_versions
    health_check
}

phase_collect_info() {
    log_step "Initial Configuration"

    # This script always runs on the controller
    save_config_var "IS_CONTROLLER" "true"

    # Consensus selection
    ask_consensus

    # Controller's own role
    local controller_role
    controller_role=$(ask_choice "What role does THIS controller PC also play?" \
        "Orderer Org (PC1) - controller is also the orderer node" \
        "Peer Org1 (PC2) - controller is also org1 peer" \
        "Peer Org2 (PC3) - controller is also org2 peer" \
        "Dedicated controller (4th machine - not running any Fabric components)")
    case "$controller_role" in
        0) save_config_var "ROLE" "orderer" ;;
        1) save_config_var "ROLE" "org1" ;;
        2) save_config_var "ROLE" "org2" ;;
        3) save_config_var "ROLE" "controller_only" ;;
    esac

    # IP collection
    echo -e "\n${BOLD}Enter IP addresses for all 3 PCs:${NC}"
    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(ask_input "IP of PC1 (Orderer Org)")
    validate_ip "$pc1_ip" || { log_error "Invalid IP"; exit 1; }
    save_config_var "PC1_IP" "$pc1_ip"

    pc2_ip=$(ask_input "IP of PC2 (Org1 - Peer)")
    validate_ip "$pc2_ip" || { log_error "Invalid IP"; exit 1; }
    save_config_var "PC2_IP" "$pc2_ip"

    pc3_ip=$(ask_input "IP of PC3 (Org2 - Peer)")
    validate_ip "$pc3_ip" || { log_error "Invalid IP"; exit 1; }
    save_config_var "PC3_IP" "$pc3_ip"

    # Detect this PC's IP
    local this_ip
    this_ip=$(get_local_ip)
    save_config_var "THIS_PC_IP" "$this_ip"

    # SSH usernames
    echo -e "\n${BOLD}SSH credentials for remote access:${NC}"
    local default_user
    default_user=$(whoami)
    local ssh1 ssh2 ssh3
    ssh1=$(ask_input "SSH username for PC1 (${pc1_ip})" "$default_user")
    ssh2=$(ask_input "SSH username for PC2 (${pc2_ip})" "$default_user")
    ssh3=$(ask_input "SSH username for PC3 (${pc3_ip})" "$default_user")
    save_config_var "SSH_USER_PC1" "$ssh1"
    save_config_var "SSH_USER_PC2" "$ssh2"
    save_config_var "SSH_USER_PC3" "$ssh3"

    log_success "Configuration collected."
}

main "$@"
