#!/usr/bin/env bash
# =============================================================================
# health-recovery.sh - Auto-detect and recover failed pods in Bevel deployments
#
# Handles any pod failure pattern after deploy-network.yaml, including:
#   1. Empty Vault certs (CA race condition on fresh deploy)
#      - Symptom: "no pem content" / "nil conf reference" crash
#      - Fix:     clear empty Vault secrets → recreate certs-job → restart pod
#   2. ImagePullBackOff
#      - Fix:     k3s ctr images pull → restart pod
#   3. General CrashLoopBackOff / OOMKilled
#      - Fix:     delete pod (restart), up to MAX_RECOVERY_ATTEMPTS
#   4. Pending / Init stuck
#      - Fix:     wait + retry
#   5. Immutable Job Helm upgrade failure (IP change → VAULT_ADDR changed in Job)
#      - Symptom: HelmRelease False "spec.template: field is immutable"
#      - Fix:     delete the immutable Job → flux suspend+resume (full reinstall)
#   6. StatefulSet spec drift (pod running with stale spec, e.g. old VAULT_ADDR)
#      - Symptom: pod VAULT_ADDR ≠ StatefulSet template VAULT_ADDR
#      - Fix:     delete pod → K8s recreates from current StatefulSet template
#
# Called automatically from run_site_deployment() in bevel-deploy.sh.
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
readonly _MAX_RECOVERY_ATTEMPTS=3
readonly _RECOVERY_WAIT_TIMEOUT=300   # per cluster, seconds
readonly _CERTS_JOB_TIMEOUT=240       # wait for new certs-job, seconds
readonly _FLUX_RECONCILE_TIMEOUT=120  # flux reconcile timeout, seconds

# ---------------------------------------------------------------------------
# _get_cluster_vault_config <namespace>
# Prints: vault_url vault_token vault_org_path  (space-separated)
# ---------------------------------------------------------------------------
_get_cluster_vault_config() {
    local namespace="$1"
    local vault_url vault_token vault_org_path

    # Never hardcode IPs — always read from config.env which is authoritative.
    case "$namespace" in
        ordererorg-net)
            vault_url=$(load_config_var "VAULT_URL_ORDERER" "")
            vault_token=$(load_config_var "VAULT_TOKEN_ORDERER" "roottoken-orderer")
            vault_org_path="devordererorg"
            ;;
        org1-net)
            vault_url=$(load_config_var "VAULT_URL_ORG1" "")
            vault_token=$(load_config_var "VAULT_TOKEN_ORG1" "roottoken-org1")
            vault_org_path="devorg1"
            ;;
        org2-net)
            vault_url=$(load_config_var "VAULT_URL_ORG2" "")
            vault_token=$(load_config_var "VAULT_TOKEN_ORG2" "roottoken-org2")
            vault_org_path="devorg2"
            ;;
        *)
            return 1
            ;;
    esac

    [[ -z "$vault_url" ]] && return 1
    echo "$vault_url $vault_token $vault_org_path"
}

# ---------------------------------------------------------------------------
# _pod_node_info <pod_name>
# Prints: node_type  node_name  certs_job_prefix  helmrelease_name
#
# Examples:
#   fabric-orderernode-orderer2-0  -> "orderer orderer2 orderer2-certs-job orderer2"
#   fabric-peernode-peer0-0        -> "peer    peer0   peer0-certs-job    peer0"
# Returns 1 for non-orderer/peer pods (CA, jobs, CLI, etc.)
# ---------------------------------------------------------------------------
_pod_node_info() {
    local pod_name="$1"

    if [[ "$pod_name" =~ ^fabric-orderernode-([a-z0-9]+)-[0-9]+$ ]]; then
        local node_name="${BASH_REMATCH[1]}"
        echo "orderer ${node_name} ${node_name}-certs-job ${node_name}"
        return 0
    fi

    if [[ "$pod_name" =~ ^fabric-peernode-([a-z0-9]+)-[0-9]+$ ]]; then
        local node_name="${BASH_REMATCH[1]}"
        echo "peer ${node_name} ${node_name}-certs-job ${node_name}"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# _vault_secret_has_empty_certs <vault_url> <vault_token> <secret_path>
# Returns 0 (true) if secret is absent OR any cert field is empty/null
# Returns 1 (false) if all cert fields have content
# ---------------------------------------------------------------------------
_vault_secret_has_empty_certs() {
    local vault_url="$1" vault_token="$2" secret_path="$3"

    local response
    response=$(VAULT_ADDR="$vault_url" VAULT_TOKEN="$vault_token" \
        vault kv get -format=json "secretsv2/${secret_path}" 2>/dev/null) || {
        # Secret absent = treat as empty
        return 0
    }

    # Use jq to check if any cert field is null or empty string
    local empty_count
    empty_count=$(echo "$response" | jq -r '
        [.data.data // {} | to_entries[]
         | select(.key | test("admincerts|signcerts|server_crt|cacerts|ca_crt"))
         | select(.value == null or .value == "" or .value == "n/a")]
        | length
    ' 2>/dev/null)

    [[ "${empty_count:-1}" -gt "0" ]]
}

# ---------------------------------------------------------------------------
# _is_ca_cert_expired <kubeconfig> <namespace>
# Checks if the CA server's TLS certificate has expired.
# Returns 0 if expired/invalid, 1 if valid.
# ---------------------------------------------------------------------------
_is_ca_cert_expired() {
    local kubeconfig="$1" namespace="$2"

    # Get the CA cert from the K8s secret
    local cert_data
    cert_data=$(kubectl --kubeconfig "$kubeconfig" get secret fabric-ca-server-certs \
        -n "$namespace" -o jsonpath='{.data.tls\.crt}' 2>/dev/null) || return 0

    # Decode and check expiration
    local cert_file
    cert_file=$(mktemp) || return 0
    echo "$cert_data" | base64 -d > "$cert_file" 2>/dev/null

    # Check if cert is expired or not yet valid
    if openssl x509 -noout -checkend 0 -in "$cert_file" 2>/dev/null; then
        # Certificate is valid
        rm -f "$cert_file"
        return 1
    else
        # Certificate is expired or invalid
        rm -f "$cert_file"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# _identify_pod_failure <kubeconfig> <namespace> <pod_name>
# Prints a failure type string and returns 0.
# Failure types: empty_vault_certs | image_pull | oom_killed | crashloop |
#                init_stuck | pending | completed | unknown
# ---------------------------------------------------------------------------
_identify_pod_failure() {
    local kubeconfig="$1" namespace="$2" pod_name="$3"

    # Get pod status
    local pod_line
    pod_line=$(kubectl --kubeconfig "$kubeconfig" get pod "$pod_name" \
        -n "$namespace" --no-headers 2>/dev/null || echo "")
    local pod_status
    pod_status=$(echo "$pod_line" | awk '{print $3}')

    # Already healthy / finished
    if [[ "$pod_status" =~ ^(Running|Completed|Succeeded)$ ]]; then
        echo "healthy"
        return 0
    fi

    # Get the first non-init container's name for log retrieval
    local container
    container=$(kubectl --kubeconfig "$kubeconfig" get pod "$pod_name" \
        -n "$namespace" \
        -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || echo "")

    # Fetch logs (previous terminated instance preferred, fall back to current)
    local logs=""
    if [[ -n "$container" ]]; then
        logs=$(kubectl --kubeconfig "$kubeconfig" logs "$pod_name" \
            -n "$namespace" -c "$container" --previous --tail=60 2>/dev/null || \
            kubectl --kubeconfig "$kubeconfig" logs "$pod_name" \
            -n "$namespace" -c "$container" --tail=60 2>/dev/null || echo "")
    fi

    # Pattern: Vault cert written empty → peer/orderer crashes on startup
    if echo "$logs" | grep -qE "no pem content|nil conf reference|Setup error: nil conf"; then
        echo "empty_vault_certs"
        return 0
    fi

    # Pattern: TLS certificate expired
    if echo "$logs" | grep -qE "x509: certificate has expired|tls: failed to verify certificate|current time.*is after.*valid"; then
        echo "empty_vault_certs"  # Handle same as empty certs - need to clear and regenerate
        return 0
    fi

    # Pattern: init container got bad data from Vault (certificates-init)
    if echo "$pod_line" | grep -qE "Init:[0-9]+/[0-9]+|Init:Error|Init:CrashLoop"; then
        local init_logs
        init_logs=$(kubectl --kubeconfig "$kubeconfig" logs "$pod_name" \
            -n "$namespace" -c "certificates-init" --tail=30 2>/dev/null || echo "")
        if echo "$init_logs" | grep -qE "no pem content|nil conf|empty|absent"; then
            echo "empty_vault_certs"
            return 0
        fi
        echo "init_stuck"
        return 0
    fi

    case "$pod_status" in
        ImagePullBackOff|ErrImagePull)
            echo "image_pull"
            ;;
        OOMKilled)
            echo "oom_killed"
            ;;
        Pending)
            echo "pending"
            ;;
        CrashLoopBackOff|Error|ContainerCannotRun)
            echo "crashloop"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# _clear_node_vault_secrets <vault_url> <vault_token> <vault_org_path>
