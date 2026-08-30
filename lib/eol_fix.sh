#!/usr/bin/env bash
# lib/eol_fix.sh — EOL (End-of-Life) distribution source fix library
# Sourced by mb and modules. Do not execute directly.
#
# Detects EOL distributions and switches package sources to archive mirrors
# so that apt/yum can still function for bootstrap and hardening. Supports:
#   - Ubuntu: archive.ubuntu.com → old-releases.ubuntu.com
#   - Debian: archive.debian.org (for EOL releases)
#   - CentOS 7/8: vault.centos.org
#
# Features:
#   - Detect EOL distros (Ubuntu 16.04/18.04, CentOS 7/8, Debian 9/10)
#   - Backup original sources.list before modifying
#   - Switch to archive sources automatically
#   - --dry-run: preview changes without modifying
#   - --restore: restore from backup

# ── EOL detection ─────────────────────────────────────────────────────────────

# Known EOL versions (major version numbers)
# Ubuntu: 16.04 (16), 18.04 (18) — EOL as of 2023/2024
# Debian: 9 (stretch), 10 (buster) — EOL as of 2022/2024
# CentOS: 7, 8 — EOL as of 2024/2021

# mb_eol_is_eol
# Returns 0 if the current distribution is EOL, 1 otherwise.
# Sets MB_EOL_DISTRO and MB_EOL_VERSION on detection.
mb_eol_is_eol() {
    MB_EOL_DISTRO="${MB_OS_DISTRO:-unknown}"
    MB_EOL_VERSION="${MB_OS_VERSION:-0}"

    case "$MB_EOL_DISTRO" in
        ubuntu)
            case "$MB_EOL_VERSION" in
                16|18) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        debian)
            case "$MB_EOL_VERSION" in
                9|10) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        centos)
            case "$MB_EOL_VERSION" in
                7|8) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

# mb_eol_detect
# Detects EOL status and echoes a human-readable description.
mb_eol_detect() {
    if mb_eol_is_eol; then
        echo "EOL detected: ${MB_EOL_DISTRO} ${MB_EOL_VERSION}"
        return 0
    else
        echo "Not EOL: ${MB_OS_DISTRO:-unknown} ${MB_OS_VERSION:-0}"
        return 1
    fi
}

# ── Source fixing ─────────────────────────────────────────────────────────────

MB_EOL_BACKUP_DIR="${MB_BACKUP_DIR}/eol-fix"

# mb_eol_backup_sources
# Backs up the current sources configuration before modifying.
mb_eol_backup_sources() {
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local backup_dir="${MB_EOL_BACKUP_DIR}/${ts}"
    mkdir -p "$backup_dir"

    case "${MB_OS_DISTRO:-}" in
        ubuntu|debian)
            if [ -f /etc/apt/sources.list ]; then
                cp -a /etc/apt/sources.list "$backup_dir/"
            fi
            # Also backup sources.list.d
            if [ -d /etc/apt/sources.list.d ]; then
                cp -a /etc/apt/sources.list.d "$backup_dir/sources.list.d"
            fi
            ;;
        centos)
            if [ -d /etc/yum.repos.d ]; then
                cp -a /etc/yum.repos.d "$backup_dir/"
            fi
            ;;
    esac

    mb_detail "Backed up sources to ${backup_dir}"
    echo "$backup_dir"
}

