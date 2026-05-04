#!/usr/bin/env bash
# =============================================================================
# common.sh - Shared utilities for Bevel Fabric Network Setup
# =============================================================================

set -euo pipefail

# ---- Colors & Formatting ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# ---- Config Directory ----
BEVEL_CONFIG_DIR="${HOME}/.bevel-setup"
BEVEL_CONFIG_FILE="${BEVEL_CONFIG_DIR}/config.env"
BEVEL_CHECKLIST_FILE="${BEVEL_CONFIG_DIR}/checklist.json"
BEVEL_LOG_FILE="${BEVEL_CONFIG_DIR}/setup.log"
BEVEL_STATE_DIR="${BEVEL_CONFIG_DIR}/state"

init_config_dir() {
    mkdir -p "$BEVEL_CONFIG_DIR" "$BEVEL_STATE_DIR"
    touch "$BEVEL_LOG_FILE"
}

# ---- Logging ----
_log() {
    local level="$1" color="$2" msg="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${color}[${level}]${NC} ${msg}"
    echo "[${timestamp}] [${level}] ${msg}" >> "$BEVEL_LOG_FILE" 2>/dev/null || true
}

log_info()    { _log "INFO"    "$BLUE"    "$1"; }
log_success() { _log "OK"      "$GREEN"   "$1"; }
log_error()   { _log "ERROR"   "$RED"     "$1"; }
log_warning() { _log "WARN"    "$YELLOW"  "$1"; }
log_step()    { echo -e "\n${CYAN}${BOLD}>>> $1${NC}\n"; }
log_header()  {
    echo -e "\n${MAGENTA}${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}${BOLD}║  $1${NC}"
    echo -e "${MAGENTA}${BOLD}╚════════════════════════════════════════════════════════╝${NC}\n"
}

log_separator() {
    echo -e "${DIM}────────────────────────────────────────────────────────${NC}"
}

# ---- Banner ----
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'BANNER'
 ____                _   _   _      _                      _
| __ )  _____   _____| | | \ | | ___| |___      _____  _ __| | __
|  _ \ / _ \ \ / / _ \ | |  \| |/ _ \ __\ \ /\ / / _ \| '__| |/ /
| |_) |  __/\ V /  __/ | | |\  |  __/ |_ \ V  V / (_) | |  |   <
|____/ \___| \_/ \___|_| |_| \_|\___|\__| \_/\_/ \___/|_|  |_|\_\

    Multi-Cluster Hyperledger Fabric Automated Setup
BANNER
    echo -e "${NC}"
}

# ---- User Input Helpers ----
# Non-interactive mode: when BEVEL_NONINTERACTIVE=1, helpers auto-answer using
# defaults / pre-seeded values. Required for unattended SSH-driven runs.
ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local result
    if [[ "${BEVEL_NONINTERACTIVE:-0}" == "1" ]]; then
        # Empty default is allowed (caller may treat empty as "skip").
        echo "$default"
        return
    fi
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${YELLOW}? ${NC}${prompt} [${default}]: ")" result </dev/tty
        echo "${result:-$default}"
    else
        while true; do
            read -rp "$(echo -e "${YELLOW}? ${NC}${prompt}: ")" result </dev/tty
            if [[ -n "$result" ]]; then
                echo "$result"
                return
            fi
            echo -e "${RED}[ERROR]${NC} Input cannot be empty." >&2
        done
    fi
}

ask_secret() {
    local prompt="$1"
    local result
    if [[ "${BEVEL_NONINTERACTIVE:-0}" == "1" ]]; then
        echo -e "${RED}[NONINTERACTIVE-FATAL]${NC} ask_secret '${prompt}' must be pre-seeded." >&2
        exit 1
    fi
    while true; do
        read -srp "$(echo -e "${YELLOW}? ${NC}${prompt}: ")" result </dev/tty
        echo "" >&2 # newline after hidden input
        if [[ -n "$result" ]]; then
            echo "$result"
            return
        fi
        echo -e "${RED}[ERROR]${NC} Input cannot be empty." >&2
    done
}

