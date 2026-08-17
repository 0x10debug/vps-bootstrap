#!/usr/bin/env bash
# install.sh — One-command installer for mb (mb)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/0x10debug/vps-bootstrap/main/install.sh | bash
#
# Or download and run:
#   wget -qO install.sh https://raw.githubusercontent.com/0x10debug/vps-bootstrap/main/install.sh
#   bash install.sh

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

REPO_URL="https://github.com/0x10debug/vps-bootstrap"
INSTALL_DIR="/opt/mb"
BIN_PATH="/usr/local/bin/mb"

# ── Colors ───────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
    BLUE='\033[0;34m' BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

log()  { echo -e "${DIM}[$(date '+%H:%M:%S')]${RESET} ${BLUE}INFO${RESET} $*"; }
ok()   { echo -e "${DIM}[$(date '+%H:%M:%S')]${RESET} ${GREEN}OK${RESET} $*"; }
warn() { echo -e "${DIM}[$(date '+%H:%M:%S')]${RESET} ${YELLOW}WARN${RESET} $*" >&2; }
err()  { echo -e "${DIM}[$(date '+%H:%M:%S')]${RESET} ${RED}ERROR${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# ── Pre-flight checks ────────────────────────────────────────────────────────

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    die "This installer must be run as root. Try: sudo bash install.sh"
fi

# Check for curl or wget
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "Neither curl nor wget is installed. Install one of them first."
fi

# Check for git
if ! command -v git >/dev/null 2>&1; then
    log "Installing git..."
    if command -v apt >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq git
    elif command -v apk >/dev/null 2>&1; then
        apk add --quiet git
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q git
    else
        die "Could not install git. Please install it manually."
    fi
fi

# ── Banner ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║  mb — VPS Initialization & Security Hardening        ║${RESET}"
echo -e "${BOLD}║  Installer                                           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Install ──────────────────────────────────────────────────────────────────

log "Installing mb to ${INSTALL_DIR}..."

# Remove old installation if present
if [ -d "$INSTALL_DIR" ]; then
    log "Removing existing installation..."
    rm -rf "$INSTALL_DIR"
fi

# Clone the repository
log "Downloading mb..."
if ! git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>/dev/null; then
    die "Failed to download mb. Check your network connection."
fi

# Remove .git directory (not needed for installed copy)
rm -rf "${INSTALL_DIR}/.git"

# Make mb executable
chmod +x "${INSTALL_DIR}/mb"

# Create symlink in PATH
log "Creating symlink: ${BIN_PATH} → ${INSTALL_DIR}/mb"
ln -sf "${INSTALL_DIR}/mb" "$BIN_PATH"

# Verify installation
if command -v mb >/dev/null 2>&1; then
    ok "mb installed successfully: $(mb help 2>&1 | head -1)"
else
    die "Installation verification failed. ${BIN_PATH} not in PATH."
fi

# ── Post-install guidance ────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}What's next?${RESET}"
echo ""
echo "  1. Run the initialization wizard (recommended for first-time users):"
echo ""
echo -e "     ${BOLD}mb init${RESET}"
echo ""
echo "  2. Or run specific modules only:"
echo ""
echo -e "     ${BOLD}mb init --module system,ssh,firewall${RESET}"
echo ""
echo "  3. Check your hardening status at any time:"
echo ""
echo -e "     ${BOLD}mb status${RESET}"
echo ""
echo "  4. If something goes wrong, rollback:"
echo ""
echo -e "     ${BOLD}mb rollback ssh${RESET}    (rollback SSH changes)"
echo -e "     ${BOLD}mb rollback all${RESET}    (rollback everything)"
echo ""
echo -e "${DIM}Documentation: https://github.com/0x10debug/vps-bootstrap${RESET}"
echo ""
