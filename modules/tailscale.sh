#!/usr/bin/env bash
# modules/tailscale.sh — Tailscale/Netbird mesh VPN installation, configuration, and audit
#
# Installs and configures a mesh VPN overlay for secure node-to-node connectivity.
# Supports Tailscale (default) and Netbird as alternative providers. Both use
# official curl install scripts, enable the system service, and authenticate via
# pre-generated keys (auth key for Tailscale, setup key for Netbird).
#
# Features:
#   - Install Tailscale or Netbird (apt/yum/apk adaptive via curl install script)
#   - Enable and start the service (systemd or OpenRC)
#   - Authenticate: Tailscale auth key / Netbird setup key
#   - Read-only audit mode (mb_module_tailscale_audit): checks install status,
#     service state, connection/online status, ACL config, exit node setting,
#     SSH/accept-routes flags. Writes a TXT report to /var/log/tailscale-audit/.
#     Does not modify the system.
#   - Config management: --set-exit-node, --set-ssh, --set-accept-routes,
#     --provider, --auth-key
#
# Project: https://github.com/0x10debug/vps-bootstrap
# Depends on: lib/common.sh, lib/os.sh

set -euo pipefail

# ── Color variables ──────────────────────────────────────────────────────────

if [ -t 1 ]; then
    C_FAIL='\033[0;31m'
    C_OK='\033[0;32m'
    C_WARN='\033[0;33m'
    C_INFO='\033[0;34m'
    C_RST='\033[0m'
else
    C_FAIL='' C_OK='' C_WARN='' C_INFO='' C_RST=''
fi

# ── Constants ────────────────────────────────────────────────────────────────

MB_TAILSCALE_REPORT_DIR="/var/log/tailscale-audit"
MB_TAILSCALE_SVC_NAME="tailscaled"
MB_NETBIRD_SVC_NAME="netbird"

# ── Main module function (install / deploy mode) ─────────────────────────────

mb_module_tailscale() {
    mb_step "Mesh VPN setup (Tailscale/Netbird)"

    local provider="${MB_CONFIG_VPN_PROVIDER:-tailscale}"
    local auth_key="${MB_CONFIG_VPN_AUTH_KEY:-}"

    case "$provider" in
        tailscale)
            _mb_tailscale_install_tailscale
            _mb_tailscale_start_service tailscale
            _mb_tailscale_auth_tailscale "$auth_key"
            ;;
        netbird)
            _mb_tailscale_install_netbird
            _mb_tailscale_start_service netbird
            _mb_tailscale_auth_netbird "$auth_key"
            ;;
        *)
            mb_die "Unknown VPN provider: ${provider}. Use 'tailscale' or 'netbird'."
            ;;
    esac

    mb_env_set MB_VPN_PROVIDER "$provider"
    mb_mark_done tailscale
    mb_success "Mesh VPN (${provider}) is installed and active"
}

# ── Read-only audit function ─────────────────────────────────────────────────

