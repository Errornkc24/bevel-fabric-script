#!/usr/bin/env bash
# =============================================================================
# vault-setup.sh - HashiCorp Vault installation and configuration
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

setup_vault() {
    log_header "PHASE 5: HashiCorp Vault Setup"

    local this_ip
    this_ip=$(load_config_var "THIS_PC_IP")
    local role
    role=$(load_config_var "ROLE")

    # Choose vault mode
    local vault_mode
    vault_mode=$(ask_choice "Vault deployment mode?" \
        "Dev mode (in-memory, easy for testing - data lost on restart)" \
        "Production mode (persistent storage, file backend)")

    save_config_var "VAULT_MODE" "$vault_mode"

    if [[ "$vault_mode" == "0" ]]; then
        setup_vault_dev "$this_ip" "$role"
    else
        setup_vault_production "$this_ip" "$role"
    fi
}

setup_vault_dev() {
    local this_ip="$1"
    local role="$2"

    local token
    case "$role" in
        orderer) token="roottoken-orderer" ;;
        org1)    token="roottoken-org1" ;;
        org2)    token="roottoken-org2" ;;
    esac

    log_info "You can customize the Vault root token."
    token=$(ask_input "Vault root token for this PC" "$token")
    save_config_var "VAULT_TOKEN_${role^^}" "$token"
    save_config_var "VAULT_URL_${role^^}" "http://${this_ip}:8200"

    # Check if vault is already running (try both localhost and actual IP)
    if curl -s "http://127.0.0.1:8200/v1/sys/health" &>/dev/null || \
       curl -s "http://${this_ip}:8200/v1/sys/health" &>/dev/null; then
        log_success "Vault already running at http://${this_ip}:8200"
        configure_vault_secrets "$this_ip" "$token"
        return 0
    fi

    # Check if port 8200 is already in use
    if ss -tlnp 2>/dev/null | grep -q ":8200 "; then
        log_warning "Port 8200 is already in use. Attempting to kill existing process..."
        sudo fuser -k 8200/tcp 2>/dev/null || true
        sleep 2
    fi

    log_info "Starting Vault in dev mode..."
    log_warning "Dev mode: data is stored in memory and will be lost on restart!"

    # Kill any existing vault process
    pkill -f "vault server" 2>/dev/null || true
    sleep 2

    # Start vault in background
    nohup vault server -dev \
        -dev-root-token-id="$token" \
        -dev-listen-address="0.0.0.0:8200" \
        > "${BEVEL_CONFIG_DIR}/vault.log" 2>&1 &

    local vault_pid=$!
    save_config_var "VAULT_PID" "$vault_pid"
    log_info "Vault started with PID ${vault_pid}"

    # Wait for vault to be ready (check localhost first - more reliable)
    log_info "Waiting for Vault to be ready..."
    local attempts=0
    while (( attempts < 20 )); do
        if curl -s "http://127.0.0.1:8200/v1/sys/health" &>/dev/null; then
            break
        fi
        # Check if process is still alive
        if ! kill -0 "$vault_pid" 2>/dev/null; then
            log_error "Vault process died. Log output:"
            cat "${BEVEL_CONFIG_DIR}/vault.log" 2>/dev/null | tail -20
            return 1
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    if curl -s "http://127.0.0.1:8200/v1/sys/health" &>/dev/null; then
        log_success "Vault is running at http://${this_ip}:8200"
    else
        log_error "Vault did not start after 40 seconds."
        log_error "Vault log output:"
        cat "${BEVEL_CONFIG_DIR}/vault.log" 2>/dev/null | tail -20
        return 1
    fi

    configure_vault_secrets "$this_ip" "$token"
}

