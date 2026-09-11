#!/usr/bin/env bash
# modules/wireguard.sh — Self-hosted WireGuard VPN (server + client modes)
#
# WireGuard complement to the Tailscale mesh module: a self-hosted tunnel with
# no third-party coordination service. Server mode turns the VPS into a VPN
# gateway (keygen, wg0.conf, IP forwarding, firewall port, client configs with
# optional QR codes). Client mode joins this machine to an existing WireGuard
# server (endpoint + server public key from config).
#
# Config keys (all optional, sane defaults):
#   MB_CONFIG_WIREGUARD_MODE        server | client   (default: server)
#   MB_CONFIG_WIREGUARD_PORT        UDP listen port   (default: 51820)
#   MB_CONFIG_WIREGUARD_ADDRESS     server tunnel IP  (default: 10.66.66.1/24)
#   MB_CONFIG_WIREGUARD_CLIENT_NAME client label      (default: client1)
#   client mode additionally:
#   MB_CONFIG_WIREGUARD_ENDPOINT    host:port of the server   (required)
#   MB_CONFIG_WIREGUARD_SERVER_PUBKEY  server public key      (required)
#   MB_CONFIG_WIREGUARD_ALLOWED_IPS routes via tunnel    (default: 0.0.0.0/0)
#   MB_CONFIG_WIREGUARD_DNS         DNS server for the client (optional)
#
# Security notes:
#   - Private keys are written 0600 under /etc/wireguard; never commit them.
#   - The UDP port is opened in the firewall configured by modules/firewall.sh
#     (MB_FIREWALL: ufw | firewalld | nftables).
#   - Server mode enables IPv4 forwarding; AllowedIPs on the server side are
#     always the tunnel subnet, never 0.0.0.0/0 (that would make the server
#     route ALL its traffic through the client).

set -euo pipefail

mb_module_wireguard() {
    mb_step "WireGuard VPN"

    local mode="${MB_CONFIG_WIREGUARD_MODE:-server}"
    case "$mode" in
        server) _mb_wireguard_server ;;
        client) _mb_wireguard_client ;;
        *) mb_die "Invalid MB_CONFIG_WIREGUARD_MODE '$mode' (expected server or client)" ;;
    esac

    mb_mark_done wireguard
    mb_success "WireGuard configured ($mode mode)"
}

# ── Shared helpers ───────────────────────────────────────────────────────────

_mb_wireguard_install_pkgs() {
    case "$MB_OS_FAMILY" in
        debian) mb_pkg_install wireguard-tools qrencode 2>/dev/null || mb_pkg_install wireguard-tools ;;
        rhel)   mb_pkg_install wireguard-tools ;;
        alpine) mb_pkg_install wireguard-tools-wg wireguard-tools-wgquick ;;
    esac
}

_mb_wireguard_install() {
    # wireguard-tools provides wg + wg-quick on every family. The 'wireguard'
    # meta-package additionally pulls DKMS kernel modules, which fail where
    # the kernel ships WireGuard built in (kernel >= 5.6) or in containers.
    _mb_wireguard_install_pkgs
    if ! mb_check_command wg; then
        # Single-module runs (mb init --module wireguard) may skip the system
        # module: package lists can be absent or stale. Refresh and retry once.
        mb_pkg_update
        _mb_wireguard_install_pkgs
    fi
    mb_check_command wg || mb_die "wg tool not available after installation"
    mb_check_command wg-quick || mb_die "wg-quick not available after installation"
}

_mb_wireguard_gen_keypair() {
    # $1 = basename under /etc/wireguard (e.g. server, clients/client1)
    local base="/etc/wireguard/$1"
    local key_dir
    key_dir=$(dirname "$base")
    mkdir -p "$key_dir"
    chmod 700 "$key_dir"
    if [ -s "${base}.key" ]; then
        mb_detail "Key pair already present: ${base}.key"
        return 0
    fi
    umask 077
    wg genkey > "${base}.key"
    wg pubkey < "${base}.key" > "${base}.pub"
    mb_detail "Generated key pair: ${base}.key/.pub"
}

_mb_wireguard_open_port() {
    local port="$1"
    local fw
    fw=$(mb_env_get MB_FIREWALL)
    case "${fw:-}" in
        ufw)
            ufw allow "${port}/udp" comment 'WireGuard (mb)' >/dev/null
            mb_detail "ufw: allowed UDP ${port}"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/udp" >/dev/null
            firewall-cmd --reload >/dev/null
            mb_detail "firewalld: allowed UDP ${port}"
            ;;
        nftables)
            mb_warn "Open UDP ${port} in /etc/nftables.nft manually (nftables is static on Alpine)"
            ;;
        *)
            mb_warn "No mb-managed firewall detected; ensure UDP ${port} is open"
            ;;
    esac
}

# ── Server mode ──────────────────────────────────────────────────────────────

