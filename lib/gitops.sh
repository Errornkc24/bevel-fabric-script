#!/usr/bin/env bash
# =============================================================================
# gitops.sh - Git repository setup, SSH keys, and GitHub configuration
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

setup_gitops() {
    log_header "PHASE 6: Git Repository & GitOps Setup"

    collect_git_info
    setup_ssh_key
    clone_bevel_repo

    log_success "GitOps setup complete."
}

collect_git_info() {
    log_step "Collecting Git/GitHub information..."

    local git_protocol
    git_protocol=$(ask_choice "Git protocol for Flux?" \
        "HTTPS (Recommended - easier setup)" \
        "SSH (Requires deploy key)")
    if [[ "$git_protocol" == "0" ]]; then
        save_config_var "GIT_PROTOCOL" "https"
    else
        save_config_var "GIT_PROTOCOL" "ssh"
    fi

    local github_username
    github_username=$(ask_input "Your GitHub username")
    save_config_var "GIT_USERNAME" "$github_username"

    local github_email
    github_email=$(ask_input "Your Git email")
    save_config_var "GIT_EMAIL" "$github_email"

    local repo_name
    repo_name=$(ask_input "Your forked Bevel repo name" "bevel")
    save_config_var "GIT_REPO_NAME" "$repo_name"

    local git_url="https://github.com/${github_username}/${repo_name}.git"
    local git_repo="github.com/${github_username}/${repo_name}.git"
    save_config_var "GIT_URL" "$git_url"
    save_config_var "GIT_REPO" "$git_repo"

    local git_branch
    git_branch=$(ask_input "Git branch to use" "main")
    save_config_var "GIT_BRANCH" "$git_branch"

    log_info "GitHub Personal Access Token is needed for Flux to push/pull."
    log_info "Create one at: GitHub -> Settings -> Developer settings -> Personal access tokens"
    log_info "Required scopes: repo (full control)"
    local git_token
    git_token=$(ask_secret "GitHub Personal Access Token (PAT)")
    save_config_var "GIT_TOKEN" "$git_token"

    # Docker registry credentials (for pulling Fabric images)
    log_separator
    log_info "Docker registry credentials (for pulling Hyperledger Fabric images)"
    log_info "If using ghcr.io/hyperledger (public), your GitHub username/PAT works."
    local docker_username
    docker_username=$(ask_input "Docker registry username" "$github_username")
    save_config_var "DOCKER_USERNAME" "$docker_username"
    local docker_password
    docker_password=$(ask_secret "Docker registry token/password")
    save_config_var "DOCKER_PASSWORD" "$docker_password"

    log_success "Git info collected."
}

setup_ssh_key() {
    log_step "Setting up SSH key for GitOps..."

    local ssh_key_path="${HOME}/.ssh/gitops"

    if [[ -f "$ssh_key_path" ]]; then
        log_info "SSH key already exists at ${ssh_key_path}"
        if ask_confirm "Use existing key?" "y"; then
            save_config_var "SSH_PRIVATE_KEY" "$ssh_key_path"
            return 0
        fi
    fi

    log_info "Generating new SSH key pair..."
    mkdir -p "${HOME}/.ssh"
    ssh-keygen -q -N "" -f "$ssh_key_path" -t ed25519

    save_config_var "SSH_PRIVATE_KEY" "$ssh_key_path"

    echo -e "\n${YELLOW}${BOLD}ACTION REQUIRED:${NC}"
    echo -e "Add this public key as a deploy key to your GitHub repo:"
    echo -e "  1. Go to: https://github.com/$(load_config_var GIT_USERNAME)/$(load_config_var GIT_REPO_NAME)/settings/keys"
    echo -e "  2. Click 'Add deploy key'"
    echo -e "  3. Title: 'Bevel GitOps'"
    echo -e "  4. Paste this key:"
    echo ""
    echo -e "${CYAN}"
    cat "${ssh_key_path}.pub"
    echo -e "${NC}"
    echo -e "  5. Check 'Allow write access'"
    echo -e "  6. Click 'Add key'"
    echo ""

    read -rp "$(echo -e "${YELLOW}Press Enter after adding the deploy key to GitHub...${NC}")"
    log_success "SSH key configured."
}

clone_bevel_repo() {
    log_step "Cloning Bevel repository..."

    local bevel_dir="${HOME}/bevel"
    local git_url
    git_url=$(load_config_var "GIT_URL")
    local git_branch
    git_branch=$(load_config_var "GIT_BRANCH")

    if [[ -d "$bevel_dir/.git" ]]; then
        log_info "Bevel repo already cloned at ${bevel_dir}"
        if ask_confirm "Pull latest changes?"; then
            cd "$bevel_dir"
            git pull origin "$git_branch" || log_warning "Git pull failed - continuing with existing."
            cd -
        fi
    else
        log_info "Cloning ${git_url} (branch: ${git_branch})..."
        local git_username git_token
        git_username=$(load_config_var "GIT_USERNAME")
        git_token=$(load_config_var "GIT_TOKEN")

        # Clone with embedded credentials for HTTPS
        local clone_url
        clone_url="https://${git_username}:${git_token}@github.com/${git_username}/$(load_config_var GIT_REPO_NAME).git"
        git clone -b "$git_branch" "$clone_url" "$bevel_dir"

        # Remove credentials from remote URL after clone
        cd "$bevel_dir"
        git remote set-url origin "$git_url"
        cd -
    fi

    save_config_var "BEVEL_DIR" "$bevel_dir"
    log_success "Bevel repository ready at ${bevel_dir}"
}
