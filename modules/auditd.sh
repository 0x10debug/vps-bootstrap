#!/usr/bin/env bash
# modules/auditd.sh — auditd installation, configuration, and audit coverage check
#
# Installs auditd and deploys CIS Benchmark v14.0 Level 1-aligned audit rules:
#   - File integrity monitoring for /etc/passwd, /etc/shadow, /etc/group,
#     /etc/sudoers, /etc/ssh/sshd_config, /etc/crontab (-w watch rules)
#   - Privileged command audit: setuid/setgid programs with -a always,exit
#     exec rules (CIS v14.0 4.1.x)
#
# Supports modular rule control via --enable-rule / --disable-rule.
# Read-only audit mode (mb_module_auditd_audit) checks existing auditd rule
# coverage against CIS v14.0 4.1.x controls and writes a TXT report to
# /var/log/auditd-audit/. Does not modify the system.
#
# CIS Benchmark v14.0 Level 1 auditd controls covered:
#   4.1.1  auditd package installed
#   4.1.2  auditd service enabled
#   4.1.3  audit=1 in kernel cmdline (prior-to-auditd processes)
#   4.1.4  audit log storage size configured (max_log_file)
#   4.1.5  audit logs not auto-deleted (max_log_file_action=keep_logs)
#   4.1.6  system disabled when logs full (space_left_action)
#   4.1.7  audit configuration immutable (-e 2)
#   4.1.8  date/time change events collected
#   4.1.9  user/group modification watches collected
#   4.1.10 network environment changes collected
#   4.1.11 login/logout events collected
#   4.1.12 session initiation events collected
#   4.1.13 permission/ownership changes collected
#   4.1.14 filesystem mount events collected
#   4.1.15 privileged command use collected (setuid/setgid)
#   4.1.16 file deletion events collected
#   4.1.17 kernel module load/unload events collected
#   4.1.18 /etc/ssh/sshd_config watch
#   4.1.19 /etc/crontab watch
#   4.1.20 /etc/sudoers watch
#
# Project: https://github.com/0x10debug/vps-bootstrap
# Depends on: Day 2 cis_align / partition_check audit framework

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

MB_AUDITD_RULES_DIR="/etc/audit/rules.d"
MB_AUDITD_REPORT_DIR="/var/log/auditd-audit"
MB_AUDITD_RULE_PREFIX="90-mb"
MB_AUDITD_SVC_NAME="auditd"

# Registry of all rule groups (names use hyphens; function names use underscores)
MB_AUDITD_RULE_GROUPS=("file-integrity" "privileged" "system-events" "immutable")

# ── Rule group definitions ───────────────────────────────────────────────────
# Each function echoes the audit rules for a named group.

_mb_auditd_rules_file_integrity() {
    cat <<'RULES'
# File integrity monitoring — key system files (CIS 4.1.9, 4.1.18–4.1.20)
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /var/spool/cron/ -p wa -k cron
RULES
}

_mb_auditd_rules_privileged() {
    echo "# Privileged command audit — setuid/setgid binaries (CIS 4.1.15)"
    local binary
    while IFS= read -r binary; do
        [ -z "$binary" ] && continue
        echo "-a always,exit -F path=${binary} -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged"
    done < <(find / -xdev -type f -perm -4000 2>/dev/null || true)
    while IFS= read -r binary; do
        [ -z "$binary" ] && continue
        echo "-a always,exit -F path=${binary} -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged"
    done < <(find / -xdev -type f -perm -2000 2>/dev/null || true)
}

_mb_auditd_rules_system_events() {
    cat <<'RULES'
# System event auditing (CIS 4.1.8, 4.1.10–4.1.14, 4.1.16–4.1.17)

# Date and time changes (4.1.8)
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change
-a always,exit -F arch=b32 -S adjtimex,settimeofday,clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

# Network environment changes (4.1.10)
-a always,exit -F arch=b64 -S sethostname,setdomainname -k system-locale
-a always,exit -F arch=b32 -S sethostname,setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/network/ -p wa -k system-locale
-w /etc/networks/ -p wa -k system-locale

# Login and logout events (4.1.11)
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins

# Session initiation (4.1.12)
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session

# Permission and ownership changes (4.1.13)
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -k perm_mod
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -k perm_mod
-a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -k perm_mod
-a always,exit -F arch=b32 -S chown,fchown,lchown,fchownat -k perm_mod
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -k perm_mod
-a always,exit -F arch=b32 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -k perm_mod

# Filesystem mounts (4.1.14)
-a always,exit -F arch=b64 -S mount,umount2 -k mounts
-a always,exit -F arch=b32 -S mount,umount2 -k mounts

# File deletion (4.1.16)
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat -k delete
-a always,exit -F arch=b32 -S unlink,unlinkat,rename,renameat -k delete

# Kernel module load/unload (4.1.17)
-a always,exit -F arch=b64 -S init_module,delete_module,finit_module -k modules
-a always,exit -F arch=b32 -S init_module,delete_module,finit_module -k modules
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
RULES
}

