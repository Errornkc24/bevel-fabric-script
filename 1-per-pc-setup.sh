#!/usr/bin/env bash
# =============================================================================
# 1-per-pc-setup.sh - Per-PC Independent Setup Script
# =============================================================================
# Run this script on EACH PC separately.
# It asks what role this PC plays and handles its local setup.
# For controller phases (Ansible/Bevel deploy), it asks if this PC is the controller.
#
# Usage: ./1-per-pc-setup.sh [--resume] [--dry-run] [--reset]
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
source "${LIB_DIR}/k3s-fixes.sh"
source "${LIB_DIR}/cleanup.sh"
source "${LIB_DIR}/network-control.sh"
source "${LIB_DIR}/monitoring.sh"
source "${LIB_DIR}/chaincode.sh"
source "${LIB_DIR}/explorer.sh"
source "${LIB_DIR}/verify.sh"
source "${LIB_DIR}/sync.sh"

# ---- Parse Arguments ----
RESUME=false
DRY_RUN=false
RESET=false
CLEAR=false
CLEAR_ALL=false
PAUSE=false
RESTART_NETWORK=false

for arg in "$@"; do
    case "$arg" in
        --resume)           RESUME=true ;;
        --dry-run)          DRY_RUN=true ;;
        --reset)            RESET=true ;;
        --clear)            CLEAR=true ;;
        --clear-all)        CLEAR_ALL=true ;;
        --pause)            PAUSE=true ;;
        --restart-network)  RESTART_NETWORK=true ;;
        --help)
            echo "Usage: ./1-per-pc-setup.sh [OPTION]"
            echo ""
            echo "Setup & Deploy:"
            echo "  (no args)          Fresh setup and deployment"
            echo "  --resume           Resume from last completed phase"
            echo "  --dry-run          Show what would be done without executing"
            echo ""
            echo "Network Control:"
            echo "  --pause            Pause the network (scale down pods, stop Vault)"
            echo "  --restart-network  Resume network after pause or PC reboot"
            echo ""
            echo "Cleanup:"
            echo "  --reset            Tear down the network via Ansible reset playbook"
            echo "  --clear            Remove all deployments & state, keep prerequisites"
            echo "  --clear-all        Remove everything except Docker, K3s, Node.js, kubectl, jq, yq"
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
        log_info "You can resume from where you left off with: ./1-per-pc-setup.sh --resume"
        log_info "Logs: ${BEVEL_LOG_FILE}"
    fi
}
trap cleanup EXIT