#                           <node_type> <node_name>
# Deletes empty Vault secrets for the given node so a fresh certs-job can
# re-enroll. For peers, also clears admin-msp/admin-tls (same certs-job).
# Only deletes secrets that actually have empty certs (safe to call always).
# ---------------------------------------------------------------------------
_clear_node_vault_secrets() {
    local vault_url="$1" vault_token="$2" vault_org_path="$3"
    local node_type="$4" node_name="$5"

    local -a paths_to_check

    if [[ "$node_type" == "orderer" ]]; then
        paths_to_check=(
            "${vault_org_path}/orderers/${node_name}-msp"
            "${vault_org_path}/orderers/${node_name}-tls"
        )
    else
        # peer: the peer certs-job creates both peer AND admin secrets
        paths_to_check=(
            "${vault_org_path}/peers/${node_name}-msp"
            "${vault_org_path}/peers/${node_name}-tls"
            "${vault_org_path}/users/admin-msp"
            "${vault_org_path}/users/admin-tls"
        )
    fi

    local cleared=0
    for path in "${paths_to_check[@]}"; do
        if _vault_secret_has_empty_certs "$vault_url" "$vault_token" "$path"; then
            log_info "    Clearing empty Vault secret: ${path}"
            VAULT_ADDR="$vault_url" VAULT_TOKEN="$vault_token" \
                vault kv metadata delete "secretsv2/${path}" 2>/dev/null || true
            (( cleared++ ))
        fi
    done

    (( cleared > 0 ))  # return 0 if we cleared at least one
}

# ---------------------------------------------------------------------------
# _clear_node_k8s_secrets <kubeconfig> <namespace> <node_type> <node_name>
# Deletes K8s secrets that the certs-job creates, so the new job can
# recreate them with correct data.
# ---------------------------------------------------------------------------
_clear_node_k8s_secrets() {
    local kubeconfig="$1" namespace="$2" node_type="$3" node_name="$4"

    local -a secrets_to_delete=("${node_name}-msp" "${node_name}-tls")
    if [[ "$node_type" == "peer" ]]; then
        secrets_to_delete+=("admin-msp" "admin-tls")
    fi

    for secret in "${secrets_to_delete[@]}"; do
        if kubectl --kubeconfig "$kubeconfig" get secret "$secret" \
            -n "$namespace" &>/dev/null; then
            log_info "    Deleting stale K8s secret: ${secret}"
            kubectl --kubeconfig "$kubeconfig" delete secret "$secret" \
                -n "$namespace" 2>/dev/null || true
        fi
    done
}

# ---------------------------------------------------------------------------
# _flux_force_reconcile <kubeconfig> <namespace> <helmrelease_name>
# Forces Flux to re-apply a HelmRelease, which recreates any deleted Jobs.
# Falls back to annotation-based trigger if flux CLI unavailable.
# ---------------------------------------------------------------------------
_flux_force_reconcile() {
    local kubeconfig="$1" namespace="$2" helmrelease="$3"

    log_info "    Triggering Flux reconcile for HelmRelease/${helmrelease} in ${namespace}..."

    if KUBECONFIG="$kubeconfig" flux reconcile helmrelease "$helmrelease" \
        -n "$namespace" --force --timeout="${_FLUX_RECONCILE_TIMEOUT}s" 2>/dev/null; then
        return 0
    fi

    # Fallback: annotate to trigger reconcile manually
    kubectl --kubeconfig "$kubeconfig" annotate helmrelease "$helmrelease" \
        -n "$namespace" \
        "reconcile.fluxcd.io/requestedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --overwrite 2>/dev/null || true

    log_info "    Waiting ${_FLUX_RECONCILE_TIMEOUT}s for Flux to reconcile..."
    sleep "$_FLUX_RECONCILE_TIMEOUT"
}

# ---------------------------------------------------------------------------
# _wait_for_certs_job <kubeconfig> <namespace> <job_prefix> [timeout]
# Waits for a certs-job (matched by prefix) to appear and complete.
# Returns 0 on success, 1 on timeout.
# ---------------------------------------------------------------------------
_wait_for_certs_job() {
    local kubeconfig="$1" namespace="$2" job_prefix="$3"
    local timeout="${4:-$_CERTS_JOB_TIMEOUT}"
    local start elapsed

    start=$(date +%s)
    log_info "    Waiting for ${job_prefix} to complete (up to ${timeout}s)..."

    while true; do
        elapsed=$(( $(date +%s) - start ))
        if (( elapsed > timeout )); then
            log_warning "    Timeout waiting for ${job_prefix}."
            return 1
        fi

        # Use jsonpath for reliable detection — kubectl 1.28+ added a STATUS column
        # that breaks awk '{print $2}' (returns "Complete" instead of "1/1").
        local succeeded
        succeeded=$(kubectl --kubeconfig "$kubeconfig" get job "${job_prefix}" \
            -n "$namespace" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)

        if [[ "$succeeded" == "1" ]]; then
            log_success "    ${job_prefix}: succeeded (elapsed: ${elapsed}s)"
            return 0
        fi

        local active
        active=$(kubectl --kubeconfig "$kubeconfig" get job "${job_prefix}" \
            -n "$namespace" -o jsonpath='{.status.active}' 2>/dev/null || true)
        log_info "    ${job_prefix}: active=${active:-0} succeeded=${succeeded:-0} (elapsed: ${elapsed}s)"

        sleep 10
    done
}

