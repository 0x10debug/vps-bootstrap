#!/usr/bin/env bash
# tests/test-modules.sh — Test each module independently
#
# Runs each module in a fresh Docker container and verifies it completes
# without errors. Not all modules can be fully tested in Docker (e.g.,
# CrowdSec needs network access, kernel tuning may not apply in containers),
# but we verify the module scripts are syntactically valid and can be sourced.
#
# Usage: ./tests/test-modules.sh
# Requires: Docker (data on D drive per AGENTS.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="/Volumes/D/mb-test/vps-bootstrap-modules"

IMAGE="ubuntu:22.04"
CONTAINER_NAME="mb-test-modules"

MODULES=(system user ssh firewall crowdsec kernel autoupdate docker motd cis_align partition_check auditd apparmor auto_updates tailscale)

echo "=== Module Independence Test ==="
echo "Image: ${IMAGE}"
echo "Modules: ${MODULES[*]}"
echo ""

mkdir -p "$TEST_DIR"

# Cleanup
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Start container
echo "Starting test container..."
docker run -d --name "$CONTAINER_NAME" \
    -v "${PROJECT_DIR}:/mb:ro" \
    --privileged \
    "$IMAGE" sleep infinity

trap 'docker rm -f "$CONTAINER_NAME" 2>/dev/null || true' EXIT

# Install deps
echo "Installing dependencies..."
docker exec "$CONTAINER_NAME" bash -c "apt-get update -qq && apt-get install -y -qq sudo curl wget git bash > /dev/null 2>&1"

PASS=true
RESULTS=()

for mod in "${MODULES[@]}"; do
    echo ""
    echo "--- Testing module: $mod ---"

    # 1. Syntax check: verify the module script is valid bash
    echo -n "  Syntax check: "
    if docker exec "$CONTAINER_NAME" bash -c "bash -n /mb/modules/${mod}.sh" 2>/dev/null; then
        echo "✅ OK"
        RESULTS+=("✅ ${mod}: syntax OK")
    else
        echo "❌ FAIL"
        RESULTS+=("❌ ${mod}: syntax error")
        PASS=false
        continue
    fi

    # 2. Sourcing check: verify the module can be sourced without errors
    echo -n "  Source check: "
    if docker exec "$CONTAINER_NAME" bash -c "source /mb/lib/common.sh && source /mb/lib/os.sh && source /mb/modules/${mod}.sh" 2>/dev/null; then
        echo "✅ OK"
        RESULTS+=("✅ ${mod}: source OK")
    else
        echo "❌ FAIL"
        RESULTS+=("❌ ${mod}: source error")
        PASS=false
        continue
    fi

    # 3. Function check: verify the module function exists
    echo -n "  Function check: "
    if docker exec "$CONTAINER_NAME" bash -c "source /mb/lib/common.sh && source /mb/lib/os.sh && source /mb/modules/${mod}.sh && type mb_module_${mod} 2>/dev/null" 2>/dev/null; then
        echo "✅ OK"
        RESULTS+=("✅ ${mod}: function exists")
    else
        echo "❌ FAIL"
        RESULTS+=("❌ ${mod}: function missing")
        PASS=false
        continue
    fi
done

# Summary
echo ""
echo "=== Results ==="
for r in "${RESULTS[@]}"; do
    echo "  $r"
done

echo ""
if [ "$PASS" = true ]; then
    echo "✅ All module tests PASSED"
    exit 0
else
    echo "❌ Some module tests FAILED"
    exit 1
fi
