#!/usr/bin/env bash
# modules/auto_updates.sh — Automatic security updates installation, configuration, and audit
#
# Configures unattended security updates so the server receives critical patches
# automatically without manual intervention. Supports Debian/Ubuntu (unattended-
# upgrades), RHEL/CentOS (dnf-automatic), and Alpine (apk + cron).
#
# Features:
#   - Debian/Ubuntu: install unattended-upgrades + apt-listchanges, configure
#     50unattended-upgrades (security-only, auto-reboot, email notification)
#   - RHEL/CentOS: configure dnf-automatic (security updates only)
#   - Alpine: configure apk autoupdate script + cron
#   - Create /etc/apt/apt.conf.d/20auto-upgrades (Auto-Upgrade "1")
#   - Configure email notification (postfix/msmtp if present)
#   - Read-only audit mode (mb_module_auto_updates_audit): checks install status,
#     config files, timer/service state, recent update logs, reboot-required.
#     Writes a TXT report to /var/log/auto-updates-audit/. Does not modify system.
#   - Config management: --enable-reboot, --disable-reboot, --set-email,
#     --enable-security-only, --enable-all-updates
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

MB_AUTO_UPDATES_REPORT_DIR="/var/log/auto-updates-audit"
MB_AUTO_UPDATES_UNATTENDED_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
MB_AUTO_UPDATES_AUTO_CONF="/etc/apt/apt.conf.d/20auto-upgrades"
MB_AUTO_UPDATES_DNF_CONF="/etc/dnf/automatic.conf"
MB_AUTO_UPDATES_SVC_NAME="unattended-upgrades"

# ── Main module function (install / deploy mode) ─────────────────────────────

mb_module_auto_updates() {
    mb_step "Automatic security updates setup"

    case "${MB_OS_FAMILY:-}" in
        debian) _mb_auto_updates_debian ;;
        rhel)   _mb_auto_updates_rhel ;;
        alpine) _mb_auto_updates_alpine ;;
        *)
            mb_warn "Auto-updates not formally supported for OS: ${MB_OS_FAMILY:-unknown}"
            mb_die "Auto-updates not supported for OS: ${MB_OS_FAMILY:-unknown}"
            ;;
    esac

    mb_mark_done auto_updates
    mb_success "Automatic security updates configured"
}

# ── Read-only audit function ─────────────────────────────────────────────────

mb_module_auto_updates_audit() {
    mb_step "Automatic security updates audit (read-only)"

    local pass_count=0
    local fail_count=0
    local warn_count=0
    local timestamp report_file
    timestamp=$(date '+%Y%m%d-%H%M%S')
    report_file="${MB_AUTO_UPDATES_REPORT_DIR}/auto-updates-audit-${timestamp}.txt"
    mkdir -p "$MB_AUTO_UPDATES_REPORT_DIR" 2>/dev/null || true

    {
        echo "Automatic Security Updates Audit Report"
        echo "========================================="
        echo "Date: $(date)"
        echo "Host: $(hostname 2>/dev/null)"
        echo "OS: ${PRETTY_NAME:-unknown}"
        echo ""
    } > "$report_file"

    echo ""
    printf "  %-45s %s\n" "CHECK" "STATUS"
    printf "  %-45s %s\n" "---------------------------------------------" "--------"

    # ── OS-specific audit ───────────────────────────────────────────────────
    case "${MB_OS_FAMILY:-}" in
        debian) _mb_auto_updates_audit_debian "$report_file" pass_count fail_count warn_count ;;
        rhel)   _mb_auto_updates_audit_rhel "$report_file" pass_count fail_count warn_count ;;
        alpine) _mb_auto_updates_audit_alpine "$report_file" pass_count fail_count warn_count ;;
        *)
            _mb_auto_updates_check "OS family supported" "FAIL" "$report_file"
            _mb_auto_updates_tally pass_count fail_count warn_count
            ;;
    esac

    # ── Reboot required check (common to all OS) ─────────────────────────────
    local reboot_status="PASS"
    if [ -f /var/run/reboot-required ]; then
        reboot_status="WARN"
    fi
    _mb_auto_updates_check "No pending reboot required" "$reboot_status" "$report_file"
    _mb_auto_updates_tally pass_count fail_count warn_count

    if [ -f /var/run/reboot-required ]; then
        local reboot_pkgs
        reboot_pkgs=$(cat /var/run/reboot-required.pkgs 2>/dev/null || echo "unknown")
        _mb_auto_updates_check "Reboot required by: ${reboot_pkgs}" "N/A" "$report_file"
        _mb_auto_updates_tally pass_count fail_count warn_count
    fi

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    mb_step "Auto-updates audit summary"
    echo "  PASS:  ${pass_count}"
    echo "  WARN:  ${warn_count}"
    echo "  FAIL:  ${fail_count}"
    echo ""

    {
        echo ""
        echo "Summary: PASS=${pass_count} WARN=${warn_count} FAIL=${fail_count}"
    } >> "$report_file"

    if [ "$fail_count" -gt 0 ]; then
        mb_warn "${fail_count} check(s) failed. Deploy with 'mb init --module auto_updates'."
    else
        mb_success "Auto-updates core checks passed (warn=${warn_count} optional items)."
    fi
    mb_detail "Report written to: ${report_file}"

    mb_mark_done auto_updates
    mb_success "Auto-updates audit complete (pass=${pass_count} warn=${warn_count} fail=${fail_count})"
}

