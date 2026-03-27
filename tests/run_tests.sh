#!/usr/bin/env bash
# Local Docker-based test runner for horde deployment roles.
# Builds a systemd+Docker container, runs Ansible test playbooks against it.
#
# Usage:
#   ./tests/run_tests.sh                              # run ALL test_*.yml across all subfolders
#   ./tests/run_tests.sh monitoring                   # run tests/monitoring/test_*.yml
#   ./tests/run_tests.sh ai_horde                     # run tests/ai_horde/test_*.yml
#   ./tests/run_tests.sh monitoring/test_full_stack   # run a specific test (without .yml)
#   ./tests/run_tests.sh --list                       # list discoverable tests
#
# Logs are written to tests/test-results/<timestamp>/ with one file per
# playbook, plus a summary.txt for scripted analysis.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER_NAME="test-container"
IMAGE_NAME="horde-test-systemd"
TEMP_DOCKER_CONFIG=""
LOG_DIR=""

export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_HOST_KEY_CHECKING=False

# Colours (disabled when not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*"; }


init_log_dir() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  LOG_DIR="$SCRIPT_DIR/test-results/${ts}"
  mkdir -p "$LOG_DIR"
  log "Logs will be saved to ${LOG_DIR}"
}

# Convert a playbook label (e.g. "monitoring/test_full_stack.yml") into
# a flat, safe filename for its log (e.g. "monitoring--test_full_stack.log").
log_filename() {
  local label="$1"
  echo "${label//\//__}" | sed 's/\.yml$//' | sed 's/[^a-zA-Z0-9_-]/_/g'
}

# Extract a one-line failure reason from an Ansible log file.
# Handles both single-line fatal messages and multi-line JSON blocks.
extract_failure_reason() {
  local logfile="$1"
  local reason
  local stripped
  stripped=$(sed 's/\x1b\[[0-9;]*m//g' "$logfile")

  # Multi-line fatal block: join lines between "fatal:" and the next
  # "PLAY RECAP" or blank line, then extract the "msg" field.
  reason=$(echo "$stripped" \
    | awk '/fatal:.*FAILED/{found=1; buf=$0; next}
           found && /^[[:space:]]*$/{found=0; next}
           found && /^PLAY|^TASK/{found=0; next}
           found{buf=buf " " $0}
           END{print buf}' \
    | grep -oP '"msg":\s*"\K[^"]+' \
    | tail -1 \
    | head -c 200)

  if [ -n "$reason" ]; then
    echo "$reason"
    return
  fi

  # Fallback: single-line fatal with inline message
  reason=$(echo "$stripped" \
    | grep -i 'fatal:' \
    | tail -1 \
    | sed 's/.*fatal: *\[.*\]: *//; s/^FAILED! *=> *//' \
    | head -c 200)

  if [ -n "$reason" ]; then
    echo "$reason"
    return
  fi

  # Last resort: any "msg" in the file
  reason=$(echo "$stripped" \
    | grep -oP '"msg":\s*"\K[^"]+' \
    | tail -1 \
    | head -c 200)

  if [ -n "$reason" ]; then
    echo "$reason"
    return
  fi

  echo "(no failure detail extracted — see full log)"
}


# Parallel arrays to accumulate results for the final summary.
declare -a RESULT_LABELS=()
declare -a RESULT_STATUSES=()
declare -a RESULT_REASONS=()
declare -a RESULT_LOGFILES=()

record_result() {
  local label="$1" status="$2" reason="${3:-}" logfile="${4:-}"
  RESULT_LABELS+=("$label")
  RESULT_STATUSES+=("$status")
  RESULT_REASONS+=("$reason")
  RESULT_LOGFILES+=("$logfile")
}

