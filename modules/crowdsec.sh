#!/usr/bin/env bash
# modules/crowdsec.sh — CrowdSec installation, configuration, and audit
#
# Replaces fail2ban with modern, crowdsourced intrusion prevention.
#
# Day 4 enhancements over the baseline module:
#   - Scenario configuration: SSH slow brute-force, web crawl/scan, TCP port
#     scan, with enable/disable management functions
#   - Bouncer extension: firewall (nftables/iptables, default), nginx bouncer,
#     and Cloudflare bouncer (requires API token), plus a status checker
#   - auditd integration: feeds /var/log/audit/audit.log into CrowdSec as an
#     acquisition source so privileged-command abuse detected by auditd.sh
#     (Day 3) can trigger CrowdSec decisions
#   - Alert integration: email (postfix/msmtp) and webhook (Discord/Slack/custom)
#     notification config templates
#   - Read-only audit mode (mb_module_crowdsec_audit): checks install status,
#     bouncer coverage, scenario freshness, threat-intel sync, and recent
#     decisions. Writes a TXT report to /var/log/crowdsec-audit/. Does not
#     modify the system.
#
# Project: https://github.com/0x10debug/vps-bootstrap
# Depends on: lib/common.sh, lib/os.sh; cooperates with modules/auditd.sh

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

MB_CROWDSEC_ACQUIS_FILE="/etc/crowdsec/acquis.yaml"
MB_CROWDSEC_REPORT_DIR="/var/log/crowdsec-audit"
MB_CROWDSEC_SVC_NAME="crowdsec"
MB_CROWDSEC_NOTIFICATIONS_DIR="/etc/crowdsec/notifications"

# Registry of scenarios (CrowdSec collections) managed by this module.
# Names match cscli collection identifiers.
MB_CROWDSEC_SCENARIOS=(
    "crowdsecurity/ssh-slow-bf"
    "crowdsecurity/http-crawl-non_statics"
    "crowdsecurity/tcp-scan-multi_ports"
)

# Registry of bouncer backends supported by this module.
MB_CROWDSEC_BOUNCERS=("firewall" "nginx" "cloudflare")

# ── Main module function (install / deploy mode) ─────────────────────────────

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

    # Configure collections and scenarios
    _mb_crowdsec_configure_collections
    _mb_crowdsec_configure_scenarios

    # Install bouncer (firewall by default; nginx/cloudflare optional)
    _mb_crowdsec_install_bouncer

    # auditd log acquisition (cooperates with modules/auditd.sh)
    _mb_crowdsec_integrate_auditd

    # Alert integration (best-effort; only if config present)
    _mb_crowdsec_configure_alerts

    # Whitelist current SSH IP
    _mb_crowdsec_whitelist_current_ip

    # Verify
    _mb_crowdsec_verify

    mb_mark_done crowdsec
    mb_success "CrowdSec is active and protecting your server"
}

# ── Read-only audit function ─────────────────────────────────────────────────