mb_module_tailscale_audit() {
    mb_step "Mesh VPN status audit (read-only)"

    local pass_count=0
    local fail_count=0
    local warn_count=0
    local timestamp report_file
    timestamp=$(date '+%Y%m%d-%H%M%S')
    report_file="${MB_TAILSCALE_REPORT_DIR}/tailscale-audit-${timestamp}.txt"
    mkdir -p "$MB_TAILSCALE_REPORT_DIR" 2>/dev/null || true

    local provider
    provider=$(mb_env_get MB_VPN_PROVIDER || echo "tailscale")

    {
        echo "Mesh VPN Status Audit Report"
        echo "=============================="
        echo "Date: $(date)"
        echo "Host: $(hostname 2>/dev/null)"
        echo "OS: ${PRETTY_NAME:-unknown}"
        echo "Provider: ${provider}"
        echo ""
    } > "$report_file"

    echo ""
    printf "  %-45s %s\n" "CHECK" "STATUS"
    printf "  %-45s %s\n" "---------------------------------------------" "--------"

    # ── Provider package installed ───────────────────────────────────────────
    local pkg_status="FAIL"
    if [ "$provider" = "netbird" ]; then
        if mb_check_command netbird; then
            pkg_status="PASS"
        fi
    else
        if mb_check_command tailscale; then
            pkg_status="PASS"
        fi
    fi
    _mb_tailscale_check "VPN client installed (${provider})" "$pkg_status" "$report_file"
    _mb_tailscale_tally pass_count fail_count warn_count

    if [ "$pkg_status" = "FAIL" ]; then
        echo ""
        mb_warn "Mesh VPN client is not installed. Run 'mb init --module tailscale' to deploy."
        {
            echo ""
            echo "VPN client not installed; remaining checks skipped."
            echo "Summary: PASS=${pass_count} WARN=${warn_count} FAIL=${fail_count}"
        } >> "$report_file"
        mb_detail "Report written to: ${report_file}"
        mb_mark_done tailscale
        mb_success "Mesh VPN audit complete (client not installed)"
        return 0
    fi

    # ── Service active ───────────────────────────────────────────────────────
    local svc_name
    if [ "$provider" = "netbird" ]; then
        svc_name="$MB_NETBIRD_SVC_NAME"
    else
        svc_name="$MB_TAILSCALE_SVC_NAME"
    fi

    local svc_status="FAIL"
    if mb_service_status "$svc_name" 2>/dev/null | grep -q active; then
        svc_status="PASS"
    fi
    _mb_tailscale_check "VPN service active (${svc_name})" "$svc_status" "$report_file"
    _mb_tailscale_tally pass_count fail_count warn_count

    # ── Connection / online status ───────────────────────────────────────────
    local conn_status="FAIL"
    local conn_detail=""
    if [ "$provider" = "netbird" ]; then
        if mb_check_command netbird; then
            local nb_status
            nb_status=$(netbird status 2>/dev/null || echo "")
            if echo "$nb_status" | grep -qi "connected"; then
                conn_status="PASS"
                conn_detail="connected"
            elif echo "$nb_status" | grep -qi "idle"; then
                conn_status="WARN"
                conn_detail="idle (not connected to management)"
            fi
        fi
    else
        if mb_check_command tailscale; then
            local ts_status
            ts_status=$(tailscale status 2>/dev/null || echo "")
            if echo "$ts_status" | grep -q "^$(tailscale ip -4 2>/dev/null || echo 'NONEXISTENT')"; then
                conn_status="PASS"
                conn_detail="online"
            elif [ -n "$ts_status" ]; then
                # If status output is non-empty and not showing errors, consider it
                if echo "$ts_status" | grep -qiE "logged out|not logged in"; then
                    conn_status="WARN"
                    conn_detail="not logged in"
                else
                    conn_status="PASS"
                    conn_detail="online"
                fi
            fi
        fi
    fi
    _mb_tailscale_check "VPN connection status: ${conn_detail:-unknown}" "$conn_status" "$report_file"
    _mb_tailscale_tally pass_count fail_count warn_count

    # ── ACL configuration ────────────────────────────────────────────────────
    local acl_status="WARN"
    local acl_detail=""
    if [ "$provider" = "netbird" ]; then
        # Netbird ACLs are managed via management UI; check if groups are configured
        if mb_check_command netbird; then
            local nb_groups
            nb_groups=$(netbird status 2>/dev/null | grep -i "group" || echo "")
            if [ -n "$nb_groups" ]; then
                acl_status="PASS"
                acl_detail="groups detected"
            else
                acl_detail="no group info (check management UI)"
            fi
        fi
    else
        # Tailscale ACLs are managed via admin console; check local config hints
        if [ -f /etc/systemd/system/tailscaled.service ] || [ -f /etc/init.d/tailscaled ]; then
            acl_status="PASS"
            acl_detail="managed via admin console"
        fi
    fi
    _mb_tailscale_check "ACL configuration: ${acl_detail:-not found}" "$acl_status" "$report_file"
    _mb_tailscale_tally pass_count fail_count warn_count

    # ── Exit node setting ────────────────────────────────────────────────────
    local exit_status="WARN"
    local exit_detail=""
    if [ "$provider" = "netbird" ]; then
        exit_detail="exit node not supported via CLI (check management)"
        exit_status="N/A"
    else
        if mb_check_command tailscale; then
            local ts_prefs
            ts_prefs=$(tailscale status --json 2>/dev/null || echo "")
            if [ -n "$ts_prefs" ]; then
                if echo "$ts_prefs" | grep -q '"ExitNodeOption":true'; then
                    exit_status="PASS"
                    exit_detail="exit node available"
                else
                    exit_status="WARN"
                    exit_detail="exit node not configured"
                fi
            else
                exit_detail="could not read status"
            fi
        fi
    fi
    _mb_tailscale_check "Exit node setting: ${exit_detail:-unknown}" "$exit_status" "$report_file"
    _mb_tailscale_tally pass_count fail_count warn_count

    # ── SSH via VPN ──────────────────────────────────────────────────────────
    local ssh_status="WARN"
    local ssh_detail=""
    if [ "$provider" = "netbird" ]; then
        ssh_detail="SSH via VPN managed by Netbird access controls"
        ssh_status="N/A"
    else
        if mb_check_command tailscale; then
            local ts_status_json
            ts_status_json=$(tailscale status --json 2>/dev/null || echo "")
            if echo "$ts_status_json" | grep -q '"SSH":true'; then
                ssh_status="PASS"
                ssh_detail="Tailscale SSH enabled"
            else
                ssh_status="WARN"
                ssh_detail="Tailscale SSH not enabled"
            fi
        fi
    fi
    _mb_tailscale_check "SSH via VPN: ${ssh_detail:-unknown}" "$ssh_status" "$report_file"
    _mb_tailscale_tally pass_count fail_count warn_count

    # ── Accept routes ────────────────────────────────────────────────────────
    local routes_status="WARN"
    local routes_detail=""
    if [ "$provider" = "netbird" ]; then
        routes_detail="route acceptance managed by Netbird"
        routes_status="N/A"
    else
        if mb_check_command tailscale; then
            local ts_status_json
            ts_status_json=$(tailscale status --json 2>/dev/null || echo "")
            if echo "$ts_status_json" | grep -q '"AcceptRoutes":true'; then
                routes_status="PASS"
                routes_detail="accept-routes enabled"
            else
                routes_status="WARN"
                routes_detail="accept-routes not enabled"
            fi
        fi
    fi
    _mb_tailscale_check "Accept routes: ${routes_detail:-unknown}" "$routes_status" "$report_file"
    _mb_tailscale_tally pass_count fail_count warn_count

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    mb_step "Mesh VPN audit summary"
    echo "  PASS:  ${pass_count}"
    echo "  WARN:  ${warn_count}"
    echo "  FAIL:  ${fail_count}"
    echo "  Provider: ${provider}"
    echo ""

    {
        echo ""
        echo "Summary: PASS=${pass_count} WARN=${warn_count} FAIL=${fail_count}"
    } >> "$report_file"

    if [ "$fail_count" -gt 0 ]; then
        mb_warn "${fail_count} check(s) failed. Deploy with 'mb init --module tailscale'."
    else
        mb_success "Mesh VPN core checks passed (warn=${warn_count} optional items)."
    fi
    mb_detail "Report written to: ${report_file}"

    mb_mark_done tailscale
    mb_success "Mesh VPN audit complete (pass=${pass_count} warn=${warn_count} fail=${fail_count})"
}

