#!/usr/bin/env bash
# lib/alpine_support.sh — Alpine Linux compatibility layer
# Sourced by mb and modules. Do not execute directly.
#
# Provides Alpine-specific abstractions that complement lib/os.sh:
#   - Alpine Linux detection (/etc/alpine-release)
#   - apk package manager wrappers (mirrors lib/os.sh apt/yum patterns)
#   - OpenRC service management wrappers (mirrors systemctl patterns)
#   - Alpine-specific path handling (/etc/init.d/ vs /etc/systemd/system/)
#   - musl libc compatibility checks
#   - Compatibility checks for already-installed modules

# ── Alpine detection ──────────────────────────────────────────────────────────

# mb_alpine_is_alpine
# Returns 0 if running on Alpine Linux, 1 otherwise.
mb_alpine_is_alpine() {
    [ -f /etc/alpine-release ]
}

# mb_alpine_version
# Echoes the Alpine version string (e.g., "3.22.0"). Empty if not Alpine.
mb_alpine_version() {
    if mb_alpine_is_alpine; then
        cat /etc/alpine-release 2>/dev/null || echo ""
    fi
}

# mb_alpine_major_version
# Echoes the major Alpine version number (e.g., "3"). Empty if not Alpine.
mb_alpine_major_version() {
    if mb_alpine_is_alpine; then
        local ver
        ver=$(cat /etc/alpine-release 2>/dev/null || echo "0")
        echo "${ver%%.*}"
    fi
}

# ── apk package manager wrappers ──────────────────────────────────────────────

# mb_alpine_pkg_install <pkg...>
# Install one or more packages via apk (idempotent).
mb_alpine_pkg_install() {
    local pkgs=("$@")
    for pkg in "${pkgs[@]}"; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            apk add --quiet "$pkg"
            mb_detail "Installed: $pkg"
        else
            mb_detail "Already installed: $pkg"
        fi
    done
}

# mb_alpine_pkg_remove <pkg...>
# Remove one or more packages via apk.
mb_alpine_pkg_remove() {
    local pkgs=("$@")
    apk del --quiet "${pkgs[@]}"
}

# mb_alpine_pkg_update
# Update apk package index.
mb_alpine_pkg_update() {
    apk update --quiet
}

# mb_alpine_pkg_upgrade
# Upgrade all packages via apk.
mb_alpine_pkg_upgrade() {
    apk upgrade --quiet
}

# mb_alpine_pkg_search <query>
# Search for a package in apk repositories.
mb_alpine_pkg_search() {
    local query="$1"
    apk search "$query" 2>/dev/null
}

# ── OpenRC service management wrappers ────────────────────────────────────────

# mb_alpine_service_restart <svc>
# Restart a service via OpenRC.
mb_alpine_service_restart() {
    local svc="$1"
    if mb_check_command rc-service; then
        rc-service "$svc" restart
    else
        mb_warn "rc-service not found. Cannot restart $svc."
        return 1
    fi
}

# mb_alpine_service_enable <svc>
# Enable a service at default runlevel via OpenRC.
mb_alpine_service_enable() {
    local svc="$1"
    if mb_check_command rc-update; then
        rc-update add "$svc" default
    else
        mb_warn "rc-update not found. Cannot enable $svc."
        return 1
    fi
}

# mb_alpine_service_disable <svc>
# Disable a service from default runlevel via OpenRC.
mb_alpine_service_disable() {
    local svc="$1"
    if mb_check_command rc-update; then
        rc-update del "$svc" default 2>/dev/null || true
    fi
}

# mb_alpine_service_status <svc>
# Check if a service is running via OpenRC.
mb_alpine_service_status() {
    local svc="$1"
    if mb_check_command rc-service; then
        rc-service "$svc" status 2>/dev/null && echo "active" || echo "inactive"
    else
        echo "inactive"
    fi
}

# mb_alpine_service_list
# List all enabled services at default runlevel.
mb_alpine_service_list() {
    if mb_check_command rc-update; then
        rc-update show default 2>/dev/null
    fi
}

# ── Alpine-specific path handling ─────────────────────────────────────────────

# mb_alpine_initd_path <svc>
# Echoes the OpenRC init.d script path for a service.
mb_alpine_initd_path() {
    local svc="$1"
    echo "/etc/init.d/${svc}"
}

# mb_alpine_confd_path <svc>
# Echoes the OpenRC conf.d configuration path for a service.
mb_alpine_confd_path() {
    local svc="$1"
    echo "/etc/conf.d/${svc}"
}

# mb_alpine_service_exists <svc>
# Returns 0 if an OpenRC init script exists for the service.
mb_alpine_service_exists() {
    local svc="$1"
    [ -f "$(mb_alpine_initd_path "$svc")" ]
}