# ── Debian/Ubuntu install ────────────────────────────────────────────────────

_mb_auto_updates_debian() {
    mb_info "Configuring unattended-upgrades (Debian/Ubuntu)..."

    mb_pkg_install unattended-upgrades apt-listchanges

    mb_backup_file "$MB_AUTO_UPDATES_UNATTENDED_CONF" auto_updates
    mb_backup_file "$MB_AUTO_UPDATES_AUTO_CONF" auto_updates

    # Create 20auto-upgrades
    {
        echo 'APT::Periodic::Update-Package-Lists "1";'
        echo 'APT::Periodic::Download-Upgradeable-Packages "1";'
        echo 'APT::Periodic::AutocleanInterval "7";'
        echo 'APT::Periodic::Unattended-Upgrade "1";'
    } > "$MB_AUTO_UPDATES_AUTO_CONF"
    mb_detail "Created ${MB_AUTO_UPDATES_AUTO_CONF}"

    # Configure 50unattended-upgrades — security-only by default
    local auto_reboot="${MB_CONFIG_AUTO_REBOOT:-false}"
    local update_email="${MB_CONFIG_UPDATE_EMAIL:-}"

    _mb_auto_updates_write_unattended_conf "$auto_reboot" "$update_email" "security"

    # Enable systemd timers
    if mb_check_command systemctl; then
        systemctl start apt-daily.timer 2>/dev/null || true
        systemctl start apt-daily-upgrade.timer 2>/dev/null || true
        systemctl enable apt-daily.timer 2>/dev/null || true
        systemctl enable apt-daily-upgrade.timer 2>/dev/null || true
    fi

    mb_service_enable "$MB_AUTO_UPDATES_SVC_NAME"

    # Configure email notification if MTA is present
    _mb_auto_updates_configure_email "$update_email"

    mb_detail "Security-only auto-updates configured (Docker packages excluded)"
}

