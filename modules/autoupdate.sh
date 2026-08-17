#!/usr/bin/env bash
# modules/autoupdate.sh — Automatic security updates

mb_module_autoupdate() {
    mb_step "Automatic security updates"

    case "$MB_OS_FAMILY" in
        debian) _mb_autoupdate_debian ;;
        alpine) _mb_autoupdate_alpine ;;
        *) mb_die "Auto-update not supported for OS: $MB_OS_FAMILY" ;;
    esac

    mb_mark_done autoupdate
    mb_success "Automatic security updates configured"
}

# ── Debian/Ubuntu (unattended-upgrades) ──────────────────────────────────────

_mb_autoupdate_debian() {
    mb_pkg_install unattended-upgrades apt-listchanges

    local auto_upg_file="/etc/apt/apt.conf.d/50unattended-upgrades"
    local auto_apt_file="/etc/apt/apt.conf.d/20auto-upgrades"

    mb_backup_file "$auto_upg_file" autoupdate
    mb_backup_file "$auto_apt_file" autoupdate

    # Configure 20auto-upgrades
    {
        echo 'APT::Periodic::Update-Package-Lists "1";'
        echo 'APT::Periodic::Download-Upgradeable-Packages "1";'
        echo 'APT::Periodic::AutocleanInterval "7";'
        echo 'APT::Periodic::Unattended-Upgrade "1";'
    } > "$auto_apt_file"

    # Configure 50unattended-upgrades — only security updates
    local auto_reboot="${MB_CONFIG_AUTO_REBOOT:-false}"
    local webhook="${MB_CONFIG_UPDATE_NOTIFICATION_WEBHOOK:-}"

    {
        echo '// mb auto-update config — generated '"$(date)"
        echo 'Unattended-Upgrade::Allowed-Origins {'
        echo '    "${distro_id}:${distro_codename}-security";'
        echo '    "${distro_id}:${distro_codename}-updates";'
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
        if [ -n "$webhook" ]; then
            echo "Unattended-Upgrade::Mail \"\";"
            echo "// Webhook notification configured separately"
            mb_detail "Webhook notification: $webhook"
        fi
    } > "$auto_upg_file"

    # Enable systemd timer
    mb_service_enable unattended-upgrades
    systemctl start apt-daily.timer 2>/dev/null || true
    systemctl start apt-daily-upgrade.timer 2>/dev/null || true

    mb_detail "Security-only auto-updates configured (Docker packages excluded)"
}

# ── Alpine (cron + apk) ──────────────────────────────────────────────────────

_mb_autoupdate_alpine() {
    mb_pkg_install dcron

    local cron_file="/etc/crontabs/root"
    mb_backup_file "$cron_file" autoupdate

    # Add daily security update if not already present
    if ! grep -q "mb-security-update" "$cron_file" 2>/dev/null; then
        {
            echo ""
            echo "# mb security update — daily at 04:00"
            echo "0 4 * * * /sbin/apk update && /sbin/apk upgrade --available 2>&1 | logger -t mb-security-update"
        } >> "$cron_file"

        mb_service_enable dcron
        mb_service_restart dcron
        mb_detail "Daily security update cron job added (04:00)"
    else
        mb_detail "Security update cron job already present"
    fi
}