_mb_wireguard_server() {
    local wg_port="${MB_CONFIG_WIREGUARD_PORT:-51820}"
    local wg_address="${MB_CONFIG_WIREGUARD_ADDRESS:-10.66.66.1/24}"
    local tunnel_base="${wg_address%/*}"; tunnel_base="${tunnel_base%.*}"
    local peer_allowed="${tunnel_base}.2/32"
    local client_addr="${tunnel_base}.2/24"
    local client_name="${MB_CONFIG_WIREGUARD_CLIENT_NAME:-client1}"

    _mb_wireguard_install

    # IPv4 forwarding for NAT
    local sysctl_file="/etc/sysctl.d/99-wireguard.conf"
    mb_backup_file "$sysctl_file" wireguard
    {
        echo "# WireGuard forwarding (managed by mb)"
        echo "net.ipv4.ip_forward = 1"
    } > "$sysctl_file"
    sysctl -p "$sysctl_file" >/dev/null

    # Server key pair (idempotent)
    _mb_wireguard_gen_keypair "server"
    local server_priv server_pub
    server_priv=$(cat /etc/wireguard/server.key)
    server_pub=$(cat /etc/wireguard/server.pub)

    # First client key pair + peer block (idempotent)
    _mb_wireguard_gen_keypair "clients/${client_name}"
    local client_priv client_pub
    client_priv=$(cat "/etc/wireguard/clients/${client_name}.key")
    client_pub=$(cat "/etc/wireguard/clients/${client_name}.pub")

    # Server interface
    local wg_conf="/etc/wireguard/wg0.conf"
    mb_backup_file "$wg_conf" wireguard
    umask 077
    cat > "$wg_conf" <<WGCONF
[Interface]
# WireGuard server (managed by mb)
Address = ${wg_address}
ListenPort = ${wg_port}
PrivateKey = ${server_priv}
PostUp = iptables -t nat -A POSTROUTING -s ${tunnel_base}.0/24 -o $(ip route | awk '/default/ {print $5; exit}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${tunnel_base}.0/24 -o $(ip route | awk '/default/ {print $5; exit}') -j MASQUERADE

[Peer]
# ${client_name}
PublicKey = ${client_pub}
AllowedIPs = ${peer_allowed}
WGCONF
    chmod 600 "$wg_conf"

    # Client config + optional QR
    local client_conf="/etc/wireguard/clients/${client_name}.conf"
    local endpoint_host="${MB_CONFIG_WIREGUARD_ENDPOINT:-}"
    if [ -z "$endpoint_host" ]; then
        endpoint_host=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    fi
    cat > "$client_conf" <<CLICONF
[Interface]
# ${client_name} - wireguard client config (generated by mb)
PrivateKey = ${client_priv}
Address = ${client_addr}
DNS = ${MB_CONFIG_WIREGUARD_DNS:-1.1.1.1}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint_host}:${wg_port}
AllowedIPs = ${MB_CONFIG_WIREGUARD_ALLOWED_IPS:-0.0.0.0/0}
PersistentKeepalive = 25
CLICONF
    chmod 600 "$client_conf"
    if mb_check_command qrencode; then
        qrencode -t ansiutf8 < "$client_conf" || mb_detail "QR rendering skipped"
    fi
    mb_detail "Client config written: ${client_conf} (scan the QR above, or copy the file)"

    # Firewall + service
    _mb_wireguard_open_port "$wg_port"
    mb_service_enable "wg-quick@wg0"
    mb_service_restart "wg-quick@wg0" 2>/dev/null \
        || mb_warn "wg-quick@wg0 could not start in this environment (no TUN device?); it will start on a real host"

    mb_env_set MB_WIREGUARD_PORT "$wg_port"
    mb_detail "Server listening on UDP ${wg_port}, tunnel ${wg_address}"
}

# ── Client mode ──────────────────────────────────────────────────────────────

_mb_wireguard_client() {
    local endpoint="${MB_CONFIG_WIREGUARD_ENDPOINT:-}"
    local server_pub="${MB_CONFIG_WIREGUARD_SERVER_PUBKEY:-}"
    [ -n "$endpoint" ] || mb_die "Client mode requires MB_CONFIG_WIREGUARD_ENDPOINT (host:port)"
    [ -n "$server_pub" ] || mb_die "Client mode requires MB_CONFIG_WIREGUARD_SERVER_PUBKEY"
    echo "$server_pub" | wg pubkey >/dev/null 2>&1 \
        || mb_die "MB_CONFIG_WIREGUARD_SERVER_PUBKEY is not a valid WireGuard public key"

    local client_name="${MB_CONFIG_WIREGUARD_CLIENT_NAME:-client1}"
    local client_address="${MB_CONFIG_WIREGUARD_ADDRESS:-10.66.66.2/24}"

    _mb_wireguard_install
    _mb_wireguard_gen_keypair "clients/${client_name}"
    local client_priv
    client_priv=$(cat "/etc/wireguard/clients/${client_name}.key")

    local wg_conf="/etc/wireguard/wg0.conf"
    mb_backup_file "$wg_conf" wireguard
    umask 077
    cat > "$wg_conf" <<WGCONF
[Interface]
# WireGuard client ${client_name} (managed by mb)
PrivateKey = ${client_priv}
Address = ${client_address}
DNS = ${MB_CONFIG_WIREGUARD_DNS:-}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint}
AllowedIPs = ${MB_CONFIG_WIREGUARD_ALLOWED_IPS:-0.0.0.0/0}
PersistentKeepalive = 25
WGCONF
    chmod 600 "$wg_conf"

    mb_service_enable "wg-quick@wg0"
    mb_service_restart "wg-quick@wg0" 2>/dev/null \
        || mb_warn "wg-quick@wg0 could not start in this environment (no TUN device?); it will start on a real host"

    mb_detail "Client tunnel to ${endpoint} configured"
}