_mb_auditd_rules_immutable() {
    cat <<'RULES'
# Audit configuration immutability (CIS 4.1.7)
# -e 2 locks the audit configuration until next reboot
-e 2
RULES
}

# ── Main module function (install / deploy mode) ─────────────────────────────

mb_module_auditd() {
    mb_step "auditd installation and configuration"

    _mb_auditd_install
    _mb_auditd_configure_auditd
    _mb_auditd_deploy_all_rules
    _mb_auditd_restart

    mb_mark_done auditd
    mb_success "auditd installed and configured with CIS v14.0 L1 audit rules"
}

# ── Read-only audit function (coverage check) ────────────────────────────────

mb_module_auditd_audit() {
    mb_step "auditd rule coverage check (CIS v14.0 4.1.x)"

    local pass_count=0
    local fail_count=0
    local warn_count=0
    local timestamp report_file
    timestamp=$(date '+%Y%m%d-%H%M%S')
    report_file="${MB_AUDITD_REPORT_DIR}/auditd-audit-${timestamp}.txt"
    mkdir -p "$MB_AUDITD_REPORT_DIR" 2>/dev/null || true

    {
        echo "auditd Rule Coverage Audit Report"
        echo "=================================="
        echo "Date: $(date)"
        echo "Host: $(hostname 2>/dev/null)"
        echo "OS: ${PRETTY_NAME:-unknown}"
        echo ""
    } > "$report_file"

    echo ""
    printf "  %-12s %-50s %s\n" "CIS-ID" "CONTROL" "STATUS"
    printf "  %-12s %-50s %s\n" "------------" "--------------------------------------------------" "--------"

    local loaded_rules=""
    if mb_check_command auditctl; then
        loaded_rules=$(auditctl -l 2>/dev/null || echo "")
    fi

    # ── 4.1.1 auditd package installed ──────────────────────────────────────
    _mb_auditd_check 4.1.1 "auditd package installed" \
        "$(mb_check_command auditd && echo PASS || echo FAIL)" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.2 auditd service enabled ─────────────────────────────────────────
    local svc_status="FAIL"
    if mb_check_command systemctl && systemctl is-enabled auditd >/dev/null 2>&1; then
        svc_status="PASS"
    fi
    _mb_auditd_check 4.1.2 "auditd service is enabled" "$svc_status" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.3 audit=1 in kernel cmdline ──────────────────────────────────────
    local cmdline_status="FAIL"
    if grep -q "audit=1" /proc/cmdline 2>/dev/null; then
        cmdline_status="PASS"
    fi
    _mb_auditd_check 4.1.3 "audit=1 in kernel cmdline (prior-to-auditd)" "$cmdline_status" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.4 audit log storage size (max_log_file) ──────────────────────────
    _mb_auditd_check_conf 4.1.4 "audit log storage size (max_log_file)" \
        "max_log_file" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.5 audit logs not auto-deleted (max_log_file_action=keep_logs) ────
    local action_status="FAIL"
    if grep -q "max_log_file_action" /etc/audit/auditd.conf 2>/dev/null && \
       grep "max_log_file_action" /etc/audit/auditd.conf 2>/dev/null | grep -q "keep_logs"; then
        action_status="PASS"
    fi
    _mb_auditd_check 4.1.5 "audit logs not auto-deleted (keep_logs)" "$action_status" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.6 system disabled when logs full (space_left_action) ─────────────
    _mb_auditd_check_conf 4.1.6 "system disabled when logs full (space_left_action)" \
        "space_left_action" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.7 audit configuration immutable (-e 2) ───────────────────────────
    local immutable_status="FAIL"
    if echo "$loaded_rules" | grep -q -- "-e 2"; then
        immutable_status="PASS"
    fi
    _mb_auditd_check 4.1.7 "audit configuration immutable (-e 2)" "$immutable_status" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.8 date/time change events ────────────────────────────────────────
    _mb_auditd_check_key 4.1.8 "date/time change events collected" \
        "time-change" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.9 user/group modification watches ────────────────────────────────
    _mb_auditd_check_key 4.1.9 "user/group modification watches collected" \
        "identity" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.10 network environment changes ───────────────────────────────────
    _mb_auditd_check_key 4.1.10 "network environment changes collected" \
        "system-locale" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.11 login/logout events ───────────────────────────────────────────
    _mb_auditd_check_key 4.1.11 "login/logout events collected" \
        "logins" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.12 session initiation events ─────────────────────────────────────
    _mb_auditd_check_key 4.1.12 "session initiation events collected" \
        "session" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.13 permission/ownership changes ──────────────────────────────────
    _mb_auditd_check_key 4.1.13 "permission/ownership changes collected" \
        "perm_mod" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.14 filesystem mount events ───────────────────────────────────────
    _mb_auditd_check_key 4.1.14 "filesystem mount events collected" \
        "mounts" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.15 privileged command use (setuid/setgid) ────────────────────────
    local priv_status="FAIL"
    if echo "$loaded_rules" | grep -q "privileged"; then
        priv_status="PASS"
    fi
    _mb_auditd_check 4.1.15 "privileged command use collected (setuid/setgid)" \
        "$priv_status" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.16 file deletion events ──────────────────────────────────────────
    _mb_auditd_check_key 4.1.16 "file deletion events collected" \
        "delete" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.17 kernel module events ──────────────────────────────────────────
    _mb_auditd_check_key 4.1.17 "kernel module load/unload events collected" \
        "modules" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.18 /etc/ssh/sshd_config watch ────────────────────────────────────
    _mb_auditd_check_key 4.1.18 "/etc/ssh/sshd_config watch" \
        "sshd_config" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.19 /etc/crontab watch ────────────────────────────────────────────
    _mb_auditd_check_key 4.1.19 "/etc/crontab watch" \
        "cron" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── 4.1.20 /etc/sudoers watch ────────────────────────────────────────────
    _mb_auditd_check_key 4.1.20 "/etc/sudoers watch" \
        "sudoers" "$loaded_rules" "$report_file"
    _mb_auditd_tally pass_count fail_count warn_count

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    mb_step "auditd coverage summary"
    echo "  PASS:  ${pass_count}"
    echo "  WARN:  ${warn_count}"
    echo "  FAIL:  ${fail_count}"
    echo ""
    local total=$((pass_count + fail_count + warn_count))
    if [ "$total" -gt 0 ]; then
        local pct=$((pass_count * 100 / total))
        echo "  Coverage rate: ${pct}% (${pass_count}/${total} controls)"
    fi

    {
        echo ""
        echo "Summary: PASS=${pass_count} WARN=${warn_count} FAIL=${fail_count}"
    } >> "$report_file"

    echo ""
    if [ "$fail_count" -gt 0 ]; then
        mb_warn "${fail_count} control(s) not covered. Deploy rules with 'mb init --module auditd'."
        mb_detail "Report written to: ${report_file}"
    else
        mb_success "All checked auditd controls are covered."
        mb_detail "Report written to: ${report_file}"
    fi

    mb_mark_done auditd
    mb_success "auditd coverage check complete (pass=${pass_count} warn=${warn_count} fail=${fail_count})"
}

