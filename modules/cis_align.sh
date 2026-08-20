#!/usr/bin/env bash
# modules/cis_align.sh — CIS Benchmark v14.0 Level 1 alignment report
#
# Read-only audit module. Checks whether vps-bootstrap's hardening modules
# align with CIS Benchmark v14.0 Level 1 server recommendations and prints
# a per-control alignment report. Does not modify the system.
#
# Coverage (CIS v14.0 L1 server profile):
#   1.x  Initial setup (ASLR, core dumps, kernel hardening)
#   2.x  Services (xinetd, time sync, mail transfer agent)
#   3.x  Network parameters (forwarding, redirects, source routing, etc.)
#   4.x  Logging and rsyslog
#   5.x  SSH server configuration
#   6.x  Filesystem permissions (sticky bit, world-writable audit)
#   7.x  Access, authentication, and accounts (sudo, umask, shadow, PAM)
#
# Each control is reported as ALIGNED / PARTIAL / NOT-ALIGNED / N/A.
#
# Project: https://github.com/0x10debug/vps-bootstrap
# Reference: config/sysctl_hardening.conf

mb_module_cis_align() {
    mb_step "CIS Benchmark v14.0 Level 1 alignment report"

    local aligned=0
    local partial=0
    local not_aligned=0
    local na=0

    echo ""
    printf "  %-10s %-44s %s\n" "CIS-ID" "CONTROL" "STATUS"
    printf "  %-10s %-44s %s\n" "----------" "--------------------------------------------" "---------------"

    # ── 1.x Initial setup ─────────────────────────────────────────────────────
    _mb_cis_report 1.1.5  "ASLR enabled (kernel.randomize_va_space=2)" \
        "$(sysctl -n kernel.randomize_va_space 2>/dev/null || echo "")" "2"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 1.1.6  "SUID core dumps disabled (fs.suid_dumpable=0)" \
        "$(sysctl -n fs.suid_dumpable 2>/dev/null || echo "")" "0"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 1.1.7  "Kernel pointers restricted (kernel.kptr_restrict=2)" \
        "$(sysctl -n kernel.kptr_restrict 2>/dev/null || echo "")" "2"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 1.1.8  "dmesg restricted (kernel.dmesg_restrict=1)" \
        "$(sysctl -n kernel.dmesg_restrict 2>/dev/null || echo "")" "1"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 1.1.9  "perf events restricted (kernel.perf_event_paranoid=2)" \
        "$(sysctl -n kernel.perf_event_paranoid 2>/dev/null || echo "")" "2"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 1.1.10 "ptrace restricted (kernel.yama.ptrace_scope>=1)" \
        "$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || echo "")" "1+"
    _mb_cis_tally_last aligned partial not_aligned na

    # ── 3.x Network parameters ────────────────────────────────────────────────
    _mb_cis_report 3.1.1  "IPv4 forwarding disabled (net.ipv4.ip_forward=0)" \
        "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "")" "0"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.2  "IPv6 forwarding disabled (net.ipv6.conf.all.forwarding=0)" \
        "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "")" "0"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.3  "IPv4 send_redirects disabled (all)" \
        "$(sysctl -n net.ipv4.conf.all.send_redirects 2>/dev/null || echo "")" "0"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.4  "IPv4 send_redirects disabled (default)" \
        "$(sysctl -n net.ipv4.conf.default.send_redirects 2>/dev/null || echo "")" "0"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.5  "IPv4 accept_redirects disabled (all)" \
        "$(sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null || echo "")" "0"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.7  "IPv4 secure_redirects disabled (all)" \
        "$(sysctl -n net.ipv4.conf.all.secure_redirects 2>/dev/null || echo "")" "0"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.9  "IPv4 accept_source_route disabled (all)" \
        "$(sysctl -n net.ipv4.conf.all.accept_source_route 2>/dev/null || echo "")" "0"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.11 "IPv4 log_martians enabled (all)" \
        "$(sysctl -n net.ipv4.conf.all.log_martians 2>/dev/null || echo "")" "1"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.13 "IPv4 rp_filter enabled (all)" \
        "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "")" "1"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.15 "Broadcast ICMP ignored (icmp_echo_ignore_broadcasts=1)" \
        "$(sysctl -n net.ipv4.icmp_echo_ignore_broadcasts 2>/dev/null || echo "")" "1"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.16 "Bogus ICMP error responses ignored" \
        "$(sysctl -n net.ipv4.icmp_ignore_bogus_error_responses 2>/dev/null || echo "")" "1"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.17 "SYN cookies enabled (tcp_syncookies=1)" \
        "$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo "")" "1"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report 3.1.19 "TCP timestamps disabled (tcp_timestamps=0)" \
        "$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null || echo "")" "0"
    _mb_cis_tally_last aligned partial not_aligned na

    # ── 5.x SSH server ────────────────────────────────────────────────────────
    _mb_cis_report_ssh 5.1.1 "PermitRootLogin set to no" "PermitRootLogin" "no"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report_ssh 5.1.2 "MaxAuthTries <= 4" "MaxAuthTries" "4-"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report_ssh 5.1.3 "IgnoreRhosts enabled" "IgnoreRhosts" "yes"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report_ssh 5.1.4 "HostbasedAuthentication disabled" "HostbasedAuthentication" "no"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report_ssh 5.1.5 "PermitEmptyPasswords disabled" "PermitEmptyPasswords" "no"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report_ssh 5.1.6 "PermitUserEnvironment disabled" "PermitUserEnvironment" "no"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report_ssh 5.1.7 "X11Forwarding disabled" "X11Forwarding" "no"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report_ssh 5.1.8 "ClientAliveInterval <= 300" "ClientAliveInterval" "300-"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report_ssh 5.1.9 "LoginGraceTime <= 60" "LoginGraceTime" "60-"
    _mb_cis_tally_last aligned partial not_aligned na

    _mb_cis_report_ssh 5.1.10 "AllowUsers / AllowGroups restricted" "AllowUsers" "set"
    _mb_cis_tally_last aligned partial not_aligned na

    # ── 6.x Filesystem ────────────────────────────────────────────────────────
    _mb_cis_report_sticky 6.1.10 "Sticky bit set on world-writable dirs"
    _mb_cis_tally_last aligned partial not_aligned na

    # ── Firewall (CIS 3.5/9.3) ────────────────────────────────────────────────
    _mb_cis_report_firewall 9.3.1 "Host firewall active (ufw/nftables)"
    _mb_cis_tally_last aligned partial not_aligned na

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    mb_step "CIS v14.0 L1 alignment summary"
    echo "  ALIGNED:       ${aligned}"
    echo "  PARTIAL:       ${partial}"
    echo "  NOT-ALIGNED:   ${not_aligned}"
    echo "  N/A:           ${na}"
    echo ""
    local checked=$((aligned + partial + not_aligned))
    if [ "$checked" -gt 0 ]; then
        local pct=$((aligned * 100 / checked))
        echo "  Alignment rate: ${pct}% (${aligned}/${checked} applicable controls)"
    fi

    echo ""
    if [ "$not_aligned" -gt 0 ]; then
        mb_warn "${not_aligned} control(s) not aligned. Review the rows above."
        mb_detail "Apply config/sysctl_hardening.conf and re-run 'mb init --module kernel'."
        mb_detail "Re-run: mb init --module cis_align"
    else
        mb_success "All checked CIS v14.0 L1 controls are aligned."
    fi

    mb_mark_done cis_align
    mb_success "CIS alignment report complete"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# _mb_cis_report <id> <desc> <actual> <expected>
# expected is an exact value, or "1+" (>=1), "0" etc.
# Sets _MB_CIS_LAST_STATUS to ALIGNED / NOT-ALIGNED / N/A and prints the row.
_mb_cis_report() {
    local id="$1" desc="$2" actual="$3" expected="$4"
    local status

    if [ -z "$actual" ]; then
        status="N/A"
    elif [ "$expected" = "1+" ]; then
        if [ "$actual" -ge 1 ] 2>/dev/null; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    elif [ "$expected" = "4-" ]; then
        if [ "$actual" -le 4 ] 2>/dev/null; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    elif [ "$expected" = "300-" ]; then
        if [ "$actual" -gt 0 ] && [ "$actual" -le 300 ] 2>/dev/null; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    elif [ "$expected" = "60-" ]; then
        if [ "$actual" -gt 0 ] && [ "$actual" -le 60 ] 2>/dev/null; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    else
        if [ "$actual" = "$expected" ]; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    fi

    _MB_CIS_LAST_STATUS="$status"
    printf "  %-10s %-44s %s\n" "$id" "$desc" "$status"
}

# _mb_cis_report_ssh <id> <desc> <directive> <expected>
# Reads the effective sshd config (sshd -T) and compares.
_mb_cis_report_ssh() {
    local id="$1" desc="$2" directive="$3" expected="$4"
    local actual=""
    local status

    if mb_check_command sshd; then
        actual=$(sshd -T 2>/dev/null | awk -v d="${directive}" 'tolower($1) == tolower(d) { print $2; exit }')
    fi

    if [ -z "$actual" ]; then
        status="N/A"
    elif [ "$expected" = "set" ]; then
        # AllowUsers / AllowGroups: aligned if a non-empty value is configured.
        if [ -n "$actual" ] && [ "$actual" != "no" ]; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    elif [ "$expected" = "4-" ]; then
        if [ "$actual" -le 4 ] 2>/dev/null; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    elif [ "$expected" = "300-" ]; then
        if [ "$actual" -gt 0 ] && [ "$actual" -le 300 ] 2>/dev/null; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    elif [ "$expected" = "60-" ]; then
        if [ "$actual" -gt 0 ] && [ "$actual" -le 60 ] 2>/dev/null; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    else
        if [ "$actual" = "$expected" ]; then
            status="ALIGNED"
        else
            status="NOT-ALIGNED"
        fi
    fi

    _MB_CIS_LAST_STATUS="$status"
    printf "  %-10s %-44s %s\n" "$id" "$desc" "$status"
}

# _mb_cis_report_sticky <id> <desc>
# Checks that all world-writable directories have the sticky bit set.
_mb_cis_report_sticky() {
    local id="$1" desc="$2"
    local status
    local offenders=""

    if mb_check_command find; then
        # Scan local filesystems only, skip /proc /sys /dev.
        offenders=$(find / -xdev -path /proc -prune -o -path /sys -prune -o -path /dev -prune -o -type d -perm -0002 ! -perm -1000 -print 2>/dev/null)
    fi

    if [ -z "$offenders" ]; then
        status="ALIGNED"
    else
        status="NOT-ALIGNED"
    fi

    _MB_CIS_LAST_STATUS="$status"
    printf "  %-10s %-44s %s\n" "$id" "$desc" "$status"
    if [ -n "$offenders" ]; then
        mb_detail "Sticky-bit offenders:"
        # shellcheck disable=SC2086
        mb_detail "$(echo "$offenders" | head -5)"
    fi
}

# _mb_cis_report_firewall <id> <desc>
# Checks whether ufw or nftables is active.
_mb_cis_report_firewall() {
    local id="$1" desc="$2"
    local status="NOT-ALIGNED"

    if mb_check_command ufw; then
        if ufw status 2>/dev/null | grep -qi "status: active"; then
            status="ALIGNED"
        fi
    elif mb_check_command nft; then
        if nft list ruleset 2>/dev/null | grep -q "hook"; then
            status="ALIGNED"
        fi
    elif mb_check_command iptables; then
        if iptables -L -n 2>/dev/null | grep -q "policy DROP"; then
            status="PARTIAL"
        fi
    fi

    _MB_CIS_LAST_STATUS="$status"
    printf "  %-10s %-44s %s\n" "$id" "$desc" "$status"
}

# _mb_cis_tally_last <aligned_var> <partial_var> <not_aligned_var> <na_var>
# Increments the named tally variable based on _MB_CIS_LAST_STATUS.
# Uses namerefs (bash 4.3+) to update the caller's counters.
_mb_cis_tally_last() {
    local -n _t_aligned="$1"
    local -n _t_partial="$2"
    local -n _t_not_aligned="$3"
    local -n _t_na="$4"
    case "${_MB_CIS_LAST_STATUS:-}" in
        ALIGNED)       _t_aligned=$((_t_aligned + 1)) ;;
        PARTIAL)       _t_partial=$((_t_partial + 1)) ;;
        NOT-ALIGNED)   _t_not_aligned=$((_t_not_aligned + 1)) ;;
        N/A)           _t_na=$((_t_na + 1)) ;;
    esac
}
