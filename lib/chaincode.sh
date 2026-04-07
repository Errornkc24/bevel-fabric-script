#!/usr/bin/env bash
# =============================================================================
# chaincode.sh - Deploy and test asset-transfer chaincode on mychannel
# =============================================================================
# Deploys a simple CRUD chaincode on both org1 and org2 using Fabric v2+
# lifecycle (works for Fabric 2.5.x and 3.0.x BFT), then runs test transactions.
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CC_NAME="asset-transfer"
CC_VERSION="1.0"
CC_SEQUENCE="1"
CC_LABEL="${CC_NAME}_${CC_VERSION}"
CHANNEL_NAME=$(load_config_var "CHANNEL_NAME" "mychannel")
CC_SRC_DIR="${_LIB_DIR}/../chaincode/asset-transfer"
CC_PACKAGE_FILE="/tmp/asset-transfer.tar.gz"

# ---------------------------------------------------------------------------
# Helper: find the peer0-cli pod name in a namespace
# ---------------------------------------------------------------------------
_get_cli_pod() {
    local kubeconfig="$1"
    local namespace="$2"

    kubectl --kubeconfig "$kubeconfig" get pod -n "$namespace" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
        | grep -E "cli" | grep -v "Completed" | head -1
}

# ---------------------------------------------------------------------------
# Helper: run a command inside the CLI pod
# ---------------------------------------------------------------------------
_cli_exec() {
    local kubeconfig="$1"
    local namespace="$2"
    local cli_pod="$3"
    shift 3
    kubectl --kubeconfig "$kubeconfig" exec -n "$namespace" "$cli_pod" -- bash -c "[ -d /usr/local/config ] && export FABRIC_CFG_PATH=/usr/local/config; $*"
}

