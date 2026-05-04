#!/usr/bin/env bash
# =============================================================================
# explorer.sh - Deploy Hyperledger Explorer on the org1 cluster
# =============================================================================
# Deploys Hyperledger Explorer (blockchain browser UI) with PostgreSQL backend.
# Explorer is deployed in org1-net namespace on PC2, accessible via NodePort.
#
# Access: http://<PC2_IP>:30080  (admin / adminpw)
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
EXPLORER_NS="org1-net"
EXPLORER_NODEPORT="30080"
EXPLORER_DB_USER="hppoc"
EXPLORER_DB_PASS="password"
EXPLORER_DB_NAME="fabricexplorer"
EXPLORER_ADMIN_USER="admin"
EXPLORER_ADMIN_PASS="adminpw"
CHANNEL_NAME="mychannel"
EXPLORER_IMAGE="ghcr.io/hyperledger-labs/explorer:latest"
EXPLORER_DB_IMAGE="ghcr.io/hyperledger-labs/explorer-db:latest"

# ---------------------------------------------------------------------------
# Helper: get peer0-cli pod name from org1
# ---------------------------------------------------------------------------
_get_org1_cli_pod() {
    local kubeconfig="$1"
    kubectl --kubeconfig "$kubeconfig" get pod -n "$EXPLORER_NS" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
        | grep -E "cli" | grep -v "Completed" | head -1
}

# ---------------------------------------------------------------------------
# Step 1: Extract TLS certificates and admin credentials from running pods
# ---------------------------------------------------------------------------
_extract_certs() {
    local kubeconfig="$1"

    log_step "Extracting TLS certificates for Explorer connection profile"

    local cli_pod
    cli_pod=$(_get_org1_cli_pod "$kubeconfig")
    if [[ -z "$cli_pod" ]]; then
        log_error "No org1 CLI pod found in ${EXPLORER_NS}"
        return 1
    fi

    # Create temp dir for certs
    rm -rf /tmp/explorer-certs && mkdir -p /tmp/explorer-certs

    # Extract peer TLS CA cert (CORE_PEER_TLS_ROOTCERT_FILE is set in CLI pod env)
    log_info "  Extracting peer TLS CA cert..."
    kubectl --kubeconfig "$kubeconfig" exec -n "$EXPLORER_NS" "$cli_pod" -- \
        bash -c 'cat "${CORE_PEER_TLS_ROOTCERT_FILE}"' \
        2>/dev/null > /tmp/explorer-certs/peer-tls-ca.pem || true

    # Extract orderer TLS CA cert (configmap key is 'cacert', not 'crt')
    log_info "  Extracting orderer TLS CA cert..."
    kubectl --kubeconfig "$kubeconfig" get configmap orderer-tls-cacert \
        -n "$EXPLORER_NS" -o jsonpath='{.data.cacert}' 2>/dev/null \
        > /tmp/explorer-certs/orderer-tls-ca.pem || true

    # Fallback: get from CLI pod's ORDERER_CA env (set by Bevel)
    if [[ ! -s /tmp/explorer-certs/orderer-tls-ca.pem ]]; then
        kubectl --kubeconfig "$kubeconfig" exec -n "$EXPLORER_NS" "$cli_pod" -- \
            bash -c 'cat "${ORDERER_CA}"' \
            2>/dev/null > /tmp/explorer-certs/orderer-tls-ca.pem || true
    fi

    # Extract admin MSP private key (path from CLI pod's CORE_PEER_MSPCONFIGPATH env)
    log_info "  Extracting admin MSP credentials..."
    # CORE_PEER_MSPCONFIGPATH = /opt/gopath/src/github.com/hyperledger/fabric/crypto/admin/msp
    kubectl --kubeconfig "$kubeconfig" exec -n "$EXPLORER_NS" "$cli_pod" -- \
        bash -c 'ls "${CORE_PEER_MSPCONFIGPATH}/keystore/" 2>/dev/null | head -1' \
        2>/dev/null > /tmp/explorer-certs/keyname.txt || true

    local keyname
    keyname=$(cat /tmp/explorer-certs/keyname.txt 2>/dev/null | tr -d '\n' || true)

    if [[ -n "$keyname" ]]; then
        kubectl --kubeconfig "$kubeconfig" exec -n "$EXPLORER_NS" "$cli_pod" -- \
            bash -c "cat \"\${CORE_PEER_MSPCONFIGPATH}/keystore/${keyname}\"" \
            2>/dev/null > /tmp/explorer-certs/admin-key.pem || true

        # Signcert file is server.crt (not cert.pem)
        kubectl --kubeconfig "$kubeconfig" exec -n "$EXPLORER_NS" "$cli_pod" -- \
            bash -c 'cat "${CORE_PEER_MSPCONFIGPATH}/signcerts/server.crt"' \
            2>/dev/null > /tmp/explorer-certs/admin-cert.pem || true
    fi

    # Verify we got the key certs
    local ok=true
    for f in peer-tls-ca.pem orderer-tls-ca.pem; do
        if [[ ! -s "/tmp/explorer-certs/${f}" ]]; then
            log_warning "  Could not extract: ${f} (explorer may have limited TLS verification)"
            ok=false
        else
            log_success "  Extracted: ${f} ($(wc -l < "/tmp/explorer-certs/${f}") lines)"
        fi
    done

    return 0
}

