#!/usr/bin/env bash
# =============================================================================
# monitoring.sh - Prometheus + Grafana setup (per-org + central federation)
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

setup_monitoring() {
    log_header "PHASE 11: Monitoring Setup (Prometheus + Grafana)"

    if ! ask_confirm "Set up Prometheus + Grafana monitoring?"; then
        log_info "Skipping monitoring setup."
        return 0
    fi

    # Add helm repo
    log_info "Adding prometheus-community Helm repo..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    install_monitoring_orderer
    install_monitoring_org1
    install_monitoring_org2

    if ask_confirm "Set up central monitoring (federated Prometheus for all orgs)?"; then
        install_monitoring_central
    fi

    setup_monitoring_firewall
    show_monitoring_urls

    log_success "Monitoring setup complete."
}

create_metrics_services_orderer() {
    local kubeconfig="$1"
    log_info "Creating metrics services for orderer components..."

    kubectl --kubeconfig "$kubeconfig" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: orderer1-metrics
  namespace: ordererorg-net
  labels:
    app: fabric-orderer
    component: orderer1
spec:
  selector:
    app: orderer1
  ports:
  - name: operations
    port: 9443
    targetPort: 9443
---
apiVersion: v1
kind: Service
metadata:
  name: orderer2-metrics
  namespace: ordererorg-net
  labels:
    app: fabric-orderer
    component: orderer2
spec:
  selector:
    app: orderer2
  ports:
  - name: operations
    port: 9443
    targetPort: 9443
---
apiVersion: v1
kind: Service
metadata:
  name: orderer3-metrics
  namespace: ordererorg-net
  labels:
    app: fabric-orderer
    component: orderer3
spec:
  selector:
    app: orderer3
  ports:
  - name: operations
    port: 9443
    targetPort: 9443
---
apiVersion: v1
kind: Service
metadata:
  name: ca-ordererorg-metrics
  namespace: ordererorg-net
  labels:
    app: fabric-ca
spec:
  selector:
    app: ca
  ports:
  - name: operations
    port: 9443
    targetPort: 9443
EOF
    log_success "Orderer metrics services created."
}

create_metrics_services_peer() {
    local kubeconfig="$1"
    local org_name="$2"
    local namespace="${org_name}-net"

    log_info "Creating metrics services for ${org_name} peer components..."

    kubectl --kubeconfig "$kubeconfig" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: peer0-${org_name}-metrics
  namespace: ${namespace}
  labels:
    app: fabric-peer
    component: peer0
    org: ${org_name}
spec:
  selector:
    app: peer0
  ports:
  - name: operations
    port: 9443
    targetPort: 9443
---
apiVersion: v1
kind: Service
metadata:
  name: ca-${org_name}-metrics
  namespace: ${namespace}
  labels:
    app: fabric-ca
    org: ${org_name}
spec:
  selector:
    app: ca
  ports:
  - name: operations
    port: 9443
    targetPort: 9443
EOF
    log_success "${org_name} metrics services created."
}

install_monitoring_orderer() {
    local kubeconfig
    kubeconfig=$(load_config_var "KUBECONFIG_ORDERER")

    log_step "Installing Prometheus + Grafana on Orderer cluster..."

    # Create metrics services first
    create_metrics_services_orderer "$kubeconfig"

    kubectl --kubeconfig "$kubeconfig" create namespace monitoring 2>/dev/null || true

    local grafana_pass
    grafana_pass=$(ask_input "Grafana admin password for OrdererOrg" "ordererorg-admin-pass")
    save_config_var "GRAFANA_PASS_ORDERER" "$grafana_pass"

    local values_file="/tmp/prom-values-ordererorg.yaml"
    cat > "$values_file" <<EOF
grafana:
  adminPassword: "${grafana_pass}"
  service:
    type: NodePort
    nodePort: 30300

prometheus:
  service:
    type: NodePort
    nodePort: 30090
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    additionalScrapeConfigs:
    - job_name: "fabric-orderers"
      metrics_path: /metrics
      scrape_interval: 15s
      static_configs:
      - targets:
        - "orderer1-metrics.ordererorg-net.svc:9443"
        - "orderer2-metrics.ordererorg-net.svc:9443"
        - "orderer3-metrics.ordererorg-net.svc:9443"
        labels:
          org: "ordererorg"
          component: "orderer"
    - job_name: "fabric-ca-ordererorg"
      metrics_path: /metrics
      scrape_interval: 15s
      static_configs:
      - targets:
        - "ca-ordererorg-metrics.ordererorg-net.svc:9443"
        labels:
          org: "ordererorg"
          component: "ca"
EOF

    helm install monitoring prometheus-community/kube-prometheus-stack \
        --kubeconfig "$kubeconfig" \
        --namespace monitoring \
        -f "$values_file" 2>&1 | tee -a "$BEVEL_LOG_FILE" || {
        log_warning "Helm install may have failed or monitoring already exists."
    }

    rm -f "$values_file"
    log_success "OrdererOrg monitoring installed."
}

