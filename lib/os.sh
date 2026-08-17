#!/usr/bin/env bash
# lib/os.sh — OS detection and package manager abstraction
# Sourced by mb and modules. Do not execute directly.

# ── OS detection ─────────────────────────────────────────────────────────────

mb_detect_os() {
    # Detect OS family and version. Sets global variables:
    #   MB_OS_FAMILY  — debian | alpine | rhel | unknown
    #   MB_OS_DISTRO  — ubuntu | debian | alpine | centos | rocky | unknown
    #   MB_OS_VERSION — major version number (e.g., 22, 12, 3)
    #   MB_PKG_MGR    — apt | apk | dnf | yum | unknown

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    else
        MB_OS_FAMILY="unknown"
        MB_OS_DISTRO="unknown"
        MB_OS_VERSION="0"
        MB_PKG_MGR="unknown"
        return 1
    fi

    MB_OS_DISTRO="${ID:-unknown}"
    MB_OS_VERSION="${VERSION_ID:-0}"
    # Extract major version
    MB_OS_VERSION="${MB_OS_VERSION%%.*}"

    case "$MB_OS_DISTRO" in
        ubuntu|debian)
            MB_OS_FAMILY="debian"
            MB_PKG_MGR="apt"
            ;;
        alpine)
            MB_OS_FAMILY="alpine"
            MB_PKG_MGR="apk"
            ;;
        centos|rocky|almalinux|fedora|rhel)
            MB_OS_FAMILY="rhel"
            if [ "$MB_OS_DISTRO" = "fedora" ] || [ "$MB_OS_VERSION" -ge 8 ] 2>/dev/null; then
                MB_PKG_MGR="dnf"
            else
                MB_PKG_MGR="yum"
            fi
            ;;
        *)
            MB_OS_FAMILY="unknown"
            MB_PKG_MGR="unknown"
            ;;
    esac

    mb_info "OS: ${MB_OS_DISTRO} ${MB_OS_VERSION} (${MB_OS_FAMILY}, ${MB_PKG_MGR})"
}

mb_require_os() {
    # Require a specific OS family. Dies if not matched.
    local required="$1"
    if [ "${MB_OS_FAMILY:-}" != "$required" ]; then
        mb_die "This module requires ${required}, but detected ${MB_OS_FAMILY:-unknown}."
    fi
}

mb_supports_os() {
    # Check if current OS is supported (debian or alpine for MVP)
    case "${MB_OS_FAMILY:-}" in
        debian) return 0 ;;
        alpine) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Package manager abstraction ──────────────────────────────────────────────

mb_pkg_update() {
    case "$MB_PKG_MGR" in
        apt) apt-get update -qq ;;
        apk) apk update --quiet ;;
        dnf) dnf check-update -q ;;
        yum) yum check-update -q ;;
        *) mb_die "Unknown package manager: $MB_PKG_MGR" ;;
    esac
}

mb_pkg_upgrade() {
    case "$MB_PKG_MGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq ;;
        apk) apk upgrade --quiet ;;
        dnf) dnf upgrade -y -q ;;
        yum) yum update -y -q ;;
        *) mb_die "Unknown package manager: $MB_PKG_MGR" ;;
    esac
}

mb_pkg_install() {
    # Install one or more packages (idempotent)
    local pkgs=("$@")
    case "$MB_PKG_MGR" in
        apt)
            # Filter out already-installed packages
            local to_install=()
            for pkg in "${pkgs[@]}"; do
                if ! dpkg -s "$pkg" >/dev/null 2>&1; then
                    to_install+=("$pkg")
                fi
            done
            if [ ${#to_install[@]} -gt 0 ]; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}"
                mb_detail "Installed: ${to_install[*]}"
            else
                mb_detail "Already installed: ${pkgs[*]}"
            fi
            ;;
        apk)
            for pkg in "${pkgs[@]}"; do
                if ! apk info -e "$pkg" >/dev/null 2>&1; then
                    apk add --quiet "$pkg"
                fi
            done
            ;;
        dnf) dnf install -y -q "${pkgs[@]}" ;;
        yum) yum install -y -q "${pkgs[@]}" ;;
        *) mb_die "Unknown package manager: $MB_PKG_MGR" ;;
    esac
}

mb_pkg_remove() {
    local pkgs=("$@")
    case "$MB_PKG_MGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "${pkgs[@]}" ;;
        apk) apk del --quiet "${pkgs[@]}" ;;
        dnf) dnf remove -y -q "${pkgs[@]}" ;;
        yum) yum remove -y -q "${pkgs[@]}" ;;
        *) mb_die "Unknown package manager: $MB_PKG_MGR" ;;
    esac
}

# ── Service management abstraction ───────────────────────────────────────────

mb_service_restart() {
    local svc="$1"
    if mb_check_command systemctl; then
        systemctl restart "$svc"
    elif mb_check_command rc-service; then
        rc-service "$svc" restart
    else
        mb_warn "No service manager found (systemd/openrc). Cannot restart $svc."
        return 1
    fi
}

mb_service_enable() {
    local svc="$1"
    if mb_check_command systemctl; then
        systemctl enable "$svc"
    elif mb_check_command rc-update; then
        rc-update add "$svc" default
    fi
}

mb_service_status() {
    local svc="$1"
    if mb_check_command systemctl; then
        systemctl is-active "$svc" 2>/dev/null
    elif mb_check_command rc-service; then
        rc-service "$svc" status 2>/dev/null && echo "active" || echo "inactive"
    fi
}