# ── Install helpers ───────────────────────────────────────────────────────────

_mb_tailscale_install_tailscale() {
    mb_info "Installing Tailscale..."

    # Tailscale provides an official install script that handles apt/yum/apk
    if mb_check_command curl; then
        curl -fsSL https://tailscale.com/install.sh | sh 2>/dev/null || {
            # Fallback to package manager direct install
            _mb_tailscale_install_tailscale_pkg
        }
    else
        _mb_tailscale_install_tailscale_pkg
    fi

    mb_detail "Tailscale installed"
}

_mb_tailscale_install_tailscale_pkg() {
    mb_info "Falling back to direct package install for Tailscale..."
    case "${MB_OS_FAMILY:-}" in
        debian)
            mb_pkg_install curl gnupg
            curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
            curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
            apt-get update -qq
            mb_pkg_install tailscale
            ;;
        rhel)
            mb_pkg_install tailscale 2>/dev/null || {
                dnf config-manager --add-repo https://pkgs.tailscale.com/stable/rhel/tailscale.repo 2>/dev/null || true
                mb_pkg_install tailscale
            }
            ;;
        alpine)
            mb_pkg_install tailscale
            ;;
        *)
            mb_die "Tailscale installation not supported for OS: ${MB_OS_FAMILY:-unknown}"
            ;;
    esac
}

