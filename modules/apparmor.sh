#!/usr/bin/env bash
# modules/apparmor.sh — AppArmor mandatory access control installation, configuration, and audit
#
# Installs AppArmor and enables enforce mode for mandatory access control (MAC).
# AppArmor confines individual programs with per-application profiles, limiting
# the damage a compromised service can do to the rest of the system.
#
# Features:
#   - Install apparmor + apparmor-utils (apt/yum/apk adaptive)
#   - Enable kernel parameters (apparmor=1 security=apparmor)
#   - Start apparmor service and load default profiles
#   - Set all profiles to enforce mode (not complain)
#   - Read-only audit mode (mb_module_apparmor_audit): checks install status,
#     kernel params, service state, profile modes, and whether key services
#     (sshd, docker, nginx, mysql, postgres, redis) have profiles. Writes a
#     TXT report to /var/log/apparmor-audit/. Does not modify the system.
#   - Profile management: --enforce, --complain, --list, --generate
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

MB_APPARMOR_REPORT_DIR="/var/log/apparmor-audit"
MB_APPARMOR_SVC_NAME="apparmor"
MB_APPARMOR_PROFILES_DIR="/etc/apparmor.d"

# Key services that should have AppArmor profiles for defense-in-depth.
MB_APPARMOR_KEY_SERVICES=("sshd" "docker" "nginx" "mysql" "postgres" "redis")

# ── Main module function (install / deploy mode) ─────────────────────────────

mb_module_apparmor() {
    mb_step "AppArmor mandatory access control setup"

    _mb_apparmor_install
    _mb_apparmor_enable_kernel_params
    _mb_apparmor_start_service
    _mb_apparmor_load_profiles
    _mb_apparmor_set_enforce_mode

    mb_mark_done apparmor
    mb_success "AppArmor is active in enforce mode with default profiles loaded"
}

# ── Read-only audit function ─────────────────────────────────────────────────

