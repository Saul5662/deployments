#!/usr/bin/env bash

# Integration test: AI-Horde + worker connectivity verification.
#
# Base tier (always):
#   Renders configs via Ansible, clones source, builds & starts the
#   AI-Horde stack, then runs a curl-based connectivity probe from
#   inside a Docker container on the same network.
#
# GPU tier (--with-worker):
#   Additionally deploys a real horde-worker-regen instance pointing at
#   the local AI-Horde.  Requires NVIDIA GPU + Docker nvidia runtime.
#   The worker registers with the horde and appears in /api/v2/workers.
#
# Usage:
#   ./tests/integration/local_deploy.sh up               # base tier
#   ./tests/integration/local_deploy.sh up --latest      # follow branch head instead of pinned SHA
#   ./tests/integration/local_deploy.sh up --with-worker  # GPU tier
#   ./tests/integration/local_deploy.sh down
#   ./tests/integration/local_deploy.sh status
#   ./tests/integration/local_deploy.sh logs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_ROOT="$REPO_ROOT/local-deploy"

export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_HOST_KEY_CHECKING=False

AI_HORDE_DIR="$LOCAL_ROOT/ai-horde"
INTEGRATION_DIR="$LOCAL_ROOT/integration"
WORKER_DIR="$LOCAL_ROOT/worker"

# Colours
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
fi

log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[x]${NC} %s\n" "$*" >&2; }
info() { printf "${CYAN}[i]${NC} %s\n" "$*"; }

WITH_WORKER=false
USE_LATEST_REF=false
AI_HORDE_REF="${AI_HORDE_REF:-af0a85a78613cdba9863e16bbec0c179a4b2b132}"

# Docker compose wrapper for AI-Horde stack
dc() {
  docker compose -f "$AI_HORDE_DIR/docker-compose.yml" "$@"
}


check_prerequisites() {
  local missing=0
  for cmd in docker curl git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Required command not found: $cmd"
      missing=$((missing + 1))
    fi
  done
  if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose V2 plugin is required."
    missing=$((missing + 1))
  fi
  if [ $missing -gt 0 ]; then
    err "$missing prerequisite(s) missing — cannot continue."
    exit 1
  fi
  log "Prerequisites verified."

  if [ "$WITH_WORKER" = true ]; then
    if ! nvidia-smi >/dev/null 2>&1; then
      err "--with-worker requires an NVIDIA GPU (nvidia-smi not found)."
      exit 1
    fi
    if ! docker info 2>/dev/null | grep -q "nvidia"; then
      err "--with-worker requires the Docker nvidia runtime."
      exit 1
    fi
    log "GPU prerequisites verified (nvidia-smi + Docker nvidia runtime)."
  fi
}


find_ansible() {
  if [ -x "$REPO_ROOT/.venv/bin/ansible-playbook" ]; then
    ANSIBLE_PLAYBOOK="$REPO_ROOT/.venv/bin/ansible-playbook"
  else
    ANSIBLE_PLAYBOOK="$(command -v ansible-playbook 2>/dev/null || true)"
  fi
  if [ -z "${ANSIBLE_PLAYBOOK:-}" ]; then
    err "ansible-playbook not found."
    exit 1
  fi
}


render_configs() {
  find_ansible
  log "Rendering integration configs ..."
  "$ANSIBLE_PLAYBOOK" \
      -i "localhost," \
      "$SCRIPT_DIR/local_deploy.yml" \
      --become \
      -v
  log "Config rendering complete."
}