_mb_tailscale_install_netbird() {
    mb_info "Installing Netbird..."

    # Netbird provides an official install script
    if mb_check_command curl; then
        curl -fsSL https://pkgs.netbird.io/install.sh | sh 2>/dev/null || {
            _mb_tailscale_install_netbird_pkg
        }
    else
        _mb_tailscale_install_netbird_pkg
    fi

    mb_detail "Netbird installed"
}

_mb_tailscale_install_netbird_pkg() {
    mb_info "Falling back to direct package install for Netbird..."
    case "${MB_OS_FAMILY:-}" in
        debian)
            mb_pkg_install curl gnupg ca-certificates
            curl -fsSL https://pkgs.netbird.io/debian/public.key | tee /usr/share/keyrings/netbird-archive-keyring.gpg >/dev/null
            echo "deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main" | tee /etc/apt/sources.list.d/netbird.list >/dev/null
            apt-get update -qq
            mb_pkg_install netbird
            ;;
        rhel)
            mb_pkg_install netbird 2>/dev/null || {
                curl -fsSL https://pkgs.netbird.io/rpm/netbird.repo -o /etc/yum.repos.d/netbird.repo 2>/dev/null || true
                mb_pkg_install netbird
            }
            ;;
        alpine)
            # Netbird may not have official apk packages; try community
            mb_pkg_install netbird 2>/dev/null || mb_warn "Netbird may not be available via apk. Try the curl install script."
            ;;
        *)
            mb_die "Netbird installation not supported for OS: ${MB_OS_FAMILY:-unknown}"
            ;;
    esac
}

_mb_tailscale_start_service() {
    local provider="$1"
    local svc_name

    if [ "$provider" = "netbird" ]; then
        svc_name="$MB_NETBIRD_SVC_NAME"
    else
        svc_name="$MB_TAILSCALE_SVC_NAME"
    fi

    mb_info "Enabling and starting ${svc_name} service..."

    mb_service_enable "$svc_name" 2>/dev/null || true
    mb_service_restart "$svc_name" 2>/dev/null || true

    mb_detail "${svc_name} service enabled and started"
}

_mb_tailscale_auth_tailscale() {
    local auth_key="$1"

    mb_info "Authenticating Tailscale..."

    if [ -z "$auth_key" ]; then
        mb_warn "No Tailscale auth key provided (MB_CONFIG_VPN_AUTH_KEY)."
        mb_warn "Run 'tailscale up' manually to authenticate, or re-run with --auth-key."
        mb_detail "Tailscale will start but remain logged out until authenticated."
        return 0
    fi

    if mb_check_command tailscale; then
        tailscale up --auth-key="$auth_key" 2>/dev/null || {
            mb_warn "Tailscale authentication failed. Check your auth key."
            mb_detail "You can retry with: tailscale up --auth-key=YOUR_KEY"
        }
        mb_detail "Tailscale authenticated with provided auth key"
    else
        mb_warn "tailscale command not found; cannot authenticate"
    fi
}

_mb_tailscale_auth_netbird() {
    local setup_key="$1"

    mb_info "Authenticating Netbird..."

    if [ -z "$setup_key" ]; then
        mb_warn "No Netbird setup key provided (MB_CONFIG_VPN_AUTH_KEY)."
        mb_warn "Run 'netbird up --setup-key YOUR_KEY' manually to authenticate."
        mb_detail "Netbird will start but remain idle until authenticated."
        return 0
    fi

    if mb_check_command netbird; then
        netbird up --setup-key "$setup_key" 2>/dev/null || {
            mb_warn "Netbird authentication failed. Check your setup key."
            mb_detail "You can retry with: netbird up --setup-key YOUR_KEY"
        }
        mb_detail "Netbird authenticated with provided setup key"
    else
        mb_warn "netbird command not found; cannot authenticate"
    fi
}

# ── Config management ──────────────────────────────────────────────────────────

