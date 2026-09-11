#!/usr/bin/env bash
# modules/system.sh — System update and base tools installation

mb_module_system() {
    mb_step "System update and base tools"

    # Check disk space before upgrading
    local avail_mb
    avail_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$avail_mb" -lt 1024 ]; then
        mb_warn "Low disk space: ${avail_mb}MB available. Upgrade may fail."
        if ! mb_ask "Continue anyway?" "n"; then
            return 1
        fi
    fi

    # Backup package-source config (debian: sources.list, rhel: repo files)
    if [ "$MB_OS_FAMILY" = "debian" ]; then
        mb_backup_file /etc/apt/sources.list system
    elif [ "$MB_OS_FAMILY" = "rhel" ]; then
        mb_backup_dir /etc/yum.repos.d system
    fi

    # Update package lists
    mb_info "Updating package lists..."
    mb_pkg_update

    # Upgrade existing packages
    mb_info "Upgrading installed packages..."
    mb_pkg_upgrade

    # Install base tools (family-aware: gnupg/lsb-release are Debian names,
    # RHEL uses gnupg2 and has no lsb-release; htop comes from EPEL on the
    # RHEL family). RHEL minimal images ship curl-minimal, which conflicts
    # with the full curl package, so curl is family-specific below.
    local base_tools=(
        wget git vim tmux
        ca-certificates
        unzip jq chrony
    )

    # Add OS-specific tools
    case "$MB_OS_FAMILY" in
        debian) base_tools+=(curl sudo ufw htop gnupg lsb-release software-properties-common) ;;
        alpine) base_tools+=(curl sudo htop) ;;
        rhel)
            base_tools+=(curl-minimal sudo gnupg2 policycoreutils-python-utils)
            # htop lives in EPEL; the clones ship epel-release in their
            # extras repo (plain RHEL needs a subscribed repo instead, so
            # htop is skipped there). Refresh metadata after enabling so
            # the batch install below can resolve EPEL packages.
            if [ "$MB_OS_DISTRO" != "rhel" ] && dnf install -y -q epel-release >/dev/null 2>&1; then
                base_tools+=(htop)
                dnf -q makecache >/dev/null 2>&1 || true
            fi
            ;;
    esac

    mb_info "Installing base tools..."
    mb_pkg_install "${base_tools[@]}"

    # Set timezone
    local timezone="${MB_CONFIG_TIMEZONE:-}"
    if [ -z "$timezone" ]; then
        timezone=$(mb_ask_value "Enter timezone" "UTC")
    fi
    if [ "$MB_OS_FAMILY" = "debian" ] || [ "$MB_OS_FAMILY" = "rhel" ]; then
        # timedatectl needs a running systemd bus - its binary can exist
        # (e.g. in containers) without the bus being up.
        if [ -d /run/systemd/system ] && mb_check_command timedatectl; then
            timedatectl set-timezone "$timezone"
        else
            ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
            echo "$timezone" > /etc/timezone
        fi
    elif [ "$MB_OS_FAMILY" = "alpine" ]; then
        setup-timezone -z "$timezone" 2>/dev/null || ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
    fi
    mb_env_set MB_TIMEZONE "$timezone"
    mb_detail "Timezone set to: $timezone"

    # Set hostname
    local hostname="${MB_CONFIG_HOSTNAME:-}"
    if [ -z "$hostname" ]; then
        local current_host
        current_host=$(hostname 2>/dev/null || echo "")
        hostname=$(mb_ask_value "Enter hostname (leave empty to keep current)" "$current_host")
    fi
    if [ -n "$hostname" ] && [ "$hostname" != "$(hostname 2>/dev/null)" ]; then
        if mb_check_command hostnamectl; then
            hostnamectl set-hostname "$hostname"
        else
            echo "$hostname" > /etc/hostname
            hostname "$hostname"
        fi
        mb_env_set MB_HOSTNAME "$hostname"
        mb_detail "Hostname set to: $hostname"
    fi

    # Sync time
    if [ "$MB_OS_FAMILY" = "debian" ]; then
        mb_service_restart chrony 2>/dev/null || mb_service_restart systemd-timesyncd 2>/dev/null || true
    fi

    mb_mark_done system
    mb_success "System update complete"
}
