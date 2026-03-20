#!/usr/bin/env bash
# Local Docker-based integration test runner for horde_monitoring
# Builds a systemd+Docker container, runs Ansible against it, verifies results.
#
# Usage:
#   ./tests/run_tests.sh                     # run all test playbooks
#   ./tests/run_tests.sh test_full_stack     # run a specific test (without .yml)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER_NAME="test-monitoring"
IMAGE_NAME="horde-test-systemd"

# Colours (disabled when not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; NC=''
fi

log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*"; }

cleanup() {
  log "Cleaning up container ${CONTAINER_NAME}..."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}

# ── Build the test image ────────────────────────────────────────────
build_image() {
  log "Building test image ${IMAGE_NAME}..."
  docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.systemd" "$SCRIPT_DIR"
}

# ── Start the test container ────────────────────────────────────────
start_container() {
  # Remove stale container
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  log "Starting container ${CONTAINER_NAME}..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --privileged \
    --cgroupns=host \
    --memory=2g \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    "$IMAGE_NAME"

  # Wait for systemd to finish booting
  log "Waiting for systemd to initialise..."
  local retries=30
  while [ $retries -gt 0 ]; do
    if docker exec "$CONTAINER_NAME" systemctl is-system-running --wait 2>/dev/null | grep -qE "running|degraded"; then
      break
    fi
    retries=$((retries - 1))
    sleep 1
  done

  if [ $retries -eq 0 ]; then
    warn "systemd did not reach 'running' — continuing anyway (may be 'degraded' in container)"
  fi

  log "Container ready (systemd running)"
}

# ── Locate ansible-playbook ──────────────────────────────────────────
# Prefer the repo venv, fall back to PATH
if [ -x "$REPO_ROOT/.venv/bin/ansible-playbook" ]; then
  ANSIBLE_PLAYBOOK="$REPO_ROOT/.venv/bin/ansible-playbook"
else
  ANSIBLE_PLAYBOOK="$(command -v ansible-playbook 2>/dev/null || true)"
fi

if [ -z "$ANSIBLE_PLAYBOOK" ]; then
  err "ansible-playbook not found. Install it or create a venv at ${REPO_ROOT}/.venv"
  exit 1
fi

# ── Run a single test playbook ──────────────────────────────────────
run_playbook() {
  local playbook="$1"
  local playbook_path="$SCRIPT_DIR/${playbook}.yml"

  if [ ! -f "$playbook_path" ]; then
    err "Playbook not found: ${playbook_path}"
    return 1
  fi

  log "Running playbook: ${playbook}.yml"
  ANSIBLE_CONFIG="$SCRIPT_DIR/ansible.cfg" \
    "$ANSIBLE_PLAYBOOK" \
      -i "$SCRIPT_DIR/inventory_docker.ini" \
      "$playbook_path" \
      -v
}

# ── Main ────────────────────────────────────────────────────────────
main() {
  trap cleanup EXIT

  build_image

  # Determine which playbooks to run
  local playbooks=()
  if [ $# -gt 0 ]; then
    playbooks=("$@")
  else
    for f in "$SCRIPT_DIR"/test_*.yml; do
      playbooks+=("$(basename "${f%.yml}")")
    done
  fi

  local passed=0 failed=0
  for pb in "${playbooks[@]}"; do
    # Each test gets a fresh container to avoid state leaking between runs
    start_container
    if run_playbook "$pb"; then
      log "PASSED: ${pb}"
      passed=$((passed + 1))
    else
      err "FAILED: ${pb}"
      failed=$((failed + 1))
    fi
  done

  echo ""
  log "Results: ${passed} passed, ${failed} failed out of ${#playbooks[@]} playbook(s)"
  [ "$failed" -eq 0 ]
}

main "$@"