ask_confirm() {
    local prompt="$1"
    local default="${2:-y}"
    if [[ "${BEVEL_NONINTERACTIVE:-0}" == "1" ]]; then
        # Allow env override to force-confirm destructive prompts (e.g., --clear).
        if [[ "${BEVEL_AUTO_CONFIRM:-0}" == "1" ]]; then return 0; fi
        [[ "${default,,}" == "y" || "${default,,}" == "yes" ]]
        return $?
    fi
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"
    local answer
    read -rp "$(echo -e "${YELLOW}? ${NC}${prompt} ${hint}: ")" answer </dev/tty
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    if [[ "${BEVEL_NONINTERACTIVE:-0}" == "1" ]]; then
        # Look up named answer in BEVEL_CHOICE_<sanitized prompt> env var, else default 0.
        local key="BEVEL_CHOICE_${prompt//[^A-Za-z0-9_]/_}"
        local val="${!key:-0}"
        echo "$val"
        return
    fi
    echo -e "\n${YELLOW}? ${NC}${prompt}" >&2
    local i
    for i in "${!options[@]}"; do
        echo -e "  ${CYAN}$((i + 1)))${NC} ${options[$i]}" >&2
    done
    local choice
    while true; do
        read -rp "$(echo -e "${YELLOW}  Select [1-${#options[@]}]: ${NC}")" choice </dev/tty
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "$((choice - 1))"
            return
        fi
        echo -e "${RED}[ERROR]${NC} Invalid choice. Enter a number between 1 and ${#options[@]}." >&2
    done
}

# ---- Config Persistence ----
save_config_var() {
    local key="$1" value="$2"
    init_config_dir
    # Remove existing key if present, then append
    if [[ -f "$BEVEL_CONFIG_FILE" ]]; then
        sed -i "/^${key}=/d" "$BEVEL_CONFIG_FILE"
    fi
    echo "${key}=${value}" >> "$BEVEL_CONFIG_FILE"
}

load_config_var() {
    local key="$1" default="${2:-}"
    if [[ -f "$BEVEL_CONFIG_FILE" ]]; then
        local val
        val=$(grep "^${key}=" "$BEVEL_CONFIG_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2-)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

load_all_config() {
    if [[ -f "$BEVEL_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$BEVEL_CONFIG_FILE"
    fi
}

# ---- Checklist / Phase Tracking ----
declare -A CHECKLIST_ITEMS

init_checklist() {
    CHECKLIST_ITEMS=(
        ["prerequisites"]="Install Prerequisites (Docker, K3s, etc.)"
        ["firewall"]="Configure Firewall Rules"
        ["dns"]="Configure DNS / /etc/hosts + CoreDNS"
        ["haproxy"]="Install HAProxy Ingress"
        ["k3s_fixes"]="Apply K3s Compatibility Fixes"
        ["vault"]="Setup HashiCorp Vault"
        ["kubeconfig"]="Export & Configure Kubeconfigs"
        ["gitops"]="Setup Git Repository & SSH Keys"
        ["network_yaml"]="Generate network.yaml"
        ["ansible_prereqs"]="Install Ansible & Python Prerequisites"
        ["k8s_env"]="Run K8s Environment Setup Playbook"
        ["deploy_network"]="Deploy Fabric Network (site.yaml)"
        ["verify_network"]="Verify Network Deployment"
        ["monitoring"]="Setup Prometheus & Grafana Monitoring"
        ["chaincode"]="Deploy Chaincode & Run Test Transactions"
        ["explorer"]="Deploy Hyperledger Explorer UI"
    )
}

mark_phase_done() {
    local phase="$1"
    save_config_var "PHASE_${phase}" "done"
    echo "done" > "${BEVEL_STATE_DIR}/${phase}.state"
}

is_phase_done() {
    local phase="$1"
    [[ -f "${BEVEL_STATE_DIR}/${phase}.state" ]] && [[ "$(cat "${BEVEL_STATE_DIR}/${phase}.state")" == "done" ]]
}

show_checklist() {
    echo -e "\n${BOLD}${MAGENTA}=== Setup Progress ===${NC}\n"
    local phases=(
        "prerequisites" "firewall" "dns" "haproxy" "k3s_fixes" "vault"
        "kubeconfig" "gitops" "network_yaml" "ansible_prereqs"
        "k8s_env" "deploy_network" "verify_network" "monitoring"
        "chaincode" "explorer"
    )
    for phase in "${phases[@]}"; do
        local desc="${CHECKLIST_ITEMS[$phase]:-$phase}"
        if is_phase_done "$phase"; then
            echo -e "  ${GREEN}[x]${NC} ${desc}"
        else
            echo -e "  ${DIM}[ ]${NC} ${desc}"
        fi
    done
    echo ""
}

# ---- Error Handling ----
handle_error() {
    local msg="${1:-Unknown error}"
    local line="${2:-unknown}"
    log_error "Failed at line ${line}: ${msg}"
    log_error "Check log: ${BEVEL_LOG_FILE}"
    echo -e "\n${YELLOW}Options:${NC}"
    echo -e "  1) Retry this step"
    echo -e "  2) Skip and continue"
    echo -e "  3) Abort"
    local choice
    read -rp "$(echo -e "${YELLOW}  Select [1-3]: ${NC}")" choice
    case "$choice" in
        1) return 1 ;; # caller should retry
        2) return 0 ;; # skip
        3) exit 1 ;;
        *) exit 1 ;;
    esac
}

run_cmd() {
    local desc="$1"
    shift
    log_info "Running: ${desc}"
    if "$@" >> "$BEVEL_LOG_FILE" 2>&1; then
        log_success "${desc} - Done"
        return 0
    else
        log_error "${desc} - Failed"
        return 1
    fi
}

run_with_retry() {
    local desc="$1" max_retries="${2:-3}"
    shift 2
    local attempt=1
    while (( attempt <= max_retries )); do
        log_info "Attempt ${attempt}/${max_retries}: ${desc}"
        if "$@" >> "$BEVEL_LOG_FILE" 2>&1; then
            log_success "${desc} - Done"
            return 0
        fi
        log_warning "Attempt ${attempt} failed."
        attempt=$((attempt + 1))
        sleep 2
    done
    log_error "${desc} - Failed after ${max_retries} attempts"
    return 1
}

# ---- Prerequisite Check Helpers ----
is_installed() {
    command -v "$1" &>/dev/null
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            log_warning "This script is designed for Ubuntu. Detected: ${ID} ${VERSION_ID}"
            if ! ask_confirm "Continue anyway?"; then
                exit 1
            fi
        else
            log_info "Detected: Ubuntu ${VERSION_ID}"
        fi
    else
        log_warning "Cannot detect OS. Proceeding assuming Ubuntu-compatible."
    fi
}

check_resources() {
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$((ram_kb / 1024 / 1024))
    local cpu_cores
    cpu_cores=$(nproc)
    local disk_free
    disk_free=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')

    log_info "System Resources: RAM=${ram_gb}GB, CPU=${cpu_cores} cores, Disk Free=${disk_free}GB"

    local warnings=0
    if (( ram_gb < 8 )); then
        log_warning "RAM ${ram_gb}GB is below minimum 8GB."
        warnings=$((warnings + 1))
    fi
    if (( cpu_cores < 4 )); then
        log_warning "CPU ${cpu_cores} cores is below minimum 4."
        warnings=$((warnings + 1))
    fi
    if (( disk_free < 50 )); then
        log_warning "Disk free ${disk_free}GB is below minimum 50GB."
        warnings=$((warnings + 1))
    fi

    if (( warnings > 0 )) && ! ask_confirm "System does not meet recommended specs. Continue?"; then
        exit 1
    fi
}

get_local_ip() {
    # Prefer the source IP used to reach the default gateway / internet.
    # Avoids picking docker/cni/flannel/tailscale bridge IPs (e.g. 172.x.0.1, 10.42.x.x, 100.64.x.x).
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    if [[ -z "$ip" ]]; then
        ip=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    if [[ -z "$ip" ]]; then
        # Fallback: skip known virtual interfaces, pick first remaining
        ip=$(ip -4 -o addr show 2>/dev/null \
            | awk '$2 !~ /^(lo|docker|br-|cni|flannel|veth|tailscale|ztpp|kube|virbr)/ {print $2, $4}' \
            | grep -v '127\.0\.0\.1' \
            | head -1 | awk '{print $2}' | cut -d'/' -f1)
    fi
    echo "$ip"
}

validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# ---- Consensus Helper ----
ask_consensus() {
    if [[ -n "$(load_config_var CONSENSUS '')" ]]; then
        log_info "Consensus already set: $(load_config_var CONSENSUS) (Fabric $(load_config_var FABRIC_VERSION))"
        return 0
    fi
    local choice
    choice=$(ask_choice "Which consensus mechanism do you want to use?" \
        "Raft (Fabric 2.5.4 - Recommended, stable)" \
        "BFT / SmartBFT (Fabric 3.x - Newer, Byzantine fault tolerant)")
    if [[ "$choice" == "0" ]]; then
        save_config_var "CONSENSUS" "raft"
        save_config_var "FABRIC_VERSION" "2.5.4"
        log_info "Selected: Raft consensus with Fabric 2.5.4"
    else
        save_config_var "CONSENSUS" "bft"
        save_config_var "FABRIC_VERSION" "3.0.0"
        log_info "Selected: SmartBFT consensus with Fabric 3.0.0"
        log_info "Note: Requires minimum 4 orderers (BFT: n >= 3f+1, f=1)."
        log_info "Ensure your Bevel fork is on branch feature/fabric-v3-bft."
    fi
}

# ---- Role Selection ----
ask_role() {
    local existing
    existing=$(load_config_var "ROLE" "")
    if [[ -n "$existing" ]]; then
        echo "$existing"
        return 0
    fi
    local choice
    choice=$(ask_choice "What role is this PC?" \
        "Orderer Org (PC1) - Runs CA, Orderer1, Orderer2, Orderer3, HAProxy" \
        "Peer Org1 (PC2) - Runs CA, Peer0, CouchDB, HAProxy" \
        "Peer Org2 (PC3) - Runs CA, Peer0, CouchDB, HAProxy")
    case "$choice" in
        0) save_config_var "ROLE" "orderer"; echo "orderer" ;;
        1) save_config_var "ROLE" "org1";    echo "org1" ;;
        2) save_config_var "ROLE" "org2";    echo "org2" ;;
    esac
}