# ---------------------------------------------------------------------------
# Step 2: Build connection profile and config.json
# ---------------------------------------------------------------------------
_build_connection_profile() {
    local kubeconfig="$1"

    log_step "Building Explorer connection profile"

    # Load config variables
    local pc1_domain pc2_domain pc3_domain pc2_ip
    pc1_domain=$(load_config_var "PC1_DOMAIN" "pc1.nirav.com")
    pc2_domain=$(load_config_var "PC2_DOMAIN" "pc2.jigs.com")
    pc3_domain=$(load_config_var "PC3_DOMAIN" "pc3.rashmi.com")
    pc2_ip=$(load_config_var "PC2_IP" "192.168.1.37")

    # Read cert files (base64 encode for JSON embedding)
    local peer_tls_ca orderer_tls_ca admin_key admin_cert
    peer_tls_ca=$(base64 -w 0 /tmp/explorer-certs/peer-tls-ca.pem 2>/dev/null || echo "")
    orderer_tls_ca=$(base64 -w 0 /tmp/explorer-certs/orderer-tls-ca.pem 2>/dev/null || echo "")
    admin_key=$(base64 -w 0 /tmp/explorer-certs/admin-key.pem 2>/dev/null || echo "")
    admin_cert=$(base64 -w 0 /tmp/explorer-certs/admin-cert.pem 2>/dev/null || echo "")

    # Read PEM content for inline use
    local peer_tls_pem orderer_tls_pem
    peer_tls_pem=$(cat /tmp/explorer-certs/peer-tls-ca.pem 2>/dev/null | \
        python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
    orderer_tls_pem=$(cat /tmp/explorer-certs/orderer-tls-ca.pem 2>/dev/null | \
        python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
    admin_key_pem=$(cat /tmp/explorer-certs/admin-key.pem 2>/dev/null | \
        python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
    admin_cert_pem=$(cat /tmp/explorer-certs/admin-cert.pem 2>/dev/null | \
        python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')

    mkdir -p /tmp/explorer-config

    # Generate connection profile (first-network style for Explorer 1.x)
    cat > /tmp/explorer-config/connection-profile.json << CONNEOF
{
  "name": "${CHANNEL_NAME}",
  "version": "1.0.0",
  "license": "Apache-2.0",
  "client": {
    "tlsEnable": true,
    "adminCredential": {
      "id": "${EXPLORER_ADMIN_USER}",
      "password": "${EXPLORER_ADMIN_PASS}"
    },
    "enableAuthentication": true,
    "organization": "org1MSP",
    "connection": {
      "timeout": {
        "peer": { "endorser": "300" },
        "orderer": "300"
      }
    }
  },
  "channels": {
    "${CHANNEL_NAME}": {
      "peers": {
        "peer0.${EXPLORER_NS}": {
          "endorsingPeer": true,
          "chaincodeQuery": true,
          "ledgerQuery": true,
          "eventSource": true
        }
      }
    }
  },
  "organizations": {
    "org1MSP": {
      "mspid": "org1MSP",
      "peers": ["peer0.${EXPLORER_NS}"],
      "adminPrivateKey": {
        "pem": ${admin_key_pem}
      },
      "signedCert": {
        "pem": ${admin_cert_pem}
      }
    }
  },
  "peers": {
    "peer0.${EXPLORER_NS}": {
      "url": "grpcs://peer0.${EXPLORER_NS}.svc.cluster.local:7051",
      "tlsCACerts": {
        "pem": ${peer_tls_pem}
      },
      "grpcOptions": {
        "ssl-target-name-override": "peer0.${EXPLORER_NS}",
        "hostnameOverride": "peer0.${EXPLORER_NS}"
      }
    }
  },
  "orderers": {
    "orderer1.ordererorg-net.${pc1_domain}": {
      "url": "grpcs://orderer1.ordererorg-net.${pc1_domain}:443",
      "tlsCACerts": {
        "pem": ${orderer_tls_pem}
      },
      "grpcOptions": {
        "ssl-target-name-override": "orderer1.ordererorg-net.${pc1_domain}"
      }
    }
  }
}
CONNEOF

    # Generate Explorer config.json
    # Profile path is relative to config.json dir; connection-profile is in subdirectory
    cat > /tmp/explorer-config/config.json << CFGEOF
{
  "network-configs": {
    "bevel-fabric": {
      "name": "Bevel Fabric Network",
      "profile": "./connection-profile/connection-profile.json"
    }
  },
  "license": "Apache-2.0"
}
CFGEOF

    log_success "Connection profile built at /tmp/explorer-config/"
}

# ---------------------------------------------------------------------------
# Step 3: Deploy Explorer PostgreSQL database
# ---------------------------------------------------------------------------
_deploy_explorer_postgres() {
    local kubeconfig="$1"

    log_step "Deploying Explorer PostgreSQL database"

    # Check if already deployed
    if kubectl --kubeconfig "$kubeconfig" get deployment explorer-db \
            -n "$EXPLORER_NS" &>/dev/null; then
        log_info "  Explorer DB already deployed, skipping."
        return 0
    fi

    kubectl --kubeconfig "$kubeconfig" apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: explorer-db-pvc
  namespace: ${EXPLORER_NS}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: explorer-db
  namespace: ${EXPLORER_NS}
  labels:
    app: explorer-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: explorer-db
  template:
    metadata:
      labels:
        app: explorer-db
    spec:
      containers:
      - name: postgres
        image: ${EXPLORER_DB_IMAGE}
        env:
        - name: DATABASE_DATABASE
          value: "${EXPLORER_DB_NAME}"
        - name: DATABASE_USERNAME
          value: "${EXPLORER_DB_USER}"
        - name: DATABASE_PASSWORD
          value: "${EXPLORER_DB_PASS}"
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: db-data
          mountPath: /var/lib/postgresql/data
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "${EXPLORER_DB_USER}", "-d", "${EXPLORER_DB_NAME}"]
          initialDelaySeconds: 15
          periodSeconds: 5
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: db-data
        persistentVolumeClaim:
          claimName: explorer-db-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: explorer-db
  namespace: ${EXPLORER_NS}
  labels:
    app: explorer-db
spec:
  selector:
    app: explorer-db
  ports:
  - port: 5432
    targetPort: 5432
EOF

    log_info "  Waiting for Explorer DB to be ready..."
    kubectl --kubeconfig "$kubeconfig" wait deployment/explorer-db \
        -n "$EXPLORER_NS" --for=condition=available --timeout=180s 2>/dev/null || \
        log_warning "  Explorer DB not ready yet (will retry)"

    log_success "  Explorer DB deployed"
}

# ---------------------------------------------------------------------------
# Step 4: Deploy Hyperledger Explorer app
# ---------------------------------------------------------------------------
_deploy_explorer_app() {
    local kubeconfig="$1"

    log_step "Deploying Hyperledger Explorer application"

    # Check if already deployed
    if kubectl --kubeconfig "$kubeconfig" get deployment explorer \
            -n "$EXPLORER_NS" &>/dev/null; then
        log_info "  Explorer already deployed. Updating config..."
        kubectl --kubeconfig "$kubeconfig" delete configmap explorer-config \
            -n "$EXPLORER_NS" --ignore-not-found 2>/dev/null || true
    fi

    # Create ConfigMaps from generated files
    kubectl --kubeconfig "$kubeconfig" create configmap explorer-config \
        -n "$EXPLORER_NS" \
        --from-file=config.json=/tmp/explorer-config/config.json \
        --from-file=connection-profile.json=/tmp/explorer-config/connection-profile.json \
        --dry-run=client -o yaml | \
        kubectl --kubeconfig "$kubeconfig" apply -f - 2>/dev/null

    log_info "  Explorer ConfigMap created"

    # Deploy Explorer
    kubectl --kubeconfig "$kubeconfig" apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: explorer
  namespace: ${EXPLORER_NS}
  labels:
    app: explorer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: explorer
  template:
    metadata:
      labels:
        app: explorer
    spec:
      initContainers:
      - name: wait-for-db
        image: busybox:1.36
        command: ['sh', '-c', 'until nc -z explorer-db 5432; do echo waiting for db; sleep 2; done']
      containers:
      - name: explorer
        image: ${EXPLORER_IMAGE}
        env:
        - name: DATABASE_HOST
          value: "explorer-db"
        - name: DATABASE_DATABASE
          value: "${EXPLORER_DB_NAME}"
        - name: DATABASE_USERNAME
          value: "${EXPLORER_DB_USER}"
        - name: DATABASE_PASSWD
          value: "${EXPLORER_DB_PASS}"
        - name: LOG_LEVEL_APP
          value: "debug"
        - name: LOG_LEVEL_DB
          value: "debug"
        - name: LOG_LEVEL_CONSOLE
          value: "info"
        - name: LOG_CONSOLE_STDOUT
          value: "true"
        - name: DISCOVERY_AS_LOCALHOST
          value: "false"
        ports:
        - name: http
          containerPort: 8080
        volumeMounts:
        - name: explorer-config
          mountPath: /opt/explorer/app/platform/fabric/config.json
          subPath: config.json
        - name: explorer-config
          mountPath: /opt/explorer/app/platform/fabric/connection-profile/connection-profile.json
          subPath: connection-profile.json
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 6
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
      volumes:
      - name: explorer-config
        configMap:
          name: explorer-config
---
apiVersion: v1
kind: Service
metadata:
  name: explorer
  namespace: ${EXPLORER_NS}
  labels:
    app: explorer
spec:
  type: NodePort
  selector:
    app: explorer
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    nodePort: ${EXPLORER_NODEPORT}
EOF

    log_success "  Explorer deployment applied"
}

# ---------------------------------------------------------------------------
# Step 4b: Patch FabricGateway.js for Fabric v3.0 (lscc → _lifecycle fallback)
# ---------------------------------------------------------------------------
_patch_explorer_for_fabric_v3() {
    local kubeconfig="$1"
    local fabric_version
    fabric_version=$(load_config_var "FABRIC_VERSION" "2.5.4")

    # Only needed for Fabric v3.0+ where lscc syscc is removed
    if [[ "$fabric_version" != 3.* ]]; then
        return 0
    fi

    log_step "Patching Explorer for Fabric v3.0 compatibility (lscc → _lifecycle)"

    # Extract FabricGateway.js from the running explorer image, patch it, and mount via ConfigMap
    local patch_file="/tmp/explorer-FabricGateway-patch.js"
    docker run --rm --entrypoint cat "${EXPLORER_IMAGE}" \
        /opt/explorer/app/platform/fabric/gateway/FabricGateway.js \
        > "$patch_file" 2>/dev/null

    if [[ ! -s "$patch_file" ]]; then
        log_warning "Could not extract FabricGateway.js from ${EXPLORER_IMAGE}"
        return 1
    fi

    # Patch: wrap lscc call in try/catch so it falls back to _lifecycle on error
    # Explorer v2.0.0 tries lscc first; Fabric v3.0 throws an error (not empty result)
    if grep -q "let contract = network.getContract('lscc')" "$patch_file"; then
        sed -i '/queryInstantiatedChaincodes(channelName) {/,/^    }$/{
            /let contract = network.getContract('\''lscc'\'');/{
                N;N;
                s/let contract = network.getContract('\''lscc'\'');\n            let result = yield contract.evaluateTransaction('\''GetChaincodes'\'');\n            let resultJson = fabprotos.protos.ChaincodeQueryResponse.decode(result);/let resultJson = { chaincodes: [], toJSON: null };\n            \/\/ Patched: wrap lscc in try\/catch for Fabric v3.0 compatibility\n            try {\n                let contract = network.getContract('\''lscc'\'');\n                let result = yield contract.evaluateTransaction('\''GetChaincodes'\'');\n                resultJson = fabprotos.protos.ChaincodeQueryResponse.decode(result);\n            }\n            catch (lsccError) {\n                logger.info('\''lscc not available, falling back to _lifecycle'\'', lsccError.message);\n            }/
            }
        }' "$patch_file"
        # The original fallback block reuses bare `contract` and `result` names
        # (declared inside the lscc try block, so out of scope after catch).
        # Strict-mode JS throws ReferenceError → sync dies → 0 blocks/tx in UI.
        # Re-declare with `let` in the fallback path.
        python3 - "$patch_file" <<'PYFIX'
import sys, re
p = sys.argv[1]
with open(p) as f: s = f.read()
# Match the fallback block exactly once (inside queryInstantiatedChaincodes).
s = s.replace(
    "                contract = network.getContract('_lifecycle');\n"
    "                result = yield contract.evaluateTransaction('QueryChaincodeDefinitions', '');",
    "                let contract = network.getContract('_lifecycle');\n"
    "                let result = yield contract.evaluateTransaction('QueryChaincodeDefinitions', '');",
    1
)
with open(p, 'w') as f: f.write(s)
PYFIX
        log_info "  Patched lscc → _lifecycle fallback (with let decls)"
    else
        log_info "  FabricGateway.js already patched or has different structure"
    fi

    # Create/update ConfigMap with patched file
    kubectl --kubeconfig "$kubeconfig" create configmap explorer-gateway-patch \
        -n "$EXPLORER_NS" \
        --from-file=FabricGateway.js="$patch_file" \
        --dry-run=client -o yaml | \
        kubectl --kubeconfig "$kubeconfig" apply -f - 2>/dev/null

    # Patch the deployment to mount the patched file
    kubectl --kubeconfig "$kubeconfig" patch deployment explorer -n "$EXPLORER_NS" --type='json' -p='[
        {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "gateway-patch", "configMap": {"name": "explorer-gateway-patch"}}},
        {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "gateway-patch", "mountPath": "/opt/explorer/app/platform/fabric/gateway/FabricGateway.js", "subPath": "FabricGateway.js"}}
    ]' 2>/dev/null

    rm -f "$patch_file"
    log_success "  Explorer patched for Fabric v3.0"
}

