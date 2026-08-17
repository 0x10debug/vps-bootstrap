#!/usr/bin/env bash
# lib/common.sh — Common functions for mb (mb)
# Sourced by mb and all modules. Do not execute directly.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

MB_VERSION="0.1.0"
MB_BACKUP_DIR="/etc/mb-backup"
MB_STATE_DIR="/var/lib/mb"
MB_LOG_DIR="/var/log/mb"
MB_CONFIG_DIR="/etc/mb"
MB_ENV_FILE="${MB_CONFIG_DIR}/env.sh"

# ── Colors ───────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    MB_RED='\033[0;31m'
    MB_GREEN='\033[0;32m'
    MB_YELLOW='\033[0;33m'
    MB_BLUE='\033[0;34m'
    MB_BOLD='\033[1m'
    MB_DIM='\033[2m'
    MB_RESET='\033[0m'
else
    MB_RED='' MB_GREEN='' MB_YELLOW='' MB_BLUE='' MB_BOLD='' MB_DIM='' MB_RESET=''
fi

# ── Logging ──────────────────────────────────────────────────────────────────

mb_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${MB_DIM}[${ts}]${MB_RESET} ${level} ${msg}"
}

mb_info()    { mb_log "${MB_BLUE}INFO${MB_RESET}"    "$*"; }
mb_success() { mb_log "${MB_GREEN}OK${MB_RESET}"    "$*"; }
mb_warn()    { mb_log "${MB_YELLOW}WARN${MB_RESET}"  "$*"; }
mb_error()   { mb_log "${MB_RED}ERROR${MB_RESET}"   "$*" >&2; }
mb_step()    { echo -e "\n${MB_BOLD}${MB_BLUE}==>${MB_RESET} ${MB_BOLD}$*${MB_RESET}"; }
mb_detail()  { echo -e "  ${MB_DIM}$*${MB_RESET}"; }

# ── Error handling ───────────────────────────────────────────────────────────

mb_die() {
    mb_error "$*"
    exit 1
}

mb_run() {
    # Run a command, log on failure, but don't exit (caller decides)
    if ! "$@" >/dev/null 2>&1; then
        mb_warn "Command failed: $*"
        return 1
    fi
    return 0
}

mb_run_verbose() {
    # Run a command with output visible
    "$@"
}

# ── Idempotency helpers ──────────────────────────────────────────────────────

mb_check_command() {
    # Returns 0 if command exists, 1 otherwise
    command -v "$1" >/dev/null 2>&1
}

mb_check_package() {
    # Returns 0 if package is installed (dpkg), 1 otherwise
    dpkg -s "$1" >/dev/null 2>&1
}

mb_check_file_contains() {
    # Returns 0 if file exists and contains the pattern
    local file="$1" pattern="$2"
    [ -f "$file" ] && grep -q "$pattern" "$file"
}

mb_mark_done() {
    # Mark a module as completed
    local module="$1"
    mkdir -p "$MB_STATE_DIR"
    date '+%Y-%m-%d %H:%M:%S' > "${MB_STATE_DIR}/${module}.done"
}

mb_is_done() {
    # Check if a module has been completed
    local module="$1"
    [ -f "${MB_STATE_DIR}/${module}.done" ]
}

# ── Backup helpers ───────────────────────────────────────────────────────────

mb_backup_file() {
    # Backup a file before modifying it. Creates timestamped copy.
    local file="$1"
    local module="${2:-general}"
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local backup_dir="${MB_BACKUP_DIR}/${module}/${ts}"
    if [ -f "$file" ]; then
        mkdir -p "$backup_dir"
        cp -a "$file" "${backup_dir}/$(basename "$file")"
        mb_detail "Backed up $file → ${backup_dir}"
    fi
}

mb_backup_dir() {
    # Backup an entire directory before modifying it
    local dir="$1"
    local module="${2:-general}"
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local backup_dir="${MB_BACKUP_DIR}/${module}/${ts}"
    if [ -d "$dir" ]; then
        mkdir -p "$backup_dir"
        cp -a "$dir" "${backup_dir}/$(basename "$dir")"
        mb_detail "Backed up $dir → ${backup_dir}"
    fi
}

# ── Interaction helpers ──────────────────────────────────────────────────────

mb_ask() {
    # Ask a yes/no question. Returns 0 for yes, 1 for no.
    local prompt="$1" default="${2:-y}"
    local reply
    if [ "$default" = "y" ]; then
        read -rp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET} [Y/n] ")" reply
        reply="${reply:-y}"
    else
        read -rp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET} [y/N] ")" reply
        reply="${reply:-n}"
    fi
    case "$reply" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        *) return 1 ;;
    esac
}

mb_ask_value() {
    # Ask for a value with a default. Echoes the result.
    local prompt="$1" default="${2:-}"
    local reply
    if [ -n "$default" ]; then
        read -rp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET} [${default}]: ")" reply
        echo "${reply:-$default}"
    else
        read -rp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET}: ")" reply
        echo "$reply"
    fi
}

mb_ask_secret() {
    # Ask for a secret value (no echo). Echoes the result.
    local prompt="$1"
    local reply
    read -rsp "$(echo -e "${MB_BOLD}${prompt}${MB_RESET}: ")" reply
    echo "" >&2
    echo "$reply"
}

# ── Environment file ─────────────────────────────────────────────────────────

mb_env_set() {
    # Set a key-value pair in the environment file
    local key="$1" value="$2"
    mkdir -p "$MB_CONFIG_DIR"
    touch "$MB_ENV_FILE"
    # Remove existing key, then append
    sed -i "/^${key}=/d" "$MB_ENV_FILE" 2>/dev/null || true
    echo "${key}=\"${value}\"" >> "$MB_ENV_FILE"
}

mb_env_get() {
    # Get a value from the environment file
    local key="$1"
    if [ -f "$MB_ENV_FILE" ]; then
        grep "^${key}=" "$MB_ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '"'
    fi
}

mb_env_source() {
    # Source the environment file if it exists
    if [ -f "$MB_ENV_FILE" ]; then
        # shellcheck disable=SC1090
        source "$MB_ENV_FILE"
    fi
}

# ── Module loading ───────────────────────────────────────────────────────────

MB_MODULE_DIR=""
mb_set_module_dir() {
    MB_MODULE_DIR="$1"
}

mb_load_module() {
    local module="$1"
    local script="${MB_MODULE_DIR}/${module}.sh"
    if [ ! -f "$script" ]; then
        mb_die "Module not found: $module ($script)"
    fi
    # shellcheck disable=SC1090
    source "$script"
}

# ── Prerequisite checks ──────────────────────────────────────────────────────

mb_check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        mb_die "This command must be run as root (or with sudo)."
    fi
}

mb_check_not_root_session() {
    # Warn if running in a pure root SSH session (risky if SSH gets broken)
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        mb_warn "Running via sudo as root. Make sure you have another SSH session open."
    elif [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
        mb_warn "Running as root directly. Ensure you have a non-root SSH session as backup."
    fi
}
