#!/usr/bin/env bash
# tests/test-idempotent.sh — Verify mb is idempotent (safe to run multiple times)
#
# This test runs mb init in a Docker container 3 times and checks that
# the system state is consistent across runs.
#
# Usage: ./tests/test-idempotent.sh
# Requires: Docker (data on D drive per AGENTS.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="/Volumes/D/mb-test/vps-bootstrap-idempotent"

IMAGE="ubuntu:22.04"
CONTAINER_NAME="mb-test-idempotent"

echo "=== Idempotency Test ==="
echo "Image: ${IMAGE}"
echo "Test dir: ${TEST_DIR}"
echo ""

# Ensure D drive test directory exists
mkdir -p "$TEST_DIR"

# Cleanup any previous test container
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Start fresh container
echo "Starting test container..."
docker run -d --name "$CONTAINER_NAME" \
    -v "${PROJECT_DIR}:/mb:ro" \
    "$IMAGE" sleep infinity

trap 'docker rm -f "$CONTAINER_NAME" 2>/dev/null || true' EXIT

# Install dependencies in container
echo "Installing dependencies in container..."
docker exec "$CONTAINER_NAME" bash -c "apt-get update -qq && apt-get install -y -qq sudo curl wget git > /dev/null 2>&1"

# Run mb init 3 times
for i in 1 2 3; do
    echo ""
    echo "--- Run $i ---"
    docker exec "$CONTAINER_NAME" bash -c "cd /mb && bash mb init --yes --module system 2>&1" | tail -5

    # Capture state (existence of done marker, not timestamp — timestamp updates each run by design)
    docker exec "$CONTAINER_NAME" bash -c "test -f /var/lib/mb/system.done && echo 'DONE' || echo 'NOT_DONE'" > "${TEST_DIR}/run-${i}-state.txt"
    docker exec "$CONTAINER_NAME" bash -c "dpkg -l | grep -c curl" > "${TEST_DIR}/run-${i}-packages.txt"
done

# Compare states
echo ""
echo "=== Comparing states ==="
RUN1_STATE=$(cat "${TEST_DIR}/run-1-state.txt")
RUN2_STATE=$(cat "${TEST_DIR}/run-2-state.txt")
RUN3_STATE=$(cat "${TEST_DIR}/run-3-state.txt")

RUN1_PKGS=$(cat "${TEST_DIR}/run-1-packages.txt")
RUN2_PKGS=$(cat "${TEST_DIR}/run-2-packages.txt")
RUN3_PKGS=$(cat "${TEST_DIR}/run-3-packages.txt")

echo "Run 1: state=${RUN1_STATE}, packages=${RUN1_PKGS}"
echo "Run 2: state=${RUN2_STATE}, packages=${RUN2_PKGS}"
echo "Run 3: state=${RUN3_STATE}, packages=${RUN3_PKGS}"

# Verify
PASS=true

if [ "$RUN1_STATE" != "$RUN2_STATE" ] || [ "$RUN2_STATE" != "$RUN3_STATE" ]; then
    echo "❌ State changed across runs (not idempotent)"
    PASS=false
fi

if [ "$RUN1_PKGS" != "$RUN2_PKGS" ] || [ "$RUN2_PKGS" != "$RUN3_PKGS" ]; then
    echo "❌ Package count changed across runs (not idempotent)"
    PASS=false
fi

echo ""
if [ "$PASS" = true ]; then
    echo "✅ Idempotency test PASSED"
    exit 0
else
    echo "❌ Idempotency test FAILED"
    exit 1
fi