# Fixes two known issues:
#   1) Docker Desktop can cache corrupt layers for unqualified slim tags
#      (e.g. python:3.10-slim resolves to bullseye with broken binaries).
#   2) The run stage uses --no-index but needs pytest-runner from PyPI to
#      build the patreon git dependency.
_patch_dockerfile() {
  local dockerfile="$1"
  [ -f "$dockerfile" ] || return 0

  # Fix 1: broken base image
  local base_img
  base_img=$(grep -m1 '^FROM.*python.*slim' "$dockerfile" | awk '{print $2}' || true)
  if [ -n "$base_img" ]; then
    if ! docker run --rm "$base_img" true >/dev/null 2>&1; then
      local fixed_img="${base_img}-bookworm"
      warn "Base image $base_img is broken (exec format error). Switching to $fixed_img."
      sed -i "s|FROM ${base_img}|FROM ${fixed_img}|g" "$dockerfile"
    fi
  fi

  # Fix 2: run-stage pip needs network access for git+https dependencies
  if grep -q '\-\-no-index' "$dockerfile" && grep -q 'git+https' "$(dirname "$dockerfile")/requirements.txt" 2>/dev/null; then
    warn "Removing --no-index from run-stage pip install (git deps need PyPI)."
    sed -i 's/--no-cache-dir --no-index --find-links=\/wheels\//--no-cache-dir --find-links=\/wheels\//' "$dockerfile"
  fi
}


clone_source() {
  local src_dir="$AI_HORDE_DIR/src"
  local ref="$AI_HORDE_REF"
  if [ "$USE_LATEST_REF" = true ]; then
    ref="main"
  fi

  if [ -d "$src_dir/.git" ]; then
    log "Updating AI-Horde source to ref: $ref ..."
    git -C "$src_dir" fetch --quiet --tags origin
    git -C "$src_dir" checkout --quiet "$ref"
    git -C "$src_dir" reset --hard "$ref" >/dev/null
  else
    log "Cloning AI-Horde source (ref: $ref) ..."
    git clone https://github.com/Haidra-Org/AI-Horde.git "$src_dir"
    git -C "$src_dir" checkout --quiet "$ref"
  fi

  
  if [ "$USE_LATEST_REF" = true ]; then
    _patch_dockerfile "$src_dir/Dockerfile"
  fi
}


wait_for_url() {
  local url="$1" label="$2" timeout="${3:-60}"
  local retries=$(( timeout / 2 ))
  while [ $retries -gt 0 ]; do
    if curl -sf "$url" >/dev/null 2>&1; then
      log "$label is ready."
      return 0
    fi
    retries=$((retries - 1))
    sleep 2
  done
  warn "$label did not become ready within ${timeout}s"
  return 1
}


start_aihorde() {
  if [ ! -f "$AI_HORDE_DIR/docker-compose.yml" ]; then
    err "No docker-compose.yml found — did render fail?"
    exit 1
  fi

  log "Building AI-Horde Docker image ..."
  dc build

  log "Starting AI-Horde stack ..."
  dc up -d

  wait_for_url "http://127.0.0.1:7001/api/v2/status/heartbeat" "AI-Horde heartbeat" 180 || {
    err "AI-Horde did not start. Dumping logs:"
    dc logs --tail=50
    return 1
  }
}


run_probe() {
  log "Running connectivity probe ..."

  # Get the compose project network name
  local network_name
  network_name=$(docker network ls --format '{{.Name}}' | grep -i "aihorde_network" | head -1)
  if [ -z "$network_name" ]; then
    warn "Could not find aihorde_network — running probe via host network."
    network_name="host"
  fi

  local probe_ok=true

  # Heartbeat check
  log "Probe: checking heartbeat ..."
  if docker run --rm --network "$network_name" curlimages/curl:latest \
    -sf http://aihorde:7001/api/v2/status/heartbeat; then
    log "  Heartbeat: PASS"
  else
    # Fallback to host check if container networking fails
    if curl -sf http://127.0.0.1:7001/api/v2/status/heartbeat >/dev/null; then
      log "  Heartbeat (via host): PASS"
    else
      err "  Heartbeat: FAIL"
      probe_ok=false
    fi
  fi

  # Models endpoint
  log "Probe: checking /api/v2/status/models ..."
  if curl -sf http://127.0.0.1:7001/api/v2/status/models >/dev/null; then
    log "  Models endpoint: PASS"
  else
    warn "  Models endpoint: FAIL (may be expected if no models registered)"
  fi

  # Registration endpoint
  log "Probe: testing user registration ..."
  local reg_code
  reg_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST http://127.0.0.1:7001/register \
    --data-urlencode "username=integration_test_user" 2>/dev/null || echo "000")
  if [ "$reg_code" = "200" ] || [ "$reg_code" = "302" ]; then
    log "  Registration: PASS (HTTP $reg_code)"
  else
    warn "  Registration: HTTP $reg_code (endpoint may require different method)"
  fi

  if [ "$probe_ok" = false ]; then
    return 1
  fi
}


