#!/usr/bin/env bash
# modules/docker.sh — Docker Engine + Docker Compose v2 installation

mb_module_docker() {
    mb_step "Docker installation"

    # Check if Docker is already installed
    if mb_check_command docker && docker --version >/dev/null 2>&1; then
        mb_detail "Docker already installed: $(docker --version)"
    else
        case "$MB_OS_FAMILY" in
            debian) _mb_docker_install_debian ;;
            alpine) _mb_docker_install_alpine ;;
            *) mb_die "Docker installation not supported for OS: $MB_OS_FAMILY" ;;
        esac
    fi

    # Configure Docker daemon
    _mb_docker_configure

    # Add non-root user to docker group
    _mb_docker_add_user

    # Verify
    _mb_docker_verify

    mb_mark_done docker
    mb_success "Docker is ready: $(docker --version)"
}

# ── Installation ─────────────────────────────────────────────────────────────

_mb_docker_install_debian() {
    mb_info "Installing Docker (Debian/Ubuntu)..."

    # Remove old Docker packages if present
    mb_pkg_remove docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list

    mb_pkg_update
    mb_pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    mb_detail "Docker installed from official repository"
}

_mb_docker_install_alpine() {
    mb_info "Installing Docker (Alpine)..."
    mb_pkg_install docker docker-cli docker-cli-compose

    mb_service_enable docker
    mb_service_restart docker

    mb_detail "Docker installed from Alpine community repo"
}

# ── Configuration ────────────────────────────────────────────────────────────

_mb_docker_configure() {
    mb_info "Configuring Docker daemon..."

    local daemon_json="/etc/docker/daemon.json"
    local data_dir="${MB_CONFIG_DOCKER_DATA_DIR:-}"
    local log_max_size="${MB_CONFIG_DOCKER_LOG_MAX_SIZE:-50m}"
    local log_max_file="${MB_CONFIG_DOCKER_LOG_MAX_FILE:-3}"

    mb_backup_file "$daemon_json" docker
    mkdir -p /etc/docker

    # Build daemon.json
    local json='{'
    json+='"log-driver": "json-file",'
    json+='"log-opts": {"max-size": "'"$log_max_size"'", "max-file": "'"$log_max_file"'"},'
    json+='"live-restore": true,'
    json+='"userland-proxy": false'

    if [ -n "$data_dir" ]; then
        json+=',"data-root": "'"$data_dir"'"'
        mb_detail "Docker data directory: $data_dir"
    fi

    json+='}'

    echo "$json" | jq . > "$daemon_json"

    # Restart Docker to apply
    mb_service_restart docker 2>/dev/null || true

    mb_detail "Docker daemon configured (log rotation: $log_max_size × $log_max_file)"
}

_mb_docker_add_user() {
    local username
    username=$(mb_env_get MB_USERNAME)
    if [ -n "$username" ]; then
        if id -nG "$username" | grep -qw docker; then
            mb_detail "User '$username' already in docker group"
        else
            usermod -aG docker "$username"
            mb_detail "Added '$username' to docker group (re-login required)"
        fi
    fi
}

_mb_docker_verify() {
    mb_info "Verifying Docker..."

    if ! docker info >/dev/null 2>&1; then
        mb_error "Docker daemon is not running!"
        return 1
    fi

    # Test with hello-world (only if no containers exist, to keep it idempotent)
    local container_count
    container_count=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
    if [ "$container_count" -eq 0 ]; then
        mb_detail "Running hello-world test..."
        if docker run --rm hello-world >/dev/null 2>&1; then
            mb_detail "Docker hello-world: OK"
        else
            mb_warn "Docker hello-world test failed (may be network issue)"
        fi
    fi

    # Check Compose
    if docker compose version >/dev/null 2>&1; then
        mb_detail "Docker Compose: $(docker compose version)"
    else
        mb_warn "Docker Compose not available"
    fi

    mb_env_set MB_DOCKER "installed"
}
