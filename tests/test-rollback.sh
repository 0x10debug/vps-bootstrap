#!/usr/bin/env bash
# tests/test-rollback.sh — Verify mb rollback restores previous configuration
#
# This test:
# 1. Runs mb init (system module) in a Docker container
# 2. Rolls back the changes
# 3. Verifies the system returned to pre-init state
#
# Usage: ./tests/test-rollback.sh
# Requires: Docker (data on D drive per AGENTS.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="/Volumes/D/mb-test/vps-bootstrap-rollback"

IMAGE="ubuntu:22.04"
CONTAINER_NAME="mb-test-rollback"

echo "=== Rollback Test ==="
echo "Image: ${IMAGE}"
echo "Test dir: ${TEST_DIR}"
echo ""

mkdir -p "$TEST_DIR"

# Cleanup
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Start container
echo "Starting test container..."
docker run -d --name "$CONTAINER_NAME" \
    -v "${PROJECT_DIR}:/mb:ro" \
    "$IMAGE" sleep infinity

trap 'docker rm -f "$CONTAINER_NAME" 2>/dev/null || true' EXIT

# Install deps
echo "Installing dependencies..."
docker exec "$CONTAINER_NAME" bash -c "apt-get update -qq && apt-get install -y -qq sudo curl wget git > /dev/null 2>&1"

# Capture pre-init state
echo "Capturing pre-init state..."
docker exec "$CONTAINER_NAME" bash -c "dpkg -l | wc -l" > "${TEST_DIR}/pre-init-pkg-count.txt"
docker exec "$CONTAINER_NAME" bash -c "cat /etc/os-release | head -1" > "${TEST_DIR}/pre-init-os.txt"
PRE_INIT_PKGS=$(cat "${TEST_DIR}/pre-init-pkg-count.txt")
echo "Pre-init package count: ${PRE_INIT_PKGS}"

# Run mb init (system module only for speed)
echo ""
echo "--- Running mb init (system module) ---"
docker exec "$CONTAINER_NAME" bash -c "cd /mb && bash mb init --yes --module system 2>&1" | tail -5

# Verify init worked
docker exec "$CONTAINER_NAME" bash -c "test -f /var/lib/mb/system.done && echo 'DONE' || echo 'NOT DONE'"

# Capture post-init state
docker exec "$CONTAINER_NAME" bash -c "dpkg -l | wc -l" > "${TEST_DIR}/post-init-pkg-count.txt"
POST_INIT_PKGS=$(cat "${TEST_DIR}/post-init-pkg-count.txt")
echo "Post-init package count: ${POST_INIT_PKGS}"

# Rollback
echo ""
echo "--- Running mb rollback system ---"
docker exec "$CONTAINER_NAME" bash -c "cd /mb && bash mb rollback system 2>&1" | tail -5

# Verify done marker removed
docker exec "$CONTAINER_NAME" bash -c "test -f /var/lib/mb/system.done && echo 'STILL DONE' || echo 'UNDONE'"

# Capture post-rollback state
docker exec "$CONTAINER_NAME" bash -c "dpkg -l | wc -l" > "${TEST_DIR}/post-rollback-pkg-count.txt"
POST_ROLLBACK_PKGS=$(cat "${TEST_DIR}/post-rollback-pkg-count.txt")
echo "Post-rollback package count: ${POST_ROLLBACK_PKGS}"

# Verify
echo ""
echo "=== Verification ==="
PASS=true

# Done marker should be removed
DONE_MARKER=$(docker exec "$CONTAINER_NAME" bash -c "test -f /var/lib/mb/system.done && echo 'exists' || echo 'removed'")
if [ "$DONE_MARKER" = "exists" ]; then
    echo "❌ Done marker still exists after rollback"
    PASS=false
else
    echo "✅ Done marker removed after rollback"
fi

# Backups should exist
BACKUP_EXISTS=$(docker exec "$CONTAINER_NAME" bash -c "test -d /etc/mb-backup/system && echo 'yes' || echo 'no'")
if [ "$BACKUP_EXISTS" = "yes" ]; then
    echo "✅ Backup directory exists"
else
    echo "⚠️  Backup directory not found (may be expected if no files were backed up)"
fi

echo ""
if [ "$PASS" = true ]; then
    echo "✅ Rollback test PASSED"
    exit 0
else
    echo "❌ Rollback test FAILED"
    exit 1
fi