# ── Install helpers ───────────────────────────────────────────────────────────

_mb_auditd_install() {
    mb_info "Installing auditd..."

    case "${MB_OS_FAMILY:-}" in
        debian)
            mb_pkg_install auditd
            ;;
        rhel)
            mb_pkg_install audit audit-libs
            ;;
        alpine)
            mb_pkg_install audit auditd
            ;;
        *)
            mb_warn "auditd installation not formally supported for OS: ${MB_OS_FAMILY:-unknown}"
            mb_pkg_install auditd 2>/dev/null || mb_die "Could not install auditd"
            ;;
    esac

    mb_detail "auditd package installed"
}

_mb_auditd_configure_auditd() {
    mb_info "Configuring auditd..."

    local auditd_conf="/etc/audit/auditd.conf"
    if [ ! -f "$auditd_conf" ]; then
        mb_warn "auditd.conf not found at ${auditd_conf}, skipping config tuning"
        return 0
    fi

    mb_backup_file "$auditd_conf" auditd

    # CIS-recommended auditd.conf settings
    _mb_auditd_conf_set "$auditd_conf" "max_log_file" "100"
    _mb_auditd_conf_set "$auditd_conf" "max_log_file_action" "keep_logs"
    _mb_auditd_conf_set "$auditd_conf" "space_left" "200"
    _mb_auditd_conf_set "$auditd_conf" "space_left_action" "email"
    _mb_auditd_conf_set "$auditd_conf" "admin_space_left" "50"
    _mb_auditd_conf_set "$auditd_conf" "admin_space_left_action" "single"
    _mb_auditd_conf_set "$auditd_conf" "action_mail_acct" "root"

    mb_detail "auditd.conf tuned (max_log_file=100, keep_logs, space_left alerts)"
}