_mb_auto_updates_write_unattended_conf() {
    local auto_reboot="$1"
    local update_email="$2"
    local update_mode="$3"

    {
        echo '// mb auto-update config — generated '"$(date)"
        echo 'Unattended-Upgrade::Allowed-Origins {'
        if [ "$update_mode" = "all" ]; then
            echo '    "${distro_id}:${distro_codename}-security";'
            echo '    "${distro_id}:${distro_codename}-updates";'
            echo '    "${distro_id}:${distro_codename}-proposed-updates";'
        else
            echo '    "${distro_id}:${distro_codename}-security";'
        fi
        echo '};'
        echo ''
        echo 'Unattended-Upgrade::Package-Blacklist {'
        echo '    "docker-ce";'
        echo '    "docker-ce-cli";'
        echo '    "containerd.io";'
        echo '};'
        echo ''
        echo 'Unattended-Upgrade::AutoFixInterruptedDpkg "true";'
        echo 'Unattended-Upgrade::MinimalSteps "true";'
        echo 'Unattended-Upgrade::InstallOnShutdown "false";'
        echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";'
        echo 'Unattended-Upgrade::Remove-New-Unused-Dependencies "true";'
        echo ''
        if [ "$auto_reboot" = "true" ]; then
            echo 'Unattended-Upgrade::Automatic-Reboot "true";'
            echo 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";'
            mb_detail "Auto-reboot: enabled (at 04:00)"
        else
            echo 'Unattended-Upgrade::Automatic-Reboot "false";'
            mb_detail "Auto-reboot: disabled"
        fi
        echo ''
        if [ -n "$update_email" ]; then
            echo "Unattended-Upgrade::Mail \"${update_email}\";"
            echo 'Unattended-Upgrade::MailReport "on-change";'
            mb_detail "Email notification: ${update_email}"
        else
            echo 'Unattended-Upgrade::Mail "root";'
            echo 'Unattended-Upgrade::MailReport "on-change";'
        fi
    } > "$MB_AUTO_UPDATES_UNATTENDED_CONF"
}

_mb_auto_updates_configure_email() {
    local email="$1"
    if [ -z "$email" ]; then
        return 0
    fi

    # Check if postfix or msmtp is installed
    if mb_check_command postfix; then
        mb_detail "Email notifications via postfix to ${email}"
    elif mb_check_command msmtp; then
        mb_detail "Email notifications via msmtp to ${email}"
    else
        mb_warn "No MTA (postfix/msmtp) found; email notifications may not be delivered to ${email}"
    fi
}

# ── RHEL/CentOS install ──────────────────────────────────────────────────────

_mb_auto_updates_rhel() {
    mb_info "Configuring dnf-automatic (RHEL/CentOS)..."

    mb_pkg_install dnf-automatic

    local dnf_conf="$MB_AUTO_UPDATES_DNF_CONF"
    if [ -f "$dnf_conf" ]; then
        mb_backup_file "$dnf_conf" auto_updates
    fi

    # Configure dnf-automatic for security updates only
    {
        echo '[commands]'
        echo 'upgrade_type = security'
        echo 'download_updates = yes'
        echo 'apply_updates = yes'
        echo 'random_sleep = 300'
        echo ''
        echo '[emitters]'
        echo 'emit_via = stdio'
        echo 'system_name = mb-auto-updates'
        echo ''
        if [ -n "${MB_CONFIG_UPDATE_EMAIL:-}" ]; then
            echo '[email]'
            echo "email_from = root@$(hostname 2>/dev/null || echo localhost)"
            echo "email_to = ${MB_CONFIG_UPDATE_EMAIL}"
            echo "email_host = localhost"
            echo 'emit_via = email'
        fi
    } > "$dnf_conf"
    mb_detail "Created ${dnf_conf} (security updates only)"

    # Enable and start the timer
    if mb_check_command systemctl; then
        systemctl enable dnf-automatic.timer 2>/dev/null || true
        systemctl start dnf-automatic.timer 2>/dev/null || true
    fi

    mb_detail "dnf-automatic timer enabled (security updates only)"
}

# ── Alpine install ───────────────────────────────────────────────────────────

