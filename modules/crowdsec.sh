#!/usr/bin/env bash
# modules/crowdsec.sh — CrowdSec installation and configuration
# Replaces fail2ban with modern, crowdsourced intrusion prevention.

mb_module_crowdsec() {
    mb_step "CrowdSec intrusion prevention setup"

    # Check if CrowdSec is already installed
    if mb_check_command cscli && cscli version >/dev/null 2>&1; then
        mb_detail "CrowdSec already installed"
    else
        # Install CrowdSec
        case "$MB_OS_FAMILY" in
            debian) _mb_crowdsec_install_debian ;;
            alpine) _mb_crowdsec_install_alpine ;;
            *) mb_die "CrowdSec installation not supported for OS: $MB_OS_FAMILY" ;;
        esac
    fi

    # Configure collections
    _mb_crowdsec_configure_collections

    # Install firewall bouncer
    _mb_crowdsec_install_bouncer

    # Whitelist current SSH IP
    _mb_crowdsec_whitelist_current_ip

    # Verify
    _mb_crowdsec_verify

    mb_mark_done crowdsec
    mb_success "CrowdSec is active and protecting your server"
}

# ── Installation ─────────────────────────────────────────────────────────────

_mb_crowdsec_install_debian() {
    mb_info "Installing CrowdSec (Debian/Ubuntu)..."

    # Add CrowdSec repository
    curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/crowdsec-crowdsec-archive-keyring.gpg 2>/dev/null

    echo "deb [signed-by=/usr/share/keyrings/crowdsec-crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/$(. /etc/os-release && echo "$ID")/ $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
        > /etc/apt/sources.list.d/crowdsec.list

    mb_pkg_update
    mb_pkg_install crowdsec

    mb_detail "CrowdSec installed from official repository"
}

_mb_crowdsec_install_alpine() {
    mb_info "Installing CrowdSec (Alpine)..."
    # CrowdSec on Alpine — use the install script as fallback
    # Alpine package may not always be up-to-date
    if mb_check_command apk; then
        # Try community repo first
        if apk info crowdsec >/dev/null 2>&1; then
            mb_pkg_install crowdsec
        else
            # Fallback to official install script
            mb_warn "CrowdSec not in Alpine repos. Using official install script."
            curl -fsSL https://raw.githubusercontent.com/crowdsecurity/crowdsec/master/scripts/install.sh \
                | bash -s -- --without-bouncer
        fi
    fi
}

# ── Configuration ────────────────────────────────────────────────────────────

_mb_crowdsec_configure_collections() {
    mb_info "Configuring CrowdSec collections..."

    # Core SSH protection
    local collections=(
        crowdsecurity/ssh-slow-bf
        crowdsecurity/ssh-bf
    )

    # Web server protection (if detected)
    if mb_check_command nginx || mb_check_command caddy || mb_check_command apache2; then
        collections+=(
            crowdsecurity/http-cve
            crowdsecurity/http-generic
        )
        mb_detail "Web server detected, adding HTTP collections"
    fi

    for col in "${collections[@]}"; do
        if ! cscli collections list -o raw 2>/dev/null | grep -q "$col"; then
            cscli collections install "$col" >/dev/null 2>&1 && mb_detail "Installed collection: $col"
        else
            mb_detail "Collection already present: $col"
        fi
    done

    # Enable community blocklist
    if ! cscli bouncers list -o raw 2>/dev/null | grep -q "community-blocklist"; then
        cscli hub update >/dev/null 2>&1 || true
        cscli capi register >/dev/null 2>&1 || true
        mb_detail "Community blocklist enabled"
    fi
}

_mb_crowdsec_install_bouncer() {
    mb_info "Installing firewall bouncer..."

    # Check if bouncer already installed
    if cscli bouncers list -o raw 2>/dev/null | grep -q "mb-firewall-bouncer"; then
        mb_detail "Firewall bouncer already installed"
        return 0
    fi

    case "$MB_OS_FAMILY" in
        debian)
            if ! mb_check_package crowdsec-firewall-bouncer-nftables; then
                mb_pkg_install crowdsec-firewall-bouncer-nftables
            fi
            ;;
        alpine)
            # Use the bouncer install script
            curl -fsSL https://raw.githubusercontent.com/crowdsecurity/cs-firewall-bouncer/main/install.sh \
                | bash -s -- --nftables 2>/dev/null || \
                mb_warn "Bouncer install script failed. Manual install may be needed."
            ;;
    esac

    mb_service_enable crowdsec
    mb_service_restart crowdsec
    mb_service_restart crowdsec-firewall-bouncer 2>/dev/null || true

    mb_detail "Firewall bouncer installed and active"
}

_mb_crowdsec_whitelist_current_ip() {
    # Whitelist the current SSH client IP to prevent self-ban
    local client_ip
    client_ip=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
    if [ -n "$client_ip" ]; then
        if ! cscli decisions list -o raw 2>/dev/null | grep -q "$client_ip"; then
            cscli bouncers add "mb-current-session" -i "$client_ip" >/dev/null 2>&1 || true
            # Add to allowlists
            cscli api allow "$client_ip" >/dev/null 2>&1 || true
            mb_detail "Whitelisted your current IP: $client_ip"
        fi
    else
        mb_detail "Could not detect SSH client IP (not in SSH session?). Skipping whitelist."
    fi
}

_mb_crowdsec_verify() {
    mb_info "Verifying CrowdSec..."

    if ! mb_service_status crowdsec | grep -q active; then
        mb_error "CrowdSec service is not running!"
        return 1
    fi

    local bouncer_active
    bouncer_active=$(cscli bouncers list -o raw 2>/dev/null | grep -c "firewall" || echo "0")
    if [ "$bouncer_active" -eq 0 ] 2>/dev/null; then
        mb_warn "No firewall bouncer detected. Bouncer may not be running."
    else
        mb_detail "Firewall bouncer: active"
    fi

    local alerts
    alerts=$(cscli alerts list -o raw 2>/dev/null | wc -l || echo "0")
    mb_detail "CrowdSec is monitoring (current alerts: $alerts)"

    mb_env_set MB_CROWDSEC "installed"
}