# mb_alpine_create_initd <svc> <content>
# Creates an OpenRC init.d script for a service if it doesn't exist.
mb_alpine_create_initd() {
    local svc="$1"
    local content="$2"
    local initd_path
    initd_path=$(mb_alpine_initd_path "$svc")

    if [ ! -f "$initd_path" ]; then
        mkdir -p /etc/init.d
        printf '%s\n' "$content" > "$initd_path"
        chmod +x "$initd_path"
        mb_detail "Created OpenRC init script: ${initd_path}"
    else
        mb_detail "OpenRC init script already exists: ${initd_path}"
    fi
}

# ── musl libc compatibility checks ────────────────────────────────────────────

# mb_alpine_is_musl
# Returns 0 if the system uses musl libc (typical for Alpine).
mb_alpine_is_musl() {
    # Check for musl-specific dynamic linker
    local musl_ld
    musl_ld=$(find /lib -maxdepth 1 -name 'ld-musl-*.so.1' 2>/dev/null | head -1 || echo "")
    if [ -n "$musl_ld" ]; then
        return 0
    fi
    # Check ldd output for musl
    if mb_check_command ldd; then
        ldd --version 2>&1 | grep -qi musl && return 0
    fi
    # Alpine always uses musl
    if mb_alpine_is_alpine; then
        return 0
    fi
    return 1
}

# mb_alpine_musl_compat_check <binary>
# Checks if a binary is compatible with musl libc.
# Returns 0 if compatible or statically linked, 1 if it requires glibc.
mb_alpine_musl_compat_check() {
    local binary="$1"

    if [ ! -f "$binary" ]; then
        mb_warn "Binary not found: ${binary}"
        return 1
    fi

    if ! mb_check_command ldd; then
        mb_warn "ldd not available; cannot check musl compatibility for ${binary}"
        return 0
    fi

    local ldd_output
    ldd_output=$(ldd "$binary" 2>/dev/null || echo "")

    # Statically linked binaries have no dependencies
    if echo "$ldd_output" | grep -q "not a dynamic executable"; then
        return 0
    fi

    # Check if it references glibc-specific libraries
    if echo "$ldd_output" | grep -q "ld-linux"; then
        mb_warn "Binary ${binary} appears to require glibc (ld-linux). May not work on musl."
        return 1
    fi

    # If it references ld-musl, it's musl-compatible
    if echo "$ldd_output" | grep -q "ld-musl"; then
        return 0
    fi

    # No dynamic linker reference — likely compatible
    return 0
}

# ── Module compatibility checks ───────────────────────────────────────────────

# mb_alpine_check_module_compat <module>
# Checks if a given module is compatible with Alpine Linux.
# Echoes "compatible", "partial", or "incompatible" and returns 0/1/2.
mb_alpine_check_module_compat() {
    local module="$1"

    case "$module" in
        system|user|ssh|firewall|kernel|motd|tailscale)
            echo "compatible"
            return 0
            ;;
        crowdsec|auto_updates|partition_check)
            echo "compatible"
            return 0
            ;;
        cis_align)
            echo "partial"
            return 1
            ;;
        auditd)
            # auditd has limited Alpine support via community repo
            echo "partial"
            return 1
            ;;
        apparmor)
            # AppArmor requires kernel support; Alpine has it in some kernels
            echo "partial"
            return 1
            ;;
        docker)
            echo "compatible"
            return 0
            ;;
        autoupdate)
            echo "compatible"
            return 0
            ;;
        *)
            echo "unknown"
            return 2
            ;;
    esac
}

# mb_alpine_compat_report
# Generates a compatibility report for all installed modules on Alpine.
# Only runs on Alpine; no-op on other systems.
mb_alpine_compat_report() {
    if ! mb_alpine_is_alpine; then
        mb_detail "Not Alpine Linux; skipping Alpine compatibility report."
        return 0
    fi

    mb_step "Alpine Linux module compatibility report"
    echo ""

    local alpine_ver
    alpine_ver=$(mb_alpine_version)
    local musl_ok="yes"
    mb_alpine_is_musl || musl_ok="no (glibc detected)"

    echo "  Alpine version:  ${alpine_ver}"
    echo "  musl libc:        ${musl_ok}"
    echo ""

    printf "  %-25s %s\n" "MODULE" "COMPATIBILITY"
    printf "  %-25s %s\n" "-------------------------" "-------------"

    local mod
    for mod in "${MB_ALL_MODULES[@]}"; do
        local compat
        compat=$(mb_alpine_check_module_compat "$mod")
        local color=""
        case "$compat" in
            compatible) color="${MB_GREEN}" ;;
            partial)    color="${MB_YELLOW}" ;;
            incompatible) color="${MB_RED}" ;;
            unknown)    color="${MB_BLUE}" ;;
        esac
        printf "  %-25s ${color}%s${MB_RESET}\n" "$mod" "$compat"
    done

    echo ""
    mb_detail "Alpine compatibility report complete."
}