mb_module_apparmor_audit() {
    mb_step "AppArmor status audit (read-only)"

    local pass_count=0
    local fail_count=0
    local warn_count=0
    local timestamp report_file
    timestamp=$(date '+%Y%m%d-%H%M%S')
    report_file="${MB_APPARMOR_REPORT_DIR}/apparmor-audit-${timestamp}.txt"
    mkdir -p "$MB_APPARMOR_REPORT_DIR" 2>/dev/null || true

    {
        echo "AppArmor Status Audit Report"
        echo "============================="
        echo "Date: $(date)"
        echo "Host: $(hostname 2>/dev/null)"
        echo "OS: ${PRETTY_NAME:-unknown}"
        echo ""
    } > "$report_file"

    echo ""
    printf "  %-45s %s\n" "CHECK" "STATUS"
    printf "  %-45s %s\n" "---------------------------------------------" "--------"

    # ── AppArmor package installed ──────────────────────────────────────────
    local pkg_status="FAIL"
    if mb_check_command apparmor_parser; then
        pkg_status="PASS"
    elif mb_check_command aa-status; then
        pkg_status="PASS"
    fi
    _mb_apparmor_check "AppArmor package installed (apparmor_parser)" "$pkg_status" "$report_file"
    _mb_apparmor_tally pass_count fail_count warn_count

    # If AppArmor is not installed, remaining checks are moot.
    if [ "$pkg_status" = "FAIL" ]; then
        echo ""
        mb_warn "AppArmor is not installed. Run 'mb init --module apparmor' to deploy."
        {
            echo ""
            echo "AppArmor not installed; remaining checks skipped."
            echo "Summary: PASS=${pass_count} WARN=${warn_count} FAIL=${fail_count}"
        } >> "$report_file"
        mb_detail "Report written to: ${report_file}"
        mb_mark_done apparmor
        mb_success "AppArmor audit complete (apparmor not installed)"
        return 0
    fi

    # ── Kernel parameters (apparmor=1 security=apparmor) ────────────────────
    local kernel_status="FAIL"
    if grep -q "apparmor=1" /proc/cmdline 2>/dev/null; then
        kernel_status="PASS"
    fi
    _mb_apparmor_check "Kernel param apparmor=1 in cmdline" "$kernel_status" "$report_file"
    _mb_apparmor_tally pass_count fail_count warn_count

    local sec_status="FAIL"
    if grep -q "security=apparmor" /proc/cmdline 2>/dev/null; then
        sec_status="PASS"
    fi
    _mb_apparmor_check "Kernel param security=apparmor in cmdline" "$sec_status" "$report_file"
    _mb_apparmor_tally pass_count fail_count warn_count

    # ── AppArmor service active ─────────────────────────────────────────────
    local svc_status="FAIL"
    if mb_service_status apparmor 2>/dev/null | grep -q active; then
        svc_status="PASS"
    fi
    _mb_apparmor_check "AppArmor service active" "$svc_status" "$report_file"
    _mb_apparmor_tally pass_count fail_count warn_count

    # ── Profile mode summary (enforce / complain / unloaded) ────────────────
    local aa_output=""
    if mb_check_command aa-status; then
        aa_output=$(aa-status 2>/dev/null || echo "")
    fi

    local enforce_count=0
    local complain_count=0
    local loaded_count=0
    if [ -n "$aa_output" ]; then
        enforce_count=$(echo "$aa_output" | grep -oP '(?<=enforce mode\.\s).*' | grep -oP '[0-9]+' || echo "0")
        complain_count=$(echo "$aa_output" | grep -oP '(?<=complain mode\.\s).*' | grep -oP '[0-9]+' || echo "0")
        loaded_count=$(echo "$aa_output" | grep -oP '(?<=profiles are loaded\.\s).*' | grep -oP '[0-9]+' || echo "0")
    fi

    _mb_apparmor_check "Profiles loaded: ${loaded_count}" "N/A" "$report_file"
    _mb_apparmor_tally pass_count fail_count warn_count

    _mb_apparmor_check "Profiles in enforce mode: ${enforce_count}" "N/A" "$report_file"
    _mb_apparmor_tally pass_count fail_count warn_count

    _mb_apparmor_check "Profiles in complain mode: ${complain_count}" "N/A" "$report_file"
    _mb_apparmor_tally pass_count fail_count warn_count

    # ── All profiles in enforce mode (not complain) ─────────────────────────
    local all_enforce="FAIL"
    if [ "${complain_count:-0}" -eq 0 ] && [ "${enforce_count:-0}" -gt 0 ]; then
        all_enforce="PASS"
    elif [ "${enforce_count:-0}" -eq 0 ] && [ "${complain_count:-0}" -eq 0 ]; then
        all_enforce="WARN"
    fi
    _mb_apparmor_check "All loaded profiles in enforce mode" "$all_enforce" "$report_file"
    _mb_apparmor_tally pass_count fail_count warn_count

    # ── Key service profile coverage ────────────────────────────────────────
    local profiles_list=""
    if mb_check_command aa-status; then
        profiles_list=$(aa-status --enabled 2>/dev/null || aa-status 2>/dev/null | grep -E "^\s+/" || echo "")
    fi

    # Also check profile files on disk
    local disk_profiles=""
    if [ -d "$MB_APPARMOR_PROFILES_DIR" ]; then
        disk_profiles=$(ls "$MB_APPARMOR_PROFILES_DIR" 2>/dev/null || echo "")
    fi

    local svc
    for svc in "${MB_APPARMOR_KEY_SERVICES[@]}"; do
        local svc_status="WARN"
        # Check if the service binary has a loaded profile or a profile file on disk
        local svc_bin=""
        case "$svc" in
            sshd)    svc_bin=$(command -v sshd 2>/dev/null || echo "/usr/sbin/sshd") ;;
            docker)  svc_bin=$(command -v dockerd 2>/dev/null || echo "/usr/bin/dockerd") ;;
            nginx)   svc_bin=$(command -v nginx 2>/dev/null || echo "/usr/sbin/nginx") ;;
            mysql)   svc_bin=$(command -v mysqld 2>/dev/null || echo "/usr/sbin/mysqld") ;;
            postgres) svc_bin=$(command -v postgres 2>/dev/null || echo "/usr/lib/postgresql/*/bin/postgres") ;;
            redis)   svc_bin=$(command -v redis-server 2>/dev/null || echo "/usr/bin/redis-server") ;;
        esac

        # Check loaded profiles for the binary path
        if [ -n "$profiles_list" ] && echo "$profiles_list" | grep -q "$svc"; then
            svc_status="PASS"
        fi
        # Check profile files on disk
        if [ "$svc_status" != "PASS" ] && [ -n "$disk_profiles" ]; then
            if echo "$disk_profiles" | grep -qi "$svc"; then
                svc_status="PASS"
            fi
        fi
        # Check if the service is even installed (if not, WARN is appropriate)
        if [ "$svc" = "sshd" ]; then
            if ! mb_check_command sshd; then svc_status="N/A"; fi
        elif [ "$svc" = "docker" ]; then
            if ! mb_check_command docker; then svc_status="N/A"; fi
        elif [ "$svc" = "nginx" ]; then
            if ! mb_check_command nginx; then svc_status="N/A"; fi
        elif [ "$svc" = "mysql" ]; then
            if ! mb_check_command mysqld; then svc_status="N/A"; fi
        elif [ "$svc" = "postgres" ]; then
            if ! mb_check_command postgres; then svc_status="N/A"; fi
        elif [ "$svc" = "redis" ]; then
            if ! mb_check_command redis-server; then svc_status="N/A"; fi
        fi

        _mb_apparmor_check "Profile for ${svc} (${svc_bin})" "$svc_status" "$report_file"
        _mb_apparmor_tally pass_count fail_count warn_count
    done

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    mb_step "AppArmor audit summary"
    echo "  PASS:  ${pass_count}"
    echo "  WARN:  ${warn_count}"
    echo "  FAIL:  ${fail_count}"
    echo "  Profiles loaded:   ${loaded_count}"
    echo "  Enforce mode:      ${enforce_count}"
    echo "  Complain mode:     ${complain_count}"
    echo ""

    {
        echo ""
        echo "Profiles loaded:   ${loaded_count}"
        echo "Enforce mode:      ${enforce_count}"
        echo "Complain mode:     ${complain_count}"
        echo "Summary: PASS=${pass_count} WARN=${warn_count} FAIL=${fail_count}"
    } >> "$report_file"

    if [ "$fail_count" -gt 0 ]; then
        mb_warn "${fail_count} check(s) failed. Deploy with 'mb init --module apparmor'."
    else
        mb_success "AppArmor core checks passed (warn=${warn_count} optional items)."
    fi
    mb_detail "Report written to: ${report_file}"

    mb_mark_done apparmor
    mb_success "AppArmor audit complete (pass=${pass_count} warn=${warn_count} fail=${fail_count})"
}

