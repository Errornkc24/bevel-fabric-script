#!/usr/bin/env bash
# =============================================================================
# prerequisites.sh - Install all required tools
# =============================================================================

# Source common if not already loaded
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

# ---- Docker Installation ----
install_docker() {
    if is_installed docker; then
        local ver
        ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
        log_success "Docker already installed: ${ver}"
        return 0
    fi

    log_step "Installing Docker..."

    # Remove old versions
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release

    # Add Docker GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true

    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Add user to docker group
    sudo usermod -aG docker "$USER"

    log_success "Docker installed: $(docker --version)"
    log_warning "You may need to log out and back in for docker group to take effect."
    log_warning "Or run: newgrp docker"
}

# ---- K3s Installation ----
install_k3s() {
    if is_installed kubectl && sudo systemctl is-active --quiet k3s 2>/dev/null; then
        log_success "K3s already installed and running."
        return 0
    fi

    local this_ip
    this_ip=$(load_config_var "THIS_PC_IP")
    if [[ -z "$this_ip" ]]; then
        this_ip=$(get_local_ip)
    fi

    log_step "Installing K3s (Kubernetes) with TLS SAN=${this_ip}..."
    log_info "Disabling Traefik (will use HAProxy instead)."

    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--tls-san ${this_ip} --write-kubeconfig-mode 644 --disable traefik" sh -

    # Wait for K3s to be ready
    log_info "Waiting for K3s to be ready..."
    local attempts=0
    while (( attempts < 30 )); do
        if kubectl get nodes &>/dev/null; then
            break
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    if kubectl get nodes &>/dev/null; then
        log_success "K3s installed and running."
        kubectl get nodes
    else
        log_error "K3s did not start within 60 seconds."
        return 1
    fi
}

# ---- Helm Installation ----
install_helm() {
    if is_installed helm; then
        local ver
        ver=$(helm version --short 2>/dev/null)
        log_success "Helm already installed: ${ver}"
        return 0
    fi

    log_step "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_success "Helm installed: $(helm version --short)"
}

# ---- kubectl Installation ----
install_kubectl() {
    if is_installed kubectl; then
        local ver
        ver=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1 || true)
        log_success "kubectl already installed: ${ver}"
        return 0
    fi

    log_step "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    log_success "kubectl installed: $(kubectl version --client --short 2>/dev/null || echo 'v1.28.0')"
}

# ---- jq Installation ----
install_jq() {
    if is_installed jq; then
        log_success "jq already installed."
        return 0
    fi
    log_step "Installing jq..."
    sudo apt-get install -y jq
    log_success "jq installed."
}

# ---- yq Installation ----
install_yq() {
    if is_installed yq; then
        log_success "yq already installed."
        return 0
    fi
    log_step "Installing yq..."
    sudo wget -q https://github.com/mikefarah/yq/releases/download/v4.35.1/yq_linux_amd64 -O /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
    log_success "yq installed."
}

# ---- Git Installation ----
install_git() {
    if is_installed git; then
        log_success "Git already installed: $(git --version)"
        return 0
    fi
    log_step "Installing Git..."
    sudo apt-get install -y git
    log_success "Git installed: $(git --version)"
}

# ---- Python & Ansible Installation ----
install_ansible() {
    local venv_dir="${HOME}/bevel-venv"

    if [[ -d "$venv_dir" ]] && [[ -f "${venv_dir}/bin/ansible" ]]; then
        log_success "Ansible venv already exists at ${venv_dir}"
        return 0
    fi

    log_step "Installing Python3, pip, and Ansible..."

    sudo apt-get update
    # python3-kubernetes is required by Bevel ansible community.kubernetes.k8s_info etc.
    # Bevel inventory has no ansible_python_interpreter override → modules run on system Python,
    # not the venv. Installing both keeps both interpreters working.
    sudo apt-get install -y python3 python3-pip python3-venv locales python3-kubernetes python3-jmespath

    # Ensure UTF-8 locale is available (Ansible requires it)
    sudo locale-gen en_US.UTF-8 2>/dev/null || true
    sudo update-locale LANG=en_US.UTF-8 2>/dev/null || true

    log_info "Creating Python virtual environment at ${venv_dir}..."
    python3 -m venv "$venv_dir"

    # shellcheck disable=SC1091
    source "${venv_dir}/bin/activate"

    pip install --upgrade pip
    pip install ansible-core==2.16.3
    pip install openshift kubernetes jmespath

    # Install required Ansible collections (Bevel uses npm, k8s, helm modules etc.)
    log_info "Installing Ansible collections..."
    ansible-galaxy collection install community.general kubernetes.core --force

    # Install Bevel-specific collection requirements if available
    local bevel_dir
    bevel_dir=$(load_config_var "BEVEL_DIR" "${HOME}/bevel")
    if [[ -f "${bevel_dir}/platforms/shared/configuration/requirements.yaml" ]]; then
        log_info "Installing Bevel Ansible collection requirements..."
        ansible-galaxy install -r "${bevel_dir}/platforms/shared/configuration/requirements.yaml"
    fi

    log_success "Ansible installed: $(ansible --version | head -1)"
    log_info "Virtual environment: ${venv_dir}"
    log_info "Activate with: source ${venv_dir}/bin/activate"

    save_config_var "ANSIBLE_VENV" "$venv_dir"
}