setup_vault_production() {
    local this_ip="$1"
    local role="$2"

    log_step "Setting up Vault in production mode..."

    # Create directories
    sudo mkdir -p /opt/vault/data
    sudo mkdir -p /etc/vault.d

    # Create config
    sudo tee /etc/vault.d/vault.hcl > /dev/null <<EOF
storage "file" {
  path = "/opt/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://${this_ip}:8200"
ui = true
EOF

    # Create systemd service
    sudo tee /etc/systemd/system/vault.service > /dev/null <<'EOF'
[Unit]
Description=HashiCorp Vault
Documentation=https://www.vaultproject.io/docs
After=network-online.target
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable vault
    sudo systemctl start vault

    sleep 3

    # Check if already initialized
    local health
    health=$(curl -s "http://${this_ip}:8200/v1/sys/health" || echo '{}')

    if echo "$health" | grep -q '"initialized":false'; then
        log_info "Initializing Vault..."
        local init_output
        init_output=$(vault operator init \
            -address="http://${this_ip}:8200" \
            -key-shares=1 \
            -key-threshold=1 \
            -format=json)

        local unseal_key root_token
        unseal_key=$(echo "$init_output" | jq -r '.unseal_keys_b64[0]')
        root_token=$(echo "$init_output" | jq -r '.root_token')

        log_success "Vault initialized!"
        echo -e "${RED}${BOLD}"
        echo "========================================="
        echo "  SAVE THESE SECURELY! CANNOT RECOVER!"
        echo "========================================="
        echo "  Unseal Key: ${unseal_key}"
        echo "  Root Token: ${root_token}"
        echo "========================================="
        echo -e "${NC}"

        save_config_var "VAULT_UNSEAL_KEY_${role^^}" "$unseal_key"
        save_config_var "VAULT_TOKEN_${role^^}" "$root_token"
        save_config_var "VAULT_URL_${role^^}" "http://${this_ip}:8200"

        # Unseal
        vault operator unseal -address="http://${this_ip}:8200" "$unseal_key"
        log_success "Vault unsealed."

        configure_vault_secrets "$this_ip" "$root_token"

    elif echo "$health" | grep -q '"sealed":true'; then
        log_warning "Vault is sealed. Enter unseal key:"
        local unseal_key
        unseal_key=$(ask_secret "Vault unseal key")
        vault operator unseal -address="http://${this_ip}:8200" "$unseal_key"

        local root_token
        root_token=$(ask_secret "Vault root token")
        save_config_var "VAULT_TOKEN_${role^^}" "$root_token"
        save_config_var "VAULT_URL_${role^^}" "http://${this_ip}:8200"

        configure_vault_secrets "$this_ip" "$root_token"
    else
        log_success "Vault is already initialized and unsealed."
        local root_token
        root_token=$(load_config_var "VAULT_TOKEN_${role^^}")
        if [[ -z "$root_token" ]]; then
            root_token=$(ask_secret "Vault root token for this PC")
            save_config_var "VAULT_TOKEN_${role^^}" "$root_token"
        fi
        save_config_var "VAULT_URL_${role^^}" "http://${this_ip}:8200"
        configure_vault_secrets "$this_ip" "$root_token"
    fi
}

configure_vault_secrets() {
    local vault_addr="$1"
    local vault_token="$2"

    export VAULT_ADDR="http://${vault_addr}:8200"
    export VAULT_TOKEN="$vault_token"

    # Check if secretsv2 already enabled
    if vault secrets list 2>/dev/null | grep -q "secretsv2/"; then
        log_success "KV v2 secrets engine 'secretsv2' already enabled."
        return 0
    fi

    log_info "Enabling KV v2 secrets engine at path 'secretsv2'..."
    if vault secrets enable -version=2 -path=secretsv2 kv 2>/dev/null; then
        log_success "Vault secrets engine configured."
    else
        log_info "secretsv2 already enabled (this is fine)."
    fi
    vault secrets list 2>/dev/null || true
}

verify_vault() {
    local this_ip
    this_ip=$(load_config_var "THIS_PC_IP")

    log_step "Verifying Vault..."
    local health
    health=$(curl -s "http://${this_ip}:8200/v1/sys/health" 2>/dev/null || echo "unreachable")

    if echo "$health" | grep -q '"initialized":true'; then
        if echo "$health" | grep -q '"sealed":false'; then
            log_success "Vault is running, initialized, and unsealed."
            return 0
        else
            log_warning "Vault is sealed."
            return 1
        fi
    else
        log_error "Vault is not reachable at http://${this_ip}:8200"
        return 1
    fi
}

# For controller: collect vault info from all PCs
collect_vault_info_for_controller() {
    log_step "Collecting Vault configuration for all organizations..."

    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    # Check if vault info already collected
    if [[ -n "$(load_config_var VAULT_TOKEN_ORDERER)" ]] && \
       [[ -n "$(load_config_var VAULT_TOKEN_ORG1)" ]] && \
       [[ -n "$(load_config_var VAULT_TOKEN_ORG2)" ]]; then
        log_success "Vault info already collected."
        return 0
    fi

    # Orderer Vault
    log_info "Vault for OrdererOrg (PC1: ${pc1_ip}):"
    local orderer_url
    orderer_url=$(ask_input "Vault URL for OrdererOrg" "http://${pc1_ip}:8200")
    local orderer_token
    orderer_token=$(ask_secret "Vault root token for OrdererOrg")
    save_config_var "VAULT_URL_ORDERER" "$orderer_url"
    save_config_var "VAULT_TOKEN_ORDERER" "$orderer_token"

    # Org1 Vault
    log_info "Vault for Org1 (PC2: ${pc2_ip}):"
    local org1_url
    org1_url=$(ask_input "Vault URL for Org1" "http://${pc2_ip}:8200")
    local org1_token
    org1_token=$(ask_secret "Vault root token for Org1")
    save_config_var "VAULT_URL_ORG1" "$org1_url"
    save_config_var "VAULT_TOKEN_ORG1" "$org1_token"

    # Org2 Vault
    log_info "Vault for Org2 (PC3: ${pc3_ip}):"
    local org2_url
    org2_url=$(ask_input "Vault URL for Org2" "http://${pc3_ip}:8200")
    local org2_token
    org2_token=$(ask_secret "Vault root token for Org2")
    save_config_var "VAULT_URL_ORG2" "$org2_url"
    save_config_var "VAULT_TOKEN_ORG2" "$org2_token"

    log_success "Vault info collected for all orgs."
}