_mb_auto_updates_alpine() {
    mb_info "Configuring apk autoupdate (Alpine)..."

    mb_pkg_install dcron

    local cron_file="/etc/crontabs/root"
    mb_backup_file "$cron_file" auto_updates

    # Create autoupdate script
    local autoupdate_script="/usr/local/bin/mb-autoupdate.sh"
    {
        echo '#!/bin/sh'
        echo '# mb-autoupdate.sh — Alpine security update script'
        echo '# Generated by mb auto_updates module'
        echo 'set -e'
        echo ''
        echo '/sbin/apk update --quiet'
        echo '/sbin/apk upgrade --available --quiet 2>&1 || true'
        echo ''
        echo '# Check if reboot is needed'
        echo 'if [ -f /sbin/apk ] && /sbin/apk info -e alpine-base 2>/dev/null | grep -q "alpine-base"; then'
        echo '    if [ "$(apk version -c 2>/dev/null | head -1)" != "$(uname -r)" ]; then'
        echo '        touch /var/run/reboot-required 2>/dev/null || true'
        echo '    fi'
        echo 'fi'
        echo ''
        echo 'logger -t mb-autoupdate "Security update completed at $(date)"'
    } > "$autoupdate_script"
    chmod +x "$autoupdate_script"
    mb_detail "Created ${autoupdate_script}"

    # Add cron job if not already present
    if ! grep -q "mb-autoupdate" "$cron_file" 2>/dev/null; then
        {
            echo ""
            echo "# mb security update — daily at 04:00"
            echo "0 4 * * * ${autoupdate_script} 2>&1 | logger -t mb-autoupdate"
        } >> "$cron_file"
        mb_detail "Daily security update cron job added (04:00)"
    else
        mb_detail "Security update cron job already present"
    fi

    mb_service_enable dcron
    mb_service_restart dcron 2>/dev/null || true
}

# ── Debian/Ubuntu audit ──────────────────────────────────────────────────────