# ---------------------------------------------------------------------------
# _wait_ca_ready <kubeconfig> <namespace> [timeout]
# Waits for fabric-ca-server-ca-0 to be fully Running AND its container ready.
#
# Critical before triggering a certs-job: the CA gRPC enrollment endpoint
# must be accepting requests, not just "Running" (it takes ~15-30s after
# the container reports ready). Called inside _fix_empty_vault_certs to
# prevent the race where a just-recovered CA writes empty certs again.
# ---------------------------------------------------------------------------
_wait_ca_ready() {
    local kubeconfig="$1" namespace="$2" timeout="${3:-180}"
    local ca_pod="fabric-ca-server-ca-0"
    local start elapsed

    start=$(date +%s)
    log_info "    Waiting for CA (${ca_pod}) to be fully ready in ${namespace} (up to ${timeout}s)..."

    while true; do
        elapsed=$(( $(date +%s) - start ))
        if (( elapsed > timeout )); then
            log_warning "    Timeout waiting for CA readiness in ${namespace}."
            return 1
        fi

        local ready_status pod_phase
        pod_phase=$(kubectl --kubeconfig "$kubeconfig" get pod "$ca_pod" \
            -n "$namespace" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        ready_status=$(kubectl --kubeconfig "$kubeconfig" get pod "$ca_pod" \
            -n "$namespace" \
            -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")

        if [[ "$pod_phase" == "Running" && "$ready_status" == "true" ]]; then
            log_success "    CA is Running+Ready in ${namespace} (elapsed: ${elapsed}s)"
            # Extra grace: gRPC enrollment endpoint takes a few seconds after
            # the container reports ready. Without this, certs-job hits EOF.
            log_info "    Waiting 20s extra for CA enrollment endpoint to initialize..."
            sleep 20
            return 0
        fi

        log_info "    CA: phase=${pod_phase:-unknown} ready=${ready_status:-false} (elapsed: ${elapsed}s)"
        sleep 10
    done
}

# ---------------------------------------------------------------------------
# _wait_pod_healthy <kubeconfig> <namespace> <pod_name> [timeout]
# Waits for a specific pod to reach Running state.
# ---------------------------------------------------------------------------
_wait_pod_healthy() {
    local kubeconfig="$1" namespace="$2" pod_name="$3" timeout="${4:-120}"
    local start elapsed

    start=$(date +%s)
    while true; do
        elapsed=$(( $(date +%s) - start ))
        (( elapsed > timeout )) && return 1

        local status
        # The pod name has a StatefulSet suffix, use grep-based match
        status=$(kubectl --kubeconfig "$kubeconfig" get pod "$pod_name" \
            -n "$namespace" --no-headers 2>/dev/null | awk '{print $2, $3}')

        if echo "$status" | grep -qE "^[0-9]+/[0-9]+ Running"; then
            local ready total
            ready=$(echo "$status" | awk '{print $1}' | cut -d/ -f1)
            total=$(echo "$status" | awk '{print $1}' | cut -d/ -f2)
            if [[ "$ready" == "$total" && "$total" -gt "0" ]]; then
                return 0
            fi
        fi

        sleep 10
    done
}

# ===========================================================================
# FIX STRATEGIES
# ===========================================================================

# ---------------------------------------------------------------------------
# _fix_empty_vault_certs <kubeconfig> <namespace> <pod_name>
#                        <vault_url> <vault_token> <vault_org_path>
#
# IMPORTANT: Before doing anything destructive, checks the certs-job state.
# Kubernetes' own job backoffLimit naturally retries failed pods — interrupting
# that with Vault clears causes infinite loops.
#
# Decision logic:
#   ACTIVE job      → wait for natural completion, then restart pod only
#   SUCCEEDED job   → restart pod only (certs may now be in Vault)
#   PERMANENTLY FAILED or ABSENT job → full recovery (clear Vault + retry)
#
# Special case: Expired CA cert
#   If the CA server's TLS cert is expired, we need to force regeneration by
#   clearing the K8s secret and Vault CA data, then restarting the CA pod.
#
# Full recovery steps (only when truly needed):
#   1. Clear empty Vault secrets
#   2. Clear stale K8s secrets
#   3. Delete old certs-job
#   3.5. Wait for CA to be fully ready (avoids re-triggering the race)
#   4. Flux reconcile → new certs-job created
#   5. Wait for new certs-job to finish
#   6. Verify Vault now has real certs
#   7. Delete crashing pod → init container re-reads from Vault → healthy
# ---------------------------------------------------------------------------
_fix_empty_vault_certs() {
    local kubeconfig="$1" namespace="$2" pod_name="$3"
    local vault_url="$4" vault_token="$5" vault_org_path="$6"

    local node_info
    if ! node_info=$(_pod_node_info "$pod_name"); then
        log_warning "    Cannot determine node info for ${pod_name}; skipping Vault fix."
        return 1
    fi

    local node_type node_name certs_job helm_release
    read -r node_type node_name certs_job helm_release <<< "$node_info"

    log_info "  [Vault-cert-fix] ${node_name} (${node_type}) in ${namespace}"

    # -------------------------------------------------------------------------
    # 0. Check certs-job state — choose the least-invasive action.
    #
    # The Bevel certs-job script unfortunately exits 0 even when CA enrollment
    # fails (it writes empty certs to Vault but doesn't return non-zero).
    # This means a "Succeeded" job may still have empty certs, and we can't
    # distinguish a real success from a silent enrollment failure.
    #
    # Strategy:
    #   - If job ACTIVE → it is still trying via backoffLimit; wait, don't interfere.
    #   - If job SUCCEEDED → restart pod; the next restart will pick up whatever
    #       certs exist; if still empty the pod will crash again and we retry.
    #   - If job PERMANENTLY FAILED or not present → full Vault-clear recovery.
    # -------------------------------------------------------------------------
    local job_active job_succeeded job_failed
    job_active=$(kubectl --kubeconfig "$kubeconfig" get job "${certs_job}" \
        -n "$namespace" -o jsonpath='{.status.active}' 2>/dev/null || echo "0")
    job_succeeded=$(kubectl --kubeconfig "$kubeconfig" get job "${certs_job}" \
        -n "$namespace" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    job_failed=$(kubectl --kubeconfig "$kubeconfig" get job "${certs_job}" \
        -n "$namespace" -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")
    local job_exists
    job_exists=$(kubectl --kubeconfig "$kubeconfig" get job "${certs_job}" \
        -n "$namespace" --no-headers 2>/dev/null | wc -l)

    if [[ "${job_active:-0}" -gt "0" ]]; then
        # Job is actively running a pod — Kubernetes is doing natural retries.
        # Clearing Vault now would corrupt a potentially-successful attempt.
        log_info "    ${certs_job} is ACTIVE (failed so far: ${job_failed:-0}) — letting Kubernetes retry naturally."
        log_info "    Waiting up to ${_CERTS_JOB_TIMEOUT}s for it to complete..."
        if _wait_for_certs_job "$kubeconfig" "$namespace" "$certs_job" "$_CERTS_JOB_TIMEOUT"; then
            log_info "    Job completed. Restarting pod ${pod_name} to pick up certs..."
            kubectl --kubeconfig "$kubeconfig" delete pod "$pod_name" \
                -n "$namespace" --force --grace-period=0 2>/dev/null || true
            log_success "  Pod restarted. Will come up when init container reads fresh Vault certs."
            return 0
        fi
        log_warning "    Wait timed out (${_CERTS_JOB_TIMEOUT}s). Escalating to full recovery..."
        # Fall through to full recovery below.

    elif [[ "${job_succeeded:-0}" == "1" ]]; then
        # Job exited 0 — restart pod so init container re-reads Vault.
        # If enrollment silently failed (empty certs), the pod will restart
        # again on the next recovery pass, and we'll try again.
        log_info "    ${certs_job} SUCCEEDED (exit 0). Restarting pod to pick up Vault certs..."
        kubectl --kubeconfig "$kubeconfig" delete pod "$pod_name" \
            -n "$namespace" --force --grace-period=0 2>/dev/null || true
        log_success "  Pod restarted. Will retry on next recovery pass if certs are still empty."
        return 0

    elif [[ "${job_exists:-0}" -gt "0" && "${job_failed:-0}" -eq "0" \
            && "${job_active:-0}" -eq "0" && "${job_succeeded:-0}" -eq "0" ]]; then
        # Job object exists but hasn't started any pods yet (just created).
        log_info "    ${certs_job} exists but hasn't started yet — waiting 30s..."
        sleep 30
        # Re-read active count
        job_active=$(kubectl --kubeconfig "$kubeconfig" get job "${certs_job}" \
            -n "$namespace" -o jsonpath='{.status.active}' 2>/dev/null || echo "0")
        if [[ "${job_active:-0}" -gt "0" ]]; then
            log_info "    Job now ACTIVE — waiting for natural completion..."
            _wait_for_certs_job "$kubeconfig" "$namespace" "$certs_job" "$_CERTS_JOB_TIMEOUT" || true
            kubectl --kubeconfig "$kubeconfig" delete pod "$pod_name" \
                -n "$namespace" --force --grace-period=0 2>/dev/null || true
            return 0
        fi
        log_info "    Job still not active after 30s — proceeding with full recovery."
        # Fall through to full recovery.

    else
        # Job permanently failed (failed > 0, active = 0, succeeded = 0)
        # OR job doesn't exist at all.
        log_info "    ${certs_job}: active=${job_active:-0} succeeded=${job_succeeded:-0} failed=${job_failed:-0} exists=${job_exists:-0}"
        log_info "    Certs-job permanently failed or absent — doing full Vault recovery."
    fi

    # -------------------------------------------------------------------------
    # Full recovery: clear Vault + K8s secrets, re-trigger certs-job.
    # Only reached when: job permanently failed OR job timed out waiting.
    # -------------------------------------------------------------------------

    # Check if the CA cert is expired - if so, we need to clear it too
    if _is_ca_cert_expired "$kubeconfig" "$namespace"; then
        log_warning "    CA TLS cert is expired - clearing CA cert to force regeneration..."
        # Clear the CA cert secret to force regeneration
        kubectl --kubeconfig "$kubeconfig" delete secret fabric-ca-server-certs \
            -n "$namespace" --ignore-not-found 2>/dev/null || true

        # Clear CA data from Vault
        VAULT_ADDR="$vault_url" VAULT_TOKEN="$vault_token" \
            vault kv metadata delete "secretsv2/${vault_org_path}/ca" 2>/dev/null || true

        # Restart CA pod to regenerate with new cert
        local ca_pod="fabric-ca-server-ca-0"
        if kubectl --kubeconfig "$kubeconfig" get pod "$ca_pod" -n "$namespace" &>/dev/null; then
            log_info "    Restarting CA pod to regenerate certs..."
            kubectl --kubeconfig "$kubeconfig" delete pod "$ca_pod" \
                -n "$namespace" --force --grace-period=0 2>/dev/null || true
            # Wait for CA to be ready
            _wait_ca_ready "$kubeconfig" "$namespace" 180 || true
        fi
    fi

    # 1. Clear empty Vault secrets
    _clear_node_vault_secrets \
        "$vault_url" "$vault_token" "$vault_org_path" "$node_type" "$node_name" || true

    # 2. Clear stale K8s secrets so new job can create them fresh
    _clear_node_k8s_secrets "$kubeconfig" "$namespace" "$node_type" "$node_name"

    # 3. Delete existing (failed/completed-with-wrong-data) certs-job
    local existing_job
    existing_job=$(kubectl --kubeconfig "$kubeconfig" get jobs -n "$namespace" \
        --no-headers 2>/dev/null | grep "^${certs_job}" | awk '{print $1}' | head -1)
    if [[ -n "$existing_job" ]]; then
        log_info "    Deleting stale certs-job: ${existing_job}"
        kubectl --kubeconfig "$kubeconfig" delete job "$existing_job" \
            -n "$namespace" 2>/dev/null || true
        sleep 5
    fi

    # 3.5. Wait for CA to be fully ready before triggering the new certs-job.
    #      Root cause of the loop: CA pod just recovered → certs-job runs
    #      immediately → CA enrollment endpoint not yet accepting connections
    #      → enroll returns EOF → empty certs written to Vault → same crash.
    #      The 20s grace in _wait_ca_ready covers the gRPC startup window.
    _wait_ca_ready "$kubeconfig" "$namespace" 180 || \
        log_warning "    CA readiness check timed out — proceeding with Flux reconcile anyway."

    # 4. Force Flux to reconcile the HelmRelease → recreates the certs-job
    _flux_force_reconcile "$kubeconfig" "$namespace" "$helm_release"

    # 5. Wait for the new certs-job to complete
    if ! _wait_for_certs_job "$kubeconfig" "$namespace" "$certs_job"; then
        log_error "    Certs-job did not complete in time for ${node_name}."
        return 1
    fi

    # 6. Verify the Vault secret now has real certs (not empty)
    local verify_path
    if [[ "$node_type" == "orderer" ]]; then
        verify_path="${vault_org_path}/orderers/${node_name}-msp"
    else
        verify_path="${vault_org_path}/peers/${node_name}-msp"
    fi

    if _vault_secret_has_empty_certs "$vault_url" "$vault_token" "$verify_path"; then
        log_error "    Certs-job finished but Vault still has empty certs for ${node_name}!"
        log_error "    CA may not be reachable. Check: kubectl logs fabric-ca-server-ca-0 -n ${namespace}"
        return 1
    fi

    # 7. Delete the crashing pod so its init container re-reads from Vault
    log_info "    Restarting pod ${pod_name} to pick up new certs..."
    kubectl --kubeconfig "$kubeconfig" delete pod "$pod_name" \
        -n "$namespace" --force --grace-period=0 2>/dev/null || true

    log_success "  Vault cert fix applied for ${node_name}. Pod restarting..."
    return 0
}

# ---------------------------------------------------------------------------
# _fix_image_pull <kubeconfig> <namespace> <pod_name>
# Tries to pull the missing image via k3s ctr and restarts the pod.
# ---------------------------------------------------------------------------
_fix_image_pull() {
    local kubeconfig="$1" namespace="$2" pod_name="$3"

    local image
    image=$(kubectl --kubeconfig "$kubeconfig" get pod "$pod_name" \
        -n "$namespace" \
        -o jsonpath='{.status.containerStatuses[?(@.state.waiting.reason=="ImagePullBackOff")].image}' \
        2>/dev/null | awk '{print $1}')

    [[ -z "$image" ]] && image=$(kubectl --kubeconfig "$kubeconfig" get pod "$pod_name" \
        -n "$namespace" \
        -o jsonpath='{.status.initContainerStatuses[?(@.state.waiting.reason=="ImagePullBackOff")].image}' \
        2>/dev/null | awk '{print $1}')

    if [[ -n "$image" ]]; then
        log_info "    Pulling image: ${image}"
        sudo k3s ctr images pull "$image" 2>/dev/null || {
            command -v docker &>/dev/null && {
                docker pull "$image" 2>/dev/null && {
                    local tmptar="/tmp/$(echo "$image" | tr '/:' '_').tar"
                    docker save "$image" -o "$tmptar" 2>/dev/null
                    sudo k3s ctr images import "$tmptar" 2>/dev/null
                    rm -f "$tmptar"
                }
            }
        }
    fi

    log_info "    Deleting pod ${pod_name} to restart with pulled image..."
    kubectl --kubeconfig "$kubeconfig" delete pod "$pod_name" \
        -n "$namespace" --force --grace-period=0 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _fix_pod_restart <kubeconfig> <namespace> <pod_name>
# Generic fix: delete pod and let K8s restart it.
# ---------------------------------------------------------------------------
_fix_pod_restart() {
    local kubeconfig="$1" namespace="$2" pod_name="$3"
    log_info "    Deleting pod ${pod_name} to restart..."
    kubectl --kubeconfig "$kubeconfig" delete pod "$pod_name" \
        -n "$namespace" --force --grace-period=0 2>/dev/null || true
}

# ===========================================================================
# NAMESPACE RECOVERY ORCHESTRATOR
# ===========================================================================

# ---------------------------------------------------------------------------
# _wait_namespace_healthy <kubeconfig> <namespace> <cluster_name> [timeout]
# Waits until all pods in namespace are Running/Completed/Succeeded.
# Returns 0 if healthy, 1 if timeout.
# ---------------------------------------------------------------------------
_wait_namespace_healthy() {
    local kubeconfig="$1" namespace="$2" cluster_name="$3" timeout="${4:-$_RECOVERY_WAIT_TIMEOUT}"
    local start elapsed

    start=$(date +%s)
    log_info "  Waiting for ${namespace} on ${cluster_name} to stabilize (up to ${timeout}s)..."

    while true; do
        elapsed=$(( $(date +%s) - start ))
        (( elapsed > timeout )) && return 1

        local pod_status not_ready
        pod_status=$(kubectl --kubeconfig "$kubeconfig" get pods \
            -n "$namespace" --no-headers 2>/dev/null || echo "")

        [[ -z "$pod_status" ]] && { sleep 10; continue; }

        not_ready=$(echo "$pod_status" | \
            grep -vcE "Running|Completed|Succeeded|^$" || true)

        if (( not_ready == 0 )); then
            log_success "  All pods in ${namespace} are healthy."
            return 0
        fi

        sleep 10
    done
}

# ---------------------------------------------------------------------------
# _recover_cluster_namespace <kubeconfig> <namespace> <cluster_name>
#                            <vault_url> <vault_token> <vault_org_path>
#
# Finds all unhealthy pods in the namespace and applies the appropriate fix.
# Returns 0 if namespace becomes healthy, 1 if any pods could not be fixed.
# ---------------------------------------------------------------------------
_recover_cluster_namespace() {
    local kubeconfig="$1" namespace="$2" cluster_name="$3"
    local vault_url="$4" vault_token="$5" vault_org_path="$6"

    log_step "Health check: ${namespace} (${cluster_name})"

    # Quick pre-check before the long stabilization sleep. If everything is already
    # Running/Completed (or only -cli- pods are Init — expected pre-channel-join),
    # skip the 90s wait + 300s "namespace healthy" wait entirely.
    _quick_namespace_ok() {
        local _status _bad
        _status=$(kubectl --kubeconfig "$kubeconfig" get pods -n "$namespace" \
            --no-headers 2>/dev/null || echo "")
        [[ -z "$_status" ]] && return 1
        _bad=$(echo "$_status" | grep -vE "Running|Completed|Succeeded|^$" | \
            grep -vE "\-cli\-.*Init" || true)
        [[ -z "$_bad" ]]
    }

    if _quick_namespace_ok; then
        log_success "  All pods healthy (or only CLI pods in expected pre-channel-join Init). Skipping recovery wait."
        return 0
    fi

    # Give pods and certs-jobs time to naturally stabilize before any intervention.
    # Before this recovery was added, Kubernetes' own job backoffLimit retried
    # certs-jobs until the CA was ready. We must not interrupt that mechanism.
    log_info "  Waiting 90s for pods to naturally stabilize in ${namespace}..."
    sleep 90

    # Get all non-healthy pods (exclude Running/Completed/Succeeded/empty lines)
    local pod_status bad_pods
    pod_status=$(kubectl --kubeconfig "$kubeconfig" get pods \
        -n "$namespace" --no-headers 2>/dev/null || echo "")

    bad_pods=$(echo "$pod_status" | \
        grep -vE "Running|Completed|Succeeded|^$" | \
        awk '{print $1}' || true)

    if [[ -z "$bad_pods" ]]; then
        log_success "  All pods healthy in ${namespace}. Nothing to recover."
        return 0
    fi

    log_warning "  Unhealthy pods found in ${namespace} (after 90s stabilization wait):"
    echo "$pod_status" | grep -vE "Running|Completed|Succeeded|^$" || true
    echo ""

    local any_fixed=false any_failed=false

    while IFS= read -r pod_name; do
        [[ -z "$pod_name" ]] && continue

        local failure_type attempt=0 pod_fixed=false

        # Initial failure type detection
        failure_type=$(_identify_pod_failure "$kubeconfig" "$namespace" "$pod_name")
        log_info "  → ${pod_name}: [${failure_type}]"

        while (( attempt < _MAX_RECOVERY_ATTEMPTS )) && ! $pod_fixed; do
            (( attempt++ ))
            (( attempt > 1 )) && {
                log_info "  Attempt ${attempt}/${_MAX_RECOVERY_ATTEMPTS} for ${pod_name}..."
                # Re-detect in case failure type changed after previous fix
                failure_type=$(_identify_pod_failure "$kubeconfig" "$namespace" "$pod_name")
                log_info "  → ${pod_name}: [${failure_type}]"
            }

            case "$failure_type" in

                healthy|completed)
                    pod_fixed=true
                    ;;

                empty_vault_certs)
                    if _fix_empty_vault_certs \
                        "$kubeconfig" "$namespace" "$pod_name" \
                        "$vault_url" "$vault_token" "$vault_org_path"; then
                        # Wait for pod to come back up before re-evaluating
                        sleep 20
                        _wait_pod_healthy "$kubeconfig" "$namespace" "$pod_name" 120 \
                            && pod_fixed=true
                    fi
                    ;;

                image_pull)
                    _fix_image_pull "$kubeconfig" "$namespace" "$pod_name"
                    sleep 30
                    _wait_pod_healthy "$kubeconfig" "$namespace" "$pod_name" 60 \
                        && pod_fixed=true
                    ;;

                oom_killed|crashloop|unknown)
                    _fix_pod_restart "$kubeconfig" "$namespace" "$pod_name"
                    sleep 30
                    _wait_pod_healthy "$kubeconfig" "$namespace" "$pod_name" 60 \
                        && pod_fixed=true
                    ;;

                pending|init_stuck)
                    # CLI pods wait for orderer-tls-cacert configmap (created during
                    # create-join-channel.yaml). This is expected - they self-resolve.
                    if [[ "$pod_name" == *"-cli-"* ]]; then
                        log_info "  ${pod_name} is a CLI pod waiting for channel join — this is expected and will self-resolve. Skipping."
                        pod_fixed=true
                        break
                    fi
                    log_info "  ${pod_name} is ${failure_type}, waiting 30s for it to progress..."
                    sleep 30
                    _wait_pod_healthy "$kubeconfig" "$namespace" "$pod_name" 60 \
                        && pod_fixed=true
                    ;;

                *)
                    log_warning "  Unknown failure type '${failure_type}' for ${pod_name}. Trying restart..."
                    _fix_pod_restart "$kubeconfig" "$namespace" "$pod_name"
                    sleep 30
                    ;;
            esac
        done

        if $pod_fixed; then
            log_success "  Recovered: ${pod_name}"
            any_fixed=true
        else
            log_warning "  Could not auto-recover: ${pod_name} (type: ${failure_type})"
            log_warning "  Diagnose with:"
            log_warning "    kubectl --kubeconfig ${kubeconfig} logs ${pod_name} -n ${namespace} --previous"
            log_warning "    kubectl --kubeconfig ${kubeconfig} describe pod ${pod_name} -n ${namespace}"
            any_failed=true
        fi

    done <<< "$bad_pods"

    # After individual fixes, wait for entire namespace to stabilize
    if $any_fixed; then
        _wait_namespace_healthy \
            "$kubeconfig" "$namespace" "$cluster_name" "$_RECOVERY_WAIT_TIMEOUT" || {
            log_warning "  ${namespace} still not fully healthy after recovery."
            any_failed=true
        }
    fi

    $any_failed && return 1
    return 0
}