mb_module_crowdsec_audit() {
    mb_step "CrowdSec status audit (read-only)"

    local pass_count=0
    local fail_count=0
    local warn_count=0
    local timestamp report_file
    timestamp=$(date '+%Y%m%d-%H%M%S')
    report_file="${MB_CROWDSEC_REPORT_DIR}/crowdsec-audit-${timestamp}.txt"
    mkdir -p "$MB_CROWDSEC_REPORT_DIR" 2>/dev/null || true

    {
        echo "CrowdSec Status Audit Report"
        echo "============================="
        echo "Date: $(date)"
        echo "Host: $(hostname 2>/dev/null)"
        echo "OS: ${PRETTY_NAME:-unknown}"
        echo ""
    } > "$report_file"

    echo ""
    printf "  %-40s %s\n" "CHECK" "STATUS"
    printf "  %-40s %s\n" "----------------------------------------" "--------"

    # ── CrowdSec installed ──────────────────────────────────────────────────
    local cs_status="FAIL"
    if mb_check_command cscli && cscli version >/dev/null 2>&1; then
        cs_status="PASS"
    fi
    _mb_crowdsec_check "CrowdSec installed (cscli present)" "$cs_status" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    # If CrowdSec is not installed, the remaining checks are moot.
    if [ "$cs_status" = "FAIL" ]; then
        echo ""
        mb_warn "CrowdSec is not installed. Run 'mb init --module crowdsec' to deploy."
        {
            echo ""
            echo "CrowdSec not installed; remaining checks skipped."
            echo "Summary: PASS=${pass_count} WARN=${warn_count} FAIL=${fail_count}"
        } >> "$report_file"
        mb_detail "Report written to: ${report_file}"
        mb_mark_done crowdsec
        mb_success "CrowdSec audit complete (crowdsec not installed)"
        return 0
    fi

    # ── CrowdSec service active ─────────────────────────────────────────────
    local svc_status="FAIL"
    if mb_service_status crowdsec 2>/dev/null | grep -q active; then
        svc_status="PASS"
    fi
    _mb_crowdsec_check "CrowdSec service active" "$svc_status" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    # ── Bouncer coverage ────────────────────────────────────────────────────
    local bouncer_raw
    bouncer_raw=$(cscli bouncers list -o raw 2>/dev/null || echo "")
    local fw_bouncer="FAIL"
    if echo "$bouncer_raw" | grep -qi "firewall"; then fw_bouncer="PASS"; fi
    _mb_crowdsec_check "Firewall bouncer present" "$fw_bouncer" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    local nginx_bouncer="WARN"
    if echo "$bouncer_raw" | grep -qi "nginx"; then nginx_bouncer="PASS"; fi
    _mb_crowdsec_check "nginx bouncer present (optional)" "$nginx_bouncer" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    local cf_bouncer="WARN"
    if echo "$bouncer_raw" | grep -qi "cloudflare"; then cf_bouncer="PASS"; fi
    _mb_crowdsec_check "Cloudflare bouncer present (optional)" "$cf_bouncer" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    # ── Scenario coverage ───────────────────────────────────────────────────
    local collections_raw
    collections_raw=$(cscli collections list -o raw 2>/dev/null || echo "")
    local scenario
    for scenario in "${MB_CROWDSEC_SCENARIOS[@]}"; do
        local sc_status="FAIL"
        if echo "$collections_raw" | grep -q "$scenario"; then sc_status="PASS"; fi
        _mb_crowdsec_check "Scenario installed: ${scenario}" "$sc_status" "$report_file"
        _mb_crowdsec_tally pass_count fail_count warn_count
    done

    # ── Hub / threat-intel freshness ────────────────────────────────────────
    local hub_status="WARN"
    if cscli hub list -o raw 2>/dev/null | grep -qi "up-to-date"; then
        hub_status="PASS"
    elif cscli hub info -o raw 2>/dev/null | grep -qi "up-to-date"; then
        hub_status="PASS"
    fi
    _mb_crowdsec_check "Hub scenarios up-to-date" "$hub_status" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    local capi_status="WARN"
    if cscli capi status >/dev/null 2>&1; then
        capi_status="PASS"
    fi
    _mb_crowdsec_check "Community threat-intel (CAPI) registered" "$capi_status" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    # ── auditd acquisition source ───────────────────────────────────────────
    local auditd_acq="WARN"
    if [ -f "$MB_CROWDSEC_ACQUIS_FILE" ] && grep -q "audit" "$MB_CROWDSEC_ACQUIS_FILE" 2>/dev/null; then
        auditd_acq="PASS"
    fi
    _mb_crowdsec_check "auditd log acquisition configured" "$auditd_acq" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    # ── Alert notifications ─────────────────────────────────────────────────
    local notif_dir="$MB_CROWDSEC_NOTIFICATIONS_DIR"
    local email_notif="WARN"
    if [ -d "$notif_dir" ] && ls "$notif_dir"/*email* >/dev/null 2>&1; then
        email_notif="PASS"
    fi
    _mb_crowdsec_check "Email notification configured (optional)" "$email_notif" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    local webhook_notif="WARN"
    if [ -d "$notif_dir" ] && ls "$notif_dir"/*http* >/dev/null 2>&1; then
        webhook_notif="PASS"
    fi
    _mb_crowdsec_check "Webhook notification configured (optional)" "$webhook_notif" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    # ── Recent decisions (informational) ────────────────────────────────────
    local decision_count
    decision_count=$(cscli decisions list -o raw 2>/dev/null | grep -c "ip" || echo "0")
    _mb_crowdsec_check "Active decisions: ${decision_count}" "N/A" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    local alert_count
    alert_count=$(cscli alerts list -o raw 2>/dev/null | grep -c "^[0-9]" || echo "0")
    _mb_crowdsec_check "Recent alerts: ${alert_count}" "N/A" "$report_file"
    _mb_crowdsec_tally pass_count fail_count warn_count

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    mb_step "CrowdSec audit summary"
    echo "  PASS:  ${pass_count}"
    echo "  WARN:  ${warn_count}"
    echo "  FAIL:  ${fail_count}"
    echo "  Active decisions: ${decision_count}"
    echo "  Recent alerts:    ${alert_count}"
    echo ""

    {
        echo ""
        echo "Active decisions: ${decision_count}"
        echo "Recent alerts:    ${alert_count}"
        echo "Summary: PASS=${pass_count} WARN=${warn_count} FAIL=${fail_count}"
    } >> "$report_file"

    if [ "$fail_count" -gt 0 ]; then
        mb_warn "${fail_count} check(s) failed. Deploy with 'mb init --module crowdsec'."
    else
        mb_success "CrowdSec core checks passed (warn=${warn_count} optional items)."
    fi
    mb_detail "Report written to: ${report_file}"

    mb_mark_done crowdsec
    mb_success "CrowdSec audit complete (pass=${pass_count} warn=${warn_count} fail=${fail_count})"
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

# ── Configuration: collections ───────────────────────────────────────────────

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

# ── Configuration: scenarios ─────────────────────────────────────────────────
# Scenarios are CrowdSec collections that detect specific attack patterns.
# Day 4 adds explicit scenario management beyond the core collections.

_mb_crowdsec_configure_scenarios() {
    mb_info "Configuring CrowdSec scenarios..."

    # Refresh hub so scenario installs resolve
    cscli hub update >/dev/null 2>&1 || true

    local scenario
    for scenario in "${MB_CROWDSEC_SCENARIOS[@]}"; do
        _mb_crowdsec_enable_scenario "$scenario"
    done

    mb_detail "Scenarios configured: ${MB_CROWDSEC_SCENARIOS[*]}"
}

# _mb_crowdsec_enable_scenario <scenario-id>
# Installs a CrowdSec collection (scenario) if not already present.
_mb_crowdsec_enable_scenario() {
    local scenario="$1"
    if ! cscli collections list -o raw 2>/dev/null | grep -q "$scenario"; then
        if cscli collections install "$scenario" >/dev/null 2>&1; then
            mb_detail "Enabled scenario: $scenario"
        else
            mb_warn "Could not install scenario: $scenario (may require hub update)"
        fi
    else
        mb_detail "Scenario already enabled: $scenario"
    fi
}

# _mb_crowdsec_disable_scenario <scenario-id>
# Removes a CrowdSec collection (scenario) if present.
_mb_crowdsec_disable_scenario() {
    local scenario="$1"
    if cscli collections list -o raw 2>/dev/null | grep -q "$scenario"; then
        cscli collections remove "$scenario" >/dev/null 2>&1 && \
            mb_detail "Disabled scenario: $scenario"
    else
        mb_detail "Scenario not present: $scenario"
    fi
}

# ── Bouncer installation ─────────────────────────────────────────────────────

_mb_crowdsec_install_bouncer() {
    mb_info "Installing CrowdSec bouncer..."

    # Determine which bouncer backend to deploy.
    # Default: firewall (nftables). nginx/cloudflare are opt-in via env vars
    # MB_CROWDSEC_BOUNCER=nginx|cloudflare or detected services.
    local backend="${MB_CROWDSEC_BOUNCER:-firewall}"

    case "$backend" in
        firewall)  _mb_crowdsec_install_firewall_bouncer ;;
        nginx)     _mb_crowdsec_install_nginx_bouncer ;;
        cloudflare) _mb_crowdsec_install_cloudflare_bouncer ;;
        *)
            mb_warn "Unknown bouncer backend '$backend', falling back to firewall"
            _mb_crowdsec_install_firewall_bouncer
            ;;
    esac

    # Bouncer status check
    _mb_crowdsec_bouncer_status
}

_mb_crowdsec_install_firewall_bouncer() {
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

# _mb_crowdsec_install_nginx_bouncer
# Installs the CrowdSec nginx bouncer for in-app HTTP remediation.
_mb_crowdsec_install_nginx_bouncer() {
    if ! mb_check_command nginx; then
        mb_warn "nginx not detected; skipping nginx bouncer (install firewall bouncer instead)"
        _mb_crowdsec_install_firewall_bouncer
        return 0
    fi

    if cscli bouncers list -o raw 2>/dev/null | grep -q "mb-nginx-bouncer"; then
        mb_detail "nginx bouncer already installed"
        return 0
    fi

    mb_info "Installing CrowdSec nginx bouncer..."
    case "$MB_OS_FAMILY" in
        debian)
            if ! mb_check_package crowdsec-nginx-bouncer; then
                mb_pkg_install crowdsec-nginx-bouncer
            fi
            ;;
        alpine)
            curl -fsSL https://raw.githubusercontent.com/crowdsecurity/cs-nginx-bouncer/main/install.sh \
                | bash -s -- 2>/dev/null || \
                mb_warn "nginx bouncer install script failed. Manual install may be needed."
            ;;
        *)
            mb_warn "nginx bouncer install not supported for OS: $MB_OS_FAMILY"
            _mb_crowdsec_install_firewall_bouncer
            return 0
            ;;
    esac

    mb_service_restart nginx 2>/dev/null || true
    mb_detail "nginx bouncer installed"
}

# _mb_crowdsec_install_cloudflare_bouncer
# Installs the CrowdSec Cloudflare bouncer. Requires a Cloudflare API token
# supplied via MB_CLOUDFLARE_API_TOKEN (and optionally MB_CLOUDFLARE_ACCOUNT_ID).
_mb_crowdsec_install_cloudflare_bouncer() {
    local cf_token="${MB_CLOUDFLARE_API_TOKEN:-}"

    if [ -z "$cf_token" ]; then
        mb_warn "MB_CLOUDFLARE_API_TOKEN not set; cannot configure Cloudflare bouncer."
        mb_warn "Falling back to firewall bouncer. Set MB_CLOUDFLARE_API_TOKEN to enable Cloudflare."
        _mb_crowdsec_install_firewall_bouncer
        return 0
    fi

    if cscli bouncers list -o raw 2>/dev/null | grep -q "mb-cloudflare-bouncer"; then
        mb_detail "Cloudflare bouncer already installed"
        return 0
    fi

    mb_info "Installing CrowdSec Cloudflare bouncer..."
    # Cloudflare bouncer is distributed as a binary; use the official installer.
    curl -fsSL https://raw.githubusercontent.com/crowdsecurity/cs-cloudflare-bouncer/main/install.sh \
        | bash -s -- 2>/dev/null || {
            mb_warn "Cloudflare bouncer install script failed. Falling back to firewall bouncer."
            _mb_crowdsec_install_firewall_bouncer
            return 0
        }

    # Write Cloudflare bouncer config with the supplied token.
    local cf_conf="/etc/crowdsec/bouncers/crowdsec-cloudflare-bouncer.yaml"
    if [ -f "$cf_conf" ]; then
        mb_backup_file "$cf_conf" crowdsec 2>/dev/null || true
        if ! grep -q "api_token" "$cf_conf" 2>/dev/null; then
            {
                echo "cloudflare_config:"
                echo "  api_token: \"${cf_token}\""
                if [ -n "${MB_CLOUDFLARE_ACCOUNT_ID:-}" ]; then
                    echo "  account_id: \"${MB_CLOUDFLARE_ACCOUNT_ID}\""
                fi
            } >> "$cf_conf"
        fi
        mb_detail "Cloudflare bouncer configured with API token"
    fi

    mb_service_restart crowdsec-cloudflare-bouncer 2>/dev/null || true
    mb_detail "Cloudflare bouncer installed"
}

# _mb_crowdsec_bouncer_status
# Reports the status of all registered bouncers.
_mb_crowdsec_bouncer_status() {
    mb_info "Bouncer status:"

    if ! mb_check_command cscli; then
        mb_warn "cscli not available; cannot check bouncer status"
        return 0
    fi

    local raw
    raw=$(cscli bouncers list -o raw 2>/dev/null || echo "")

    local backend
    for backend in "${MB_CROWDSEC_BOUNCERS[@]}"; do
        if echo "$raw" | grep -qi "$backend"; then
            mb_detail "  ${backend}: present"
        else
            mb_detail "  ${backend}: not configured"
        fi
    done
}

# ── auditd integration ───────────────────────────────────────────────────────
# Feeds auditd logs into CrowdSec as an acquisition source. When auditd.sh
# (Day 3) detects privileged-command abuse or file-integrity violations, the
# resulting /var/log/audit/audit.log entries become CrowdSec input, allowing
# CrowdSec scenarios to issue decisions against offending source IPs.

_mb_crowdsec_integrate_auditd() {
    mb_info "Integrating auditd log source with CrowdSec..."

    # Only configure if auditd log actually exists (auditd.sh was run).
    if [ ! -f /var/log/audit/audit.log ]; then
        mb_detail "auditd log not present yet (run 'mb init --module auditd'). Skipping acquisition config."
        return 0
    fi

    if [ ! -f "$MB_CROWDSEC_ACQUIS_FILE" ]; then
        mb_detail "CrowdSec acquis.yaml not found; skipping auditd integration"
        return 0
    fi

    # Idempotent: only append the auditd source if not already present.
    if grep -q "auditd-audit-log" "$MB_CROWDSEC_ACQUIS_FILE" 2>/dev/null; then
        mb_detail "auditd acquisition source already configured"
        return 0
    fi

    mb_backup_file "$MB_CROWDSEC_ACQUIS_FILE" crowdsec 2>/dev/null || true

    {
        echo ""
        echo "# ── auditd log acquisition (added by mb crowdsec module) ──"
        echo "# Feeds privileged-command and file-integrity audit events"
        echo "# from modules/auditd.sh into CrowdSec for correlation/decisions."
        echo "filenames:"
        echo "  - /var/log/audit/audit.log"
        echo "labels:"
        echo "  type: auditd"
        echo "  source: mb-auditd-module"
    } >> "$MB_CROWDSEC_ACQUIS_FILE"

    # Reload CrowdSec so it picks up the new acquisition source.
    mb_service_restart crowdsec 2>/dev/null || true
    mb_detail "auditd log acquisition added to CrowdSec"
}

# ── Alert integration ────────────────────────────────────────────────────────
# Deploys notification config templates for email and webhook alerts.
# These are best-effort: CrowdSec notification plugins must be installed via
# cscli notifications install; we only write the config templates.

_mb_crowdsec_configure_alerts() {
    mb_info "Configuring CrowdSec alert notifications..."

    mkdir -p "$MB_CROWDSEC_NOTIFICATIONS_DIR" 2>/dev/null || true

    # Email notification template (postfix or msmtp).
    # Enabled when MB_CROWDSEC_ALERT_EMAIL is set to a recipient address.
    local email_to="${MB_CROWDSEC_ALERT_EMAIL:-}"
    if [ -n "$email_to" ]; then
        _mb_crowdsec_configure_email_alert "$email_to"
    else
        mb_detail "Email alert skipped (set MB_CROWDSEC_ALERT_EMAIL=you@example.com to enable)"
    fi

    # Webhook notification template (Discord/Slack/custom URL).
    # Enabled when MB_CROWDSEC_ALERT_WEBHOOK is set to a URL.
    local webhook_url="${MB_CROWDSEC_ALERT_WEBHOOK:-}"
    if [ -n "$webhook_url" ]; then
        _mb_crowdsec_configure_webhook_alert "$webhook_url"
    else
        mb_detail "Webhook alert skipped (set MB_CROWDSEC_ALERT_WEBHOOK=https://... to enable)"
    fi
}

# _mb_crowdsec_configure_email_alert <recipient>
# Writes an email notification config template. Uses CrowdSec's built-in
# email plugin; requires a working MTA (postfix or msmtp) on the host.
_mb_crowdsec_configure_email_alert() {
    local recipient="$1"
    local cfg="${MB_CROWDSEC_NOTIFICATIONS_DIR}/email.yaml"

    # Install the email notification plugin if available.
    cscli notifications install crowdsecurity/email 2>/dev/null || true

    cat > "$cfg" <<EOF
# CrowdSec email notification (managed by mb crowdsec module)
# Requires a working MTA (postfix or msmtp) on the host.
type: email
name: mb-email-alert
format: |
  CrowdSec alert on \$(hostname)
  Alert: {{.Alert.Message}}
  Source IPs: {{.Alert.Source.IP}}
  Scenario: {{.Alert.Scenario}}
  Decisions: {{.Decisions}}
api_config:
  smtp_host: 127.0.0.1
  smtp_port: 25
  sender: crowdsec@$(hostname 2>/dev/null || echo localhost)
  recipients:
    - ${recipient}
EOF

    # Register the notification with cscli so it becomes active.
    cscli notifications add mb-email-alert -f "$cfg" >/dev/null 2>&1 || true
    mb_detail "Email alert configured → ${recipient}"
}

# _mb_crowdsec_configure_webhook_alert <url>
# Writes an HTTP webhook notification config template. Works with Discord,
# Slack, or any custom webhook URL.
_mb_crowdsec_configure_webhook_alert() {
    local url="$1"
    local cfg="${MB_CROWDSEC_NOTIFICATIONS_DIR}/http.yaml"

    # Install the http notification plugin if available.
    cscli notifications install crowdsecurity/http 2>/dev/null || true

    # Build a JSON payload template suitable for Discord/Slack-style webhooks.
    cat > "$cfg" <<EOF
# CrowdSec webhook notification (managed by mb crowdsec module)
# Works with Discord, Slack, or any custom HTTP webhook.
type: http
name: mb-webhook-alert
format: |
  {
    "text": "CrowdSec alert on $(hostname 2>/dev/null || echo host): {{.Alert.Message}} (source: {{.Alert.Source.IP}}, scenario: {{.Alert.Scenario}})"
  }
api_config:
  url: ${url}
  method: POST
  headers:
    Content-Type: application/json
EOF

    cscli notifications add mb-webhook-alert -f "$cfg" >/dev/null 2>&1 || true
    mb_detail "Webhook alert configured → ${url}"
}

# ── Whitelist ────────────────────────────────────────────────────────────────

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

# ── Verify ───────────────────────────────────────────────────────────────────

_mb_crowdsec_verify() {
    mb_info "Verifying CrowdSec..."

    if ! mb_service_status "$MB_CROWDSEC_SVC_NAME" | grep -q active; then
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

# ── Audit check helpers ───────────────────────────────────────────────────────

# _mb_crowdsec_check <desc> <status> <report_file>
# Prints a colored status row and appends a plain-text line to the report.
_mb_crowdsec_check() {
    local desc="$1" status="$2" report_file="$3"
    local color=""
    case "$status" in
        PASS) color="$C_OK" ;;
        FAIL) color="$C_FAIL" ;;
        WARN) color="$C_WARN" ;;
        N/A)  color="$C_INFO" ;;
    esac
    _MB_CROWDSEC_LAST_STATUS="$status"
    printf "  %-40s ${color}%s${C_RST}\n" "$desc" "$status"
    printf "  %-40s %s\n" "$desc" "$status" >> "$report_file"
}

# _mb_crowdsec_tally <pass_var> <fail_var> <warn_var>
# Increments the named tally variable based on the last printed status.
# Uses namerefs (bash 4.3+) to update the caller's counters.
_mb_crowdsec_tally() {
    local -n _c_pass="$1"
    local -n _c_fail="$2"
    local -n _c_warn="$3"
    case "${_MB_CROWDSEC_LAST_STATUS:-}" in
        PASS) _c_pass=$((_c_pass + 1)) ;;
        FAIL) _c_fail=$((_c_fail + 1)) ;;
        WARN) _c_warn=$((_c_warn + 1)) ;;
    esac
}

# ── Direct invocation support ─────────────────────────────────────────────────
# When executed directly (not sourced by mb), wire up mb helpers and dispatch.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _MB_CROWDSEC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/common.sh
    source "${_MB_CROWDSEC_SCRIPT_DIR}/../lib/common.sh"
    # shellcheck source=lib/os.sh
    source "${_MB_CROWDSEC_SCRIPT_DIR}/../lib/os.sh"
    mb_detect_os

    _mb_crowdsec_usage() {
        cat <<'USAGE'
Usage: modules/crowdsec.sh <command>

Commands:
  install               Install CrowdSec, collections, scenarios, bouncer, alerts
  audit                 Read-only status check (writes report to /var/log/crowdsec-audit/)
  --enable-scenario ID  Enable a specific CrowdSec scenario (collection)
  --disable-scenario ID Disable a specific CrowdSec scenario (collection)
  --install-bouncer BK  Install a bouncer backend: firewall, nginx, cloudflare
  --bouncer-status      Show status of all configured bouncers
  --integrate-auditd    Add auditd log acquisition source to CrowdSec
  --configure-alerts    Deploy email/webhook notification config templates
  list-scenarios        List managed scenarios
  help                  Show this help

Scenarios:
  crowdsecurity/ssh-slow-bf            SSH slow brute-force detection
  crowdsecurity/http-crawl-non_statics Web crawler / non-static scan detection
  crowdsecurity/tcp-scan-multi_ports   TCP multi-port scan detection

Bouncers:
  firewall    nftables/iptables firewall bouncer (default)
  nginx       CrowdSec nginx bouncer (in-app HTTP remediation)
  cloudflare  CrowdSec Cloudflare bouncer (requires MB_CLOUDFLARE_API_TOKEN)

Alerts (set via environment before install):
  MB_CROWDSEC_ALERT_EMAIL=you@example.com        Enable email notification
  MB_CROWDSEC_ALERT_WEBHOOK=https://hook.example  Enable webhook notification
  MB_CROWDSEC_BOUNCER=nginx|cloudflare           Select bouncer backend
  MB_CLOUDFLARE_API_TOKEN=...                    Cloudflare bouncer token
USAGE
    }

    case "${1:-help}" in
        install)
            mb_check_root
            mb_module_crowdsec
            ;;
        audit)
            mb_module_crowdsec_audit
            ;;
        --enable-scenario)
            [ -z "${2:-}" ] && { echo "Error: scenario id required" >&2; exit 1; }
            mb_check_root
            _mb_crowdsec_enable_scenario "$2"
            mb_success "Scenario '$2' enabled"
            ;;
        --disable-scenario)
            [ -z "${2:-}" ] && { echo "Error: scenario id required" >&2; exit 1; }
            mb_check_root
            _mb_crowdsec_disable_scenario "$2"
            mb_success "Scenario '$2' disabled"
            ;;
        --install-bouncer)
            [ -z "${2:-}" ] && { echo "Error: bouncer backend required" >&2; exit 1; }
            mb_check_root
            case "$2" in
                firewall)  _mb_crowdsec_install_firewall_bouncer ;;
                nginx)     _mb_crowdsec_install_nginx_bouncer ;;
                cloudflare) _mb_crowdsec_install_cloudflare_bouncer ;;
                *) echo "Error: unknown bouncer '$2' (firewall|nginx|cloudflare)" >&2; exit 1 ;;
            esac
            _mb_crowdsec_bouncer_status
            mb_success "Bouncer '$2' installed"
            ;;
        --bouncer-status)
            _mb_crowdsec_bouncer_status
            ;;
        --integrate-auditd)
            mb_check_root
            _mb_crowdsec_integrate_auditd
            mb_success "auditd integration configured"
            ;;
        --configure-alerts)
            mb_check_root
            _mb_crowdsec_configure_alerts
            mb_success "Alerts configured"
            ;;
        list-scenarios)
            echo "Managed scenarios:"
            for _s in "${MB_CROWDSEC_SCENARIOS[@]}"; do
                echo "  $_s"
            done
            ;;
        help|-h|--help)
            _mb_crowdsec_usage
            ;;
        *)
            echo "Unknown command: $1" >&2
            _mb_crowdsec_usage
            exit 1
            ;;
    esac
fi