# ---- Main Flow ----
main() {
    init_config_dir
    init_checklist
    show_banner

    echo -e "${BOLD}Architecture: Per-PC Independent Setup${NC}"
    echo -e "${DIM}Run this script on each PC separately.${NC}\n"

    # Handle special commands
    if $CLEAR_ALL; then
        run_clear_all
        exit 0
    fi

    if $CLEAR; then
        run_clear
        exit 0
    fi

    if $PAUSE; then
        run_pause
        exit 0
    fi

    if $RESTART_NETWORK; then
        run_restart_network
        exit 0
    fi

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
        # Fresh start - collect basic info
        phase_collect_info
    fi

    local role
    role=$(load_config_var "ROLE")

    # ===== PHASE 1: Prerequisites =====
    if ! is_phase_done "prerequisites"; then
        show_checklist
        install_all_node_prerequisites
        mark_phase_done "prerequisites"
        log_success "Phase 1 complete: Prerequisites installed."
    else
        log_info "Phase 1 (Prerequisites) already done. Skipping."
    fi

    # ===== PHASE 1.5: Export Kubeconfig =====
    if ! is_phase_done "kubeconfig"; then
        show_checklist
        export_local_kubeconfig
        mark_phase_done "kubeconfig"
    else
        log_info "Kubeconfig already exported. Skipping."
    fi

    # ===== PHASE 2: Firewall =====
    if ! is_phase_done "firewall"; then
        show_checklist
        setup_firewall
        verify_firewall
        mark_phase_done "firewall"
    else
        log_info "Phase 2 (Firewall) already done. Skipping."
    fi

    # ===== SYNC: Wait for other PCs to have K3s + Firewall ready =====
    log_separator
    log_info "Before configuring DNS, all PCs should have K3s and firewall ready."
    wait_for_other_pcs "k3s"

    # ===== PHASE 3: DNS =====
    if ! is_phase_done "dns"; then
        show_checklist
        setup_etc_hosts
        setup_coredns
        verify_dns
        mark_phase_done "dns"
    else
        log_info "Phase 3 (DNS) already done. Skipping."
    fi

    # ===== PHASE 4: HAProxy =====
    if ! is_phase_done "haproxy"; then
        show_checklist
        install_haproxy_local
        verify_haproxy_local
        mark_phase_done "haproxy"
    else
        log_info "Phase 4 (HAProxy) already done. Skipping."
    fi

    # ===== PHASE 5: Vault =====
    if ! is_phase_done "vault"; then
        show_checklist
        setup_vault
        verify_vault
        mark_phase_done "vault"
    else
        # Verify Vault is actually running, not just marked done from stale state
        local this_ip
        this_ip=$(load_config_var "THIS_PC_IP" "127.0.0.1")
        if ! curl -s --connect-timeout 3 "http://${this_ip}:8200/v1/sys/health" 2>/dev/null | grep -q '"initialized":true'; then
            log_warning "Vault marked as done but not running. Re-running Vault setup..."
            rm -f "${BEVEL_STATE_DIR}/vault.state"
            show_checklist
            setup_vault
            verify_vault
            mark_phase_done "vault"
        else
            log_info "Phase 5 (Vault) already done. Skipping."
        fi
    fi

    # ===== SYNC: Wait for all PCs to have Vault ready =====
    wait_for_other_pcs "vault"
    verify_cross_pc_connectivity

    show_checklist
    log_separator
    echo -e "\n${GREEN}${BOLD}Local setup for this PC is complete!${NC}\n"

    # ===== CONTROLLER PHASES =====
    local is_controller
    is_controller=$(ask_choice "Is this PC also the Ansible controller?" \
        "Yes - this PC will run Ansible playbooks to deploy the network" \
        "No - another PC/machine is the controller (stop here)")

    if [[ "$is_controller" == "1" ]]; then
        log_info "Local setup complete. Run the controller phases from the controller machine."
        log_info "The controller needs:"
        echo -e "  - Kubeconfigs from all 3 PCs"
        echo -e "  - Ansible + Python installed"
        echo -e "  - Bevel repo cloned"
        echo -e "  - Access to all 3 Vault instances"
        show_checklist
        exit 0
    fi

    save_config_var "IS_CONTROLLER" "true"

    # ===== PHASE 6: Controller Prerequisites =====
    if ! is_phase_done "ansible_prereqs"; then
        show_checklist
        install_controller_prerequisites
        mark_phase_done "ansible_prereqs"
    fi

    # ===== PHASE 6.5: Setup all kubeconfigs on controller =====
    setup_controller_kubeconfigs
    verify_kubectl_access

    # ===== PHASE 6: GitOps =====
    if ! is_phase_done "gitops"; then
        show_checklist
        setup_gitops
        mark_phase_done "gitops"
    fi

    # ===== Collect Vault info from all PCs =====
    collect_vault_info_for_controller

    # ===== PHASE 7: DNS on remote clusters =====
    log_info "Configuring CoreDNS on remote clusters..."
    local kc_org1 kc_org2
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2")

    if [[ "$role" == "orderer" ]]; then
        # Controller is PC1 - configure CoreDNS on PC2, PC3
        setup_coredns_remote "$kc_org1" "org1-cluster"
        setup_coredns_remote "$kc_org2" "org2-cluster"
    fi

    # ===== PHASE 7: HAProxy on remote clusters =====
    log_info "Ensuring HAProxy on all clusters..."
    local kc_orderer
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")

    install_haproxy_remote "$kc_orderer" "orderer-cluster"
    install_haproxy_remote "$kc_org1" "org1-cluster"
    install_haproxy_remote "$kc_org2" "org2-cluster"

    # ===== PHASE 7.5: K3s Compatibility Fixes =====
    # Disable Traefik, promote HAProxy to LoadBalancer, create IngressClass
    if ! is_phase_done "k3s_fixes"; then
        apply_all_k3s_fixes
        mark_phase_done "k3s_fixes"
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

    # ===== PHASE 12: Chaincode =====
    if ! is_phase_done "chaincode"; then
        show_checklist
        setup_chaincode
        mark_phase_done "chaincode"
    else
        log_info "Phase 12 (Chaincode) already done. Skipping."
        log_info "  To re-run: rm ~/.bevel-setup/state/chaincode.state && ./1-per-pc-setup.sh --resume"
    fi

    # ===== PHASE 13: Explorer =====
    if ! is_phase_done "explorer"; then
        show_checklist
        setup_explorer
        mark_phase_done "explorer"
    else
        log_info "Phase 13 (Explorer) already done. Skipping."
    fi

    # ===== DONE =====
    show_checklist
    log_header "SETUP COMPLETE!"
    echo -e "${GREEN}${BOLD}Your Hyperledger Fabric network is deployed and running!${NC}\n"
    show_installed_versions
    health_check
    echo ""
    echo -e "${CYAN}${BOLD}Deployed Services:${NC}"
    show_chaincode_summary 2>/dev/null || true
    show_explorer_urls 2>/dev/null || true
    show_monitoring_urls 2>/dev/null || true
}

phase_collect_info() {
    log_step "Initial Configuration"

    # Role selection
    local role
    role=$(ask_role)
    log_info "Role: ${role}"

    # Consensus selection
    ask_consensus

    # IP collection
    collect_ips

    log_success "Configuration collected. Starting setup..."
}

main "$@"