deploy_worker() {
  log "=== GPU Worker Tier ==="
  mkdir -p "$WORKER_DIR"

  # Clone worker repo
  if [ -d "$WORKER_DIR/horde-worker-regen/.git" ]; then
    log "Updating worker source ..."
    git -C "$WORKER_DIR/horde-worker-regen" pull --quiet
  else
    log "Cloning horde-worker-regen ..."
    git clone https://github.com/Haidra-Org/horde-worker-regen.git \
      "$WORKER_DIR/horde-worker-regen"
  fi

  # Render bridgeData.yaml pointing at local AI-Horde
  find_ansible
  log "Rendering worker bridgeData.yaml ..."
  "$ANSIBLE_PLAYBOOK" -i "localhost," -c local --become \
    -e "worker_username=root" \
    -e "worker_runtime_dir=$WORKER_DIR/horde-worker-regen" \
    -e "worker_clone_dir=$WORKER_DIR/horde-worker-regen" \
    -e "horde_url=http://localhost:7001" \
    -e "api_key=0000000000" \
    -e "dreamer_name=integration-test-worker" \
    -e "max_power=8" \
    -e "max_threads=1" \
    -e "models_to_load=[\"stable_diffusion\"]" \
    -e "models_to_skip=[\"pix2pix\"]" \
    -e "nsfw=false" \
    -e "allow_img2img=true" \
    -e "allow_painting=true" \
    -e "allow_controlnet=false" \
    -e "allow_lora=false" \
    -e "safety_on_gpu=false" \
    -e '{"_worker_tasks": []}' \
    "$SCRIPT_DIR/_render_bridge.yml" \
    -v

  # Set up worker runtime
  log "Setting up worker runtime (this may take a while on first run) ..."
  cd "$WORKER_DIR/horde-worker-regen"
  if [ ! -d "conda" ] && [ ! -d ".venv" ] && [ -f "update-runtime.sh" ]; then
    bash update-runtime.sh 2>&1 | tail -5
  fi

  # Start worker in background
  log "Starting worker ..."
  if [ -f "horde-bridge.sh" ]; then
    nohup bash horde-bridge.sh > "$WORKER_DIR/worker.log" 2>&1 &
    echo $! > "$WORKER_DIR/worker.pid"
    log "Worker started (PID: $(cat "$WORKER_DIR/worker.pid"))"
  else
    err "horde-bridge.sh not found in worker repo."
    return 1
  fi

  # Wait for worker to register (check /api/v2/workers)
  log "Waiting for worker to register with AI-Horde ..."
  local retries=60
  while [ $retries -gt 0 ]; do
    local workers
    workers=$(curl -sf http://127.0.0.1:7001/api/v2/workers 2>/dev/null || echo "[]")
    if echo "$workers" | grep -q "integration-test-worker"; then
      log "Worker registered successfully!"
      echo "$workers" | python3 -m json.tool 2>/dev/null | head -20
      return 0
    fi
    retries=$((retries - 1))
    sleep 5
  done

  warn "Worker did not appear in /api/v2/workers within timeout."
  info "Worker log (last 20 lines):"
  tail -20 "$WORKER_DIR/worker.log" 2>/dev/null || true
  return 1
}


stop_worker() {
  if [ -f "$WORKER_DIR/worker.pid" ]; then
    local pid
    pid=$(cat "$WORKER_DIR/worker.pid")
    if kill -0 "$pid" 2>/dev/null; then
      log "Stopping worker (PID: $pid) ..."
      kill -INT "$pid" 2>/dev/null || true
      sleep 5
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$WORKER_DIR/worker.pid"
  fi
}


compose_down() {
  stop_worker

  if [ -f "$AI_HORDE_DIR/docker-compose.yml" ]; then
    log "Stopping AI-Horde stack ..."
    dc down -v --remove-orphans 2>/dev/null || true
  fi

  # Clean up rendered configs (not worker runtime — that's expensive to rebuild)
  for dir in "$AI_HORDE_DIR" "$INTEGRATION_DIR"; do
    if [ -d "$dir" ]; then
      log "Removing $dir ..."
      sudo rm -rf "$dir"
    fi
  done

  log "Integration environment cleaned up."
  if [ -d "$WORKER_DIR" ]; then
    info "Worker runtime preserved at $WORKER_DIR (remove manually if desired)."
  fi
}


compose_status() {
  if [ ! -f "$AI_HORDE_DIR/docker-compose.yml" ]; then
    info "No integration deployment found."
    return
  fi
  dc ps
  if [ -f "$WORKER_DIR/worker.pid" ]; then
    local pid
    pid=$(cat "$WORKER_DIR/worker.pid")
    if kill -0 "$pid" 2>/dev/null; then
      info "Worker running (PID: $pid)"
    else
      info "Worker not running (stale PID file)"
    fi
  fi
}


compose_logs() {
  if [ ! -f "$AI_HORDE_DIR/docker-compose.yml" ]; then
    err "No integration deployment found."
    exit 1
  fi
  dc logs -f --tail=100
}


print_banner() {
  local hb_status probe_status worker_status
  hb_status="PASS"
  probe_status="PASS"
  worker_status="N/A"

  if ! curl -sf http://127.0.0.1:7001/api/v2/status/heartbeat >/dev/null 2>&1; then
    hb_status="FAIL"
  fi
  if [ "$WITH_WORKER" = true ] && [ -f "$WORKER_DIR/worker.pid" ]; then
    if kill -0 "$(cat "$WORKER_DIR/worker.pid")" 2>/dev/null; then
      worker_status="RUNNING"
    else
      worker_status="STOPPED"
    fi
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Integration test results:"
  info "  AI-Horde heartbeat  →  $hb_status"
  info "  Connectivity probe  →  $probe_status"
  info "  GPU Worker          →  $worker_status"
  echo ""
  info "AI-Horde API  →  http://localhost:7001"
  info "Heartbeat     →  http://localhost:7001/api/v2/status/heartbeat"
  info "Workers       →  http://localhost:7001/api/v2/workers"
  echo ""
  info "Tear down:  $0 down"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}


main() {
  local cmd="${1:-up}"
  shift || true

  # Parse flags
  for arg in "$@"; do
    case "$arg" in
      --with-worker) WITH_WORKER=true ;;
      --latest) USE_LATEST_REF=true ;;
      *) warn "Unknown flag: $arg" ;;
    esac
  done

  case "$cmd" in
    up)
      check_prerequisites
      render_configs
      clone_source
      start_aihorde
      run_probe
      if [ "$WITH_WORKER" = true ]; then
        deploy_worker || warn "Worker deployment had issues (see above)."
      fi
      print_banner
      ;;
    down)
      compose_down
      ;;
    status)
      compose_status
      ;;
    logs)
      compose_logs
      ;;
    *)
      echo "Usage: $0 {up|down|status|logs} [--with-worker] [--latest]"
      exit 1
      ;;
  esac
}

main "$@"