# ── Install helpers ───────────────────────────────────────────────────────────

_mb_apparmor_install() {
    mb_info "Installing AppArmor..."

    case "${MB_OS_FAMILY:-}" in
        debian)
            mb_pkg_install apparmor apparmor-utils
            ;;
        rhel)
            mb_pkg_install apparmor apparmor-utils
            ;;
        alpine)
            mb_pkg_install apparmor apparmor-utils
            ;;
        *)
            mb_warn "AppArmor installation not formally supported for OS: ${MB_OS_FAMILY:-unknown}"
            mb_pkg_install apparmor apparmor-utils 2>/dev/null || mb_die "Could not install apparmor"
            ;;
    esac

    mb_detail "AppArmor packages installed"
}

_mb_apparmor_enable_kernel_params() {
    mb_info "Enabling AppArmor kernel parameters..."

    # Check if AppArmor is already enabled in kernel
    if [ -f /sys/module/apparmor/parameters/enabled ]; then
        local enabled
        enabled=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo "0")
        if [ "$enabled" = "Y" ]; then
            mb_detail "AppArmor already enabled in running kernel"
        fi
    fi

    # Add kernel parameters to GRUB config for persistence across reboots
    local grub_default="/etc/default/grub"
    if [ -f "$grub_default" ]; then
        mb_backup_file "$grub_default" apparmor

        local grub_cmdline
        grub_cmdline=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$grub_default" 2>/dev/null | head -1 || echo "")

        if [ -n "$grub_cmdline" ]; then
            # Check if params already present
            if ! echo "$grub_cmdline" | grep -q "apparmor=1"; then
                sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 apparmor=1 security=apparmor"/' "$grub_default"
                mb_detail "Added apparmor=1 security=apparmor to GRUB_CMDLINE_LINUX_DEFAULT"
            else
                mb_detail "apparmor=1 already in GRUB config"
            fi
        else
            echo 'GRUB_CMDLINE_LINUX_DEFAULT="apparmor=1 security=apparmor"' >> "$grub_default"
            mb_detail "Created GRUB_CMDLINE_LINUX_DEFAULT with apparmor params"
        fi

        # Update GRUB if grub-mkconfig or grub2-mkconfig is available
        if mb_check_command grub-mkconfig; then
            grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
            mb_detail "GRUB configuration updated (grub-mkconfig)"
        elif mb_check_command grub2-mkconfig; then
            grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
            mb_detail "GRUB configuration updated (grub2-mkconfig)"
        else
            mb_warn "Could not find grub-mkconfig; kernel params will apply after manual GRUB update"
        fi
    else
        mb_warn "GRUB config not found at ${grub_default}; kernel params not persisted"
    fi
}