# ---- Collect IP Addresses ----
collect_ips() {
    if [[ -n "$(load_config_var THIS_PC_IP '')" ]] && \
       [[ -n "$(load_config_var PC1_IP '')" ]] && \
       [[ -n "$(load_config_var PC2_IP '')" ]] && \
       [[ -n "$(load_config_var PC3_IP '')" ]]; then
        log_info "IPs already configured — skipping prompts."
        return 0
    fi
    local detected_ip
    detected_ip=$(get_local_ip)
    log_info "Detected local IP: ${detected_ip}"

    local this_ip
    this_ip=$(ask_input "IP address of THIS PC" "$detected_ip")
    if ! validate_ip "$this_ip"; then
        log_error "Invalid IP: ${this_ip}"
        exit 1
    fi
    save_config_var "THIS_PC_IP" "$this_ip"

    local pc1_ip pc2_ip pc3_ip
    local role
    role=$(load_config_var "ROLE")

    echo -e "\n${BOLD}Enter IP addresses of all 3 PCs:${NC}"

    case "$role" in
        orderer)
            save_config_var "PC1_IP" "$this_ip"
            pc2_ip=$(ask_input "IP of PC2 (Org1 - Peer)")
            validate_ip "$pc2_ip" || { log_error "Invalid IP"; exit 1; }
            save_config_var "PC2_IP" "$pc2_ip"
            pc3_ip=$(ask_input "IP of PC3 (Org2 - Peer)")
            validate_ip "$pc3_ip" || { log_error "Invalid IP"; exit 1; }
            save_config_var "PC3_IP" "$pc3_ip"
            ;;
        org1)
            pc1_ip=$(ask_input "IP of PC1 (Orderer Org)")
            validate_ip "$pc1_ip" || { log_error "Invalid IP"; exit 1; }
            save_config_var "PC1_IP" "$pc1_ip"
            save_config_var "PC2_IP" "$this_ip"
            pc3_ip=$(ask_input "IP of PC3 (Org2 - Peer)")
            validate_ip "$pc3_ip" || { log_error "Invalid IP"; exit 1; }
            save_config_var "PC3_IP" "$pc3_ip"
            ;;
        org2)
            pc1_ip=$(ask_input "IP of PC1 (Orderer Org)")
            validate_ip "$pc1_ip" || { log_error "Invalid IP"; exit 1; }
            save_config_var "PC1_IP" "$pc1_ip"
            pc2_ip=$(ask_input "IP of PC2 (Org1 - Peer)")
            validate_ip "$pc2_ip" || { log_error "Invalid IP"; exit 1; }
            save_config_var "PC2_IP" "$pc2_ip"
            save_config_var "PC3_IP" "$this_ip"
            ;;
    esac

    log_success "IP addresses configured:"
    log_info "  PC1 (Orderer): $(load_config_var PC1_IP)"
    log_info "  PC2 (Org1):    $(load_config_var PC2_IP)"
    log_info "  PC3 (Org2):    $(load_config_var PC3_IP)"
}