install_monitoring_org1() {
    local kubeconfig
    kubeconfig=$(load_config_var "KUBECONFIG_ORG1")

    log_step "Installing Prometheus + Grafana on Org1 cluster..."

    create_metrics_services_peer "$kubeconfig" "org1"

    kubectl --kubeconfig "$kubeconfig" create namespace monitoring 2>/dev/null || true

    local grafana_pass
    grafana_pass=$(ask_input "Grafana admin password for Org1" "org1-admin-pass")
    save_config_var "GRAFANA_PASS_ORG1" "$grafana_pass"

    local values_file="/tmp/prom-values-org1.yaml"
    cat > "$values_file" <<EOF
grafana:
  adminPassword: "${grafana_pass}"
  service:
    type: NodePort
    nodePort: 30300

prometheus:
  service:
    type: NodePort
    nodePort: 30090
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    additionalScrapeConfigs:
    - job_name: "fabric-peers-org1"
      metrics_path: /metrics
      scrape_interval: 15s
      static_configs:
      - targets:
        - "peer0-org1-metrics.org1-net.svc:9443"
        labels:
          org: "org1"
          component: "peer"
    - job_name: "fabric-ca-org1"
      metrics_path: /metrics
      scrape_interval: 15s
      static_configs:
      - targets:
        - "ca-org1-metrics.org1-net.svc:9443"
        labels:
          org: "org1"
          component: "ca"
EOF

    helm install monitoring prometheus-community/kube-prometheus-stack \
        --kubeconfig "$kubeconfig" \
        --namespace monitoring \
        -f "$values_file" 2>&1 | tee -a "$BEVEL_LOG_FILE" || {
        log_warning "Helm install may have failed or monitoring already exists."
    }

    rm -f "$values_file"
    log_success "Org1 monitoring installed."
}

install_monitoring_org2() {
    local kubeconfig
    kubeconfig=$(load_config_var "KUBECONFIG_ORG2")

    log_step "Installing Prometheus + Grafana on Org2 cluster..."

    create_metrics_services_peer "$kubeconfig" "org2"

    kubectl --kubeconfig "$kubeconfig" create namespace monitoring 2>/dev/null || true

    local grafana_pass
    grafana_pass=$(ask_input "Grafana admin password for Org2" "org2-admin-pass")
    save_config_var "GRAFANA_PASS_ORG2" "$grafana_pass"

    local values_file="/tmp/prom-values-org2.yaml"
    cat > "$values_file" <<EOF
grafana:
  adminPassword: "${grafana_pass}"
  service:
    type: NodePort
    nodePort: 30300

prometheus:
  service:
    type: NodePort
    nodePort: 30090
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    additionalScrapeConfigs:
    - job_name: "fabric-peers-org2"
      metrics_path: /metrics
      scrape_interval: 15s
      static_configs:
      - targets:
        - "peer0-org2-metrics.org2-net.svc:9443"
        labels:
          org: "org2"
          component: "peer"
    - job_name: "fabric-ca-org2"
      metrics_path: /metrics
      scrape_interval: 15s
      static_configs:
      - targets:
        - "ca-org2-metrics.org2-net.svc:9443"
        labels:
          org: "org2"
          component: "ca"
EOF

    helm install monitoring prometheus-community/kube-prometheus-stack \
        --kubeconfig "$kubeconfig" \
        --namespace monitoring \
        -f "$values_file" 2>&1 | tee -a "$BEVEL_LOG_FILE" || {
        log_warning "Helm install may have failed or monitoring already exists."
    }

    rm -f "$values_file"
    log_success "Org2 monitoring installed."
}