_mb_apparmor_start_service() {
    mb_info "Starting AppArmor service..."

    mb_service_enable "$MB_APPARMOR_SVC_NAME"
    mb_service_restart "$MB_APPARMOR_SVC_NAME" 2>/dev/null || true

    mb_detail "AppArmor service enabled and started"
}

_mb_apparmor_load_profiles() {
    mb_info "Loading default AppArmor profiles..."

    if mb_check_command apparmor_parser; then
        # Load all profiles from the profiles directory
        if [ -d "$MB_APPARMOR_PROFILES_DIR" ]; then
            local profile
            while IFS= read -r profile; do
                [ -z "$profile" ] && continue
                apparmor_parser -r "$profile" 2>/dev/null || true
            done < <(find "$MB_APPARMOR_PROFILES_DIR" -maxdepth 1 -type f 2>/dev/null || true)
            mb_detail "Loaded profiles from ${MB_APPARMOR_PROFILES_DIR}"
        else
            mb_warn "AppArmor profiles directory not found: ${MB_APPARMOR_PROFILES_DIR}"
        fi
    else
        mb_warn "apparmor_parser not found; cannot load profiles"
    fi
}

_mb_apparmor_set_enforce_mode() {
    mb_info "Setting all profiles to enforce mode..."

    if mb_check_command aa-enforce; then
        # Set all loaded profiles to enforce mode
        if [ -d "$MB_APPARMOR_PROFILES_DIR" ]; then
            aa-enforce "$MB_APPARMOR_PROFILES_DIR"/* 2>/dev/null || true
            mb_detail "All profiles set to enforce mode"
        fi
    elif mb_check_command enforce; then
        # Alpine uses 'enforce' command
        if [ -d "$MB_APPARMOR_PROFILES_DIR" ]; then
            local profile
            while IFS= read -r profile; do
                [ -z "$profile" ] && continue
                enforce "$profile" 2>/dev/null || true
            done < <(find "$MB_APPARMOR_PROFILES_DIR" -maxdepth 1 -type f 2>/dev/null || true)
            mb_detail "All profiles set to enforce mode (via enforce command)"
        fi
    else
        mb_warn "aa-enforce not found; cannot set enforce mode. Profiles may remain in complain mode."
    fi

    mb_env_set MB_APPARMOR "enforce"
}

# ── Profile management ────────────────────────────────────────────────────────

# _mb_apparmor_enforce_profile <profile>
# Switches a profile to enforce mode.
_mb_apparmor_enforce_profile() {
    local profile="$1"
    if ! mb_check_command aa-enforce; then
        mb_die "aa-enforce not found. Install apparmor-utils first."
    fi
    aa-enforce "$profile" 2>/dev/null || mb_die "Failed to set enforce mode for: ${profile}"
    mb_detail "Profile '${profile}' set to enforce mode"
}

# _mb_apparmor_complain_profile <profile>
# Switches a profile to complain mode.
_mb_apparmor_complain_profile() {
    local profile="$1"
    if ! mb_check_command aa-complain; then
        mb_die "aa-complain not found. Install apparmor-utils first."
    fi
    aa-complain "$profile" 2>/dev/null || mb_die "Failed to set complain mode for: ${profile}"
    mb_detail "Profile '${profile}' set to complain mode"
}

# _mb_apparmor_list_profiles
# Lists all profiles and their current mode.
_mb_apparmor_list_profiles() {
    if ! mb_check_command aa-status; then
        mb_die "aa-status not found. Install apparmor-utils first."
    fi

    echo ""
    mb_step "AppArmor profiles"
    echo ""

    local enforce_profiles=""
    local complain_profiles=""

    # Try to get enforce and complain lists
    if mb_check_command aa-status; then
        enforce_profiles=$(aa-status 2>/dev/null | sed -n '/enforce mode/,/^$/p' | grep -E '^\s+/' || echo "")
        complain_profiles=$(aa-status 2>/dev/null | sed -n '/complain mode/,/^$/p' | grep -E '^\s+/' || echo "")
    fi

    echo "  Enforce mode profiles:"
    if [ -n "$enforce_profiles" ]; then
        echo "$enforce_profiles" | sed 's/^/    /'
    else
        echo "    (none)"
    fi

    echo ""
    echo "  Complain mode profiles:"
    if [ -n "$complain_profiles" ]; then
        echo "$complain_profiles" | sed 's/^/    /'
    else
        echo "    (none)"
    fi

    echo ""
    echo "  Profile files on disk (${MB_APPARMOR_PROFILES_DIR}):"
    if [ -d "$MB_APPARMOR_PROFILES_DIR" ]; then
        local count
        count=$(find "$MB_APPARMOR_PROFILES_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l || echo "0")
        echo "    ${count} profile file(s)"
    else
        echo "    (directory not found)"
    fi
}

# _mb_apparmor_generate_profile <binary>
# Generates a new profile template for the specified binary using aa-genprof.
_mb_apparmor_generate_profile() {
    local binary="$1"
    if ! mb_check_command aa-genprof; then
        mb_die "aa-genprof not found. Install apparmor-utils first."
    fi
    if [ ! -x "$binary" ]; then
        mb_die "Binary not found or not executable: ${binary}"
    fi
    mb_info "Generating AppArmor profile for: ${binary}"
    mb_detail "This will launch aa-genprof interactively."
    aa-genprof "$binary"
}

# ── Audit check helpers ───────────────────────────────────────────────────────

# _mb_apparmor_check <desc> <status> <report_file>
# Prints a colored status row and appends a plain-text line to the report.
_mb_apparmor_check() {
    local desc="$1" status="$2" report_file="$3"
    local color=""
    case "$status" in
        PASS) color="$C_OK" ;;
        FAIL) color="$C_FAIL" ;;
        WARN) color="$C_WARN" ;;
        N/A)  color="$C_INFO" ;;
    esac
    _MB_APPARMOR_LAST_STATUS="$status"
    printf "  %-45s ${color}%s${C_RST}\n" "$desc" "$status"
    printf "  %-45s %s\n" "$desc" "$status" >> "$report_file"
}

# _mb_apparmor_tally <pass_var> <fail_var> <warn_var>
# Increments the named tally variable based on the last printed status.
# Uses namerefs (bash 4.3+) to update the caller's counters.
_mb_apparmor_tally() {
    local -n _a_pass="$1"
    local -n _a_fail="$2"
    local -n _a_warn="$3"
    case "${_MB_APPARMOR_LAST_STATUS:-}" in
        PASS) _a_pass=$((_a_pass + 1)) ;;
        FAIL) _a_fail=$((_a_fail + 1)) ;;
        WARN) _a_warn=$((_a_warn + 1)) ;;
    esac
}

# ── Direct invocation support ─────────────────────────────────────────────────
# When executed directly (not sourced by mb), wire up mb helpers and dispatch.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _MB_APPARMOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/common.sh
    source "${_MB_APPARMOR_SCRIPT_DIR}/../lib/common.sh"
    # shellcheck source=lib/os.sh
    source "${_MB_APPARMOR_SCRIPT_DIR}/../lib/os.sh"
    mb_detect_os

    _mb_apparmor_usage() {
        cat <<'USAGE'
Usage: modules/apparmor.sh <command>

Commands:
  install               Install AppArmor, enable kernel params, load profiles, enforce mode
  audit                 Read-only status check (writes report to /var/log/apparmor-audit/)
  --enforce PROFILE     Switch a profile to enforce mode
  --complain PROFILE    Switch a profile to complain mode
  --list                List all profiles and their current mode
  --generate BINARY     Generate a new profile template for a binary (aa-genprof)
  help                  Show this help

Key services checked in audit:
  sshd, docker, nginx, mysql, postgres, redis
USAGE
    }

    case "${1:-help}" in
        install)
            mb_check_root
            mb_module_apparmor
            ;;
        audit)
            mb_module_apparmor_audit
            ;;
        --enforce)
            [ -z "${2:-}" ] && { echo "Error: profile name required" >&2; exit 1; }
            mb_check_root
            _mb_apparmor_enforce_profile "$2"
            mb_success "Profile '$2' set to enforce mode"
            ;;
        --complain)
            [ -z "${2:-}" ] && { echo "Error: profile name required" >&2; exit 1; }
            mb_check_root
            _mb_apparmor_complain_profile "$2"
            mb_success "Profile '$2' set to complain mode"
            ;;
        --list)
            _mb_apparmor_list_profiles
            ;;
        --generate)
            [ -z "${2:-}" ] && { echo "Error: binary path required" >&2; exit 1; }
            mb_check_root
            _mb_apparmor_generate_profile "$2"
            ;;
        help|-h|--help)
            _mb_apparmor_usage
            ;;
        *)
            echo "Unknown command: $1" >&2
            _mb_apparmor_usage
            exit 1
            ;;
    esac
fi