# =============================================================================
# STALE RESOURCE GUARD
# Detects IP/domain changes between deployments and clears stale Vault data
# and K8s jobs so every fresh deploy starts clean regardless of IP/domain.
# These functions are called from BOTH cleanup.sh (--clear) and bevel-deploy.sh
# (pre-Ansible) to ensure stale resources are removed as early as possible.
# =============================================================================

# ---------------------------------------------------------------------------
# _clear_org_vault: Wipe all known cert paths from an org's Vault.
# Handles ordererorg (orderer cert paths) and peer orgs (peer/user paths).
# ---------------------------------------------------------------------------
_clear_org_vault() {
    local org_name="$1" vault_url="$2" vault_token="$3"
    local root_path="secretsv2/dev${org_name}/"

    [[ -z "$vault_url" ]] || [[ -z "$vault_token" ]] && return 0
    if ! VAULT_ADDR="$vault_url" VAULT_TOKEN="$vault_token" vault status &>/dev/null; then
        log_info "  Vault at ${vault_url} not reachable — skipping Vault clear for ${org_name}."
        return 0
    fi

    log_info "  Clearing Vault data for ${org_name} at ${vault_url} (path: ${root_path})..."

    # Recursively list and delete every key under the org's root path.
    # This handles any path Bevel writes without needing a hardcoded list.
    _vault_delete_recursive() {
        local v_url="$1" v_token="$2" path="$3"
        local entries
        entries=$(VAULT_ADDR="$v_url" VAULT_TOKEN="$v_token" \
            vault kv list -format=json "$path" 2>/dev/null \
            | jq -r '.[]' 2>/dev/null || true)
        [[ -z "$entries" ]] && return 0
        while IFS= read -r entry; do
            if [[ "$entry" == */ ]]; then
                _vault_delete_recursive "$v_url" "$v_token" "${path}${entry}"
            else
                VAULT_ADDR="$v_url" VAULT_TOKEN="$v_token" \
                    vault kv metadata delete "${path}${entry}" 2>/dev/null || true
            fi
        done <<< "$entries"
    }

    _vault_delete_recursive "$vault_url" "$vault_token" "$root_path"
    log_success "  Vault cleared for ${org_name}."
}