install_monitoring_central() {
    log_step "Installing Central Federated Monitoring..."

    local kubeconfig
    kubeconfig=$(load_config_var "KUBECONFIG_ORDERER")
    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    kubectl --kubeconfig "$kubeconfig" create namespace central-monitoring 2>/dev/null || true

    local grafana_pass
    grafana_pass=$(ask_input "Central Grafana admin password" "central-admin-pass")
    save_config_var "GRAFANA_PASS_CENTRAL" "$grafana_pass"

    local values_file="/tmp/prom-values-central.yaml"
    cat > "$values_file" <<EOF
grafana:
  adminPassword: "${grafana_pass}"
  service:
    type: NodePort
    nodePort: 31300

prometheus:
  service:
    type: NodePort
    nodePort: 31090
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    additionalScrapeConfigs:
    - job_name: "federate-ordererorg"
      honor_labels: true
      metrics_path: /federate
      scrape_interval: 30s
      params:
        match[]:
        - '{job=~"fabric.*"}'
        - '{__name__=~"ledger_.*"}'
        - '{__name__=~"endorser_.*"}'
        - '{__name__=~"chaincode_.*"}'
        - '{__name__=~"gossip_.*"}'
        - '{__name__=~"grpc_.*"}'
        - '{__name__=~"broadcast_.*"}'
        - '{__name__=~"consensus_.*"}'
        - '{__name__=~"deliver_.*"}'
        - '{__name__=~"blockcutter_.*"}'
      static_configs:
      - targets:
        - "${pc1_ip}:30090"
        labels:
          cluster: "ordererorg"
    - job_name: "federate-org1"
      honor_labels: true
      metrics_path: /federate
      scrape_interval: 30s
      params:
        match[]:
        - '{job=~"fabric.*"}'
        - '{__name__=~"ledger_.*"}'
        - '{__name__=~"endorser_.*"}'
        - '{__name__=~"chaincode_.*"}'
        - '{__name__=~"gossip_.*"}'
        - '{__name__=~"grpc_.*"}'
      static_configs:
      - targets:
        - "${pc2_ip}:30090"
        labels:
          cluster: "org1"
    - job_name: "federate-org2"
      honor_labels: true
      metrics_path: /federate
      scrape_interval: 30s
      params:
        match[]:
        - '{job=~"fabric.*"}'
        - '{__name__=~"ledger_.*"}'
        - '{__name__=~"endorser_.*"}'
        - '{__name__=~"chaincode_.*"}'
        - '{__name__=~"gossip_.*"}'
        - '{__name__=~"grpc_.*"}'
      static_configs:
      - targets:
        - "${pc3_ip}:30090"
        labels:
          cluster: "org2"
EOF

    helm install central-monitoring prometheus-community/kube-prometheus-stack \
        --kubeconfig "$kubeconfig" \
        --namespace central-monitoring \
        -f "$values_file" 2>&1 | tee -a "$BEVEL_LOG_FILE" || {
        log_warning "Central monitoring install may have failed."
    }

    rm -f "$values_file"
    log_success "Central federated monitoring installed."
}

setup_monitoring_firewall() {
    log_info "Adding monitoring firewall rules..."
    sudo ufw allow 30090/tcp comment "Prometheus NodePort" 2>/dev/null || true
    sudo ufw allow 30300/tcp comment "Grafana NodePort" 2>/dev/null || true
    sudo ufw allow 31090/tcp comment "Central Prometheus" 2>/dev/null || true
    sudo ufw allow 31300/tcp comment "Central Grafana" 2>/dev/null || true
    log_success "Monitoring firewall rules added."
}

show_monitoring_urls() {
    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    log_separator
    echo -e "\n${BOLD}${CYAN}Monitoring URLs:${NC}\n"
    echo -e "  ${BOLD}Per-Org Grafana:${NC}"
    echo -e "    OrdererOrg: http://${pc1_ip}:30300  (admin / $(load_config_var GRAFANA_PASS_ORDERER 'ordererorg-admin-pass'))"
    echo -e "    Org1:       http://${pc2_ip}:30300  (admin / $(load_config_var GRAFANA_PASS_ORG1 'org1-admin-pass'))"
    echo -e "    Org2:       http://${pc3_ip}:30300  (admin / $(load_config_var GRAFANA_PASS_ORG2 'org2-admin-pass'))"
    echo ""
    echo -e "  ${BOLD}Per-Org Prometheus:${NC}"
    echo -e "    OrdererOrg: http://${pc1_ip}:30090"
    echo -e "    Org1:       http://${pc2_ip}:30090"
    echo -e "    Org2:       http://${pc3_ip}:30090"
    echo ""
    echo -e "  ${BOLD}Central (Federated):${NC}"
    echo -e "    Grafana:    http://${pc1_ip}:31300  (admin / $(load_config_var GRAFANA_PASS_CENTRAL 'central-admin-pass'))"
    echo -e "    Prometheus: http://${pc1_ip}:31090"
    echo ""
}