# ---- Vault Binary Installation ----
install_vault_binary() {
    if is_installed vault; then
        local ver
        ver=$(vault --version 2>/dev/null)
        log_success "Vault already installed: ${ver}"
        return 0
    fi

    log_step "Installing HashiCorp Vault binary..."
    sudo apt-get install -y unzip

    local vault_version="1.15.2"
    wget -q "https://releases.hashicorp.com/vault/${vault_version}/vault_${vault_version}_linux_amd64.zip" -O /tmp/vault.zip
    unzip -o /tmp/vault.zip -d /tmp/
    sudo mv /tmp/vault /usr/local/bin/
    rm -f /tmp/vault.zip

    log_success "Vault installed: $(vault --version)"
}

# ---- netcat Installation (for connectivity checks) ----
install_netcat() {
    if is_installed nc || is_installed ncat; then
        log_success "netcat already available."
        return 0
    fi
    log_step "Installing netcat..."
    sudo apt-get install -y netcat-openbsd
    log_success "netcat installed."
}

# ---- Run All Prerequisites for a Node ----
install_all_node_prerequisites() {
    log_header "PHASE 1: Installing Prerequisites"

    check_os
    check_resources

    sudo apt-get update -y >> "$BEVEL_LOG_FILE" 2>&1 || log_warning "apt-get update had warnings (non-fatal, continuing)"

    local steps=(
        "install_docker"
        "install_k3s"
        "install_helm"
        "install_kubectl"
        "install_git"
        "install_jq"
        "install_yq"
        "install_netcat"
        "install_vault_binary"
    )

    for step in "${steps[@]}"; do
        if ! "$step"; then
            if ! handle_error "$step failed" "$LINENO"; then
                # retry
                "$step" || log_warning "Skipping $step after retry failure."
            fi
        fi
    done

    log_success "All node prerequisites installed."
}

# ---- Run Controller-Only Prerequisites ----
install_controller_prerequisites() {
    log_header "Installing Controller Prerequisites (Helm, kubectl, Ansible)"

    install_helm
    install_kubectl
    install_ansible
    install_jq
    install_yq

    log_success "Controller prerequisites installed."
}

# ---- Show Installed Versions ----
show_installed_versions() {
    log_step "Installed Tool Versions:"
    echo -e "  Docker:  $(docker --version 2>/dev/null || echo 'Not installed')"
    echo -e "  K3s:     $(k3s --version 2>/dev/null || echo 'Not installed')"
    echo -e "  kubectl: $(kubectl version --client --short 2>/dev/null || echo 'Not installed')"
    echo -e "  Helm:    $(helm version --short 2>/dev/null || echo 'Not installed')"
    echo -e "  Vault:   $(vault --version 2>/dev/null || echo 'Not installed')"
    echo -e "  Git:     $(git --version 2>/dev/null || echo 'Not installed')"
    echo -e "  jq:      $(jq --version 2>/dev/null || echo 'Not installed')"
    echo -e "  yq:      $(yq --version 2>/dev/null || echo 'Not installed')"
    echo -e "  Python:  $(python3 --version 2>/dev/null || echo 'Not installed')"

    local venv="${HOME}/bevel-venv"
    if [[ -f "${venv}/bin/ansible" ]]; then
        echo -e "  Ansible: $(${venv}/bin/ansible --version 2>/dev/null | head -1)"
    else
        echo -e "  Ansible: Not installed"
    fi
}
