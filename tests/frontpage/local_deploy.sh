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

# shellcheck source=../lib.sh
source "$REPO_ROOT/tests/lib.sh"

export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_HOST_KEY_CHECKING=False
USE_LATEST_REF=false
FRONTPAGE_REF="${FRONTPAGE_REF:-17e5052ad5d7da01037c3c8e8770e1471c4b481a}"

# Override these to change the host port/listen address Docker binds to.
FRONTPAGE_PORT="${FRONTPAGE_PORT:-8006}"
FRONTPAGE_LISTEN="${FRONTPAGE_LISTEN:-0.0.0.0}"

# Docker compose wrapper
dc() {
  docker compose -f "$LOCAL_ROOT/docker-compose.yml" "$@"
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
  local ref="$FRONTPAGE_REF"
  if [ "$USE_LATEST_REF" = true ]; then
    ref="master"
  fi

  clone_or_update_source \
    "https://github.com/Haidra-Org/AiHordeFrontpage.git" \
    "$LOCAL_ROOT/src" \
    "$ref"
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
      check_prerequisites git
      render_configs
      clone_source
      compose_up
      print_banner
      ;;
    down)
      compose_down "$LOCAL_ROOT"
      ;;
    status)
      compose_status "$LOCAL_ROOT/docker-compose.yml"
      ;;
    logs)
      compose_logs "$LOCAL_ROOT/docker-compose.yml"
      ;;
    *)
      echo "Usage: $0 {up|down|status|logs} [--latest]"
      exit 1
      ;;
  esac
}

main "$@"
