#!/usr/bin/env bash

# Local deployment of AiHordeFrontpage for manual validation.
# Renders configs via Ansible, clones source, builds Docker image,
# then starts the service via Docker Compose.
#
# Usage:
#   ./tests/frontpage/local_deploy.sh up       # render + clone + build + start
#   ./tests/frontpage/local_deploy.sh up --latest  # follow branch head instead of pinned SHA
#   ./tests/frontpage/local_deploy.sh down     # tear down stack + remove files
#   ./tests/frontpage/local_deploy.sh status   # show running containers
#   ./tests/frontpage/local_deploy.sh logs     # tail compose logs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_ROOT="$REPO_ROOT/local-deploy/frontpage"

export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_HOST_KEY_CHECKING=False
USE_LATEST_REF=false
FRONTPAGE_REF="${FRONTPAGE_REF:-a56aec53f46470ca3796e1a7eabbe029e32563d3}"


# Override these to change the host port/listen address Docker binds to.
FRONTPAGE_PORT="${FRONTPAGE_PORT:-8006}"
FRONTPAGE_LISTEN="${FRONTPAGE_LISTEN:-0.0.0.0}"

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
  log "Rendering AiHordeFrontpage configs into $LOCAL_ROOT ..."
  log "  Host port: $FRONTPAGE_PORT  Listen: $FRONTPAGE_LISTEN"
  "$ANSIBLE_PLAYBOOK" \
      -i "localhost," \
      "$SCRIPT_DIR/local_deploy.yml" \
      --become \
      -e "aihorde_frontpage_port=$FRONTPAGE_PORT" \
      -e "aihorde_frontpage_listen=$FRONTPAGE_LISTEN" \
      -v
  log "Config rendering complete."
}


clone_source() {
  local src_dir="$LOCAL_ROOT/src"
  local ref="$FRONTPAGE_REF"
  if [ "$USE_LATEST_REF" = true ]; then
    ref="master"
  fi

  if [ -d "$src_dir/.git" ]; then
    log "Updating AiHordeFrontpage source in $src_dir to ref: $ref ..."
    git -C "$src_dir" fetch --quiet --tags origin
    git -C "$src_dir" checkout --quiet "$ref"
    git -C "$src_dir" reset --hard "$ref" >/dev/null
  else
    log "Cloning AiHordeFrontpage source into $src_dir (ref: $ref) ..."
    git clone https://github.com/Haidra-Org/AiHordeFrontpage.git "$src_dir"
    git -C "$src_dir" checkout --quiet "$ref"
  fi
}


wait_for_url() {
  local url="$1" label="$2" timeout="${3:-120}"
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

  log "Building AiHordeFrontpage Docker image (this may take a few minutes) ..."
  dc build

  log "Starting Docker Compose stack ..."
  dc up -d

  wait_for_url "http://127.0.0.1:${FRONTPAGE_PORT}/" "AiHordeFrontpage" 120 || true
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
  info "AiHordeFrontpage  →  http://localhost:${FRONTPAGE_PORT}"
  info "Health check      →  http://localhost:${FRONTPAGE_PORT}/"
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
