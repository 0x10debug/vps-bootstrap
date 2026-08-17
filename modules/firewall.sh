#!/usr/bin/env bash
# modules/firewall.sh — Firewall configuration (UFW on Debian, nftables on Alpine)

mb_module_firewall() {
    mb_step "Firewall configuration"

    local ssh_port
    ssh_port=$(mb_env_get MB_SSH_PORT)
    if [ -z "$ssh_port" ]; then
        ssh_port="${MB_CONFIG_SSH_PORT:-22}"
        mb_warn "SSH port not found in env, using ${ssh_port}"
    fi

    case "$MB_OS_FAMILY" in
        debian) _mb_firewall_ufw "$ssh_port" ;;
        alpine) _mb_firewall_nftables "$ssh_port" ;;
        *) mb_die "Firewall configuration not supported for OS: $MB_OS_FAMILY" ;;
    esac

    mb_mark_done firewall
    mb_success "Firewall configured and active"
}

# ── UFW (Debian/Ubuntu) ──────────────────────────────────────────────────────

_mb_firewall_ufw() {
    local ssh_port="$1"

    # Ensure UFW is installed
    mb_pkg_install ufw

    # Backup UFW config
    mb_backup_file /etc/ufw/ufw.conf firewall
    mb_backup_dir /etc/ufw firewall

    # Reset to clean state (idempotent)
    mb_info "Resetting UFW rules..."
    echo "y" | ufw reset >/dev/null 2>&1 || true

    # Default policies
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH on the configured port (CRITICAL: do this before enabling)
    mb_info "Allowing SSH on port ${ssh_port}..."
    ufw allow "${ssh_port}/tcp" comment 'SSH (mb)'

    # Allow HTTP and HTTPS for web services
    ufw allow 80/tcp comment 'HTTP (mb)'
    ufw allow 443/tcp comment 'HTTPS (mb)'

    # Allow any extra ports from config
    local extra_ports="${MB_CONFIG_EXTRA_PORTS:-}"
    if [ -n "$extra_ports" ]; then
        for port in $extra_ports; do
            ufw allow "${port}" comment "Custom (mb)"
            mb_detail "Allowed port: $port"
        done
    fi

    # Enable UFW
    mb_info "Enabling UFW..."
    echo "y" | ufw enable

    # Show status
    ufw status verbose

    mb_env_set MB_FIREWALL "ufw"
}

# ── nftables (Alpine) ────────────────────────────────────────────────────────

_mb_firewall_nftables() {
    local ssh_port="$1"

    mb_pkg_install nftables

    local nft_config="/etc/nftables.nft"
    mb_backup_file "$nft_config" firewall

    cat > "$nft_config" <<NFTABLES
#!/usr/sbin/nft -f

flush ruleset

table inet mb_filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Loopback
        iif "lo" accept

        # Established/related connections
        ct state established,related accept

        # Invalid packets
        ct state invalid drop

        # ICMP (ping)
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept

        # SSH (custom port)
        tcp dport ${ssh_port} accept comment 'SSH (mb)'

        # HTTP / HTTPS
        tcp dport 80 accept comment 'HTTP (mb)'
        tcp dport 443 accept comment 'HTTPS (mb)'
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFTABLES

    # Apply
    nft -f "$nft_config"

    # Enable on boot
    mb_service_enable nftables
    mb_service_restart nftables

    mb_detail "nftables configured with SSH port ${ssh_port}, HTTP, HTTPS allowed"

    mb_env_set MB_FIREWALL "nftables"
}
