#!/usr/bin/env bash
# =============================================================================
# 3-hybrid-setup.sh - Hybrid Setup Script
# =============================================================================
# Part A (infra): Run on EACH PC locally - installs Docker, K3s, firewall,
#                 DNS, HAProxy, Vault (Phases 1-5)
# Part B (deploy): Run on CONTROLLER only - Ansible, Bevel deploy, monitoring
#                  (Phases 6-12)
#
# Usage:
#   ./3-hybrid-setup.sh infra    # Run on each PC for local infrastructure
#   ./3-hybrid-setup.sh deploy   # Run on controller for Bevel deployment
#   ./3-hybrid-setup.sh health   # Quick health check
#   ./3-hybrid-setup.sh reset    # Tear down the network
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

# ---- Usage ----
show_usage() {
    echo "Usage: ./3-hybrid-setup.sh <mode> [options]"
    echo ""
    echo "Modes:"
    echo "  infra    Run local infrastructure setup (each PC)"
    echo "  deploy   Run Bevel deployment (controller only)"
    echo "  health   Quick health check of the network"
    echo "  reset    Tear down the network"
    echo ""
    echo "Options:"
    echo "  --resume   Resume from last completed phase"
    echo ""
    echo "Workflow:"
    echo "  1. Run './3-hybrid-setup.sh infra' on ALL 3 PCs"
    echo "  2. Run './3-hybrid-setup.sh deploy' on the CONTROLLER PC"
    exit 0
}

# ---- Parse Arguments ----
MODE="${1:-}"
RESUME=false

if [[ -z "$MODE" ]] || [[ "$MODE" == "--help" ]] || [[ "$MODE" == "-h" ]]; then
    show_usage
fi

shift
for arg in "$@"; do
    case "$arg" in
        --resume) RESUME=true ;;
    esac
done

# ---- Cleanup trap ----
cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        echo ""
        log_error "Script exited with code ${exit_code}"
        log_info "Resume with: ./3-hybrid-setup.sh ${MODE} --resume"
        log_info "Logs: ${BEVEL_LOG_FILE}"
    fi
}
trap cleanup EXIT

# =============================================================================
# PART A: Infrastructure Mode (run on each PC)
# =============================================================================
run_infra_mode() {
    init_config_dir
    init_checklist
    show_banner

    echo -e "${BOLD}Hybrid Script - Part A: Local Infrastructure Setup${NC}"
    echo -e "${DIM}Run this on EACH PC to set up Docker, K3s, Firewall, DNS, HAProxy, Vault.${NC}\n"

    if $RESUME && [[ -f "$BEVEL_CONFIG_FILE" ]]; then
        log_info "Resuming from previous session..."
        load_all_config
        show_checklist
    else
        # Collect basic info
        log_step "Initial Configuration"
        local role
        role=$(ask_role)
        ask_consensus
        collect_ips
    fi

    # ===== PHASE 1: Prerequisites =====
    if ! is_phase_done "prerequisites"; then
        show_checklist
        install_all_node_prerequisites
        mark_phase_done "prerequisites"
    else
        log_info "Phase 1 (Prerequisites) already done."
    fi

    # ===== Export Kubeconfig =====
    if ! is_phase_done "kubeconfig"; then
        show_checklist
        export_local_kubeconfig
        mark_phase_done "kubeconfig"
    fi

    # ===== PHASE 2: Firewall =====
    if ! is_phase_done "firewall"; then
        show_checklist
        setup_firewall
        verify_firewall
        mark_phase_done "firewall"
    fi

    # ===== SYNC: Wait for other PCs =====
    log_info "Waiting for other PCs to complete prerequisites + firewall..."
    wait_for_other_pcs "k3s"

    # ===== PHASE 3: DNS =====
    if ! is_phase_done "dns"; then
        show_checklist
        setup_etc_hosts
        setup_coredns
        verify_dns
        mark_phase_done "dns"
    fi

    # ===== PHASE 4: HAProxy =====
    if ! is_phase_done "haproxy"; then
        show_checklist
        install_haproxy_local
        verify_haproxy_local
        mark_phase_done "haproxy"
    fi

    # ===== PHASE 5: Vault =====
    if ! is_phase_done "vault"; then
        show_checklist
        setup_vault
        verify_vault
        mark_phase_done "vault"
    fi

    # ===== Final sync =====
    wait_for_other_pcs "vault"
    verify_cross_pc_connectivity

    # ===== Show summary =====
    show_checklist
    log_separator

    echo -e "\n${GREEN}${BOLD}Local infrastructure setup complete for this PC!${NC}\n"
    echo -e "${BOLD}Next steps:${NC}"
    echo -e "  1. Ensure all 3 PCs have completed 'infra' mode"
    echo -e "  2. On the controller PC, run:"
    echo -e "     ${CYAN}./3-hybrid-setup.sh deploy${NC}"
    echo ""

    local role
    role=$(load_config_var "ROLE")
    local this_ip
    this_ip=$(load_config_var "THIS_PC_IP")

    echo -e "${BOLD}Info for the controller:${NC}"
    echo -e "  Role:      ${role}"
    echo -e "  IP:        ${this_ip}"
    echo -e "  Kubeconfig: $(load_config_var "KUBECONFIG_${role^^}")"
    echo -e "  Vault URL:  $(load_config_var "VAULT_URL_${role^^}")"
    echo -e "  Vault Token: [stored in ${BEVEL_CONFIG_FILE}]"
    echo ""

    show_installed_versions
}