# ===========================================================================
# CLI POD CERT REFRESH
# ===========================================================================

# ---------------------------------------------------------------------------
# _restart_cli_deployments <kc_org1> <kc_org2>
#
# Restarts CLI Deployment pods in org1-net and org2-net so their
# certificates-init init containers re-read certs from Vault.
#
# Problem: CLI pods (Deployments) start concurrently with certs-jobs during
# deploy-network.yaml. If the CA race condition causes a certs-job to write
# empty certs to Vault, the certificates-init init container completes
# successfully but with empty cert files. The CLI pod shows "Running" status
# (health-recovery skips it) but peer lifecycle commands fail later with
# "no pem content for server.crt".
#
# This function is called AFTER recover_all_clusters() has verified that
# Vault has good certs for all peers. Restarting CLI pods at this point
# ensures their init containers pick up valid certs from Vault.
#
# Note: CLI pods will briefly enter Init state after restart — this is
# normal. Those waiting for the orderer-tls-cacert configmap will self-
# resolve when create-join-channel.yaml runs.
# ---------------------------------------------------------------------------
_restart_cli_deployments() {
    local kc_org1="$1"
    local kc_org2="$2"

    log_step "Refreshing CLI pod certs (restart to pick up latest Vault certs)..."

    local restarted=false

    for pair in \
        "org1-net:${kc_org1}:devorg1:VAULT_URL_ORG1:VAULT_TOKEN_ORG1" \
        "org2-net:${kc_org2}:devorg2:VAULT_URL_ORG2:VAULT_TOKEN_ORG2"; do

        IFS=: read -r ns kc vault_path v_url_key v_token_key <<< "$pair"

        if [[ -z "$kc" ]] || [[ ! -f "$kc" ]]; then
            continue
        fi

        if ! kubectl --kubeconfig "$kc" cluster-info &>/dev/null; then
            log_info "  ${ns}: cluster not reachable, skipping CLI restart."
            continue
        fi

        # Only restart if Vault now has good (non-empty) admin-msp certs.
        # If certs are still empty, a restart would just re-read empty certs.
        local vault_url vault_token
        vault_url=$(load_config_var "$v_url_key" "")
        vault_token=$(load_config_var "$v_token_key" "")
        if [[ -n "$vault_url" ]] && [[ -n "$vault_token" ]]; then
            if _vault_secret_has_empty_certs \
                "$vault_url" "$vault_token" "${vault_path}/users/admin-msp"; then
                log_info "  ${ns}: Vault admin-msp still empty — skipping CLI restart."
                continue
            fi
            log_info "  ${ns}: Vault admin-msp certs confirmed good."
        fi

        # Find all CLI Deployments (peer0-cli, etc.)
        local cli_deps
        cli_deps=$(kubectl --kubeconfig "$kc" get deployment -n "$ns" \
            --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
            | grep -E "cli$" || true)

        if [[ -z "$cli_deps" ]]; then
            log_info "  ${ns}: No CLI deployments found."
            continue
        fi

        for dep in $cli_deps; do
            log_info "  Restarting ${dep} in ${ns}..."
            kubectl --kubeconfig "$kc" rollout restart deployment/"$dep" \
                -n "$ns" 2>/dev/null && restarted=true \
                || log_warning "  Could not restart ${dep} in ${ns}"
        done
    done

    if $restarted; then
        log_info "  Waiting 45s for CLI pods to restart with fresh Vault certs..."
        sleep 45
        log_success "  CLI pods restarted. Chaincode lifecycle will use valid admin MSP certs."
    else
        log_info "  No CLI pods needed restarting (Vault certs already confirmed good or clusters unreachable)."
    fi
}