# ---------------------------------------------------------------------------
# _track_pc_ip_changes:
# Persist all three PC IPs after each deployment. On the next run (--clear
# or deploy), compare saved vs current IPs. If any changed, automatically
# clear stale Vault data for that PC's org so bevel-vault-mgmt re-configures
# K8s auth against the new cluster and old certs don't block the new deploy.
# ---------------------------------------------------------------------------
_track_pc_ip_changes() {
    local state_file="${HOME}/.bevel-setup/state/last_ips.state"
    local pc1_ip pc2_ip pc3_ip
    pc1_ip=$(load_config_var "PC1_IP")
    pc2_ip=$(load_config_var "PC2_IP")
    pc3_ip=$(load_config_var "PC3_IP")

    if [[ -f "$state_file" ]]; then
        local saved_pc1 saved_pc2 saved_pc3
        saved_pc1=$(grep "^PC1_IP=" "$state_file" 2>/dev/null | cut -d= -f2)
        saved_pc2=$(grep "^PC2_IP=" "$state_file" 2>/dev/null | cut -d= -f2)
        saved_pc3=$(grep "^PC3_IP=" "$state_file" 2>/dev/null | cut -d= -f2)

        if [[ -n "$saved_pc1" ]] && [[ "$saved_pc1" != "$pc1_ip" ]]; then
            log_warning "PC1 (Orderer) IP changed: ${saved_pc1} → ${pc1_ip}"
            log_info "  Clearing stale orderer Vault data..."
            _clear_org_vault "ordererorg" \
                "$(load_config_var VAULT_URL_ORDERER)" "$(load_config_var VAULT_TOKEN_ORDERER)"
        fi
        if [[ -n "$saved_pc2" ]] && [[ "$saved_pc2" != "$pc2_ip" ]]; then
            log_warning "PC2 (Org1) IP changed: ${saved_pc2} → ${pc2_ip}"
            log_info "  Clearing stale org1 Vault data..."
            _clear_org_vault "org1" \
                "$(load_config_var VAULT_URL_ORG1)" "$(load_config_var VAULT_TOKEN_ORG1)"
        fi
        if [[ -n "$saved_pc3" ]] && [[ "$saved_pc3" != "$pc3_ip" ]]; then
            log_warning "PC3 (Org2) IP changed: ${saved_pc3} → ${pc3_ip}"
            log_info "  Clearing stale org2 Vault data..."
            _clear_org_vault "org2" \
                "$(load_config_var VAULT_URL_ORG2)" "$(load_config_var VAULT_TOKEN_ORG2)"
        fi
    fi

    # Persist current IPs as the new baseline
    mkdir -p "$(dirname "$state_file")"
    {
        echo "PC1_IP=${pc1_ip}"
        echo "PC2_IP=${pc2_ip}"
        echo "PC3_IP=${pc3_ip}"
    } > "$state_file"
}

