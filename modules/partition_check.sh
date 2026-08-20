#!/usr/bin/env bash
# modules/partition_check.sh — Partition isolation check (CIS v14.0 L1)
#
# Checks whether key mount points are on separate partitions and whether they
# carry the CIS-recommended mount options (nodev / nosuid / noexec). Read-only
# audit module: it reports status and never modifies /etc/fstab or mounts.
#
# CIS Benchmark v14.0 Level 1 partition controls covered:
#   - /tmp            separate partition, nodev,nosuid,noexec
#   - /var            separate partition
#   - /var/tmp        bound to /tmp or separate, nodev,nosuid,noexec
#   - /var/log        separate partition
#   - /var/log/audit  separate partition
#   - /home           separate partition, nodev
#   - /dev/shm        separate, nodev,nosuid,noexec
#
# Project: https://github.com/0x10debug/vps-bootstrap

mb_module_partition_check() {
    mb_step "Partition isolation check (CIS v14.0 L1)"

    local pass_count=0
    local fail_count=0
    local warn_count=0

    echo ""
    printf "  %-18s %-10s %-32s %s\n" "MOUNT" "SEPARATE" "OPTIONS" "STATUS"
    printf "  %-18s %-10s %-32s %s\n" "------------------" "----------" "--------------------------------" "--------"

    # /tmp — separate, nodev,nosuid,noexec
    _mb_partition_check_one "/tmp" "nodev,nosuid,noexec"
    case $? in
        0) pass_count=$((pass_count + 1)) ;;
        1) fail_count=$((fail_count + 1)) ;;
        2) warn_count=$((warn_count + 1)) ;;
    esac

    # /var — separate (no option requirement at L1)
    _mb_partition_check_one "/var" ""
    case $? in
        0) pass_count=$((pass_count + 1)) ;;
        1) fail_count=$((fail_count + 1)) ;;
        2) warn_count=$((warn_count + 1)) ;;
    esac

    # /var/tmp — separate or bind to /tmp, nodev,nosuid,noexec
    _mb_partition_check_one "/var/tmp" "nodev,nosuid,noexec"
    case $? in
        0) pass_count=$((pass_count + 1)) ;;
        1) fail_count=$((fail_count + 1)) ;;
        2) warn_count=$((warn_count + 1)) ;;
    esac

    # /var/log — separate
    _mb_partition_check_one "/var/log" ""
    case $? in
        0) pass_count=$((pass_count + 1)) ;;
        1) fail_count=$((fail_count + 1)) ;;
        2) warn_count=$((warn_count + 1)) ;;
    esac

    # /var/log/audit — separate
    _mb_partition_check_one "/var/log/audit" ""
    case $? in
        0) pass_count=$((pass_count + 1)) ;;
        1) fail_count=$((fail_count + 1)) ;;
        2) warn_count=$((warn_count + 1)) ;;
    esac

    # /home — separate, nodev
    _mb_partition_check_one "/home" "nodev"
    case $? in
        0) pass_count=$((pass_count + 1)) ;;
        1) fail_count=$((fail_count + 1)) ;;
        2) warn_count=$((warn_count + 1)) ;;
    esac

    # /dev/shm — separate, nodev,nosuid,noexec
    _mb_partition_check_one "/dev/shm" "nodev,nosuid,noexec"
    case $? in
        0) pass_count=$((pass_count + 1)) ;;
        1) fail_count=$((fail_count + 1)) ;;
        2) warn_count=$((warn_count + 1)) ;;
    esac

    echo ""
    mb_step "Partition check summary"
    echo "  PASS:  ${pass_count}"
    echo "  WARN:  ${warn_count}  (partition not separate — common on small VPS)"
    echo "  FAIL:  ${fail_count}  (separate partition missing required options)"

    if [ "$fail_count" -gt 0 ]; then
        echo ""
        mb_warn "Some separate partitions are missing CIS-recommended mount options."
        mb_detail "Edit /etc/fstab and remount, or re-partition at provisioning time."
        mb_detail "Reference: docs/hardening-reference.md and config/sysctl_hardening.conf"
    fi

    if [ "$warn_count" -gt 0 ]; then
        echo ""
        mb_info "Partitions sharing a single root filesystem cannot be isolated"
        mb_info "without re-partitioning. This is expected on many small VPS images."
        mb_info "On a fresh VPS, provision with separate /tmp, /var, /home if possible."
    fi

    mb_mark_done partition_check
    mb_success "Partition check complete (pass=${pass_count} warn=${warn_count} fail=${fail_count})"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# _mb_partition_check_one <mount> <required_opts>
# Required options are comma-separated (e.g. "nodev,nosuid,noexec").
# Empty required_opts means only the separate-partition check applies.
#
# Prints a status row and returns:
#   0 = PASS (separate partition + all required options present)
#   1 = FAIL (separate partition exists but missing required options)
#   2 = WARN (not on a separate partition — shares root filesystem)
_mb_partition_check_one() {
    local mount="$1"
    local required_opts="$2"
    local separate="no"
    local status="FAIL"
    local present_opts=""
    local missing=""

    # Determine whether the path is on its own mount point.
    if findmnt -kn -e -m "$mount" >/dev/null 2>&1; then
        separate="yes"
    elif mountpoint -q "$mount" 2>/dev/null; then
        separate="yes"
    fi

    if [ "$separate" = "yes" ]; then
        # Gather the actual mount options for this mount point.
        if mb_check_command findmnt; then
            present_opts=$(findmnt -kn -o OPTIONS -m "$mount" 2>/dev/null || echo "")
        else
            # Fallback: parse /proc/mounts (column 4, comma-separated).
            present_opts=$(awk -v m="$mount" '$2 == m { print $4 }' /proc/mounts 2>/dev/null | head -1)
        fi

        # Check each required option.
        if [ -n "$required_opts" ]; then
            local IFS=','
            local opt
            for opt in $required_opts; do
                if ! echo ",${present_opts}," | grep -q ",${opt},"; then
                    missing="${missing}${missing:+,}${opt}"
                fi
            done
        fi

        if [ -z "$missing" ]; then
            status="PASS"
        else
            status="FAIL (missing: ${missing})"
        fi
    else
        separate="no"
        status="WARN (shares /)"
    fi

    local display_opts
    if [ "$separate" = "yes" ]; then
        display_opts="${present_opts:-<none>}"
    else
        display_opts="<root fs>"
    fi

    printf "  %-18s %-10s %-32s %s\n" "$mount" "$separate" "$display_opts" "$status"

    case "$status" in
        PASS*) return 0 ;;
        WARN*) return 2 ;;
        *)     return 1 ;;
    esac
}