# ===========================================================================
# PUBLIC ENTRY POINT
# ===========================================================================

# ---------------------------------------------------------------------------
# _fix_immutable_helmrelease_failures <kubeconfig> <namespace>
#
# Kubernetes Jobs have an immutable spec.template — if a Helm upgrade changes
# any Job field (e.g., VAULT_ADDR after an IP change), the upgrade is
# permanently blocked with:
#   "cannot patch <job>: spec.template: field is immutable"
#
# This function:
#   1. Finds all HelmReleases in <namespace> whose status contains "immutable"
#   2. Extracts the Job name from the error message
#   3. Deletes the immutable Job so Helm can reinstall (not upgrade) it
#   4. Forces a full Helm reinstall via flux suspend→resume
# ---------------------------------------------------------------------------
_fix_immutable_helmrelease_failures() {
    local kubeconfig="$1" namespace="$2"

    local failed_hrs
    failed_hrs=$(kubectl --kubeconfig "$kubeconfig" get helmrelease \
        -n "$namespace" -o json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for hr in data.get('items', []):
    name = hr['metadata']['name']
    for cond in hr.get('status', {}).get('conditions', []):
        msg = cond.get('message', '')
        if 'immutable' in msg or 'field is immutable' in msg:
            print(name + '|' + msg)
" 2>/dev/null)

    [[ -z "$failed_hrs" ]] && return 0

    log_warning "  Found HelmRelease(s) blocked by immutable resource(s) in ${namespace}:"

    while IFS='|' read -r hr_name error_msg; do
        log_info "    HelmRelease: ${hr_name}"

        # Extract all Job names from the error (pattern: cannot patch "<name>" with kind Job)
        local job_names
        job_names=$(echo "$error_msg" | grep -oP 'cannot patch "\K[^"]+(?=" with kind Job)' 2>/dev/null || true)

        if [[ -n "$job_names" ]]; then
            while IFS= read -r job_name; do
                log_info "    Deleting immutable Job: ${job_name}"
                kubectl --kubeconfig "$kubeconfig" delete job "$job_name" \
                    -n "$namespace" --ignore-not-found 2>/dev/null || true
            done <<< "$job_names"
        else
            # Fallback: delete any Failed/Complete jobs in namespace so Helm can reinstall
            log_info "    Could not parse Job name from error — deleting all non-running Jobs in ${namespace}"
            kubectl --kubeconfig "$kubeconfig" get jobs -n "$namespace" \
                --no-headers 2>/dev/null | \
                awk '$2 ~ /Failed|Complete/ {print $1}' | \
                while read -r j; do
                    kubectl --kubeconfig "$kubeconfig" delete job "$j" \
                        -n "$namespace" --ignore-not-found 2>/dev/null || true
                done
        fi

        # Force full Helm reinstall: suspend clears the "upgrade failed" state,
        # resume triggers a fresh install that can create new Jobs cleanly.
        log_info "    Forcing Helm reinstall for HelmRelease/${hr_name}..."
        KUBECONFIG="$kubeconfig" flux suspend helmrelease "$hr_name" \
            -n "$namespace" 2>/dev/null || true
        sleep 2
        KUBECONFIG="$kubeconfig" flux resume helmrelease "$hr_name" \
            -n "$namespace" 2>/dev/null || true

        log_success "    HelmRelease/${hr_name} reinstall triggered."
    done <<< "$failed_hrs"
}

# ---------------------------------------------------------------------------
# _fix_blocked_statefulset_rollouts <kubeconfig> <namespace>
#
# When a StatefulSet's spec.template is updated (e.g., VAULT_ADDR IP changed)
# but the running pod is in CrashLoopBackOff, Kubernetes cannot roll out the
# new spec because it waits for the old pod to become Ready first.
#
# This function detects StatefulSets where the pod's actual spec differs from
# the current template (by comparing pod's VAULT_ADDR env vs StatefulSet's),
# and deletes the stuck pod to force recreation from the current template.
# ---------------------------------------------------------------------------
_fix_blocked_statefulset_rollouts() {
    local kubeconfig="$1" namespace="$2"

    local sts_list
    sts_list=$(kubectl --kubeconfig "$kubeconfig" get statefulset \
        -n "$namespace" --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null)
    [[ -z "$sts_list" ]] && return 0

    while IFS= read -r sts_name; do
        # Get desired VAULT_ADDR from StatefulSet template
        local desired_vault_addr
        desired_vault_addr=$(kubectl --kubeconfig "$kubeconfig" get statefulset "$sts_name" \
            -n "$namespace" \
            -o jsonpath='{.spec.template.spec.initContainers[0].env[?(@.name=="VAULT_ADDR")].value}' \
            2>/dev/null)
        [[ -z "$desired_vault_addr" ]] && continue

        # Get actual VAULT_ADDR from the running pod
        local pod_name="${sts_name}-0"
        local actual_vault_addr
        actual_vault_addr=$(kubectl --kubeconfig "$kubeconfig" get pod "$pod_name" \
            -n "$namespace" \
            -o jsonpath='{.spec.initContainers[0].env[?(@.name=="VAULT_ADDR")].value}' \
            2>/dev/null)
        [[ -z "$actual_vault_addr" ]] && continue

        if [[ "$desired_vault_addr" != "$actual_vault_addr" ]]; then
            log_warning "  StatefulSet ${sts_name}: pod has stale VAULT_ADDR (${actual_vault_addr}), desired (${desired_vault_addr}) — deleting pod to force rollout"
            kubectl --kubeconfig "$kubeconfig" delete pod "$pod_name" \
                -n "$namespace" --force --grace-period=0 2>/dev/null || true
            log_success "    Deleted ${pod_name} — will restart with updated spec."
        fi
    done <<< "$sts_list"
}

# ---------------------------------------------------------------------------
# recover_all_clusters
#
# Checks and recovers all three clusters (orderer, org1, org2).
# Designed to be called:
#   - After deploy-network.yaml fails → fix then retry Ansible
#   - After deploy-network.yaml succeeds → ensure no silent pod failures
#     that would block the next step (e.g., missing admin-msp for genesis)
#
# Returns 0 if all clusters healthy (or recovered), 1 if issues remain.
# ---------------------------------------------------------------------------
recover_all_clusters() {
    log_header "POD HEALTH RECOVERY CHECK"

    local kc_orderer kc_org1 kc_org2
    kc_orderer=$(load_config_var "KUBECONFIG_ORDERER" "")
    kc_org1=$(load_config_var "KUBECONFIG_ORG1" "")
    kc_org2=$(load_config_var "KUBECONFIG_ORG2" "")

    if [[ -z "$kc_orderer" || -z "$kc_org1" || -z "$kc_org2" ]]; then
        log_warning "Kubeconfigs not set - skipping recovery check."
        return 0
    fi

    # --- Pre-flight: fix Helm + StatefulSet spec drift across all clusters ---
    # Must run BEFORE pod recovery so that immutable-Job failures are unblocked
    # and stale pods are recreated with the correct spec (e.g., updated VAULT_ADDR
    # after an IP change) before we start checking pod health.
    log_step "Pre-flight: checking for HelmRelease and StatefulSet spec drift..."
    for kc_ns_pair in \
        "${kc_orderer}:ordererorg-net" \
        "${kc_org1}:org1-net" \
        "${kc_org2}:org2-net"; do
        local kc="${kc_ns_pair%%:*}"
        local ns="${kc_ns_pair##*:}"
        _fix_immutable_helmrelease_failures "$kc" "$ns"
        _fix_blocked_statefulset_rollouts   "$kc" "$ns"
    done
    # Give pods a moment to restart after spec-drift fixes before health checks
    sleep 10

    # --- Vault K8s auth setup (token_reviewer_jwt) ---
    # bevel-vault-mgmt enables K8s auth but never sets token_reviewer_jwt.
    # Without it, every CA/peer init container fails with "permission denied".
    # Run this early (before pod health checks) so pods can authenticate.
    log_step "Ensuring Vault K8s auth token_reviewer_jwt is configured..."
    local o1_vault o2_vault
    if o1_vault=$(_get_cluster_vault_config "org1-net"); then
        read -r v1_url v1_token v1_path <<< "$o1_vault"
        _setup_org_vault_k8s_auth             "$kc_org1" "org1-net" "$v1_url" "$v1_token"             "$(kubectl --kubeconfig "$kc_org1" config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"             "devorg1" || true
    fi
    if o2_vault=$(_get_cluster_vault_config "org2-net"); then
        read -r v2_url v2_token v2_path <<< "$o2_vault"
        _setup_org_vault_k8s_auth             "$kc_org2" "org2-net" "$v2_url" "$v2_token"             "$(kubectl --kubeconfig "$kc_org2" config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"             "devorg2" || true
    fi

    local all_healthy=true issues_found=false

    # --- Orderer cluster ---
    local o_vault
    if o_vault=$(_get_cluster_vault_config "ordererorg-net"); then
        read -r o_url o_token o_path <<< "$o_vault"
        if ! _recover_cluster_namespace \
            "$kc_orderer" "ordererorg-net" "PC1 (Orderer)" \
            "$o_url" "$o_token" "$o_path"; then
            all_healthy=false issues_found=true
        fi
    fi

    # --- Org1 cluster ---
    local o1_vault
    if o1_vault=$(_get_cluster_vault_config "org1-net"); then
        read -r o1_url o1_token o1_path <<< "$o1_vault"
        if ! _recover_cluster_namespace \
            "$kc_org1" "org1-net" "PC2 (Org1)" \
            "$o1_url" "$o1_token" "$o1_path"; then
            all_healthy=false issues_found=true
        fi
    fi

    # --- Org2 cluster ---
    local o2_vault
    if o2_vault=$(_get_cluster_vault_config "org2-net"); then
        read -r o2_url o2_token o2_path <<< "$o2_vault"
        if ! _recover_cluster_namespace \
            "$kc_org2" "org2-net" "PC3 (Org2)" \
            "$o2_url" "$o2_token" "$o2_path"; then
            all_healthy=false issues_found=true
        fi
    fi

    echo ""
    if $all_healthy; then
        log_success "All clusters healthy."
    elif $issues_found; then
        log_warning "Some pods could not be auto-recovered (see warnings above)."
        log_warning "The deployment may still proceed if the affected pods are not critical."
    fi

    # After all cluster pod recovery: restart CLI pods so their init containers
    # re-read certs from Vault. CLI pods may have started with empty certs
    # during the CA race condition (they show "Running" but cert files are
    # empty). Now that peer certs are confirmed good in Vault, CLI pods will
    # get valid certs on restart — preventing chaincode failures later.
    _restart_cli_deployments "$kc_org1" "$kc_org2"

    $issues_found && return 1
    return 0
}

# ---------------------------------------------------------------------------
# _setup_org_vault_k8s_auth: Ensure Vault K8s auth backend has a valid
# token_reviewer_jwt and kubernetes_ca_cert for an org cluster.
#
# bevel-vault-mgmt enables the K8s auth backend and creates the role, but
# does NOT configure token_reviewer_jwt. Without it, Vault cannot call the
# K8s TokenReview API to validate service-account JWTs → every CA and peer
# init container fails with "permission denied" on fresh deploys.
#
# Args: kubeconfig  namespace  vault_url  vault_token  k8s_host  auth_path
# ---------------------------------------------------------------------------
_setup_org_vault_k8s_auth() {
    local kubeconfig="$1"
    local namespace="$2"
    local vault_url="$3"
    local vault_token="$4"
    local k8s_host="$5"
    local auth_path="$6"

    # Check if token_reviewer_jwt is already set (Vault redacts it - non-empty = configured)
    # We test by checking if the backend exists and trying a dummy login
    local auth_exists
    auth_exists=$(curl -sf -H "X-Vault-Token: ${vault_token}" \
        "${vault_url}/v1/sys/auth" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); \
            print('yes' if '${auth_path}/' in d else 'no')" 2>/dev/null)

    if [[ "$auth_exists" != "yes" ]]; then
        log_warning "  Vault K8s auth backend '${auth_path}/' not found - bevel-vault-mgmt may not have run yet"
        return 1
    fi

    # Check if token_reviewer_jwt is already configured by testing a login
    # (if it works for the CA pod, we can skip)
    local needs_setup=true
    local current_len
    current_len=$(curl -sf -H "X-Vault-Token: ${vault_token}" \
        "${vault_url}/v1/auth/${auth_path}/config" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); \
            print(len(d.get('data',{}).get('token_reviewer_jwt','')))" 2>/dev/null || echo "0")

    # Vault redacts the JWT (returns empty string) even when set.
    # Try a test: if we can verify the backend is healthy via a dummy call
    # that doesn't fail with "permission denied", skip.
    # For safety, always ensure it's set if we can.

    # Create vault-auth-token Secret if it doesn't exist (K8s 1.24+: no auto SA secrets)
    if ! kubectl --kubeconfig "$kubeconfig" get secret vault-auth-token \
        -n "$namespace" &>/dev/null 2>&1; then
        log_info "  Creating vault-auth-token Secret for ${namespace}..."
        kubectl --kubeconfig "$kubeconfig" apply -f - <<EOF 2>/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: ${namespace}
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
EOF
        sleep 5  # wait for K8s to populate the token
    fi

    # Ensure system:auth-delegator ClusterRoleBinding exists
    local crb_name="vault-auth-${namespace}"
    if ! kubectl --kubeconfig "$kubeconfig" get clusterrolebinding "$crb_name" &>/dev/null 2>&1; then
        log_info "  Creating ClusterRoleBinding ${crb_name}..."
        kubectl --kubeconfig "$kubeconfig" create clusterrolebinding "$crb_name" \
            --clusterrole=system:auth-delegator \
            --serviceaccount="${namespace}:vault-auth" 2>/dev/null || true
    fi

    # Extract token and K3s CA cert
    local reviewer_jwt
    reviewer_jwt=$(kubectl --kubeconfig "$kubeconfig" get secret vault-auth-token \
        -n "$namespace" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)

    if [[ -z "$reviewer_jwt" ]]; then
        log_warning "  vault-auth-token not populated yet — skipping Vault K8s auth config"
        return 1
    fi

    # Get cluster name from kubeconfig to extract CA cert
    local cluster_name
    cluster_name=$(kubectl --kubeconfig "$kubeconfig" config view \
        -o jsonpath='{.clusters[0].name}' 2>/dev/null)
    local k8s_ca
    k8s_ca=$(kubectl --kubeconfig "$kubeconfig" config view --raw \
        -o jsonpath="{.clusters[?(@.name==\"${cluster_name}\")].cluster.certificate-authority-data}" \
        2>/dev/null | base64 -d)

    if [[ -z "$k8s_ca" ]]; then
        log_warning "  Could not extract K8s CA cert for ${cluster_name}"
        return 1
    fi

    # Update Vault K8s auth config
    log_info "  Configuring Vault K8s auth backend '${auth_path}/' with token_reviewer_jwt..."
    local result
    result=$(VAULT_ADDR="$vault_url" VAULT_TOKEN="$vault_token" \
        vault write "auth/${auth_path}/config" \
            kubernetes_host="$k8s_host" \
            token_reviewer_jwt="$reviewer_jwt" \
            kubernetes_ca_cert="$k8s_ca" 2>&1)

    if echo "$result" | grep -q "Success"; then
        log_success "  Vault K8s auth configured for ${namespace} (${auth_path}/)"
        return 0
    else
        log_warning "  Failed to configure Vault K8s auth: ${result}"
        return 1
    fi
}