# ---------------------------------------------------------------------------
# _detect_and_fix_stale_vault_resources:
# Before deployment (or during --clear), check each cluster's bevel-vault-mgmt
# Job for a stale Vault URL left over from a previous deploy with a different IP.
# If stale: delete the Job so Flux recreates it with the current URL, and clear
# the org Vault so bevel-vault-mgmt re-configures K8s auth from scratch.
# ---------------------------------------------------------------------------
_detect_and_fix_stale_vault_resources() {
    log_info "Checking for stale bevel-vault-mgmt resources (IP change guard)..."

    local -A cluster_vault_ns=(
        ["KUBECONFIG_ORDERER"]="VAULT_URL_ORDERER VAULT_TOKEN_ORDERER ordererorg ordererorg-net"
        ["KUBECONFIG_ORG1"]="VAULT_URL_ORG1 VAULT_TOKEN_ORG1 org1 org1-net"
        ["KUBECONFIG_ORG2"]="VAULT_URL_ORG2 VAULT_TOKEN_ORG2 org2 org2-net"
    )

    for kc_var in "${!cluster_vault_ns[@]}"; do
        local kubeconfig
        kubeconfig=$(load_config_var "$kc_var")
        [[ -z "$kubeconfig" ]] || [[ ! -f "$kubeconfig" ]] && continue
        kubectl --kubeconfig "$kubeconfig" cluster-info &>/dev/null || continue

        local meta="${cluster_vault_ns[$kc_var]}"
        local vault_url_var vault_token_var org_name namespace
        read -r vault_url_var vault_token_var org_name namespace <<< "$meta"

        local expected_vault_url
        expected_vault_url=$(load_config_var "$vault_url_var")

        # Get VAULT_ADDR baked into the existing bevel-vault-mgmt Job spec
        local job_vault_addr
        job_vault_addr=$(kubectl --kubeconfig "$kubeconfig" get job bevel-vault-mgmt \
            -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].env}' \
            2>/dev/null | python3 -c "
import sys, json
try:
    for e in json.load(sys.stdin):
        if e['name'] == 'VAULT_ADDR':
            print(e.get('value',''))
            break
except: pass
" 2>/dev/null)

        [[ -z "$job_vault_addr" ]] && continue  # Job not deployed yet — nothing to fix

        if [[ "$job_vault_addr" == "$expected_vault_url" ]]; then
            log_info "  ${namespace}: bevel-vault-mgmt URL OK (${job_vault_addr})"
            continue
        fi

        log_warning "  ${namespace}: STALE bevel-vault-mgmt detected!"
        log_warning "    Deployed : ${job_vault_addr}"
        log_warning "    Expected : ${expected_vault_url}"
        log_info "  Deleting stale job and clearing Vault so Flux recreates clean..."

        kubectl --kubeconfig "$kubeconfig" delete job bevel-vault-mgmt \
            -n "$namespace" --ignore-not-found 2>/dev/null && \
            log_success "  Deleted stale bevel-vault-mgmt in ${namespace}."

        # Clear org Vault so next bevel-vault-mgmt gets a clean slate
        _clear_org_vault "$org_name" \
            "$(load_config_var "$vault_url_var")" "$(load_config_var "$vault_token_var")"

        # Trigger HR reconcile so the fresh bevel-vault-mgmt runs immediately
        flux --kubeconfig "$kubeconfig" reconcile hr ca \
            -n "$namespace" --timeout=90s 2>/dev/null || true
    done

    log_info "Stale resource check complete."
}