# Print a structured summary table and write summary.txt.
print_summary() {
  local passed=0 failed=0 skipped=0 total=${#RESULT_LABELS[@]}

  echo ""
  printf "${BOLD}%-50s  %-6s  %s${NC}\n" "TEST" "STATUS" "DETAILS"
  printf '%.0s─' {1..100}; echo ""

  for i in "${!RESULT_LABELS[@]}"; do
    local label="${RESULT_LABELS[$i]}"
    local status="${RESULT_STATUSES[$i]}"
    local reason="${RESULT_REASONS[$i]}"
    local logfile="${RESULT_LOGFILES[$i]}"

    if [ "$status" = "PASS" ]; then
      printf "${GREEN}%-50s  %-6s${NC}\n" "$label" "PASS"
      passed=$((passed + 1))
    elif [ "$status" = "SKIP" ]; then
      printf "${YELLOW}%-50s  %-6s${NC}  %s\n" "$label" "SKIP" "$reason"
      skipped=$((skipped + 1))
    else
      printf "${RED}%-50s  %-6s${NC}  %s\n" "$label" "FAIL" "$reason"
      failed=$((failed + 1))
    fi
  done

  printf '%.0s─' {1..100}; echo ""
  log "Results: ${passed} passed, ${failed} failed, ${skipped} skipped out of ${total} playbook(s)"

  if [ -n "$LOG_DIR" ]; then
    # Write machine-readable summary
    {
      echo "# test-runner summary $(date -Iseconds)"
      echo "# total=${total} passed=${passed} failed=${failed} skipped=${skipped}"
      echo "#"
      echo "# FORMAT: STATUS | LABEL | LOG_FILE | REASON"
      for i in "${!RESULT_LABELS[@]}"; do
        local rel_log=""
        if [ -n "${RESULT_LOGFILES[$i]}" ]; then
          rel_log="$(basename "${RESULT_LOGFILES[$i]}")"
        fi
        printf '%s | %s | %s | %s\n' \
          "${RESULT_STATUSES[$i]}" \
          "${RESULT_LABELS[$i]}" \
          "$rel_log" \
          "${RESULT_REASONS[$i]}"
      done
    } > "$LOG_DIR/summary.txt"

    echo ""
    log "Full logs:  ${LOG_DIR}/"
    log "Summary:    ${LOG_DIR}/summary.txt"
  fi

  [ "$failed" -eq 0 ]
}

cleanup() {
  log "Cleaning up container ${CONTAINER_NAME}..."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  if [ -n "$TEMP_DOCKER_CONFIG" ] && [ -d "$TEMP_DOCKER_CONFIG" ]; then
    rm -rf "$TEMP_DOCKER_CONFIG"
  fi
}


# Some environments inject a desktop-only credential helper into
# ~/.docker/config.json (e.g. docker-credential-desktop.exe), which is
# not executable on Linux CI/containers. Use a minimal, isolated config
# for this test runner so docker build/pull works reliably.
configure_docker_cli() {
  TEMP_DOCKER_CONFIG="$(mktemp -d)"
  printf '{}' > "$TEMP_DOCKER_CONFIG/config.json"
  export DOCKER_CONFIG="$TEMP_DOCKER_CONFIG"
  log "Using isolated Docker CLI config at ${DOCKER_CONFIG}"
}


build_image() {
  log "Building test image ${IMAGE_NAME}..."
  docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.systemd" "$SCRIPT_DIR"
}


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
    local state
    state="$(docker exec "$CONTAINER_NAME" systemctl is-system-running 2>/dev/null || true)"
    if echo "$state" | grep -qE "running|degraded"; then
      break
    fi
    retries=$((retries - 1))
    sleep 2
  done

  if [ $retries -eq 0 ]; then
    warn "systemd did not reach 'running' — continuing anyway (may be 'degraded' in container)"
  fi

  log "Container ready (systemd running)"
}


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