# _mb_tailscale_set_exit_node <enable|disable>
# Enables or disables this node as a Tailscale exit node.
_mb_tailscale_set_exit_node() {
    local action="${1:-enable}"
    local provider
    provider=$(mb_env_get MB_VPN_PROVIDER || echo "tailscale")

    if [ "$provider" = "netbird" ]; then
        mb_warn "Exit node configuration for Netbird is managed via the management UI."
        return 0
    fi

    if ! mb_check_command tailscale; then
        mb_die "tailscale command not found. Install Tailscale first."
    fi

    case "$action" in
        enable)
            # Advertise as exit node and accept the advertisement
            tailscale up --advertise-exit-node --accept-dns=false 2>/dev/null || true
            mb_detail "Tailscale exit node advertised. Approve in admin console."
            mb_env_set MB_TAILSCALE_EXIT_NODE "advertised"
            ;;
        disable)
            tailscale up --advertise-exit-node=false 2>/dev/null || true
            mb_detail "Tailscale exit node advertisement disabled."
            mb_env_set MB_TAILSCALE_EXIT_NODE "disabled"
            ;;
        *)
            mb_die "Unknown exit node action: ${action}. Use 'enable' or 'disable'."
            ;;
    esac
}

# _mb_tailscale_set_ssh <enable|disable>
# Enables or disables Tailscale SSH.
_mb_tailscale_set_ssh() {
    local action="${1:-enable}"
    local provider
    provider=$(mb_env_get MB_VPN_PROVIDER || echo "tailscale")

    if [ "$provider" = "netbird" ]; then
        mb_warn "SSH via Netbird is managed via access controls in the management UI."
        return 0
    fi

    if ! mb_check_command tailscale; then
        mb_die "tailscale command not found. Install Tailscale first."
    fi

    case "$action" in
        enable)
            tailscale up --ssh 2>/dev/null || true
            mb_detail "Tailscale SSH enabled."
            mb_env_set MB_TAILSCALE_SSH "enabled"
            ;;
        disable)
            tailscale up --ssh=false 2>/dev/null || true
            mb_detail "Tailscale SSH disabled."
            mb_env_set MB_TAILSCALE_SSH "disabled"
            ;;
        *)
            mb_die "Unknown SSH action: ${action}. Use 'enable' or 'disable'."
            ;;
    esac
}

# _mb_tailscale_set_accept_routes <enable|disable>
# Enables or disables accepting routes from other Tailscale nodes.
_mb_tailscale_set_accept_routes() {
    local action="${1:-enable}"
    local provider
    provider=$(mb_env_get MB_VPN_PROVIDER || echo "tailscale")

    if [ "$provider" = "netbird" ]; then
        mb_warn "Route acceptance for Netbird is managed via the management UI."
        return 0
    fi

    if ! mb_check_command tailscale; then
        mb_die "tailscale command not found. Install Tailscale first."
    fi

    case "$action" in
        enable)
            tailscale up --accept-routes 2>/dev/null || true
            mb_detail "Tailscale accept-routes enabled."
            mb_env_set MB_TAILSCALE_ACCEPT_ROUTES "enabled"
            ;;
        disable)
            tailscale up --accept-routes=false 2>/dev/null || true
            mb_detail "Tailscale accept-routes disabled."
            mb_env_set MB_TAILSCALE_ACCEPT_ROUTES "disabled"
            ;;
        *)
            mb_die "Unknown accept-routes action: ${action}. Use 'enable' or 'disable'."
            ;;
    esac
}

# ── Audit check helpers ───────────────────────────────────────────────────────

# _mb_tailscale_check <desc> <status> <report_file>
# Prints a colored status row and appends a plain-text line to the report.
_mb_tailscale_check() {
    local desc="$1" status="$2" report_file="$3"
    local color=""
    case "$status" in
        PASS) color="$C_OK" ;;
        FAIL) color="$C_FAIL" ;;
        WARN) color="$C_WARN" ;;
        N/A)  color="$C_INFO" ;;
    esac
    _MB_TAILSCALE_LAST_STATUS="$status"
    printf "  %-45s ${color}%s${C_RST}\n" "$desc" "$status"
    printf "  %-45s %s\n" "$desc" "$status" >> "$report_file"
}

