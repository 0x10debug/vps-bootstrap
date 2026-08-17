#!/usr/bin/env bash
# lib/rollback.sh — Rollback logic for mb
# Sourced by mb. Do not execute directly.

# ── Rollback ─────────────────────────────────────────────────────────────────

mb_rollback() {
    # Rollback the last configuration change for a module (or all modules)
    local module="${1:-all}"

    if [ "$module" = "all" ]; then
        mb_step "Rolling back all modules..."
        # List all modules that have backups
        if [ -d "$MB_BACKUP_DIR" ]; then
            local modules=()
            for mod_dir in "$MB_BACKUP_DIR"/*/; do
                [ -d "$mod_dir" ] || continue
                modules+=("$(basename "$mod_dir")")
            done
            if [ ${#modules[@]} -eq 0 ]; then
                mb_warn "No module backups found."
                return 0
            fi
            for mod in "${modules[@]}"; do
                mb_rollback_module "$mod"
            done
        else
            mb_warn "No backups directory found ($MB_BACKUP_DIR)."
        fi
    else
        mb_rollback_module "$module"
    fi
}

mb_rollback_module() {
    local module="$1"
    local backup_dir
    backup_dir=$(mb_backup_latest "$module")

    if [ -z "$backup_dir" ]; then
        mb_warn "No backup found for module: $module"
        return 1
    fi

    mb_step "Rolling back module: $module"
    mb_detail "Restoring from: $backup_dir"

    # Restore all files in the backup
    local restored=0
    for backup_file in "$backup_dir"/*; do
        [ -f "$backup_file" ] || continue
        local filename
        filename=$(basename "$backup_file")
        # Skip state files
        case "$filename" in
            state-*.yaml) continue ;;
        esac

        # Try to find the original location
        # We backed up from various locations, so we need to check common paths
        local restored_path=""
        for candidate in \
            "/etc/apt/sources.list" \
            "/etc/ssh/sshd_config" \
            "/etc/ufw/user.rules" \
            "/etc/ufw/ufw.conf" \
            "/etc/nftables.nft" \
            "/etc/sysctl.d/99-mb.conf" \
            "/etc/security/limits.d/99-mb.conf" \
            "/etc/apt/apt.conf.d/50unattended-upgrades" \
            "/etc/apt/apt.conf.d/20auto-upgrades" \
            "/etc/crontabs/root" \
            "/etc/docker/daemon.json" \
            "/etc/motd" \
            "/etc/update-motd.d/99-mb-status" \
            "/etc/profile.d/mb-status.sh" \
            "/etc/ssh/sshd_config.d" \
            "/etc/ufw"; do
            if [ "$filename" = "$(basename "$candidate")" ]; then
                if [ -d "$candidate" ] && [ -d "$backup_file" ]; then
                    # Directory backup
                    cp -a "$backup_file"/* "$candidate"/ 2>/dev/null || true
                elif [ -f "$backup_file" ]; then
                    cp -a "$backup_file" "$candidate"
                fi
                mb_detail "  Restored: $candidate"
                restored_path="$candidate"
                restored=$((restored + 1))
                break
            fi
        done

        if [ -z "$restored_path" ]; then
            mb_warn "  Don't know where to restore: $filename"
        fi
    done

    if [ "$restored" -gt 0 ]; then
        mb_success "Restored $restored file(s) for module: $module"
    else
        mb_warn "No files restored for module: $module (backup may only contain state files)"
    fi

    # Always remove the done marker — rollback intent is to undo "completed" state
    rm -f "${MB_STATE_DIR}/${module}.done"
    mb_detail "Removed completion marker for: $module"
}

mb_rollback_list() {
    # List available rollback points
    if [ ! -d "$MB_BACKUP_DIR" ]; then
        mb_info "No backups available."
        return 0
    fi

    mb_step "Available rollback points:"
    for mod_dir in "$MB_BACKUP_DIR"/*/; do
        [ -d "$mod_dir" ] || continue
        local mod_name
        mod_name=$(basename "$mod_dir")
        local backups
        backups=$(ls -1 "$mod_dir" 2>/dev/null | grep -v '^state-' | wc -l | tr -d ' ')
        if [ "$backups" -gt 0 ]; then
            mb_detail "$mod_name: $backups backup(s)"
            ls -1 "$mod_dir" | grep -v '^state-' | sort -r | head -3 | while read -r ts; do
                echo "    - $ts"
            done
        fi
    done
}