# =============================================================================
# PART B: Deploy Mode (run on controller only)
# =============================================================================
run_deploy_mode() {
    init_config_dir
    init_checklist
    show_banner

    echo -e "${BOLD}Hybrid Script - Part B: Controller Deployment${NC}"
    echo -e "${DIM}Run this on the CONTROLLER PC after all 3 PCs completed 'infra' mode.${NC}\n"

    save_config_var "IS_CONTROLLER" "true"

    if $RESUME && [[ -f "$BEVEL_CONFIG_FILE" ]]; then
        log_info "Resuming from previous session..."
        load_all_config
        show_checklist
    else
        # Collect info for controller
        deploy_collect_info
    fi

    # ===== Controller Prerequisites =====
    if ! is_phase_done "ansible_prereqs"; then
        show_checklist
        install_controller_prerequisites
        mark_phase_done "ansible_prereqs"
    fi

    # ===== Kubeconfig setup =====
    if ! is_phase_done "kubeconfig"; then
        setup_controller_kubeconfigs
        verify_kubectl_access
        mark_phase_done "kubeconfig"
    else
        # Still verify access
        local kc_orderer kc_org1 kc_org2
        kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")
        kc_org1=$(load_config_var "KUBECONFIG_ORG1")
        kc_org2=$(load_config_var "KUBECONFIG_ORG2")
        verify_kubectl_access || log_warning "Some clusters not reachable."
    fi

    # ===== CoreDNS on all clusters =====
    local kc_orderer kc_org1 kc_org2
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2")

    if ! is_phase_done "dns"; then
        if [[ -z "$(load_config_var PC1_DOMAIN)" ]]; then
            local d1 d2 d3
            d1=$(ask_input "Domain suffix for PC1" "pc1.example.com")
            d2=$(ask_input "Domain suffix for PC2" "pc2.example.com")
            d3=$(ask_input "Domain suffix for PC3" "pc3.example.com")
            save_config_var "PC1_DOMAIN" "$d1"
            save_config_var "PC2_DOMAIN" "$d2"
            save_config_var "PC3_DOMAIN" "$d3"
        fi

        setup_coredns_remote "$kc_orderer" "orderer-cluster"
        setup_coredns_remote "$kc_org1" "org1-cluster"
        setup_coredns_remote "$kc_org2" "org2-cluster"
        setup_etc_hosts
        mark_phase_done "dns"
    fi

    # ===== HAProxy on all clusters (from controller) =====
    if ! is_phase_done "haproxy"; then
        show_checklist
        install_haproxy_remote "$kc_orderer" "orderer-cluster"
        install_haproxy_remote "$kc_org1" "org1-cluster"
        install_haproxy_remote "$kc_org2" "org2-cluster"
        mark_phase_done "haproxy"
    fi

    # ===== Vault info collection =====
    if ! is_phase_done "vault"; then
        collect_vault_info_for_controller
        mark_phase_done "vault"
    fi

    # ===== GitOps =====
    if ! is_phase_done "gitops"; then
        show_checklist
        setup_gitops
        mark_phase_done "gitops"
    fi

    # ===== Generate network.yaml =====
    if ! is_phase_done "network_yaml"; then
        show_checklist
        generate_network_yaml
        mark_phase_done "network_yaml"
    fi

    # ===== Deploy =====
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

    # ===== Verify =====
    if ! is_phase_done "verify_network"; then
        show_checklist
        verify_network
        mark_phase_done "verify_network"
    fi

    # ===== Monitoring =====
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

deploy_collect_info() {
    log_step "Controller Configuration"

    # Consensus
    if [[ -z "$(load_config_var CONSENSUS)" ]]; then
        ask_consensus
    fi

    # Controller role
    local controller_role
    controller_role=$(ask_choice "Is this controller also one of the 3 PCs?" \
        "Yes - PC1 (Orderer)" \
        "Yes - PC2 (Org1)" \
        "Yes - PC3 (Org2)" \
        "No - dedicated 4th machine")
    case "$controller_role" in
        0) save_config_var "ROLE" "orderer" ;;
        1) save_config_var "ROLE" "org1" ;;
        2) save_config_var "ROLE" "org2" ;;
        3) save_config_var "ROLE" "controller_only" ;;
    esac

    # IPs
    echo -e "\n${BOLD}Enter IP addresses:${NC}"
    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(ask_input "PC1 IP (Orderer)")
    save_config_var "PC1_IP" "$pc1_ip"
    pc2_ip=$(ask_input "PC2 IP (Org1)")
    save_config_var "PC2_IP" "$pc2_ip"
    pc3_ip=$(ask_input "PC3 IP (Org2)")
    save_config_var "PC3_IP" "$pc3_ip"

    local this_ip
    this_ip=$(get_local_ip)
    save_config_var "THIS_PC_IP" "$this_ip"

    log_success "Controller configuration collected."
}

# =============================================================================
# Entry Point
# =============================================================================
case "$MODE" in
    infra)
        run_infra_mode
        ;;
    deploy)
        run_deploy_mode
        ;;
    health)
        init_config_dir
        init_checklist
        load_all_config
        health_check
        ;;
    reset)
        init_config_dir
        init_checklist
        load_all_config
        run_network_reset
        ;;
    *)
        log_error "Unknown mode: ${MODE}"
        show_usage
        ;;
esac