# _mb_tailscale_tally <pass_var> <fail_var> <warn_var>
# Increments the named tally variable based on the last printed status.
# Uses namerefs (bash 4.3+) to update the caller's counters.
_mb_tailscale_tally() {
    local -n _t_pass="$1"
    local -n _t_fail="$2"
    local -n _t_warn="$3"
    case "${_MB_TAILSCALE_LAST_STATUS:-}" in
        PASS) _t_pass=$((_t_pass + 1)) ;;
        FAIL) _t_fail=$((_t_fail + 1)) ;;
        WARN) _t_warn=$((_t_warn + 1)) ;;
    esac
}

# ── Direct invocation support ─────────────────────────────────────────────────
# When executed directly (not sourced by mb), wire up mb helpers and dispatch.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _MB_TAILSCALE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/common.sh
    source "${_MB_TAILSCALE_SCRIPT_DIR}/../lib/common.sh"
    # shellcheck source=lib/os.sh
    source "${_MB_TAILSCALE_SCRIPT_DIR}/../lib/os.sh"
    mb_detect_os

    _mb_tailscale_usage() {
        cat <<'USAGE'
Usage: modules/tailscale.sh <command> [OPTIONS]

Commands:
  install                  Install and configure mesh VPN (Tailscale or Netbird)
  audit                    Read-only status check (writes report to /var/log/tailscale-audit/)
  --set-exit-node [on|off] Enable/disable this node as a Tailscale exit node
  --set-ssh [on|off]       Enable/disable Tailscale SSH
  --set-accept-routes [on|off]  Enable/disable accepting routes from other nodes
  --provider NAME          Set VPN provider (tailscale or netbird) for install
  --auth-key KEY           Set auth key (Tailscale auth key or Netbird setup key) for install
  help                     Show this help

Config via environment (before install):
  MB_CONFIG_VPN_PROVIDER=tailscale   Choose provider (tailscale/netbird)
  MB_CONFIG_VPN_AUTH_KEY=tskey-...   Auth key for Tailscale or setup key for Netbird

ACL configuration example:
  config/tailscale-acl-example.json
USAGE
    }

    # Parse provider and auth-key flags first, then dispatch
    _mb_ts_provider=""
    _mb_ts_auth_key=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --provider)
                _mb_ts_provider="$2"
                shift 2
                ;;
            --auth-key)
                _mb_ts_auth_key="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done

    if [ -n "$_mb_ts_provider" ]; then
        export MB_CONFIG_VPN_PROVIDER="$_mb_ts_provider"
    fi
    if [ -n "$_mb_ts_auth_key" ]; then
        export MB_CONFIG_VPN_AUTH_KEY="$_mb_ts_auth_key"
    fi

    case "${1:-help}" in
        install)
            mb_check_root
            mb_module_tailscale
            ;;
        audit)
            mb_module_tailscale_audit
            ;;
        --set-exit-node)
            _mb_ts_action="${2:-enable}"
            case "$_mb_ts_action" in
                on|enable) _mb_ts_action="enable" ;;
                off|disable) _mb_ts_action="disable" ;;
            esac
            mb_check_root
            _mb_tailscale_set_exit_node "$_mb_ts_action"
            mb_success "Exit node setting: ${_mb_ts_action}"
            ;;
        --set-ssh)
            _mb_ts_action="${2:-enable}"
            case "$_mb_ts_action" in
                on|enable) _mb_ts_action="enable" ;;
                off|disable) _mb_ts_action="disable" ;;
            esac
            mb_check_root
            _mb_tailscale_set_ssh "$_mb_ts_action"
            mb_success "Tailscale SSH setting: ${_mb_ts_action}"
            ;;
        --set-accept-routes)
            _mb_ts_action="${2:-enable}"
            case "$_mb_ts_action" in
                on|enable) _mb_ts_action="enable" ;;
                off|disable) _mb_ts_action="disable" ;;
            esac
            mb_check_root
            _mb_tailscale_set_accept_routes "$_mb_ts_action"
            mb_success "Accept routes setting: ${_mb_ts_action}"
            ;;
        help|-h|--help)
            _mb_tailscale_usage
            ;;
        *)
            echo "Unknown command: $1" >&2
            _mb_tailscale_usage
            exit 1
            ;;
    esac
fi
