#!/usr/bin/env bash
# =============================================================================
# network-yaml.sh - Generate network.yaml from collected configuration
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

generate_network_yaml() {
    log_header "PHASE 8: Generating network.yaml"

    # Load all config
    local consensus fabric_version
    consensus=$(load_config_var "CONSENSUS" "raft")
    fabric_version=$(load_config_var "FABRIC_VERSION" "2.5.4")

    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    local pc1_domain pc2_domain pc3_domain
    pc1_domain=$(load_config_var "PC1_DOMAIN" "pc1.example.com")
    pc2_domain=$(load_config_var "PC2_DOMAIN" "pc2.example.com")
    pc3_domain=$(load_config_var "PC3_DOMAIN" "pc3.example.com")

    local kc_orderer kc_org1 kc_org2
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2")

    local ctx_orderer ctx_org1 ctx_org2
    ctx_orderer=$(load_config_var "K8S_CONTEXT_ORDERER" "orderer-cluster")
    ctx_org1=$(load_config_var "K8S_CONTEXT_ORG1" "org1-cluster")
    ctx_org2=$(load_config_var "K8S_CONTEXT_ORG2" "org2-cluster")

    local vault_url_orderer vault_token_orderer
    vault_url_orderer=$(load_config_var "VAULT_URL_ORDERER")
    vault_token_orderer=$(load_config_var "VAULT_TOKEN_ORDERER")
    local vault_url_org1 vault_token_org1
    vault_url_org1=$(load_config_var "VAULT_URL_ORG1")
    vault_token_org1=$(load_config_var "VAULT_TOKEN_ORG1")
    local vault_url_org2 vault_token_org2
    vault_url_org2=$(load_config_var "VAULT_URL_ORG2")
    vault_token_org2=$(load_config_var "VAULT_TOKEN_ORG2")

    local git_protocol git_url git_branch git_repo git_username git_token git_email ssh_key
    git_protocol=$(load_config_var "GIT_PROTOCOL" "https")
    git_url=$(load_config_var "GIT_URL")
    git_branch=$(load_config_var "GIT_BRANCH" "main")
    git_repo=$(load_config_var "GIT_REPO")
    git_username=$(load_config_var "GIT_USERNAME")
    git_token=$(load_config_var "GIT_TOKEN")
    git_token="${git_token//\\/}"   # strip any accidental backslashes (common paste artifact)
    git_email=$(load_config_var "GIT_EMAIL")
    ssh_key=$(load_config_var "SSH_PRIVATE_KEY" "${HOME}/.ssh/gitops")

    # Auto-select docker registry based on Fabric version
    # v3.x uses custom registry (no official v3 bevel images), v2.x uses official
    local docker_url_default="ghcr.io/hyperledger"
    if [[ "$fabric_version" == 3.* ]]; then
        docker_url_default="ghcr.io/niravchangelavhits-blockchain-dev"
    fi
    local docker_url docker_username docker_password
    docker_url=$(load_config_var "DOCKER_URL" "$docker_url_default")
    docker_username=$(load_config_var "DOCKER_USERNAME" "")
    docker_password=$(load_config_var "DOCKER_PASSWORD" "")

    # Ask for channel name
    local channel_name
    channel_name=$(ask_input "Channel name" "mychannel")
    save_config_var "CHANNEL_NAME" "$channel_name"

    # Ask for cloud provider
    local cloud_provider
    local cp_choice
    cp_choice=$(ask_choice "Cloud provider (for K8s setup)?" \
        "minikube (for local/bare-metal K3s - Recommended)" \
        "aws (if running on AWS EKS)")
    if [[ "$cp_choice" == "0" ]]; then
        cloud_provider="minikube"
    else
        cloud_provider="aws"
    fi
    save_config_var "CLOUD_PROVIDER" "$cloud_provider"

    # Determine external_dns setting
    local external_dns="disabled"
    if ask_confirm "Are you using external DNS (e.g., Route53) instead of /etc/hosts?" "n"; then
        external_dns="enabled"
    fi

    # Build BFT-specific orderer section if needed
    local consensus_orderer_config=""
    if [[ "$consensus" == "bft" ]]; then
        consensus_orderer_config="
      consensus:
        name: BFT"
    else
        consensus_orderer_config="
      consensus:
        name: raft"
    fi

    # BFT requires minimum 4 orderers — add orderer4 entry for BFT only
    local orderer4_top_level=""
    local orderer4_service=""
    if [[ "$consensus" == "bft" ]]; then
        orderer4_top_level="
  - orderer:
    name: orderer4
    type: orderer
    org_name: ordererorg
    uri: orderer4.ordererorg-net.${pc1_domain}:443"
        orderer4_service="
      - orderer:
        name: orderer4
        type: orderer
        consensus: ${consensus^^}
        grpc:
          port: 7050
        ordererAddress: orderer4.ordererorg-net.${pc1_domain}:443"
    fi

    local output_dir="${BEVEL_CONFIG_DIR}"
    local output_file="${output_dir}/network.yaml"
    mkdir -p "$output_dir"

    log_info "Generating network.yaml..."
    log_info "  Consensus: ${consensus}"
    log_info "  Fabric Version: ${fabric_version}"
    log_info "  Cloud Provider: ${cloud_provider}"

    cat > "$output_file" <<EOFYAML
---
##############################################################################################
# Auto-generated network.yaml for Bevel Hyperledger Fabric Deployment
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Consensus: ${consensus} | Fabric: ${fabric_version}
##############################################################################################

network:
  type: fabric
  version: ${fabric_version}
  upgrade: false
  frontend: enabled

  env:
    type: "dev"
    proxy: haproxy
    retry_count: 20
    external_dns: ${external_dns}
    labels:
      service: {}
      deployment: {}
      pvc: {}

  docker:
    url: "${docker_url}"${docker_username:+
    username: "${docker_username}"}${docker_password:+
    password: "${docker_password}"}

  consensus:
    name: ${consensus^^}

  orderers:
  - orderer:
    name: orderer1
    type: orderer
    org_name: ordererorg
    uri: orderer1.ordererorg-net.${pc1_domain}:443
  - orderer:
    name: orderer2
    type: orderer
    org_name: ordererorg
    uri: orderer2.ordererorg-net.${pc1_domain}:443
  - orderer:
    name: orderer3
    type: orderer
    org_name: ordererorg
    uri: orderer3.ordererorg-net.${pc1_domain}:443${orderer4_top_level}

  channels:
  - channel:
    consortium: MyConsortium
    channel_name: ${channel_name}
    channel_status: new
    osn_creator_org:
      name: ordererorg
    orderers:
    - ordererorg
    participants:
    - organization:
      name: org1
      type: creator
      org_status: new
      peers:
      - peer:
        name: peer0
        type: anchor
        gossipAddress: peer0.org1-net.${pc2_domain}:443
        peerAddress: peer0.org1-net.${pc2_domain}:443
      ordererAddress: orderer1.ordererorg-net.${pc1_domain}:443
    - organization:
      name: org2
      type: joiner
      org_status: new
      peers:
      - peer:
        name: peer0
        type: anchor
        gossipAddress: peer0.org2-net.${pc3_domain}:443
        peerAddress: peer0.org2-net.${pc3_domain}:443
      ordererAddress: orderer1.ordererorg-net.${pc1_domain}:443

  organizations:

  # ----- OrdererOrg (PC1) -----
  - organization:
    name: ordererorg
    country: US
    state: California
    location: SanFrancisco
    subject: "O=OrdererOrg,OU=Orderer,L=37.77/-122.42/SanFrancisco,C=US"
    external_url_suffix: ${pc1_domain}
    org_status: new
    ca_data:
      certificate: /path/to/ordererorg/ca-server.crt

    cloud_provider: ${cloud_provider}

    k8s:
      region: "local"
      context: "${ctx_orderer}"
      config_file: "${kc_orderer}"

    vault:
      url: "${vault_url_orderer}"
      root_token: "${vault_token_orderer}"
      secret_path: "secretsv2"

    gitops:
      git_protocol: "${git_protocol}"
      git_url: "${git_url}"
      branch: "${git_branch}"
      release_dir: "platforms/hyperledger-fabric/releases/ordererorg"
      component_dir: "platforms/hyperledger-fabric/releases/k8sComponent"
      chart_source: "platforms/hyperledger-fabric/charts"
      git_repo: "${git_repo}"
      username: "${git_username}"
      password: "${git_token}"
      email: "${git_email}"
      private_key: "${ssh_key}"

    services:
      ca:
        name: ca
        subject: "/C=US/ST=California/L=SanFrancisco/O=OrdererOrg"
        type: ca
        grpc:
          port: 7054
${consensus_orderer_config}
      orderers:
      - orderer:
        name: orderer1
        type: orderer
        consensus: ${consensus^^}
        grpc:
          port: 7050
        ordererAddress: orderer1.ordererorg-net.${pc1_domain}:443
      - orderer:
        name: orderer2
        type: orderer
        consensus: ${consensus^^}
        grpc:
          port: 7050
        ordererAddress: orderer2.ordererorg-net.${pc1_domain}:443
      - orderer:
        name: orderer3
        type: orderer
        consensus: ${consensus^^}
        grpc:
          port: 7050
        ordererAddress: orderer3.ordererorg-net.${pc1_domain}:443${orderer4_service}

      peers: []

  # ----- Org1 (PC2) -----
  - organization:
    name: org1
    country: US
    state: NewYork
    location: NewYork
    subject: "O=Org1,OU=Org1,L=40.73/-74/NewYork,C=US"
    external_url_suffix: ${pc2_domain}
    org_status: new
    orderer_org: ordererorg
    ca_data:
      certificate: /path/to/org1/ca-server.crt

    cloud_provider: ${cloud_provider}

    k8s:
      region: "local"
      context: "${ctx_org1}"
      config_file: "${kc_org1}"

    vault:
      url: "${vault_url_org1}"
      root_token: "${vault_token_org1}"
      secret_path: "secretsv2"

    gitops:
      git_protocol: "${git_protocol}"
      git_url: "${git_url}"
      branch: "${git_branch}"
      release_dir: "platforms/hyperledger-fabric/releases/org1"
      component_dir: "platforms/hyperledger-fabric/releases/k8sComponent"
      chart_source: "platforms/hyperledger-fabric/charts"
      git_repo: "${git_repo}"
      username: "${git_username}"
      password: "${git_token}"
      email: "${git_email}"
      private_key: "${ssh_key}"

    services:
      ca:
        name: ca
        subject: "/C=US/ST=NewYork/L=NewYork/O=Org1"
        type: ca
        grpc:
          port: 7054

      peers:
      - peer:
        name: peer0
        type: anchor
        gossippeeraddress: peer0.org1-net.${pc2_domain}:443
        peerAddress: peer0.org1-net.${pc2_domain}:443
        cli: enabled
        grpc:
          port: 7051
        events:
          port: 7053
        couchdb:
          port: 5984
        restserver:
          targetPort: 20001
          port: 20001
        expressapi:
          targetPort: 3000
          port: 3000

  # ----- Org2 (PC3) -----
  - organization:
    name: org2
    country: US
    state: Texas
    location: Dallas
    subject: "O=Org2,OU=Org2,L=32.78/-96.80/Dallas,C=US"
    external_url_suffix: ${pc3_domain}
    org_status: new
    orderer_org: ordererorg
    ca_data:
      certificate: /path/to/org2/ca-server.crt

    cloud_provider: ${cloud_provider}

    k8s:
      region: "local"
      context: "${ctx_org2}"
      config_file: "${kc_org2}"

    vault:
      url: "${vault_url_org2}"
      root_token: "${vault_token_org2}"
      secret_path: "secretsv2"

    gitops:
      git_protocol: "${git_protocol}"
      git_url: "${git_url}"
      branch: "${git_branch}"
      release_dir: "platforms/hyperledger-fabric/releases/org2"
      component_dir: "platforms/hyperledger-fabric/releases/k8sComponent"
      chart_source: "platforms/hyperledger-fabric/charts"
      git_repo: "${git_repo}"
      username: "${git_username}"
      password: "${git_token}"
      email: "${git_email}"
      private_key: "${ssh_key}"

    services:
      ca:
        name: ca
        subject: "/C=US/ST=Texas/L=Dallas/O=Org2"
        type: ca
        grpc:
          port: 7054

      peers:
      - peer:
        name: peer0
        type: anchor
        gossippeeraddress: peer0.org2-net.${pc3_domain}:443
        peerAddress: peer0.org2-net.${pc3_domain}:443
        cli: enabled
        grpc:
          port: 7051
        events:
          port: 7053
        couchdb:
          port: 5984
        restserver:
          targetPort: 20001
          port: 20001
        expressapi:
          targetPort: 3000
          port: 3000
EOFYAML

    log_success "network.yaml generated at: ${output_file}"

    # Show preview
    echo -e "\n${BOLD}--- network.yaml preview (first 50 lines) ---${NC}"
    head -50 "$output_file"
    echo -e "${DIM}... (truncated) ...${NC}\n"

    if [[ "${BEVEL_NONINTERACTIVE:-0}" != "1" ]] && ask_confirm "Review full network.yaml?"; then
        less "$output_file"
    fi

    # Ask where to save a copy
    local copy_dest
    copy_dest=$(ask_input "Also save a copy to (leave empty to skip)" "${BEVEL_NETWORK_YAML_COPY:-}")
    if [[ -n "$copy_dest" ]]; then
        cp "$output_file" "$copy_dest"
        log_success "Copy saved to ${copy_dest}"
    fi

    save_config_var "NETWORK_YAML" "$output_file"
    log_success "network.yaml is ready for deployment."
}
