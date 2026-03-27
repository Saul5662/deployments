#!/usr/bin/env bash

# Local deployment of the AI-Horde backend for manual validation.
# Renders configs via Ansible, clones source, builds Docker image,
# then starts the stack via Docker Compose.
#
# Usage:
#   ./tests/ai_horde/local_deploy.sh up       # render + clone + build + start
#   ./tests/ai_horde/local_deploy.sh up --latest  # follow branch head instead of pinned SHA
#   ./tests/ai_horde/local_deploy.sh down     # tear down stack + remove files
#   ./tests/ai_horde/local_deploy.sh status   # show running containers
#   ./tests/ai_horde/local_deploy.sh logs     # tail compose logs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_ROOT="$REPO_ROOT/local-deploy/ai-horde"

export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_HOST_KEY_CHECKING=False
ENV_FILE="$LOCAL_ROOT/local-deploy.env"
USE_LATEST_REF=false
AI_HORDE_REF="${AI_HORDE_REF:-af0a85a78613cdba9863e16bbec0c179a4b2b132}"

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

# Docker compose wrapper
dc() {
  docker compose -f "$LOCAL_ROOT/docker-compose.yml" "$@"
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
  log "Prerequisites verified (docker, curl, git, docker compose)."
}


find_ansible() {
  if [ -x "$REPO_ROOT/.venv/bin/ansible-playbook" ]; then
    ANSIBLE_PLAYBOOK="$REPO_ROOT/.venv/bin/ansible-playbook"
  else
    ANSIBLE_PLAYBOOK="$(command -v ansible-playbook 2>/dev/null || true)"
  fi
  if [ -z "${ANSIBLE_PLAYBOOK:-}" ]; then
    err "ansible-playbook not found. Install Ansible or create a venv at $REPO_ROOT/.venv"
    exit 1
  fi
}


render_configs() {
  find_ansible
  log "Rendering AI-Horde configs into $LOCAL_ROOT ..."
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
  local src_dir="$LOCAL_ROOT/src"
  local ref="$AI_HORDE_REF"
  if [ "$USE_LATEST_REF" = true ]; then
    ref="main"
  fi

  if [ -d "$src_dir/.git" ]; then
    log "Updating AI-Horde source in $src_dir to ref: $ref ..."
    git -C "$src_dir" fetch --quiet --tags origin
    git -C "$src_dir" checkout --quiet "$ref"
    git -C "$src_dir" reset --hard "$ref" >/dev/null
  else
    log "Cloning AI-Horde source into $src_dir (ref: $ref) ..."
    git clone https://github.com/Haidra-Org/AI-Horde.git "$src_dir"
    git -C "$src_dir" checkout --quiet "$ref"
  fi

  
  if [ "$USE_LATEST_REF" = true ]; then
    _patch_dockerfile "$src_dir/Dockerfile"
  fi
}


load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    err "Environment file not found at $ENV_FILE — did render_configs fail?"
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  log "Loaded environment from $ENV_FILE"
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


compose_up() {
  if [ ! -f "$LOCAL_ROOT/docker-compose.yml" ]; then
    err "No docker-compose.yml found — did render fail?"
    exit 1
  fi

  log "Building AI-Horde Docker image (this may take a few minutes) ..."
  dc build

  log "Starting Docker Compose stack ..."
  dc up -d

  wait_for_url "http://127.0.0.1:${AI_HORDE_PORT}/api/v2/status/heartbeat" "AI-Horde heartbeat" 120 || true
}


compose_down() {
  if [ -f "$LOCAL_ROOT/docker-compose.yml" ]; then
    log "Stopping Docker Compose stack ..."
    dc down -v --remove-orphans 2>/dev/null || true
  fi

  if [ -d "$LOCAL_ROOT" ]; then
    log "Removing $LOCAL_ROOT ..."
    sudo rm -rf "$LOCAL_ROOT"
  fi

  log "Local deployment cleaned up."
}


compose_status() {
  if [ ! -f "$LOCAL_ROOT/docker-compose.yml" ]; then
    info "No local deployment found."
    return
  fi
  dc ps
}


compose_logs() {
  if [ ! -f "$LOCAL_ROOT/docker-compose.yml" ]; then
    err "No local deployment found."
    exit 1
  fi
  dc logs -f --tail=100
}


print_banner() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "AI-Horde API      →  http://localhost:${AI_HORDE_PORT}"
  info "Heartbeat         →  http://localhost:${AI_HORDE_PORT}/api/v2/status/heartbeat"
  info "Registration      →  http://localhost:${AI_HORDE_PORT}/register"
  echo ""
  info "Test user setup:"
  info "  curl -X POST --data-raw 'username=test_user' http://localhost:${AI_HORDE_PORT}/register"
  echo ""
  info "Tear down:  $0 down"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}


main() {
  local cmd="${1:-up}"
  shift || true

  for arg in "$@"; do
    case "$arg" in
      --latest) USE_LATEST_REF=true ;;
      -*) warn "Unknown flag: $arg" ;;
    esac
  done

  case "$cmd" in
    up)
      check_prerequisites
      render_configs
      clone_source
      load_env
      compose_up
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
      echo "Usage: $0 {up|down|status|logs} [--latest]"
      exit 1
      ;;
  esac
}

main "$@"
