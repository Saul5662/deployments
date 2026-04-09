#!/usr/bin/env bash
# tests/lib.sh — Shared functions for local_deploy.sh scripts.
# Source this from individual deploy scripts after setting REPO_ROOT.
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
#   source "$REPO_ROOT/tests/lib.sh"

# ── Colours ──────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
fi

log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[x]${NC} %s\n" "$*" >&2; }
info() { printf "${CYAN}[i]${NC} %s\n" "$*"; }

# ── Prerequisites ───────────────────────────────────────────
# Usage: check_prerequisites [extra_cmd ...]
#   Always checks docker, curl, docker compose.
#   Pass additional commands as arguments (e.g. git, python3).
check_prerequisites() {
  local missing=0
  local extra_cmds=("$@")
  for cmd in docker curl "${extra_cmds[@]}"; do
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
}

# ── Ansible discovery ────────────────────────────────────────
# Sets ANSIBLE_PLAYBOOK to the best available ansible-playbook binary.
# Requires REPO_ROOT to be set.
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

# ── URL health probe ────────────────────────────────────────
# Usage: wait_for_url <url> <label> [timeout_secs=60]
wait_for_url() {
  local url="$1" label="$2" timeout="${3:-60}"
  local retries=$(( timeout / 2 ))
  while [ $retries -gt 0 ]; do
    if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
      log "$label is ready."
      return 0
    fi
    retries=$((retries - 1))
    sleep 2
  done
  warn "$label did not become ready within ${timeout}s"
  return 1
}

# ── Environment loader ──────────────────────────────────────
# Usage: load_env <env_file>
load_env() {
  local env_file="${1:?load_env requires a file path}"
  if [ ! -f "$env_file" ]; then
    err "Environment file not found at $env_file — did render_configs fail?"
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  log "Loaded environment from $env_file"
}

# ── Compose helpers ─────────────────────────────────────────
# These expect a dc() wrapper to be defined by the calling script.

compose_down() {
  local root_dir="${1:?compose_down requires a directory}"
  if type dc &>/dev/null; then
    dc down -v --remove-orphans 2>/dev/null || true
  fi
  if [ -d "$root_dir" ]; then
    log "Removing $root_dir ..."
    sudo rm -rf "$root_dir"
    # Restore any git-tracked files that lived inside the directory.
    git -C "$REPO_ROOT" checkout -- "$root_dir" 2>/dev/null || true
  fi
  log "Local deployment cleaned up."
}

compose_status() {
  local compose_file="${1:-docker-compose.yml}"
  if [ ! -f "$compose_file" ]; then
    info "No local deployment found."
    return
  fi
  dc ps
}

compose_logs() {
  local compose_file="${1:-docker-compose.yml}"
  if [ ! -f "$compose_file" ]; then
    err "No local deployment found."
    exit 1
  fi
  dc logs -f --tail=100
}

# ── Source checkout ──────────────────────────────────────────
# Usage: clone_or_update_source <repo_url> <dest_dir> <ref>
clone_or_update_source() {
  local repo_url="$1" dest_dir="$2" ref="$3"
  if [ -d "$dest_dir/.git" ]; then
    log "Updating source in $dest_dir to ref: $ref ..."
    git -C "$dest_dir" fetch --quiet --tags origin
    git -C "$dest_dir" checkout --quiet "$ref"
    git -C "$dest_dir" reset --hard "$ref" >/dev/null
  else
    log "Cloning $repo_url into $dest_dir (ref: $ref) ..."
    git clone "$repo_url" "$dest_dir"
    git -C "$dest_dir" checkout --quiet "$ref"
  fi
}

# ── Dockerfile patching (Docker Desktop workarounds) ────────
# Fixes two known issues when running with USE_LATEST_REF=true:
#   1) Docker Desktop can cache corrupt layers for unqualified slim tags.
#   2) The run stage uses --no-index but needs network for git+https deps.
#
# This function MUTATES the upstream Dockerfile in-place. It is only
# called when the operator opts in via USE_LATEST_REF(S)=true; pinned
# ref deploys do not trigger patching.
_patch_dockerfile() {
  local dockerfile="$1"
  [ -f "$dockerfile" ] || return 0

  local patched=0

  # Fix 1: broken base image
  local base_img
  base_img=$(grep -m1 '^FROM.*python.*slim' "$dockerfile" | awk '{print $2}' || true)
  if [ -n "$base_img" ]; then
    if ! docker run --rm "$base_img" true >/dev/null 2>&1; then
      local fixed_img="${base_img}-bookworm"
      warn "Base image $base_img is broken (exec format error). Switching to $fixed_img."
      sed -i "s|FROM ${base_img}|FROM ${fixed_img}|g" "$dockerfile"
      patched=$((patched + 1))
    fi
  fi

  # Fix 2: run-stage pip needs network access for git+https dependencies
  if grep -q '\-\-no-index' "$dockerfile" && grep -q 'git+https' "$(dirname "$dockerfile")/requirements.txt" 2>/dev/null; then
    warn "Removing --no-index from run-stage pip install (git deps need PyPI)."
    sed -i 's/--no-cache-dir --no-index --find-links=\/wheels\//--no-cache-dir --find-links=\/wheels\//' "$dockerfile"
    patched=$((patched + 1))
  fi

  if [ "$patched" -gt 0 ]; then
    warn "──── UPSTREAM SOURCE MODIFIED ────"
    warn "  File:    $dockerfile"
    warn "  Patches: $patched applied"
    warn "  Reason:  Docker Desktop / latest-ref compatibility"
    warn "  To avoid: use pinned refs (omit --latest)"
    warn "─────────────────────────────────"
  fi
}
