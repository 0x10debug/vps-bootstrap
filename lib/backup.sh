#!/usr/bin/env bash
# lib/backup.sh — Configuration backup logic
# Sourced by mb and modules. Do not execute directly.

# ── Backup management ────────────────────────────────────────────────────────

mb_backup_init() {
    # Initialize backup directory structure for a module
    local module="$1"
    mkdir -p "${MB_BACKUP_DIR}/${module}"
}

mb_backup_list() {
    # List all backups for a module
    local module="$1"
    local dir="${MB_BACKUP_DIR}/${module}"
    if [ -d "$dir" ]; then
        ls -1 "$dir" | sort -r
    fi
}

mb_backup_latest() {
    # Echo the path to the latest backup for a module
    local module="$1"
    local dir="${MB_BACKUP_DIR}/${module}"
    if [ -d "$dir" ]; then
        local latest
        latest=$(ls -1 "$dir" | sort -r | head -1)
        if [ -n "$latest" ]; then
            echo "${dir}/${latest}"
        fi
    fi
}

mb_backup_restore() {
    # Restore a file from the latest backup of a module
    local module="$1" file="$2"
    local backup_dir
    backup_dir=$(mb_backup_latest "$module")
    if [ -z "$backup_dir" ]; then
        mb_error "No backup found for module: $module"
        return 1
    fi
    local backup_file="${backup_dir}/$(basename "$file")"
    if [ -f "$backup_file" ]; then
        cp -a "$backup_file" "$file"
        mb_success "Restored $file from $backup_file"
    else
        mb_error "Backup file not found: $backup_file"
        return 1
    fi
}

mb_backup_save_state() {
    # Save the current module state (which modules are done, current config)
    # Used before making changes, for rollback
    local module="$1"
    local state_file="${MB_BACKUP_DIR}/${module}/state-$(date '+%Y%m%d-%H%M%S').yaml"
    mkdir -p "${MB_BACKUP_DIR}/${module}"

    {
        echo "# mb state snapshot for ${module}"
        echo "timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "module: ${module}"
        echo "os: ${MB_OS_DISTRO:-unknown} ${MB_OS_VERSION:-0}"
        echo "modules_done:"
        if [ -d "$MB_STATE_DIR" ]; then
            for done_file in "$MB_STATE_DIR"/*.done; do
                [ -f "$done_file" ] || continue
                local mod_name
                mod_name=$(basename "$done_file" .done)
                local mod_time
                mod_time=$(cat "$done_file")
                echo "  - ${mod_name}: ${mod_time}"
            done
        fi
    } > "$state_file"

    mb_detail "State saved to $state_file"
}