# mb_eol_fix_ubuntu
# Fixes Ubuntu EOL sources: archive.ubuntu.com → old-releases.ubuntu.com
mb_eol_fix_ubuntu() {
    local dry_run="${1:-false}"
    local sources_file="/etc/apt/sources.list"

    if [ ! -f "$sources_file" ]; then
        mb_warn "Ubuntu sources.list not found at ${sources_file}"
        return 1
    fi

    local codename
    case "$MB_EOL_VERSION" in
        16) codename="xenial" ;;
        18) codename="bionic" ;;
        *)  codename="" ;;
    esac

    if [ -z "$codename" ]; then
        mb_warn "Unknown Ubuntu EOL version: ${MB_EOL_VERSION}"
        return 1
    fi

    mb_info "Switching Ubuntu ${codename} sources to old-releases.ubuntu.com..."

    if [ "$dry_run" = true ]; then
        mb_info "[dry-run] Would replace archive.ubuntu.com with old-releases.ubuntu.com in ${sources_file}"
        mb_info "[dry-run] Would replace security.ubuntu.com with old-releases.ubuntu.com in ${sources_file}"
        if [ -d /etc/apt/sources.list.d ]; then
            mb_info "[dry-run] Would also fix files in /etc/apt/sources.list.d/"
        fi
        return 0
    fi

    # Backup before modifying
    mb_eol_backup_sources >/dev/null

    # Replace archive.ubuntu.com and security.ubuntu.com with old-releases.ubuntu.com
    sed -i \
        -e 's|archive\.ubuntu\.com|old-releases.ubuntu.com|g' \
        -e 's|security\.ubuntu\.com|old-releases.ubuntu.com|g' \
        "$sources_file"

    # Also fix any .list files in sources.list.d
    if [ -d /etc/apt/sources.list.d ]; then
        local f
        for f in /etc/apt/sources.list.d/*.list; do
            [ -f "$f" ] || continue
            sed -i \
                -e 's|archive\.ubuntu\.com|old-releases.ubuntu.com|g' \
                -e 's|security\.ubuntu\.com|old-releases.ubuntu.com|g' \
                "$f"
        done
    fi

    mb_detail "Ubuntu sources switched to old-releases.ubuntu.com"
}

# mb_eol_fix_debian
# Fixes Debian EOL sources: switches to archive.debian.org
mb_eol_fix_debian() {
    local dry_run="${1:-false}"
    local sources_file="/etc/apt/sources.list"

    if [ ! -f "$sources_file" ]; then
        mb_warn "Debian sources.list not found at ${sources_file}"
        return 1
    fi

    local codename
    case "$MB_EOL_VERSION" in
        9)  codename="stretch" ;;
        10) codename="buster" ;;
        *)  codename="" ;;
    esac

    if [ -z "$codename" ]; then
        mb_warn "Unknown Debian EOL version: ${MB_EOL_VERSION}"
        return 1
    fi

    mb_info "Switching Debian ${codename} sources to archive.debian.org..."

    if [ "$dry_run" = true ]; then
        mb_info "[dry-run] Would replace deb.debian.org with archive.debian.org in ${sources_file}"
        mb_info "[dry-run] Would replace security.debian.org with archive.debian.org in ${sources_file}"
        mb_info "[dry-run] Would remove [check-valid-until] requirement (archive sources)"
        return 0
    fi

    # Backup before modifying
    mb_eol_backup_sources >/dev/null

    # Replace deb.debian.org and security.debian.org with archive.debian.org
    sed -i \
        -e 's|deb\.debian\.org|archive.debian.org|g' \
        -e 's|security\.debian\.org|archive.debian.org|g' \
        "$sources_file"

    # Debian archive sources need Acquire::Check-Valid-Until "false";
    # add a config file for apt to skip expired signature checks
    local apt_conf="/etc/apt/apt.conf.d/10no-check-valid-until"
    if [ ! -f "$apt_conf" ]; then
        echo 'Acquire::Check-Valid-Until "false";' > "$apt_conf"
        mb_detail "Created ${apt_conf} to skip valid-until check for archived sources"
    fi

    mb_detail "Debian sources switched to archive.debian.org"
}

# mb_eol_fix_centos
# Fixes CentOS EOL sources: switches to vault.centos.org
mb_eol_fix_centos() {
    local dry_run="${1:-false}"
    local repos_dir="/etc/yum.repos.d"

    if [ ! -d "$repos_dir" ]; then
        mb_warn "CentOS repos directory not found at ${repos_dir}"
        return 1
    fi

    local codename
    case "$MB_EOL_VERSION" in
        7) codename="7" ;;
        8) codename="8" ;;
        *) codename="" ;;
    esac

    if [ -z "$codename" ]; then
        mb_warn "Unknown CentOS EOL version: ${MB_EOL_VERSION}"
        return 1
    fi

    mb_info "Switching CentOS ${codename} sources to vault.centos.org..."

    if [ "$dry_run" = true ]; then
        mb_info "[dry-run] Would replace mirrorlist with vault.centos.org in ${repos_dir}/*.repo"
        mb_info "[dry-run] Would replace baseurl mirrors with vault.centos.org"
        return 0
    fi

    # Backup before modifying
    mb_eol_backup_sources >/dev/null

    local repo_file
    for repo_file in "$repos_dir"/*.repo; do
        [ -f "$repo_file" ] || continue

        # Comment out mirrorlist lines
        sed -i 's|^mirrorlist=|#mirrorlist=|g' "$repo_file"

        # Replace baseurl mirrors with vault.centos.org
        if [ "$MB_EOL_VERSION" = "7" ]; then
            sed -i \
                -e 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
                -e 's|http://mirror\.centos\.org|http://vault.centos.org|g' \
                "$repo_file"
        elif [ "$MB_EOL_VERSION" = "8" ]; then
            # shellcheck disable=SC2016 # $contentdir is a yum variable, not a shell var; keep literal in sed
            sed -i \
                -e 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
                -e 's|http://mirror\.centos\.org|http://vault.centos.org|g' \
                -e 's|baseurl=http://vault.centos.org/$contentdir|baseurl=http://vault.centos.org/8.5.2111|g' \
                "$repo_file"
        fi
    done

    mb_detail "CentOS sources switched to vault.centos.org"
}

# mb_eol_fix_sources
# Main entry point: detects EOL and fixes sources for the current distribution.
# Arguments:
#   --dry-run   Preview changes without modifying
#   --restore   Restore from the latest backup
mb_eol_fix_sources() {
    local dry_run=false
    local restore=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)  dry_run=true; shift ;;
            --restore)  restore=true; shift ;;
            *) mb_die "Unknown eol-fix option: $1" ;;
        esac
    done

    mb_detect_os 2>/dev/null || true

    # ── Restore mode ─────────────────────────────────────────────────────────
    if [ "$restore" = true ]; then
        mb_info "Restoring sources from latest EOL-fix backup..."
        local latest_backup
        latest_backup=$(find "$MB_EOL_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r | head -1)

        if [ -z "$latest_backup" ]; then
            mb_warn "No EOL-fix backup found in ${MB_EOL_BACKUP_DIR}"
            return 1
        fi

        local backup_path="$latest_backup"
        mb_info "Restoring from: ${backup_path}"

        case "${MB_OS_DISTRO:-}" in
            ubuntu|debian)
                if [ -f "${backup_path}/sources.list" ]; then
                    cp -a "${backup_path}/sources.list" /etc/apt/sources.list
                    mb_detail "Restored /etc/apt/sources.list"
                fi
                if [ -d "${backup_path}/sources.list.d" ]; then
                    rm -rf /etc/apt/sources.list.d
                    cp -a "${backup_path}/sources.list.d" /etc/apt/sources.list.d
                    mb_detail "Restored /etc/apt/sources.list.d/"
                fi
                # Remove the valid-until override if it exists
                rm -f /etc/apt/apt.conf.d/10no-check-valid-until 2>/dev/null || true
                ;;
            centos)
                if [ -d "${backup_path}/yum.repos.d" ]; then
                    rm -rf /etc/yum.repos.d
                    cp -a "${backup_path}/yum.repos.d" /etc/yum.repos.d
                    mb_detail "Restored /etc/yum.repos.d/"
                fi
                ;;
        esac

        mb_success "Sources restored from backup"
        return 0
    fi

    # ── Fix mode ─────────────────────────────────────────────────────────────
    if ! mb_eol_is_eol; then
        mb_info "Current distribution is not EOL. No source fix needed."
        return 0
    fi

    mb_step "EOL distribution detected: ${MB_EOL_DISTRO} ${MB_EOL_VERSION}"

    if [ "$dry_run" = true ]; then
        mb_info "DRY RUN — no changes will be made"
    fi

    case "$MB_EOL_DISTRO" in
        ubuntu)
            mb_eol_fix_ubuntu "$dry_run"
            ;;
        debian)
            mb_eol_fix_debian "$dry_run"
            ;;
        centos)
            mb_eol_fix_centos "$dry_run"
            ;;
        *)
            mb_warn "No EOL fix available for: ${MB_EOL_DISTRO}"
            return 1
            ;;
    esac

    if [ "$dry_run" = false ]; then
        mb_success "EOL sources fixed. Run 'mb_pkg_update' to refresh package index."
    else
        mb_success "Dry run complete. Re-run without --dry-run to apply changes."
    fi
}