_mb_auto_updates_audit_debian() {
    local report_file="$1"
    local -n _ad_pass="$2"
    local -n _ad_fail="$3"
    local -n _ad_warn="$4"

    # ── unattended-upgrades installed ───────────────────────────────────────
    local pkg_status="FAIL"
    if mb_check_command unattended-upgrades; then
        pkg_status="PASS"
    elif dpkg -s unattended-upgrades >/dev/null 2>&1; then
        pkg_status="PASS"
    fi
    _mb_auto_updates_check "unattended-upgrades package installed" "$pkg_status" "$report_file"
    _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn

    if [ "$pkg_status" = "FAIL" ]; then
        echo ""
        mb_warn "unattended-upgrades not installed. Run 'mb init --module auto_updates'."
        {
            echo ""
            echo "unattended-upgrades not installed; remaining checks skipped."
        } >> "$report_file"
        return 0
    fi

    # ── 20auto-upgrades config ──────────────────────────────────────────────
    local auto_conf_status="FAIL"
    if [ -f "$MB_AUTO_UPDATES_AUTO_CONF" ] && \
       grep -q 'APT::Periodic::Unattended-Upgrade "1"' "$MB_AUTO_UPDATES_AUTO_CONF" 2>/dev/null; then
        auto_conf_status="PASS"
    fi
    _mb_auto_updates_check "20auto-upgrades: Unattended-Upgrade enabled" "$auto_conf_status" "$report_file"
    _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn

    # ── 50unattended-upgrades: allowed origins ──────────────────────────────
    local origins_status="FAIL"
    if [ -f "$MB_AUTO_UPDATES_UNATTENDED_CONF" ] && \
       grep -q 'Allowed-Origins' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null; then
        origins_status="PASS"
    fi
    _mb_auto_updates_check "50unattended-upgrades: Allowed-Origins configured" "$origins_status" "$report_file"
    _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn

    # ── Security-only updates ───────────────────────────────────────────────
    local security_only="FAIL"
    if [ -f "$MB_AUTO_UPDATES_UNATTENDED_CONF" ]; then
        local security_lines
        security_lines=$(grep -c '\-security"' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null || echo "0")
        local updates_lines
        updates_lines=$(grep -c '\-updates"' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null || echo "0")
        if [ "${security_lines:-0}" -gt 0 ] && [ "${updates_lines:-0}" -eq 0 ]; then
            security_only="PASS"
        elif [ "${security_lines:-0}" -gt 0 ] && [ "${updates_lines:-0}" -gt 0 ]; then
            security_only="WARN"
        fi
    fi
    _mb_auto_updates_check "Security-only updates (no -updates origin)" "$security_only" "$report_file"
    _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn

    # ── Auto-reboot setting ─────────────────────────────────────────────────
    local reboot_status="N/A"
    if [ -f "$MB_AUTO_UPDATES_UNATTENDED_CONF" ]; then
        if grep -q 'Automatic-Reboot "true"' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null; then
            reboot_status="PASS"
        elif grep -q 'Automatic-Reboot "false"' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null; then
            reboot_status="WARN"
        fi
    fi
    _mb_auto_updates_check "Automatic-Reboot configured" "$reboot_status" "$report_file"
    _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn

    # ── Email notification ──────────────────────────────────────────────────
    local email_status="WARN"
    if [ -f "$MB_AUTO_UPDATES_UNATTENDED_CONF" ]; then
        local mail_line
        mail_line=$(grep 'Unattended-Upgrade::Mail' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null | head -1 || echo "")
        if [ -n "$mail_line" ] && ! echo "$mail_line" | grep -q '""'; then
            email_status="PASS"
        fi
    fi
    _mb_auto_updates_check "Email notification configured" "$email_status" "$report_file"
    _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn

    # ── Timer/service status ────────────────────────────────────────────────
    local timer_status="FAIL"
    if mb_check_command systemctl; then
        if systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; then
            timer_status="PASS"
        fi
    fi
    _mb_auto_updates_check "apt-daily-upgrade.timer enabled" "$timer_status" "$report_file"
    _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn

    local svc_status="FAIL"
    if mb_check_command systemctl; then
        if systemctl is-active apt-daily-upgrade.timer >/dev/null 2>&1; then
            svc_status="PASS"
        fi
    fi
    _mb_auto_updates_check "apt-daily-upgrade.timer active" "$svc_status" "$report_file"
    _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn

    # ── Recent update logs ──────────────────────────────────────────────────
    local log_dir="/var/log/unattended-upgrades"
    if [ -d "$log_dir" ]; then
        local log_count
        log_count=$(ls "$log_dir"/*.log 2>/dev/null | wc -l || echo "0")
        if [ "${log_count:-0}" -gt 0 ]; then
            local latest_log
            latest_log=$(ls -t "$log_dir"/*.log 2>/dev/null | head -1 || echo "")
            local latest_date
            latest_date=$(stat -c '%y' "$latest_log" 2>/dev/null | cut -d. -f1 || echo "unknown")
            _mb_auto_updates_check "Update logs: ${log_count} file(s), latest: ${latest_date}" "N/A" "$report_file"
            _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn
        else
            _mb_auto_updates_check "No unattended-upgrades log files found" "WARN" "$report_file"
            _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn
        fi
    else
        _mb_auto_updates_check "No unattended-upgrades log directory" "WARN" "$report_file"
        _mb_auto_updates_tally _ad_pass _ad_fail _ad_warn
    fi
}

# ── RHEL/CentOS audit ────────────────────────────────────────────────────────

_mb_auto_updates_audit_rhel() {
    local report_file="$1"
    local -n _ar_pass="$2"
    local -n _ar_fail="$3"
    local -n _ar_warn="$4"

    # ── dnf-automatic installed ─────────────────────────────────────────────
    local pkg_status="FAIL"
    if mb_check_command dnf-automatic; then
        pkg_status="PASS"
    elif rpm -q dnf-automatic >/dev/null 2>&1; then
        pkg_status="PASS"
    fi
    _mb_auto_updates_check "dnf-automatic package installed" "$pkg_status" "$report_file"
    _mb_auto_updates_tally _ar_pass _ar_fail _ar_warn

    if [ "$pkg_status" = "FAIL" ]; then
        echo ""
        mb_warn "dnf-automatic not installed. Run 'mb init --module auto_updates'."
        return 0
    fi

    # ── dnf-automatic config ────────────────────────────────────────────────
    local conf_status="FAIL"
    if [ -f "$MB_AUTO_UPDATES_DNF_CONF" ] && \
       grep -q 'upgrade_type = security' "$MB_AUTO_UPDATES_DNF_CONF" 2>/dev/null; then
        conf_status="PASS"
    fi
    _mb_auto_updates_check "dnf-automatic: security-only updates" "$conf_status" "$report_file"
    _mb_auto_updates_tally _ar_pass _ar_fail _ar_warn

    local apply_status="FAIL"
    if [ -f "$MB_AUTO_UPDATES_DNF_CONF" ] && \
       grep -q 'apply_updates = yes' "$MB_AUTO_UPDATES_DNF_CONF" 2>/dev/null; then
        apply_status="PASS"
    fi
    _mb_auto_updates_check "dnf-automatic: apply_updates = yes" "$apply_status" "$report_file"
    _mb_auto_updates_tally _ar_pass _ar_fail _ar_warn

    # ── Timer status ────────────────────────────────────────────────────────
    local timer_status="FAIL"
    if mb_check_command systemctl; then
        if systemctl is-enabled dnf-automatic.timer >/dev/null 2>&1; then
            timer_status="PASS"
        fi
    fi
    _mb_auto_updates_check "dnf-automatic.timer enabled" "$timer_status" "$report_file"
    _mb_auto_updates_tally _ar_pass _ar_fail _ar_warn

    local svc_status="FAIL"
    if mb_check_command systemctl; then
        if systemctl is-active dnf-automatic.timer >/dev/null 2>&1; then
            svc_status="PASS"
        fi
    fi
    _mb_auto_updates_check "dnf-automatic.timer active" "$svc_status" "$report_file"
    _mb_auto_updates_tally _ar_pass _ar_fail _ar_warn
}

# ── Alpine audit ─────────────────────────────────────────────────────────────

_mb_auto_updates_audit_alpine() {
    local report_file="$1"
    local -n _al_pass="$2"
    local -n _al_fail="$3"
    local -n _al_warn="$4"

    # ── dcron installed ─────────────────────────────────────────────────────
    local cron_status="FAIL"
    if mb_check_command crond; then
        cron_status="PASS"
    elif apk info -e dcron >/dev/null 2>&1; then
        cron_status="PASS"
    fi
    _mb_auto_updates_check "dcron installed" "$cron_status" "$report_file"
    _mb_auto_updates_tally _al_pass _al_fail _al_warn

    if [ "$cron_status" = "FAIL" ]; then
        echo ""
        mb_warn "dcron not installed. Run 'mb init --module auto_updates'."
        return 0
    fi

    # ── Autoupdate script present ───────────────────────────────────────────
    local script_status="FAIL"
    if [ -f /usr/local/bin/mb-autoupdate.sh ] && [ -x /usr/local/bin/mb-autoupdate.sh ]; then
        script_status="PASS"
    fi
    _mb_auto_updates_check "Autoupdate script present and executable" "$script_status" "$report_file"
    _mb_auto_updates_tally _al_pass _al_fail _al_warn

    # ── Cron job configured ─────────────────────────────────────────────────
    local cron_job_status="FAIL"
    if [ -f /etc/crontabs/root ] && grep -q "mb-autoupdate" /etc/crontabs/root 2>/dev/null; then
        cron_job_status="PASS"
    fi
    _mb_auto_updates_check "Cron job for security updates configured" "$cron_job_status" "$report_file"
    _mb_auto_updates_tally _al_pass _al_fail _al_warn

    # ── dcron service active ────────────────────────────────────────────────
    local svc_status="FAIL"
    if mb_service_status dcron 2>/dev/null | grep -q active; then
        svc_status="PASS"
    fi
    _mb_auto_updates_check "dcron service active" "$svc_status" "$report_file"
    _mb_auto_updates_tally _al_pass _al_fail _al_warn
}

# ── Config management ─────────────────────────────────────────────────────────

# _mb_auto_updates_enable_reboot
# Enables automatic reboot in unattended-upgrades config.
_mb_auto_updates_enable_reboot() {
    if [ ! -f "$MB_AUTO_UPDATES_UNATTENDED_CONF" ]; then
        mb_die "Config file not found: ${MB_AUTO_UPDATES_UNATTENDED_CONF}. Run install first."
    fi
    mb_backup_file "$MB_AUTO_UPDATES_UNATTENDED_CONF" auto_updates
    if grep -q 'Automatic-Reboot' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null; then
        sed -i 's/Unattended-Upgrade::Automatic-Reboot "false"/Unattended-Upgrade::Automatic-Reboot "true"/' "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    else
        echo 'Unattended-Upgrade::Automatic-Reboot "true";' >> "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    fi
    if ! grep -q 'Automatic-Reboot-Time' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null; then
        echo 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' >> "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    fi
    mb_detail "Automatic reboot enabled (at 04:00)"
}

# _mb_auto_updates_disable_reboot
# Disables automatic reboot in unattended-upgrades config.
_mb_auto_updates_disable_reboot() {
    if [ ! -f "$MB_AUTO_UPDATES_UNATTENDED_CONF" ]; then
        mb_die "Config file not found: ${MB_AUTO_UPDATES_UNATTENDED_CONF}. Run install first."
    fi
    mb_backup_file "$MB_AUTO_UPDATES_UNATTENDED_CONF" auto_updates
    sed -i 's/Unattended-Upgrade::Automatic-Reboot "true"/Unattended-Upgrade::Automatic-Reboot "false"/' "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    mb_detail "Automatic reboot disabled"
}

# _mb_auto_updates_set_email <email>
# Sets the email notification address in unattended-upgrades config.
_mb_auto_updates_set_email() {
    local email="$1"
    if [ ! -f "$MB_AUTO_UPDATES_UNATTENDED_CONF" ]; then
        mb_die "Config file not found: ${MB_AUTO_UPDATES_UNATTENDED_CONF}. Run install first."
    fi
    mb_backup_file "$MB_AUTO_UPDATES_UNATTENDED_CONF" auto_updates
    if grep -q 'Unattended-Upgrade::Mail' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null; then
        sed -i "s|Unattended-Upgrade::Mail \".*\"|Unattended-Upgrade::Mail \"${email}\"|" "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    else
        echo "Unattended-Upgrade::Mail \"${email}\";" >> "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    fi
    if ! grep -q 'MailReport' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null; then
        echo 'Unattended-Upgrade::MailReport "on-change";' >> "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    fi
    mb_detail "Email notification set to: ${email}"
}

# _mb_auto_updates_enable_security_only
# Configures unattended-upgrades to only install security updates.
_mb_auto_updates_enable_security_only() {
    if [ ! -f "$MB_AUTO_UPDATES_UNATTENDED_CONF" ]; then
        mb_die "Config file not found: ${MB_AUTO_UPDATES_UNATTENDED_CONF}. Run install first."
    fi
    mb_backup_file "$MB_AUTO_UPDATES_UNATTENDED_CONF" auto_updates
    # Remove non-security origins
    sed -i '/${distro_id}:${distro_codename}-updates";/d' "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    sed -i '/${distro_id}:${distro_codename}-proposed-updates";/d' "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    mb_detail "Security-only updates enabled (non-security origins removed)"
}

# _mb_auto_updates_enable_all_updates
# Configures unattended-upgrades to install all updates (security + regular).
_mb_auto_updates_enable_all_updates() {
    if [ ! -f "$MB_AUTO_UPDATES_UNATTENDED_CONF" ]; then
        mb_die "Config file not found: ${MB_AUTO_UPDATES_UNATTENDED_CONF}. Run install first."
    fi
    mb_backup_file "$MB_AUTO_UPDATES_UNATTENDED_CONF" auto_updates
    # Add updates origin if not present
    if ! grep -q '${distro_id}:${distro_codename}-updates"' "$MB_AUTO_UPDATES_UNATTENDED_CONF" 2>/dev/null; then
        sed -i '/${distro_id}:${distro_codename}-security";/a\    "${distro_id}:${distro_codename}-updates";' "$MB_AUTO_UPDATES_UNATTENDED_CONF"
    fi
    mb_detail "All updates enabled (security + regular updates)"
}

# ── Audit check helpers ───────────────────────────────────────────────────────

# _mb_auto_updates_check <desc> <status> <report_file>
# Prints a colored status row and appends a plain-text line to the report.
_mb_auto_updates_check() {
    local desc="$1" status="$2" report_file="$3"
    local color=""
    case "$status" in
        PASS) color="$C_OK" ;;
        FAIL) color="$C_FAIL" ;;
        WARN) color="$C_WARN" ;;
        N/A)  color="$C_INFO" ;;
    esac
    _MB_AUTO_UPDATES_LAST_STATUS="$status"
    printf "  %-45s ${color}%s${C_RST}\n" "$desc" "$status"
    printf "  %-45s %s\n" "$desc" "$status" >> "$report_file"
}

# _mb_auto_updates_tally <pass_var> <fail_var> <warn_var>
# Increments the named tally variable based on the last printed status.
# Uses namerefs (bash 4.3+) to update the caller's counters.
_mb_auto_updates_tally() {
    local -n _u_pass="$1"
    local -n _u_fail="$2"
    local -n _u_warn="$3"
    case "${_MB_AUTO_UPDATES_LAST_STATUS:-}" in
        PASS) _u_pass=$((_u_pass + 1)) ;;
        FAIL) _u_fail=$((_u_fail + 1)) ;;
        WARN) _u_warn=$((_u_warn + 1)) ;;
    esac
}

# ── Direct invocation support ─────────────────────────────────────────────────
# When executed directly (not sourced by mb), wire up mb helpers and dispatch.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _MB_AUTO_UPDATES_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/common.sh
    source "${_MB_AUTO_UPDATES_SCRIPT_DIR}/../lib/common.sh"
    # shellcheck source=lib/os.sh
    source "${_MB_AUTO_UPDATES_SCRIPT_DIR}/../lib/os.sh"
    mb_detect_os

    _mb_auto_updates_usage() {
        cat <<'USAGE'
Usage: modules/auto_updates.sh <command>

Commands:
  install                  Install and configure automatic security updates
  audit                    Read-only status check (writes report to /var/log/auto-updates-audit/)
  --enable-reboot          Enable automatic reboot after updates
  --disable-reboot         Disable automatic reboot after updates
  --set-email EMAIL        Set email notification address
  --enable-security-only   Only install security updates (default)
  --enable-all-updates     Install all updates (security + regular)
  help                     Show this help

Config via environment (before install):
  MB_CONFIG_AUTO_REBOOT=true        Enable auto-reboot during install
  MB_CONFIG_UPDATE_EMAIL=you@ex.com Set email notification during install
USAGE
    }

    case "${1:-help}" in
        install)
            mb_check_root
            mb_module_auto_updates
            ;;
        audit)
            mb_module_auto_updates_audit
            ;;
        --enable-reboot)
            mb_check_root
            _mb_auto_updates_enable_reboot
            mb_success "Automatic reboot enabled"
            ;;
        --disable-reboot)
            mb_check_root
            _mb_auto_updates_disable_reboot
            mb_success "Automatic reboot disabled"
            ;;
        --set-email)
            [ -z "${2:-}" ] && { echo "Error: email address required" >&2; exit 1; }
            mb_check_root
            _mb_auto_updates_set_email "$2"
            mb_success "Email notification set to: $2"
            ;;
        --enable-security-only)
            mb_check_root
            _mb_auto_updates_enable_security_only
            mb_success "Security-only updates enabled"
            ;;
        --enable-all-updates)
            mb_check_root
            _mb_auto_updates_enable_all_updates
            mb_success "All updates enabled"
            ;;
        help|-h|--help)
            _mb_auto_updates_usage
            ;;
        *)
            echo "Unknown command: $1" >&2
            _mb_auto_updates_usage
            exit 1
            ;;
    esac
fi