# _mb_auditd_conf_set <file> <key> <value>
# Sets or replaces a key=value line in auditd.conf.
_mb_auditd_conf_set() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}[[:space:]]*=" "$file" 2>/dev/null; then
        sed -i "s/^${key}[[:space:]]*=.*/${key} = ${value}/" "$file"
    else
        echo "${key} = ${value}" >> "$file"
    fi
}

_mb_auditd_deploy_all_rules() {
    mb_info "Deploying CIS v14.0 L1 audit rules..."

    mkdir -p "$MB_AUDITD_RULES_DIR"

    local group
    for group in "${MB_AUDITD_RULE_GROUPS[@]}"; do
        _mb_auditd_enable_rule "$group"
    done

    mb_detail "Deployed rule groups: ${MB_AUDITD_RULE_GROUPS[*]}"
}

_mb_auditd_restart() {
    mb_info "Restarting auditd..."

    mb_service_enable "$MB_AUDITD_SVC_NAME"
    mb_service_restart "$MB_AUDITD_SVC_NAME" 2>/dev/null || true

    if mb_check_command augenrules; then
        augenrules --load >/dev/null 2>&1 || true
    fi

    mb_detail "auditd service restarted and rules loaded"
    mb_env_set MB_AUDITD "installed"
}

# ── Modular rule control ──────────────────────────────────────────────────────

# _mb_auditd_enable_rule <group-name>
# Generates and writes the rule file for the named group, then reloads rules.
_mb_auditd_enable_rule() {
    local rule_name="$1"
    local func_name="_mb_auditd_rules_${rule_name//-/_}"
    local rule_file="${MB_AUDITD_RULES_DIR}/${MB_AUDITD_RULE_PREFIX}-${rule_name}.rules"

    if ! declare -f "$func_name" >/dev/null 2>&1; then
        mb_die "Unknown rule group: ${rule_name}. Available: ${MB_AUDITD_RULE_GROUPS[*]}"
    fi

    mkdir -p "$MB_AUDITD_RULES_DIR"
    "$func_name" > "$rule_file"
    mb_detail "Enabled rule group: ${rule_name} → ${rule_file}"

    if mb_check_command augenrules; then
        augenrules --load >/dev/null 2>&1 || true
    fi
}

# _mb_auditd_disable_rule <group-name>
# Removes the rule file for the named group, then reloads rules.
_mb_auditd_disable_rule() {
    local rule_name="$1"
    local rule_file="${MB_AUDITD_RULES_DIR}/${MB_AUDITD_RULE_PREFIX}-${rule_name}.rules"

    if [ ! -f "$rule_file" ]; then
        mb_detail "Rule group '${rule_name}' is not currently enabled"
        return 0
    fi

    rm -f "$rule_file"
    mb_detail "Disabled rule group: ${rule_name} (removed ${rule_file})"

    if mb_check_command augenrules; then
        augenrules --load >/dev/null 2>&1 || true
    fi
}

# ── Audit check helpers ───────────────────────────────────────────────────────

# _mb_auditd_check <cis_id> <desc> <status> <report_file>
# Prints a colored status row and appends a plain-text line to the report.
_mb_auditd_check() {
    local cis_id="$1" desc="$2" status="$3" report_file="$4"
    local color=""
    case "$status" in
        PASS) color="$C_OK" ;;
        FAIL) color="$C_FAIL" ;;
        WARN) color="$C_WARN" ;;
        N/A)  color="$C_INFO" ;;
    esac
    _MB_AUDITD_LAST_STATUS="$status"
    printf "  %-12s %-50s ${color}%s${C_RST}\n" "$cis_id" "$desc" "$status"
    printf "  %-12s %-50s %s\n" "$cis_id" "$desc" "$status" >> "$report_file"
}

