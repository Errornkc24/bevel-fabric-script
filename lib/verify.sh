#!/usr/bin/env bash
# =============================================================================
# verify.sh - Network verification and health checks
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

verify_network() {
    log_header "PHASE 10: Network Verification"

    verify_pods
    verify_orderer_logs
    verify_peer_logs
    verify_channel

    log_success "Network verification complete."
}

verify_pods() {
    log_step "Checking pod status across all clusters..."

    local kc_orderer kc_org1 kc_org2
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2")

    echo -e "\n${BOLD}Orderer Cluster (PC1):${NC}"
    kubectl --kubeconfig "$kc_orderer" get pods -n ordererorg-net 2>/dev/null || \
        log_warning "Cannot list pods on orderer cluster."

    echo -e "\n${BOLD}Org1 Cluster (PC2):${NC}"
    kubectl --kubeconfig "$kc_org1" get pods -n org1-net 2>/dev/null || \
        log_warning "Cannot list pods on org1 cluster."

    echo -e "\n${BOLD}Org2 Cluster (PC3):${NC}"
    kubectl --kubeconfig "$kc_org2" get pods -n org2-net 2>/dev/null || \
        log_warning "Cannot list pods on org2 cluster."

    # Check if all expected pods are running
    local all_ok=true

    # Check orderer pods (BFT requires 4 orderers; Raft uses 3)
    local orderer_pods expected_orderers
    orderer_pods=$(kubectl --kubeconfig "$kc_orderer" get pods -n ordererorg-net --no-headers 2>/dev/null)
    if [[ "$(load_config_var CONSENSUS)" == "bft" ]]; then
        expected_orderers=("orderer1" "orderer2" "orderer3" "orderer4" "ca")
    else
        expected_orderers=("orderer1" "orderer2" "orderer3" "ca")
    fi
    for expected in "${expected_orderers[@]}"; do
        if echo "$orderer_pods" | grep -q "$expected"; then
            if echo "$orderer_pods" | grep "$expected" | grep -q "Running"; then
                log_success "  ${expected} - Running"
            else
                log_warning "  ${expected} - Not Running"
                all_ok=false
            fi
        else
            log_warning "  ${expected} - Not found"
            all_ok=false
        fi
    done

    # Check org1 pods
    local org1_pods
    org1_pods=$(kubectl --kubeconfig "$kc_org1" get pods -n org1-net --no-headers 2>/dev/null)
    for expected in "peer0" "ca" "couchdb"; do
        if echo "$org1_pods" | grep -q "$expected"; then
            if echo "$org1_pods" | grep "$expected" | grep -q "Running"; then
                log_success "  org1/${expected} - Running"
            else
                log_warning "  org1/${expected} - Not Running"
                all_ok=false
            fi
        else
            log_warning "  org1/${expected} - Not found"
            all_ok=false
        fi
    done

    # Check org2 pods
    local org2_pods
    org2_pods=$(kubectl --kubeconfig "$kc_org2" get pods -n org2-net --no-headers 2>/dev/null)
    for expected in "peer0" "ca" "couchdb"; do
        if echo "$org2_pods" | grep -q "$expected"; then
            if echo "$org2_pods" | grep "$expected" | grep -q "Running"; then
                log_success "  org2/${expected} - Running"
            else
                log_warning "  org2/${expected} - Not Running"
                all_ok=false
            fi
        else
            log_warning "  org2/${expected} - Not found"
            all_ok=false
        fi
    done

    if $all_ok; then
        log_success "All expected pods are running!"
    else
        log_warning "Some pods are missing or not running."
        log_info "Use 'kubectl describe pod <name> -n <namespace>' to debug."
    fi
}