run_playbook() {
  local playbook_path="$1"
  local pb_label="$2"

  if [ ! -f "$playbook_path" ]; then
    err "Playbook not found: ${playbook_path}"
    return 1
  fi

  local playbook_name
  playbook_name="$(basename "$playbook_path")"

  # Skip playbooks that require a running Docker daemon when none is
  # available inside the test container (e.g. test_runtime_services
  # — the container only ships the Docker CLI, not the daemon).
  if head -5 "$playbook_path" | grep -qi '# requires: docker-daemon'; then
    if ! docker exec "$CONTAINER_NAME" docker info >/dev/null 2>&1; then
      log "SKIP ${playbook_name}: requires a Docker daemon inside ${CONTAINER_NAME}"
      record_result "$pb_label" "SKIP" "Docker daemon unavailable in container" ""
      return 0
    fi
  fi

  # Per-test log file
  local logfile=""
  if [ -n "$LOG_DIR" ]; then
    logfile="${LOG_DIR}/$(log_filename "$pb_label").log"
  fi

  log "Running playbook: ${playbook_name}"

  # Run the playbook, teeing to both console and log file
  local rc=0
  if [ -n "$logfile" ]; then
    set +e
    "$ANSIBLE_PLAYBOOK" \
      -i "$SCRIPT_DIR/inventory_docker.ini" \
      "$playbook_path" \
      -v 2>&1 | tee "$logfile"
    rc="${PIPESTATUS[0]}"
    set -e
  else
    "$ANSIBLE_PLAYBOOK" \
      -i "$SCRIPT_DIR/inventory_docker.ini" \
      "$playbook_path" \
      -v || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    local reason=""
    [ -n "$logfile" ] && reason="$(extract_failure_reason "$logfile")"
    record_result "$pb_label" "FAIL" "$reason" "$logfile"
    return 1
  fi

  
  # Skip for runtime tests (services aren't idempotent on a fresh
  # container), local_deploy playbooks, and any playbook that declares
  # "# idempotency: skip" near the top (multi-play tests that
  # intentionally overwrite the same files with different variable sets).
  if echo "$playbook_name" | grep -qE 'runtime|local_deploy'; then
    log "Skipping idempotency check for ${playbook_name}"
    record_result "$pb_label" "PASS" "" "$logfile"
    return 0
  fi
  if head -5 "$playbook_path" | grep -qi '# idempotency: skip'; then
    log "Skipping idempotency check for ${playbook_name} (opted out via marker)"
    record_result "$pb_label" "PASS" "" "$logfile"
    return 0
  fi

  log "Idempotency check: re-running ${playbook_name}..."
  local idem_logfile=""
  [ -n "$LOG_DIR" ] && idem_logfile="${LOG_DIR}/$(log_filename "$pb_label")__idempotency.log"

  local idem_rc=0
  local idem_output
  set +e
  idem_output=$("$ANSIBLE_PLAYBOOK" \
    -i "$SCRIPT_DIR/inventory_docker.ini" \
    "$playbook_path" \
    -v 2>&1)
  idem_rc=$?
  set -e
  if [ -n "$idem_logfile" ]; then
    echo "$idem_output" > "$idem_logfile"
  fi

  if [ "$idem_rc" -ne 0 ]; then
    err "Idempotency re-run failed for ${playbook_name}"
    local reason="Idempotency re-run crashed"
    [ -n "$idem_logfile" ] && reason="$(extract_failure_reason "$idem_logfile")"
    record_result "$pb_label" "FAIL" "IDEMPOTENCY: $reason" "$idem_logfile"
    return 1
  fi

  local changed_count
  changed_count=$(echo "$idem_output" | grep -oP 'changed=\K[0-9]+' | awk '{s+=$1} END {print s+0}')
  if [ "$changed_count" -gt 0 ]; then
    local changed_tasks
    changed_tasks=$(echo "$idem_output" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'changed:' | head -3 | tr '\n' '; ')
    warn "Idempotency violation: ${changed_count} changed task(s) on re-run of ${playbook_name}"
    echo "$idem_output" | grep -E 'changed:' || true
    record_result "$pb_label" "FAIL" "IDEMPOTENCY: ${changed_count} changed — ${changed_tasks}" "${idem_logfile}"
    return 1
  fi
  log "Idempotency check passed (0 changed)"
  record_result "$pb_label" "PASS" "" "$logfile"
}


main() {
  # --list: print discoverable test playbooks and exit (no container needed)
  if [ "${1:-}" = "--list" ]; then
    while IFS= read -r -d '' f; do
      printf '%s\n' "$(realpath --relative-to="$SCRIPT_DIR" "$f")"
    done < <(find "$SCRIPT_DIR" -name 'test_*.yml' -type f -print0 | sort -z)
    exit 0
  fi

  trap cleanup EXIT

  configure_docker_cli

  init_log_dir

  build_image

  # Determine which playbooks to run
  local playbooks=()
  if [ $# -gt 0 ]; then
    local arg="$1"; shift
    if [[ "$arg" == *"/"* ]]; then
      # Specific test: e.g. "monitoring/test_full_stack"
      playbooks+=("$SCRIPT_DIR/${arg}.yml")
    elif [ -d "$SCRIPT_DIR/$arg" ]; then
      # Subfolder name: e.g. "monitoring"
      while IFS= read -r -d '' f; do
        playbooks+=("$f")
      done < <(find "$SCRIPT_DIR/$arg" -name 'test_*.yml' -type f -print0 | sort -z)
    else
      # Bare test name for backward compat: e.g. "test_full_stack"
      # Search subfolders for it
      while IFS= read -r -d '' f; do
        playbooks+=("$f")
      done < <(find "$SCRIPT_DIR" -name "${arg}.yml" -type f -print0)
      if [ ${#playbooks[@]} -eq 0 ]; then
        err "No test found matching: ${arg}"
        exit 1
      fi
    fi
  else
    # No arguments: discover all test_*.yml recursively
    while IFS= read -r -d '' f; do
      playbooks+=("$f")
    done < <(find "$SCRIPT_DIR" -name 'test_*.yml' -type f -print0 | sort -z)
  fi

  if [ ${#playbooks[@]} -eq 0 ]; then
    warn "No test playbooks found."
    exit 0
  fi

  log "Found ${#playbooks[@]} test playbook(s)"

  for pb in "${playbooks[@]}"; do
    local pb_label
    pb_label="$(realpath --relative-to="$SCRIPT_DIR" "$pb")"
    # Each test gets a fresh container to avoid state leaking between runs
    start_container
    if run_playbook "$pb" "$pb_label"; then
      log "PASSED: ${pb_label}"
    else
      err "FAILED: ${pb_label}"
    fi
  done

  print_summary
}

main "$@"