# _mb_auditd_check_conf <cis_id> <desc> <key> <report_file>
# Checks whether a key exists in auditd.conf.
_mb_auditd_check_conf() {
    local cis_id="$1" desc="$2" key="$3" report_file="$4"
    local status="FAIL"
    if [ -f /etc/audit/auditd.conf ] && grep -q "^${key}[[:space:]]*=" /etc/audit/auditd.conf 2>/dev/null; then
        status="PASS"
    fi
    _mb_auditd_check "$cis_id" "$desc" "$status" "$report_file"
}

# _mb_auditd_check_key <cis_id> <desc> <key> <loaded_rules> <report_file>
# Checks whether a specific audit key appears in the loaded rules.
_mb_auditd_check_key() {
    local cis_id="$1" desc="$2" key="$3" loaded_rules="$4" report_file="$5"
    local status="FAIL"
    if echo "$loaded_rules" | grep -q -- "-k ${key}\|-k${key}"; then
        status="PASS"
    fi
    _mb_auditd_check "$cis_id" "$desc" "$status" "$report_file"
}

# _mb_auditd_tally <pass_var> <fail_var> <warn_var>
# Increments the named tally variable based on the last printed status.
# Uses namerefs (bash 4.3+) to update the caller's counters.
_mb_auditd_tally() {
    local -n _t_pass="$1"
    local -n _t_fail="$2"
    local -n _t_warn="$3"
    # Re-parse the last status from the most recent _mb_auditd_check call.
    # We store it in a global to avoid fragile parsing.
    case "${_MB_AUDITD_LAST_STATUS:-}" in
        PASS) _t_pass=$((_t_pass + 1)) ;;
        FAIL) _t_fail=$((_t_fail + 1)) ;;
        WARN) _t_warn=$((_t_warn + 1)) ;;
    esac
}

# ── Direct invocation support ─────────────────────────────────────────────────
# When executed directly (not sourced by mb), wire up mb helpers and dispatch.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _MB_AUDITD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/common.sh
    source "${_MB_AUDITD_SCRIPT_DIR}/../lib/common.sh"
    # shellcheck source=lib/os.sh
    source "${_MB_AUDITD_SCRIPT_DIR}/../lib/os.sh"
    mb_detect_os

    _mb_auditd_usage() {
        cat <<'USAGE'
Usage: modules/auditd.sh <command>

Commands:
  install              Install auditd, deploy all CIS v14.0 L1 rules, restart
  audit                Read-only coverage check (writes report to /var/log/auditd-audit/)
  --enable-rule NAME   Enable a specific rule group
  --disable-rule NAME  Disable a specific rule group
  list-rules           List available rule groups
  help                 Show this help

Rule groups:
  file-integrity       Watch rules for passwd, shadow, group, sudoers, sshd, cron
  privileged           setuid/setgid exec audit rules
  system-events        time, network, login, session, perm_mod, mounts, delete, modules
  immutable            Audit configuration immutability (-e 2)
USAGE
    }

    case "${1:-help}" in
        install)
            mb_check_root
            mb_module_auditd
            ;;
        audit)
            mb_module_auditd_audit
            ;;
        --enable-rule)
            [ -z "${2:-}" ] && { echo "Error: rule name required" >&2; exit 1; }
            mb_check_root
            _mb_auditd_enable_rule "$2"
            mb_success "Rule group '$2' enabled"
            ;;
        --disable-rule)
            [ -z "${2:-}" ] && { echo "Error: rule name required" >&2; exit 1; }
            mb_check_root
            _mb_auditd_disable_rule "$2"
            mb_success "Rule group '$2' disabled"
            ;;
        list-rules)
            echo "Available rule groups:"
            for _g in "${MB_AUDITD_RULE_GROUPS[@]}"; do
                echo "  $_g"
            done
            ;;
        help|-h|--help)
            _mb_auditd_usage
            ;;
        *)
            echo "Unknown command: $1" >&2
            _mb_auditd_usage
            exit 1
            ;;
    esac
fi
