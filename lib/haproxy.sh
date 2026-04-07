#!/usr/bin/env bash
# =============================================================================
# haproxy.sh - Install HAProxy Ingress Controller
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -z "${NC:-}" ]] && source "${_LIB_DIR}/common.sh"

# Get the local kubeconfig path (K3s default or our exported one)
_get_local_kubeconfig() {
    local role
    role=$(load_config_var "ROLE")
    local kc
    kc=$(load_config_var "KUBECONFIG_${role^^}")
    if [[ -n "$kc" ]] && [[ -f "$kc" ]]; then
        echo "$kc"
    elif [[ -f "/etc/rancher/k3s/k3s.yaml" ]]; then
        echo "/etc/rancher/k3s/k3s.yaml"
    else
        echo "${HOME}/.kube/config"
    fi
}

install_haproxy_local() {
    log_header "PHASE 4: HAProxy Ingress Installation"

    local kubeconfig
    kubeconfig=$(_get_local_kubeconfig)
    log_info "Using kubeconfig: ${kubeconfig}"

    log_info "Adding HAProxy Helm repo..."
    helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts 2>/dev/null || true
    helm repo update

    # Check if already installed
    if kubectl --kubeconfig "$kubeconfig" get namespace ingress-controller &>/dev/null; then
        if kubectl --kubeconfig "$kubeconfig" get pods -n ingress-controller 2>/dev/null | grep -q "haproxy"; then
            log_success "HAProxy already installed on this cluster."
            return 0
        fi
    fi

    log_info "Installing HAProxy Ingress on local cluster..."
    kubectl --kubeconfig "$kubeconfig" create namespace ingress-controller 2>/dev/null || true

    # Detect K8s distro to choose service type
    # K3s: LoadBalancer (K3s servicelb binds to node IP, needed for port 443)
    # Minikube: NodePort (minikube tunnel or port-forward handles external access)
    local svc_type="LoadBalancer"
    if command -v minikube &>/dev/null && minikube status &>/dev/null; then
        svc_type="NodePort"
        log_info "Minikube detected - using NodePort service type."
    else
        log_info "K3s/bare-metal detected - using LoadBalancer service type."
    fi

    helm install haproxy haproxy-ingress/haproxy-ingress \
        --kubeconfig "$kubeconfig" \
        --namespace ingress-controller \
        --set controller.service.type="$svc_type" \
        --set-string controller.config.ssl-passthrough="true"

    # Wait for HAProxy to be ready
    log_info "Waiting for HAProxy pods to be ready..."
    kubectl --kubeconfig "$kubeconfig" wait --for=condition=ready pod \
        -l app.kubernetes.io/name=haproxy-ingress \
        -n ingress-controller --timeout=120s 2>/dev/null || true

    log_success "HAProxy Ingress installed on local cluster."
    kubectl --kubeconfig "$kubeconfig" get pods -n ingress-controller
}

install_haproxy_remote() {
    local kubeconfig="$1"
    local cluster_name="$2"

    log_step "Installing HAProxy Ingress on ${cluster_name}..."

    helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts 2>/dev/null || true
    helm repo update

    # Check if already installed
    if kubectl --kubeconfig "$kubeconfig" get pods -n ingress-controller 2>/dev/null | grep -q "haproxy"; then
        log_success "HAProxy already installed on ${cluster_name}."
        return 0
    fi

    kubectl --kubeconfig "$kubeconfig" create namespace ingress-controller 2>/dev/null || true

    # Use same service type detection as local install
    local svc_type="LoadBalancer"
    if command -v minikube &>/dev/null && minikube status &>/dev/null; then
        svc_type="NodePort"
    fi

    helm install haproxy haproxy-ingress/haproxy-ingress \
        --kubeconfig "$kubeconfig" \
        --namespace ingress-controller \
        --set controller.service.type="$svc_type" \
        --set-string controller.config.ssl-passthrough="true"

    log_info "Waiting for HAProxy pods on ${cluster_name}..."
    kubectl --kubeconfig "$kubeconfig" wait --for=condition=ready pod \
        -l app.kubernetes.io/name=haproxy-ingress \
        -n ingress-controller --timeout=120s 2>/dev/null || true

    log_success "HAProxy Ingress installed on ${cluster_name}."
    kubectl --kubeconfig "$kubeconfig" get pods -n ingress-controller
}

verify_haproxy_local() {
    log_step "Verifying HAProxy on local cluster..."
    local kubeconfig
    kubeconfig=$(_get_local_kubeconfig)
    local pods
    pods=$(kubectl --kubeconfig "$kubeconfig" get pods -n ingress-controller --no-headers 2>/dev/null)
    if echo "$pods" | grep -q "Running"; then
        log_success "HAProxy is running."
    else
        log_error "HAProxy pods not running."
        kubectl --kubeconfig "$kubeconfig" get pods -n ingress-controller
        return 1
    fi
}

verify_haproxy_remote() {
    local kubeconfig="$1"
    local cluster_name="$2"
    log_step "Verifying HAProxy on ${cluster_name}..."
    local pods
    pods=$(kubectl --kubeconfig "$kubeconfig" get pods -n ingress-controller --no-headers 2>/dev/null)
    if echo "$pods" | grep -q "Running"; then
        log_success "HAProxy running on ${cluster_name}."
    else
        log_warning "HAProxy not running on ${cluster_name}."
        return 1
    fi
}