verify_orderer_logs() {
    log_step "Checking orderer logs (last 10 lines)..."

    local kc_orderer
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")

    local orderer_pod
    orderer_pod=$(kubectl --kubeconfig "$kc_orderer" get pods -n ordererorg-net \
        -l app=orderer1 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$orderer_pod" ]]; then
        echo -e "${DIM}"
        kubectl --kubeconfig "$kc_orderer" logs "$orderer_pod" -n ordererorg-net --tail=10 2>/dev/null || \
            log_warning "Cannot read orderer1 logs."
        echo -e "${NC}"
    else
        log_warning "orderer1 pod not found."
    fi
}

verify_peer_logs() {
    log_step "Checking peer logs (last 10 lines)..."

    local kc_org1
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")

    local peer_pod
    peer_pod=$(kubectl --kubeconfig "$kc_org1" get pods -n org1-net \
        -l app=peer0 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$peer_pod" ]]; then
        echo -e "${DIM}"
        kubectl --kubeconfig "$kc_org1" logs "$peer_pod" -n org1-net --tail=10 2>/dev/null || \
            log_warning "Cannot read org1/peer0 logs."
        echo -e "${NC}"
    else
        log_warning "org1/peer0 pod not found."
    fi
}

verify_channel() {
    log_step "Verifying channel..."

    local kc_org1
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")
    local channel_name
    channel_name=$(load_config_var "CHANNEL_NAME" "mychannel")

    local cli_pod
    cli_pod=$(kubectl --kubeconfig "$kc_org1" get pods -n org1-net \
        -l app=cli -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$cli_pod" ]]; then
        log_info "Listing channels from org1 CLI pod..."
        kubectl --kubeconfig "$kc_org1" exec "$cli_pod" -n org1-net -- \
            peer channel list 2>/dev/null || log_warning "Cannot list channels."

        log_info "Getting channel info for ${channel_name}..."
        kubectl --kubeconfig "$kc_org1" exec "$cli_pod" -n org1-net -- \
            peer channel getinfo -c "$channel_name" 2>/dev/null || \
            log_warning "Cannot get channel info."
    else
        log_info "No CLI pod found. Trying to exec into peer pod..."
        local peer_pod
        peer_pod=$(kubectl --kubeconfig "$kc_org1" get pods -n org1-net \
            --no-headers 2>/dev/null | grep "peer0" | head -1 | awk '{print $1}')
        if [[ -n "$peer_pod" ]]; then
            kubectl --kubeconfig "$kc_org1" exec "$peer_pod" -n org1-net -- \
                peer channel list 2>/dev/null || log_warning "Cannot list channels from peer pod."
        else
            log_warning "No peer pod found to verify channels."
        fi
    fi
}

# Quick health check - can be run anytime
health_check() {
    log_header "Network Health Check"

    local kc_orderer kc_org1 kc_org2
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2")

    local all_ok=true

    # K8s cluster access
    echo -e "\n${BOLD}Cluster Access:${NC}"
    for kc_pair in "Orderer:${kc_orderer}" "Org1:${kc_org1}" "Org2:${kc_org2}"; do
        local name="${kc_pair%%:*}"
        local kc="${kc_pair#*:}"
        if kubectl --kubeconfig "$kc" cluster-info &>/dev/null 2>&1; then
            log_success "  ${name} cluster - reachable"
        else
            log_error "  ${name} cluster - NOT reachable"
            all_ok=false
        fi
    done

    # Vault health
    echo -e "\n${BOLD}Vault Status:${NC}"
    for pc in PC1_IP PC2_IP PC3_IP; do
        local ip
        ip=$(load_config_var "$pc")
        local health
        health=$(curl -s --connect-timeout 3 "http://${ip}:8200/v1/sys/health" 2>/dev/null || echo "")
        if echo "$health" | grep -q '"sealed":false'; then
            log_success "  Vault at ${ip} - healthy (unsealed)"
        elif echo "$health" | grep -q '"sealed":true'; then
            log_warning "  Vault at ${ip} - SEALED"
            all_ok=false
        else
            log_error "  Vault at ${ip} - unreachable"
            all_ok=false
        fi
    done

    # HAProxy
    echo -e "\n${BOLD}HAProxy Ingress:${NC}"
    for kc_pair in "Orderer:${kc_orderer}" "Org1:${kc_org1}" "Org2:${kc_org2}"; do
        local name="${kc_pair%%:*}"
        local kc="${kc_pair#*:}"
        if kubectl --kubeconfig "$kc" get pods -n ingress-controller --no-headers 2>/dev/null | grep -q "Running"; then
            log_success "  ${name} - HAProxy running"
        else
            log_warning "  ${name} - HAProxy not running"
            all_ok=false
        fi
    done

    echo ""
    if $all_ok; then
        log_success "All systems healthy!"
    else
        log_warning "Some components have issues. Review above."
    fi
}