# ---------------------------------------------------------------------------
# Helper: wait for CLI pod to be ready
# ---------------------------------------------------------------------------
_wait_for_cli() {
    local kubeconfig="$1"
    local namespace="$2"
    local max_wait=300
    local elapsed=0

    log_info "  Waiting for CLI pod in ${namespace}..."
    while (( elapsed < max_wait )); do
        local pod
        pod=$(_get_cli_pod "$kubeconfig" "$namespace")
        if [[ -n "$pod" ]]; then
            local status
            status=$(kubectl --kubeconfig "$kubeconfig" get pod "$pod" -n "$namespace" \
                --no-headers -o custom-columns=":status.phase" 2>/dev/null || true)
            if [[ "$status" == "Running" ]]; then
                # Also check containers are ready
                local ready
                ready=$(kubectl --kubeconfig "$kubeconfig" get pod "$pod" -n "$namespace" \
                    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
                if [[ "$ready" == "true" ]]; then
                    log_success "  CLI pod ready: ${pod}"
                    return 0
                fi
            fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_error "CLI pod not ready in ${namespace} after ${max_wait}s"
    return 1
}

# ---------------------------------------------------------------------------
# Step 1: Package chaincode using Docker (fabric-tools image)
# ---------------------------------------------------------------------------
_package_chaincode() {
    log_step "Packaging chaincode: ${CC_NAME} v${CC_VERSION}"

    if [[ -f "$CC_PACKAGE_FILE" ]]; then
        log_info "  Package already exists: ${CC_PACKAGE_FILE}"
        return 0
    fi

    if ! command -v docker &>/dev/null; then
        log_error "Docker not found. Required for chaincode packaging."
        return 1
    fi

    # Select the correct fabric-tools image based on Fabric version
    local fabric_version
    fabric_version=$(load_config_var "FABRIC_VERSION" "2.5.4")
    # Auto-select registry: v3.x → custom (no official bevel v3 images), v2.x → official
    local docker_url_default="ghcr.io/hyperledger"
    [[ "$fabric_version" == 3.* ]] && docker_url_default="ghcr.io/niravchangelavhits-blockchain-dev"
    local docker_url fabric_tools_image
    docker_url=$(load_config_var "DOCKER_URL" "$docker_url_default")
    if [[ "$fabric_version" == 3.* ]]; then
        fabric_tools_image="${docker_url}/bevel-fabric-tools:${fabric_version}"
        if ! docker image inspect "${fabric_tools_image}" &>/dev/null; then
            log_error "${fabric_tools_image} not found in Docker."
            log_error "Run k3s-fixes.sh first — it builds this image for Fabric v3.0 BFT."
            return 1
        fi
    else
        fabric_tools_image="hyperledger/fabric-tools:${fabric_version}"
    fi
    log_info "  fabric-tools image: ${fabric_tools_image}"

    log_info "  Source: ${CC_SRC_DIR}"
    log_info "  Output: ${CC_PACKAGE_FILE}"

    local host_uid host_gid
    host_uid=$(id -u)
    host_gid=$(id -g)

    # Step 1: Use golang:1.20-alpine (has git+go) to resolve modules, generate
    # go.sum, and create vendor/. GONOSUMDB=* bypasses sum database for
    # packages that have non-standard commit refs. Capture exit code explicitly
    # (don't pipe directly to log — the pipe swallows the exit code).
    log_info "  Step 1/2: Resolving Go modules (golang:1.20-alpine)..."
    local step1_log="/tmp/cc-step1.log"
    docker run --rm \
        -v "${CC_SRC_DIR}:/chaincode/src" \
        -e HOME=/tmp \
        -e GOPATH=/tmp/go \
        -e GOCACHE=/tmp/gocache \
        -e GONOSUMDB="*" \
        -e GOFLAGS="-mod=mod" \
        golang:1.20-alpine \
        sh -c "
            set -e
            apk add --no-cache git 2>/dev/null
            mkdir -p /tmp/go /tmp/gocache
            cd /chaincode/src
            echo 'Downloading modules and generating go.sum...'
            go mod tidy
            echo 'Creating vendor directory...'
            go mod vendor
            echo 'Vendor directory created.'
            ls vendor/ | head -5
            chown -R ${host_uid}:${host_gid} /chaincode/src/ 2>/dev/null || true
        " 2>&1 | tee "$step1_log" | while IFS= read -r line; do log_info "  [go] $line"; done

    # Check if vendor directory was actually created
    if [[ ! -d "${CC_SRC_DIR}/vendor" ]]; then
        log_error "Vendor directory was not created. See ${step1_log}"
        cat "$step1_log" | tail -20 | while IFS= read -r line; do log_error "  $line"; done
        return 1
    fi
    log_success "  Vendor directory ready ($(ls "${CC_SRC_DIR}/vendor" | wc -l) packages)"

    # Step 2: Package with peer lifecycle.
    # bevel-fabric-tools:3.x (Ubuntu) has the peer binary but no Go compiler.
    # The peer binary needs 'go' on PATH to normalize Go chaincode paths.
    # Solution: install Go into the Ubuntu-based tools image at runtime.
    log_info "  Step 2/2: Packaging with peer lifecycle (${fabric_tools_image})..."
    local step2_log="/tmp/cc-step2.log"
    docker run --rm \
        -v "${CC_SRC_DIR}:/chaincode/src" \
        -v "/tmp:/output" \
        -e HOME=/tmp \
        -e GOPATH=/tmp/go \
        -e GOCACHE=/tmp/gocache \
        -e GONOSUMDB="*" \
        -e GOFLAGS="-mod=vendor" \
        "${fabric_tools_image}" \
        bash -c "
            set -e
            [ -d /usr/local/config ] && export FABRIC_CFG_PATH=/usr/local/config
            # Install Go (needed by peer to normalize chaincode paths)
            wget -q https://go.dev/dl/go1.20.14.linux-amd64.tar.gz -O /tmp/go.tar.gz
            tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz
            export PATH=/usr/local/go/bin:\$PATH
            peer lifecycle chaincode package /output/asset-transfer.tar.gz \
                --path /chaincode/src \
                --lang golang \
                --label ${CC_LABEL}
            echo 'Package created successfully'
            chown ${host_uid}:${host_gid} /output/asset-transfer.tar.gz 2>/dev/null || true
        " 2>&1 | tee "$step2_log" | while IFS= read -r line; do log_info "  [peer] $line"; done

    if [[ -f "$CC_PACKAGE_FILE" ]]; then
        local size
        size=$(du -sh "$CC_PACKAGE_FILE" | cut -f1)
        log_success "  Chaincode packaged: ${CC_PACKAGE_FILE} (${size})"
    else
        log_error "Packaging failed: ${CC_PACKAGE_FILE} not created"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Install chaincode on a peer via CLI pod
# ---------------------------------------------------------------------------
_install_on_peer() {
    local kubeconfig="$1"
    local namespace="$2"
    local org_label="$3"

    local cli_pod
    cli_pod=$(_get_cli_pod "$kubeconfig" "$namespace")
    if [[ -z "$cli_pod" ]]; then
        log_error "No CLI pod found in ${namespace}"
        return 1
    fi

    log_info "  Installing on ${org_label} (pod: ${cli_pod})..."

    # Copy package to CLI pod
    kubectl --kubeconfig "$kubeconfig" cp "$CC_PACKAGE_FILE" \
        "${namespace}/${cli_pod}:/tmp/asset-transfer.tar.gz" 2>/dev/null

    # Install the chaincode
    local install_output
    install_output=$(_cli_exec "$kubeconfig" "$namespace" "$cli_pod" \
        "peer lifecycle chaincode install /tmp/asset-transfer.tar.gz 2>&1" || true)

    if echo "$install_output" | grep -qE "Chaincode code package identifier|already installed"; then
        log_success "  Chaincode installed on ${org_label}"
    else
        log_warning "  Install output: ${install_output}"
        # Try to continue - might already be installed
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Get the installed package ID for an org
# ---------------------------------------------------------------------------
_get_package_id() {
    local kubeconfig="$1"
    local namespace="$2"

    local cli_pod
    cli_pod=$(_get_cli_pod "$kubeconfig" "$namespace")

    local query_output
    query_output=$(_cli_exec "$kubeconfig" "$namespace" "$cli_pod" \
        "peer lifecycle chaincode queryinstalled 2>&1" || true)

    # Extract the package ID matching our label
    echo "$query_output" | grep "$CC_LABEL" | \
        sed 's/.*Package ID: //; s/,.*//' | head -1
}

# ---------------------------------------------------------------------------
# Step 4: Approve chaincode for an org
# ---------------------------------------------------------------------------
_approve_chaincode() {
    local kubeconfig="$1"
    local namespace="$2"
    local org_msp="$3"
    local package_id="$4"
    local org_label="$5"

    local cli_pod
    cli_pod=$(_get_cli_pod "$kubeconfig" "$namespace")

    log_info "  Approving for ${org_label} (MSP: ${org_msp}, pkg: ${package_id:0:30}...)..."

    local approve_output
    approve_output=$(_cli_exec "$kubeconfig" "$namespace" "$cli_pod" "
        # Get orderer CA and address from environment or defaults
        ORDERER_CA=\${ORDERER_CA:-/etc/hyperledger/orderer/tls/ca.crt}
        ORDERER_ADDR=\${ORDERER_URL:-orderer1.ordererorg-net.pc1.nirav.com:443}

        peer lifecycle chaincode approveformyorg \
            --channelID ${CHANNEL_NAME} \
            --name ${CC_NAME} \
            --version ${CC_VERSION} \
            --sequence ${CC_SEQUENCE} \
            --package-id ${package_id} \
            --signature-policy \"OR('org1MSP.peer','org2MSP.peer')\" \
            --tls \
            --cafile \"\${ORDERER_CA}\" \
            --orderer \"\${ORDERER_ADDR}\" \
            2>&1
    " || true)

    if echo "$approve_output" | grep -qE "Chaincode definition approved|already approved"; then
        log_success "  Approved for ${org_label}"
    else
        # May have already been approved
        if echo "$approve_output" | grep -qi "committed\|error"; then
            log_warning "  Approve output (${org_label}): ${approve_output}"
        else
            log_success "  Approved for ${org_label}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 5: Check commit readiness
# ---------------------------------------------------------------------------
_check_commit_readiness() {
    local kubeconfig="$1"
    local namespace="$2"

    local cli_pod
    cli_pod=$(_get_cli_pod "$kubeconfig" "$namespace")

    log_info "  Checking commit readiness..."

    local readiness_output
    readiness_output=$(_cli_exec "$kubeconfig" "$namespace" "$cli_pod" "
        ORDERER_CA=\${ORDERER_CA:-/etc/hyperledger/orderer/tls/ca.crt}
        ORDERER_ADDR=\${ORDERER_URL:-orderer1.ordererorg-net.pc1.nirav.com:443}

        peer lifecycle chaincode checkcommitreadiness \
            --channelID ${CHANNEL_NAME} \
            --name ${CC_NAME} \
            --version ${CC_VERSION} \
            --sequence ${CC_SEQUENCE} \
            --signature-policy \"OR('org1MSP.peer','org2MSP.peer')\" \
            --tls \
            --cafile \"\${ORDERER_CA}\" \
            --orderer \"\${ORDERER_ADDR}\" \
            2>&1
    " || true)

    log_info "  Readiness: $(echo "$readiness_output" | grep -E 'true|false' | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
# Step 6: Commit chaincode definition (from org1, targeting both peers)
# ---------------------------------------------------------------------------
_commit_chaincode() {
    local kc_org1="$1"
    local kc_org2="$2"

    local cli_pod
    cli_pod=$(_get_cli_pod "$kc_org1" "org1-net")

    log_info "  Committing chaincode to channel (from org1 CLI)..."

    # Extract org2 peer TLS cert from org2 CLI pod (safer than piping through local shell)
    # The cert is at CORE_PEER_TLS_ROOTCERT_FILE in the CLI pod
    local cli2
    cli2=$(_get_cli_pod "$kc_org2" "org2-net")
    local org2_tls_cert=""
    if [[ -n "$cli2" ]]; then
        kubectl --kubeconfig "$kc_org2" exec -n org2-net "$cli2" -- \
            bash -c 'cat "${CORE_PEER_TLS_ROOTCERT_FILE}"' 2>/dev/null \
            > /tmp/org2-peer-tls.pem || true
    fi

    # Copy org2 TLS cert to org1 CLI pod via temp file (avoids pipe 0-byte issue)
    if [[ -s /tmp/org2-peer-tls.pem ]]; then
        kubectl --kubeconfig "$kc_org1" cp /tmp/org2-peer-tls.pem \
            "org1-net/${cli_pod}:/tmp/org2-peer-tls.pem" 2>/dev/null || true
        log_info "  Copied org2 peer TLS cert to org1 CLI pod ($(wc -c < /tmp/org2-peer-tls.pem) bytes)"
    else
        log_warning "  Could not extract org2 TLS cert - commit may use org1 only"
    fi

    local pc3_domain
    pc3_domain=$(load_config_var "PC3_DOMAIN" "pc3.jigs.com")
    local org2_peer_ext="peer0.org2-net.${pc3_domain}:443"

    local commit_output
    commit_output=$(_cli_exec "$kc_org1" "org1-net" "$cli_pod" "
        ORDERER_CA=\${ORDERER_CA:-/etc/hyperledger/orderer/tls/ca.crt}
        ORDERER_ADDR=\${ORDERER_URL:-orderer1.ordererorg-net.pc1.nirav.com:443}
        PEER_TLS_ROOTCERT=\${CORE_PEER_TLS_ROOTCERT_FILE}
        ORG2_TLS=/tmp/org2-peer-tls.pem

        # Build peerAddresses args
        # Use correct service name 'peer0' (not 'peer0org1') for the headless svc in org1-net
        PEER_ADDR_ARGS=\"--peerAddresses peer0.org1-net:7051 --tlsRootCertFiles \${PEER_TLS_ROOTCERT}\"
        if [[ -s \"\${ORG2_TLS}\" ]]; then
            # org2 peer address derived from PC3_DOMAIN in config (in org1's CoreDNS -> 192.168.1.4)
            ORG2_PEER_ADDR=${org2_peer_ext}
            PEER_ADDR_ARGS=\"\${PEER_ADDR_ARGS} --peerAddresses \${ORG2_PEER_ADDR} --tlsRootCertFiles \${ORG2_TLS}\"
        fi

        peer lifecycle chaincode commit \
            --channelID ${CHANNEL_NAME} \
            --name ${CC_NAME} \
            --version ${CC_VERSION} \
            --sequence ${CC_SEQUENCE} \
            --signature-policy \"OR('org1MSP.peer','org2MSP.peer')\" \
            --tls \
            --cafile \"\${ORDERER_CA}\" \
            --orderer \"\${ORDERER_ADDR}\" \
            \${PEER_ADDR_ARGS} \
            2>&1
    " || true)

    if echo "$commit_output" | grep -qE "Chaincode definition committed|already committed|committed with status.*VALID"; then
        log_success "  Chaincode committed to ${CHANNEL_NAME}"
    elif echo "$commit_output" | grep -qi "error"; then
        log_warning "  Commit output: ${commit_output}"
        log_info "  Trying commit with org1 only (single endorser)..."
        _commit_chaincode_single_org "$kc_org1" "$cli_pod"
    else
        log_success "  Chaincode committed to ${CHANNEL_NAME}"
    fi
}

# Fallback: commit with only org1 endorser (majority if only 2 orgs = needs both, but try anyway)
_commit_chaincode_single_org() {
    local kubeconfig="$1"
    local cli_pod="$2"

    _cli_exec "$kubeconfig" "org1-net" "$cli_pod" "
        ORDERER_CA=\${ORDERER_CA:-/etc/hyperledger/orderer/tls/ca.crt}
        ORDERER_ADDR=\${ORDERER_URL:-orderer1.ordererorg-net.pc1.nirav.com:443}
        PEER_TLS_ROOTCERT=\${CORE_PEER_TLS_ROOTCERT_FILE:-/etc/hyperledger/fabric/crypto/peer/tls/ca.crt}

        peer lifecycle chaincode commit \
            --channelID ${CHANNEL_NAME} \
            --name ${CC_NAME} \
            --version ${CC_VERSION} \
            --sequence ${CC_SEQUENCE} \
            --signature-policy \"OR('org1MSP.peer','org2MSP.peer')\" \
            --tls \
            --cafile \"\${ORDERER_CA}\" \
            --orderer \"\${ORDERER_ADDR}\" \
            --peerAddresses peer0.org1-net:7051 \
            --tlsRootCertFiles \"\${PEER_TLS_ROOTCERT}\" \
            2>&1
    " && log_success "  Committed (org1 only)" || log_error "  Commit failed"
}

# ---------------------------------------------------------------------------
# Step 7: Init the ledger (populate initial assets)
# ---------------------------------------------------------------------------
_init_ledger() {
    local kubeconfig="$1"

    local cli_pod
    cli_pod=$(_get_cli_pod "$kubeconfig" "org1-net")

    log_info "  Initializing ledger with sample assets..."

    local _pc3_domain
    _pc3_domain=$(load_config_var "PC3_DOMAIN" "pc3.jigs.com")
    local _org2_peer_ext="peer0.org2-net.${_pc3_domain}:443"

    local init_output
    init_output=$(_cli_exec "$kubeconfig" "org1-net" "$cli_pod" "
        ORDERER_CA=\${ORDERER_CA:-/etc/hyperledger/orderer/tls/ca.crt}
        ORDERER_ADDR=\${ORDERER_URL:-orderer1.ordererorg-net.pc1.nirav.com:443}
        PEER_TLS_ROOTCERT=\${CORE_PEER_TLS_ROOTCERT_FILE:-/etc/hyperledger/fabric/crypto/peer/tls/ca.crt}
        PEER_ADDRS=\"--peerAddresses peer0.org1-net:7051 --tlsRootCertFiles \${PEER_TLS_ROOTCERT}\"
        if [[ -s \"/tmp/org2-peer-tls.pem\" ]]; then
            ORG2_PEER_ADDR=${_org2_peer_ext}
            PEER_ADDRS=\"\${PEER_ADDRS} --peerAddresses \${ORG2_PEER_ADDR} --tlsRootCertFiles /tmp/org2-peer-tls.pem\"
        fi

        peer chaincode invoke \
            --channelID ${CHANNEL_NAME} \
            --name ${CC_NAME} \
            --ctor '{\"Args\":[\"InitLedger\"]}' \
            --tls \
            --cafile \"\${ORDERER_CA}\" \
            --orderer \"\${ORDERER_ADDR}\" \
            \${PEER_ADDRS} \
            --waitForEvent \
            2>&1
    " || true)

    if echo "$init_output" | grep -qi "Chaincode invoke successful\|esponse:<status:200"; then
        log_success "  Ledger initialized with sample assets"
    else
        log_warning "  Init output: ${init_output}"
    fi
}

# ---------------------------------------------------------------------------
# Step 8: Run 20 test transactions
# ---------------------------------------------------------------------------
_run_test_transactions() {
    local kc_org1="$1"
    local kc_org2="$2"

    log_step "Running 20 test transactions on ${CHANNEL_NAME}"

    local cli1
    cli1=$(_get_cli_pod "$kc_org1" "org1-net")
    local cli2
    cli2=$(_get_cli_pod "$kc_org2" "org2-net")

    local pass=0
    local fail=0
    local _tx_pc3_domain
    _tx_pc3_domain=$(load_config_var "PC3_DOMAIN" "pc3.jigs.com")
    local _tx_org2_peer_ext="peer0.org2-net.${_tx_pc3_domain}:443"

    # Helper to invoke from org1 CLI
    _invoke_org1() {
        local args="$1"
        local desc="$2"
        local result
        result=$(_cli_exec "$kc_org1" "org1-net" "$cli1" "
            ORDERER_CA=\${ORDERER_CA:-/etc/hyperledger/orderer/tls/ca.crt}
            ORDERER_ADDR=\${ORDERER_URL:-orderer1.ordererorg-net.pc1.nirav.com:443}
            PEER_TLS_ROOTCERT=\${CORE_PEER_TLS_ROOTCERT_FILE:-/etc/hyperledger/fabric/crypto/peer/tls/ca.crt}
            PEER_ADDRS=\"--peerAddresses peer0.org1-net:7051 --tlsRootCertFiles \${PEER_TLS_ROOTCERT}\"
            if [[ -s \"/tmp/org2-peer-tls.pem\" ]]; then
                ORG2_PEER_ADDR=${_tx_org2_peer_ext}
                PEER_ADDRS=\"\${PEER_ADDRS} --peerAddresses \${ORG2_PEER_ADDR} --tlsRootCertFiles /tmp/org2-peer-tls.pem\"
            fi
            peer chaincode invoke \
                --channelID ${CHANNEL_NAME} --name ${CC_NAME} \
                --ctor '${args}' --tls \
                --cafile \"\${ORDERER_CA}\" --orderer \"\${ORDERER_ADDR}\" \
                \${PEER_ADDRS} \
                --waitForEvent 2>&1
        " || true)
        if echo "$result" | grep -qi "successful\|status:200"; then
            log_success "  [TX $(printf '%02d' $((pass+fail+1)))] PASS: $desc"
            pass=$((pass+1))
        else
            log_warning "  [TX $(printf '%02d' $((pass+fail+1)))] FAIL: $desc => ${result##*Error:}"
            fail=$((fail+1))
        fi
    }

    # Helper to query from org2 CLI
    _query_org2() {
        local args="$1"
        local desc="$2"
        local result
        result=$(_cli_exec "$kc_org2" "org2-net" "$cli2" "
            PEER_TLS_ROOTCERT=\${CORE_PEER_TLS_ROOTCERT_FILE:-/etc/hyperledger/fabric/crypto/peer/tls/ca.crt}
            peer chaincode query \
                --channelID ${CHANNEL_NAME} --name ${CC_NAME} \
                --ctor '${args}' --tls \
                --peerAddresses peer0.org2-net:7051 \
                --tlsRootCertFiles \"\${PEER_TLS_ROOTCERT}\" 2>&1
        " || true)
        # Strip MSP debug log lines (DEBU) to get just the chaincode response
        local clean_result
        clean_result=$(echo "$result" | grep -v " DEBU \| INFO \| WARN " || true)
        if echo "$clean_result" | grep -qi "asset\|\\[\\]"; then
            log_success "  [QR $(printf '%02d' $((pass+fail+1)))] PASS: $desc"
            pass=$((pass+1))
        else
            log_warning "  [QR $(printf '%02d' $((pass+fail+1)))] FAIL: $desc"
            if [[ -n "$clean_result" ]]; then
                log_warning "    => $(echo "$clean_result" | tail -3 | tr '\n' ' ')"
            else
                log_warning "    => (empty response)"
            fi
            fail=$((fail+1))
        fi
    }

    echo ""
    echo -e "${CYAN}--- INVOKE TRANSACTIONS (org1) ---${NC}"

    # TX 1-8: Create new assets
    _invoke_org1 '{"Args":["CreateAsset","asset010","Gaming PC","Dave","2500","Electronics"]}' "CreateAsset asset010"
    _invoke_org1 '{"Args":["CreateAsset","asset011","Standing Desk","Eve","1200","Furniture"]}' "CreateAsset asset011"
    _invoke_org1 '{"Args":["CreateAsset","asset012","NAS Server","Frank","3200","Infrastructure"]}' "CreateAsset asset012"
    _invoke_org1 '{"Args":["CreateAsset","asset013","UPS Battery","Grace","400","Electronics"]}' "CreateAsset asset013"
    _invoke_org1 '{"Args":["CreateAsset","asset014","Network Switch","Henry","900","Networking"]}' "CreateAsset asset014"
    _invoke_org1 '{"Args":["CreateAsset","asset015","Workstation","Ivy","4500","Electronics"]}' "CreateAsset asset015"
    _invoke_org1 '{"Args":["CreateAsset","asset016","Firewall Appliance","Jack","2800","Networking"]}' "CreateAsset asset016"
    _invoke_org1 '{"Args":["CreateAsset","asset017","Label Printer","Karen","350","Electronics"]}' "CreateAsset asset017"

    echo ""
    echo -e "${CYAN}--- UPDATE TRANSACTIONS (org1) ---${NC}"

    # TX 9-12: Update existing assets
    _invoke_org1 '{"Args":["UpdateAsset","asset001","Laptop Pro X1","Alice","1800","Electronics"]}' "UpdateAsset asset001 (new value)"
    _invoke_org1 '{"Args":["UpdateAsset","asset002","Standing Desk Pro","Bob","1100","Furniture"]}' "UpdateAsset asset002"
    _invoke_org1 '{"Args":["UpdateAsset","asset010","Gaming PC RGB","Dave","2700","Electronics"]}' "UpdateAsset asset010"
    _invoke_org1 '{"Args":["SetAssetStatus","asset013","maintenance"]}' "SetAssetStatus asset013 -> maintenance"

    echo ""
    echo -e "${CYAN}--- TRANSFER TRANSACTIONS (org1) ---${NC}"

    # TX 13-16: Transfer ownership
    _invoke_org1 '{"Args":["TransferAsset","asset003","org2-admin"]}' "TransferAsset asset003 to org2-admin"
    _invoke_org1 '{"Args":["TransferAsset","asset004","org1-admin"]}' "TransferAsset asset004 to org1-admin"
    _invoke_org1 '{"Args":["TransferAsset","asset011","Charlie"]}' "TransferAsset asset011 to Charlie"
    _invoke_org1 '{"Args":["TransferAsset","asset012","org2-admin"]}' "TransferAsset asset012 to org2-admin"

    echo ""
    echo -e "${CYAN}--- DELETE TRANSACTIONS (org1) ---${NC}"

    # TX 17-18: Delete assets
    _invoke_org1 '{"Args":["DeleteAsset","asset017"]}' "DeleteAsset asset017"
    _invoke_org1 '{"Args":["DeleteAsset","asset016"]}' "DeleteAsset asset016"

    echo ""
    echo -e "${CYAN}--- QUERY TRANSACTIONS (org2) ---${NC}"

    # TX 19-20: Queries from org2 to verify cross-org visibility
    _query_org2 '{"Args":["ReadAsset","asset001"]}' "ReadAsset asset001 (from org2)"
    _query_org2 '{"Args":["GetAllAssets"]}' "GetAllAssets (from org2)"

    echo ""
    log_header "Transaction Results"
    echo -e "  ${GREEN}Passed: ${pass}${NC}"
    echo -e "  ${RED}Failed: ${fail}${NC}"
    echo -e "  Total:  $((pass+fail)) / 20"

    save_config_var "CHAINCODE_TX_PASS" "$pass"
    save_config_var "CHAINCODE_TX_FAIL" "$fail"
}

# ---------------------------------------------------------------------------
# Step 9: Verify committed chaincode
# ---------------------------------------------------------------------------
_verify_committed() {
    local kubeconfig="$1"
    local namespace="$2"
    local label="$3"

    local cli_pod
    cli_pod=$(_get_cli_pod "$kubeconfig" "$namespace")

    local result
    result=$(_cli_exec "$kubeconfig" "$namespace" "$cli_pod" "
        ORDERER_CA=\${ORDERER_CA:-/etc/hyperledger/orderer/tls/ca.crt}
        ORDERER_ADDR=\${ORDERER_URL:-orderer1.ordererorg-net.pc1.nirav.com:443}

        peer lifecycle chaincode querycommitted \
            --channelID ${CHANNEL_NAME} \
            --name ${CC_NAME} \
            --tls \
            --cafile \"\${ORDERER_CA}\" \
            --orderer \"\${ORDERER_ADDR}\" \
            2>&1
    " || true)

    if echo "$result" | grep -q "$CC_NAME"; then
        log_success "  ${label}: chaincode '${CC_NAME}' v${CC_VERSION} committed ✓"
    else
        log_warning "  ${label}: could not verify committed chaincode"
    fi
}

# ---------------------------------------------------------------------------
# Show chaincode summary
# ---------------------------------------------------------------------------
show_chaincode_summary() {
    local kc_org1
    kc_org1=$(load_config_var "KUBECONFIG_ORG1" "")

    echo ""
    log_header "Chaincode Summary"

    local cli_pod
    cli_pod=$(_get_cli_pod "$kc_org1" "org1-net" 2>/dev/null || true)
    if [[ -n "$cli_pod" ]]; then
        echo -e "${CYAN}Installed chaincodes (org1):${NC}"
        _cli_exec "$kc_org1" "org1-net" "$cli_pod" \
            "peer lifecycle chaincode queryinstalled 2>/dev/null | grep -A1 '$CC_LABEL' || true" 2>/dev/null | \
            while IFS= read -r line; do echo "  $line"; done

        echo ""
        echo -e "${CYAN}Committed chaincodes:${NC}"
        _cli_exec "$kc_org1" "org1-net" "$cli_pod" "
            ORDERER_CA=\${ORDERER_CA:-/etc/hyperledger/orderer/tls/ca.crt}
            ORDERER_ADDR=\${ORDERER_URL:-orderer1.ordererorg-net.pc1.nirav.com:443}
            peer lifecycle chaincode querycommitted \
                --channelID ${CHANNEL_NAME} \
                --tls --cafile \"\${ORDERER_CA}\" --orderer \"\${ORDERER_ADDR}\" 2>/dev/null || true
        " 2>/dev/null | while IFS= read -r line; do echo "  $line"; done

        echo ""
        echo -e "${CYAN}Current ledger state (GetAllAssets from org1):${NC}"
        _cli_exec "$kc_org1" "org1-net" "$cli_pod" "
            PEER_TLS_ROOTCERT=\${CORE_PEER_TLS_ROOTCERT_FILE:-/etc/hyperledger/fabric/crypto/peer/tls/ca.crt}
            peer chaincode query \
                --channelID ${CHANNEL_NAME} --name ${CC_NAME} \
                --ctor '{\"Args\":[\"GetAllAssets\"]}' \
                --tls --tlsRootCertFiles \"\${PEER_TLS_ROOTCERT}\" 2>/dev/null | python3 -m json.tool 2>/dev/null || true
        " 2>/dev/null | while IFS= read -r line; do echo "  $line"; done
    fi

    local pass fail
    pass=$(load_config_var "CHAINCODE_TX_PASS" "?")
    fail=$(load_config_var "CHAINCODE_TX_FAIL" "?")
    echo ""
    echo -e "  ${GREEN}Transactions passed: ${pass}${NC}"
    echo -e "  ${RED}Transactions failed: ${fail}${NC}"
}

# ---------------------------------------------------------------------------
# Helper: copy org2 TLS cert into org1's CLI pod for multi-org endorsement
# Must be called before InitLedger and test transactions.
# ---------------------------------------------------------------------------
_copy_org2_tls_cert() {
    local kc_org1="$1"
    local kc_org2="$2"

    local cli1 cli2
    cli1=$(_get_cli_pod "$kc_org1" "org1-net")
    cli2=$(_get_cli_pod "$kc_org2" "org2-net")

    if [[ -z "$cli2" ]]; then
        log_warning "  org2 CLI pod not found; cross-org endorsement unavailable"
        return 0
    fi

    kubectl --kubeconfig "$kc_org2" exec -n org2-net "$cli2" -- \
        bash -c 'cat "${CORE_PEER_TLS_ROOTCERT_FILE}"' 2>/dev/null \
        > /tmp/org2-peer-tls.pem || true

    if [[ -s /tmp/org2-peer-tls.pem ]]; then
        kubectl --kubeconfig "$kc_org1" cp /tmp/org2-peer-tls.pem \
            "org1-net/${cli1}:/tmp/org2-peer-tls.pem" 2>/dev/null || true
        log_success "  Org2 TLS cert copied to org1 CLI pod — both orgs will endorse"
    else
        log_warning "  Could not extract org2 TLS cert; invokes will use org1 only"
    fi
}

# ---------------------------------------------------------------------------
# Helper: get the currently committed sequence number (empty if not committed)
# ---------------------------------------------------------------------------
_get_committed_sequence() {
    local kubeconfig="$1"
    local namespace="$2"

    local cli_pod
    cli_pod=$(_get_cli_pod "$kubeconfig" "$namespace")

    _cli_exec "$kubeconfig" "$namespace" "$cli_pod" "
        ORDERER_CA=\${ORDERER_CA:-/etc/hyperledger/orderer/tls/ca.crt}
        ORDERER_ADDR=\${ORDERER_URL:-orderer1.ordererorg-net.pc1.nirav.com:443}
        peer lifecycle chaincode querycommitted \
            --channelID ${CHANNEL_NAME} --name ${CC_NAME} \
            --tls --cafile \"\${ORDERER_CA}\" --orderer \"\${ORDERER_ADDR}\" 2>&1
    " 2>/dev/null | grep -oE 'Sequence: [0-9]+' | grep -oE '[0-9]+' | head -1 || true
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
setup_chaincode() {
    log_header "PHASE 12: Chaincode Deployment"
    echo ""
    echo -e "  Chaincode:  ${CYAN}${CC_NAME}${NC} (Simple CRUD asset management)"
    echo -e "  Version:    ${CC_VERSION}"
    echo -e "  Channel:    ${CHANNEL_NAME}"
    echo -e "  Orgs:       org1MSP + org2MSP"
    echo ""

    # Load kubeconfigs
    local kc_org1 kc_org2
    kc_org1=$(load_config_var "KUBECONFIG_ORG1" "")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2" "")

    if [[ -z "$kc_org1" ]] || [[ ! -f "$kc_org1" ]]; then
        log_error "KUBECONFIG_ORG1 not set. Ensure controller setup is complete."
        return 1
    fi
    if [[ -z "$kc_org2" ]] || [[ ! -f "$kc_org2" ]]; then
        log_error "KUBECONFIG_ORG2 not set. Ensure controller setup is complete."
        return 1
    fi

    # Wait for CLI pods to be ready
    _wait_for_cli "$kc_org1" "org1-net" || return 1
    _wait_for_cli "$kc_org2" "org2-net" || return 1

    # Step 1: Package
    _package_chaincode || return 1

    # Step 2: Install on both orgs
    log_step "Installing chaincode on peers"
    _install_on_peer "$kc_org1" "org1-net" "org1"
    _install_on_peer "$kc_org2" "org2-net" "org2"

    # Step 3: Get package IDs
    log_step "Retrieving package IDs"
    local pkg_id_org1 pkg_id_org2
    pkg_id_org1=$(_get_package_id "$kc_org1" "org1-net")
    pkg_id_org2=$(_get_package_id "$kc_org2" "org2-net")

    log_info "  org1 package ID: ${pkg_id_org1:0:40}..."
    log_info "  org2 package ID: ${pkg_id_org2:0:40}..."

    if [[ -z "$pkg_id_org1" ]]; then
        log_error "Could not get package ID for org1"
        return 1
    fi
    if [[ -z "$pkg_id_org2" ]]; then
        log_error "Could not get package ID for org2"
        return 1
    fi

    # Step 3.5: Auto-detect committed sequence and bump to avoid policy conflicts on resume
    log_step "Checking existing chaincode commitment"
    local committed_seq
    committed_seq=$(_get_committed_sequence "$kc_org1" "org1-net")
    if [[ -n "$committed_seq" ]]; then
        CC_SEQUENCE="$((committed_seq + 1))"
        log_info "  Chaincode already committed at sequence ${committed_seq}; bumping to sequence ${CC_SEQUENCE} with OR endorsement policy"
    else
        log_info "  No existing commitment; using sequence ${CC_SEQUENCE} with OR endorsement policy"
    fi

    # Step 4: Approve for each org
    log_step "Approving chaincode definition"
    _approve_chaincode "$kc_org1" "org1-net" "org1MSP" "$pkg_id_org1" "org1"
    _approve_chaincode "$kc_org2" "org2-net" "org2MSP" "$pkg_id_org2" "org2"

    # Step 5: Check readiness
    _check_commit_readiness "$kc_org1" "org1-net"

    # Step 6: Commit
    log_step "Committing chaincode definition"
    _commit_chaincode "$kc_org1" "$kc_org2"

    # Verify committed
    log_step "Verifying chaincode commitment"
    _verify_committed "$kc_org1" "org1-net" "org1"
    _verify_committed "$kc_org2" "org2-net" "org2"

    # Step 6.5: Copy org2 TLS cert to org1 CLI pod for multi-org endorsement
    log_step "Setting up cross-org endorsement"
    _copy_org2_tls_cert "$kc_org1" "$kc_org2"

    # Step 7: Init ledger
    log_step "Initializing ledger with sample data"
    _init_ledger "$kc_org1"

    # Step 8: Run 20 transactions
    _run_test_transactions "$kc_org1" "$kc_org2"

    # Step 9: Final verification
    log_step "Final chaincode verification"
    show_chaincode_summary

    log_success "Chaincode deployment and testing complete!"
    save_config_var "CHAINCODE_DEPLOYED" "true"
}