# ---------------------------------------------------------------------------
# Step 5: Setup firewall for Explorer NodePort
# ---------------------------------------------------------------------------
_setup_explorer_firewall() {
    log_step "Opening firewall for Explorer NodePort ${EXPLORER_NODEPORT}"

    if command -v ufw &>/dev/null; then
        sudo ufw allow "${EXPLORER_NODEPORT}/tcp" comment "Hyperledger Explorer" 2>/dev/null || true
        log_success "  Firewall rule added for port ${EXPLORER_NODEPORT}"
    fi
}

# ---------------------------------------------------------------------------
# Step 6: Wait for Explorer to be ready
# ---------------------------------------------------------------------------
_wait_for_explorer() {
    local kubeconfig="$1"
    local pc2_ip="$2"
    local max_wait=300
    local elapsed=0

    log_step "Waiting for Explorer to be ready (up to ${max_wait}s)..."

    while (( elapsed < max_wait )); do
        local ready
        ready=$(kubectl --kubeconfig "$kubeconfig" get deployment explorer \
            -n "$EXPLORER_NS" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

        if [[ "${ready:-0}" -ge 1 ]]; then
            # Also check HTTP endpoint
            if curl -s --connect-timeout 5 "http://${pc2_ip}:${EXPLORER_NODEPORT}" \
                    -o /dev/null -w "%{http_code}" 2>/dev/null | grep -qE "200|302|301"; then
                log_success "  Explorer is ready and responding at http://${pc2_ip}:${EXPLORER_NODEPORT}"
                return 0
            fi
        fi

        log_info "  Explorer not ready yet (${elapsed}/${max_wait}s)..."
        sleep 15
        elapsed=$((elapsed + 15))
    done

    log_warning "Explorer did not become ready within ${max_wait}s"
    log_info "  Check pod status: kubectl --kubeconfig ${kubeconfig} get pods -n ${EXPLORER_NS} | grep explorer"
    return 1
}

# ---------------------------------------------------------------------------
# Show Explorer access info
# ---------------------------------------------------------------------------
show_explorer_urls() {
    local pc2_ip
    pc2_ip=$(load_config_var "PC2_IP" "?")

    echo ""
    log_header "Hyperledger Explorer"
    echo ""
    echo -e "  ${GREEN}URL:${NC}       http://${pc2_ip}:${EXPLORER_NODEPORT}"
    echo -e "  ${GREEN}Username:${NC}  ${EXPLORER_ADMIN_USER}"
    echo -e "  ${GREEN}Password:${NC}  ${EXPLORER_ADMIN_PASS}"
    echo ""
    echo -e "  ${CYAN}Features:${NC}"
    echo "    - Block explorer with transaction details"
    echo "    - Channel overview (mychannel)"
    echo "    - Chaincode list (asset-transfer)"
    echo "    - Node status (peers, orderers)"
    echo "    - Search blocks and transactions"
    echo ""
    echo -e "  ${DIM}Namespace: ${EXPLORER_NS} | NodePort: ${EXPLORER_NODEPORT}${NC}"
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
setup_explorer() {
    log_header "PHASE 13: Hyperledger Explorer"
    echo ""
    echo "  Deploying blockchain browser UI for visual network inspection."
    echo ""

    # Load kubeconfig for org1 (where Explorer is deployed)
    local kc_org1 pc2_ip
    kc_org1=$(load_config_var "KUBECONFIG_ORG1" "")
    pc2_ip=$(load_config_var "PC2_IP" "")

    if [[ -z "$kc_org1" ]] || [[ ! -f "$kc_org1" ]]; then
        log_error "KUBECONFIG_ORG1 not set. Skipping Explorer setup."
        return 1
    fi

    # Test connectivity to org1 cluster
    if ! kubectl --kubeconfig "$kc_org1" cluster-info &>/dev/null; then
        log_error "Cannot reach org1 cluster. Skipping Explorer setup."
        return 1
    fi

    # Step 1: Extract TLS certs
    _extract_certs "$kc_org1" || log_warning "Some certs could not be extracted - Explorer TLS may be limited"

    # Step 2: Build connection profile
    _build_connection_profile "$kc_org1"

    # Step 3: Deploy PostgreSQL
    _deploy_explorer_postgres "$kc_org1"

    # Step 4: Deploy Explorer app
    _deploy_explorer_app "$kc_org1"

    # Step 4b: Patch for Fabric v3.0 (lscc removed)
    _patch_explorer_for_fabric_v3 "$kc_org1"

    # Step 5: Firewall
    _setup_explorer_firewall

    # Step 6: Wait for readiness
    _wait_for_explorer "$kc_org1" "$pc2_ip" || true

    # Show access info
    show_explorer_urls

    save_config_var "EXPLORER_URL" "http://${pc2_ip}:${EXPLORER_NODEPORT}"
    save_config_var "EXPLORER_DEPLOYED" "true"

    log_success "Hyperledger Explorer deployment complete!"
}
