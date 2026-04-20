#!/usr/bin/env bash

# Full-stack local deploy: the complete Horde business stack.
#
# Orchestrates Backend (AI-Horde + Postgres + Redis), Frontend
# (AiHordeFrontpage), HAProxy (unified edge router), and optionally
# the monitoring stack and GPU worker.  Services are started in
# dependency order with health gates between each tier.
#
# Usage:
#   ./tests/full_stack/local_deploy.sh up                    # core stack
#   ./tests/full_stack/local_deploy.sh up --with-monitoring   # + monitoring
#   ./tests/full_stack/local_deploy.sh up --with-worker       # + GPU worker
#   ./tests/full_stack/local_deploy.sh up --latest            # follow default branches instead of pinned SHAs
#   ./tests/full_stack/local_deploy.sh up --all               # everything
#   ./tests/full_stack/local_deploy.sh down
#   ./tests/full_stack/local_deploy.sh status
#   ./tests/full_stack/local_deploy.sh logs [service]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_ROOT="$REPO_ROOT/local-deploy/runtime"
STATIC_ROOT="$REPO_ROOT/local-deploy/static"

# shellcheck source=../lib.sh
source "$REPO_ROOT/tests/lib.sh"

export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_HOST_KEY_CHECKING=False


WITH_MONITORING=false
WITH_WORKER=false
WITH_ARTBOT=false
USE_LATEST_REFS=false
INSTANCES=3

# Pinned refs for reproducible local deploys.
# Use --latest (or set USE_LATEST_REFS=true in env) to follow branch heads.
AI_HORDE_REPO_DEFAULT="https://github.com/Haidra-Org/AI-Horde.git"
if [ -z "${AI_HORDE_REPO+x}" ]; then
  AI_HORDE_REPO="$AI_HORDE_REPO_DEFAULT"
else
  AI_HORDE_REPO="$AI_HORDE_REPO"
fi

AI_HORDE_REF_DEFAULT="f40ae696acd0f23f6484db7f3d2408884185e960"
FRONTPAGE_REF_DEFAULT="17e5052ad5d7da01037c3c8e8770e1471c4b481a"
ARTBOT_REF_DEFAULT="main"

if [ -z "${AI_HORDE_REF+x}" ]; then
  AI_HORDE_REF="$AI_HORDE_REF_DEFAULT"
  AI_HORDE_REF_EXPLICIT=false
else
  AI_HORDE_REF="$AI_HORDE_REF"
  AI_HORDE_REF_EXPLICIT=true
fi

if [ -z "${FRONTPAGE_REF+x}" ]; then
  FRONTPAGE_REF="$FRONTPAGE_REF_DEFAULT"
  FRONTPAGE_REF_EXPLICIT=false
else
  FRONTPAGE_REF="$FRONTPAGE_REF"
  FRONTPAGE_REF_EXPLICIT=true
fi

if [ -z "${ARTBOT_REF+x}" ]; then
  ARTBOT_REF="$ARTBOT_REF_DEFAULT"
  ARTBOT_REF_EXPLICIT=false
else
  ARTBOT_REF="$ARTBOT_REF"
  ARTBOT_REF_EXPLICIT=true
fi


# Each tier has its own wrapper so that the compose project name and
# file list are consistent across up / down / status / logs.

dc_backend() {
  docker compose \
    -f "$LOCAL_ROOT/ai-horde/docker-compose.yml" \
    -f "$STATIC_ROOT/ai-horde/docker-compose.network-overlay.yml" \
    --project-name horde-aihorde \
    "$@"
}

dc_frontpage() {
  docker compose \
    -f "$LOCAL_ROOT/frontpage/docker-compose.yml" \
    -f "$STATIC_ROOT/frontpage/docker-compose.network-overlay.yml" \
    --project-name horde-frontpage \
    "$@"
}

dc_monitoring() {
  local args="-f $LOCAL_ROOT/compose/docker-compose.yml"
  if [ -f "$LOCAL_ROOT/compose/docker-compose.local.yml" ]; then
    args="$args -f $LOCAL_ROOT/compose/docker-compose.local.yml"
  fi
  # shellcheck disable=SC2086
  docker compose $args --project-name horde-monitoring "$@"
}

dc_exporter_overlay() {
  # Exporter is part of the monitoring compose + its network overlay.
  # This layers the exporter overlay onto the full monitoring compose.
  local args="-f $LOCAL_ROOT/compose/docker-compose.yml"
  if [ -f "$LOCAL_ROOT/compose/docker-compose.local.yml" ]; then
    args="$args -f $LOCAL_ROOT/compose/docker-compose.local.yml"
  fi
  args="$args -f $STATIC_ROOT/exporter/docker-compose.network-overlay.yml"
  # shellcheck disable=SC2086
  docker compose $args --project-name horde-monitoring "$@"
}

dc_haproxy() {
  docker compose \
    -f "$STATIC_ROOT/compose/docker-compose.fullstack-haproxy.yml" \
    --project-name horde-fullstack \
    "$@"
}

dc_artbot() {
  docker compose \
    -f "$LOCAL_ROOT/artbot/docker-compose.artbot.yml" \
    -f "$LOCAL_ROOT/artbot/docker-compose.network-overlay.yml" \
    --project-name horde-artbot \
    "$@"
}


check_fullstack_prerequisites() {
  check_prerequisites git ss

  # Port conflict detection
  local core_ports=(80 8006 8404)
  for port in "${core_ports[@]}"; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      err "Port $port is already in use."
      exit 1
    fi
  done
  for port in $(seq 7001 $((7001 + INSTANCES - 1))); do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      err "Port $port is already in use (AI-Horde instance)."
      exit 1
    fi
  done

  if [ "$WITH_MONITORING" = true ]; then
    local mon_ports=(3000 9009 9090 9093)
    for port in "${mon_ports[@]}"; do
      if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        err "Port $port is already in use (--with-monitoring)."
        exit 1
      fi
    done
  fi

  if [ "$WITH_WORKER" = true ]; then
    if ! nvidia-smi >/dev/null 2>&1; then
      err "--with-worker requires an NVIDIA GPU (nvidia-smi not found)."
      exit 1
    fi
    if ! docker info 2>/dev/null | grep -q "nvidia"; then
      err "--with-worker requires the Docker nvidia runtime."
      exit 1
    fi
    log "GPU prerequisites verified."
  fi

  if [ "$WITH_ARTBOT" = true ]; then
    local artbot_ports=(8080 8484)
    for port in "${artbot_ports[@]}"; do
      if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        err "Port $port is already in use (--with-artbot)."
        exit 1
      fi
    done
  fi
}


render_configs() {
  find_ansible

  # Render backend + frontpage configs
  log "Rendering backend + frontpage configs via Ansible ..."
  "$ANSIBLE_PLAYBOOK" \
      -i "localhost," \
      "$SCRIPT_DIR/local_deploy.yml" \
      -e "ai_horde_replicas=$INSTANCES" \
      --become \
      -v
  log "Backend + frontpage config rendering complete."

  # Render monitoring configs if requested
  if [ "$WITH_MONITORING" = true ]; then
    local mon_playbook="$REPO_ROOT/tests/monitoring/local_deploy.yml"
    if [ -f "$mon_playbook" ]; then
      log "Rendering monitoring stack configs via Ansible ..."
      "$ANSIBLE_PLAYBOOK" \
          -i "localhost," \
          "$mon_playbook" \
          --become \
          -v
      log "Monitoring config rendering complete."
    else
      warn "Monitoring playbook not found at $mon_playbook — monitoring may not work."
    fi
  fi
}


clone_sources() {
  local ai_ref="$AI_HORDE_REF"
  local fp_ref="$FRONTPAGE_REF"
  local artbot_ref="$ARTBOT_REF"
  if [ "${USE_LATEST_REFS:-false}" = true ]; then
    if [ "$AI_HORDE_REF_EXPLICIT" = false ]; then
      ai_ref="main"
    fi
    if [ "$FRONTPAGE_REF_EXPLICIT" = false ]; then
      fp_ref="master"
    fi
    if [ "$ARTBOT_REF_EXPLICIT" = false ]; then
      artbot_ref="main"
    fi
  fi

  # AI-Horde backend source
  clone_or_update_source \
    "$AI_HORDE_REPO" \
    "$LOCAL_ROOT/ai-horde/src" \
    "$ai_ref"

  if [ "${USE_LATEST_REFS:-false}" = true ] || [ "$AI_HORDE_REF_EXPLICIT" = true ]; then
    _patch_dockerfile "$LOCAL_ROOT/ai-horde/src/Dockerfile"
  fi

  # AiHordeFrontpage source
  clone_or_update_source \
    "https://github.com/Haidra-Org/AiHordeFrontpage.git" \
    "$LOCAL_ROOT/frontpage/src" \
    "$fp_ref"

  # Artbot source (only when --with-artbot)
  if [ "$WITH_ARTBOT" = true ]; then
    clone_or_update_source \
      "https://github.com/Haidra-Org/artbot.git" \
      "$LOCAL_ROOT/artbot/src" \
      "$artbot_ref"
  fi
}


cleanup_monitoring_container_name_conflicts() {
  [ "$WITH_MONITORING" = true ] || return 0

  local auto_clean="${HORDE_FULLSTACK_AUTO_CLEAN_MONITORING_CONFLICTS:-true}"
  local -a known_names=(
    s3-store
    s3-init
    memcached
    mimir
    grafana
    loki
    tempo
    pyroscope
    alertmanager
    prometheus
    horde-exporter
    alloy
  )
  local -a conflicts=()
  local name project

  for name in "${known_names[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
      project=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)
      if [ "$project" != "horde-monitoring" ]; then
        conflicts+=("$name")
      fi
    fi
  done

  if [ "${#conflicts[@]}" -eq 0 ]; then
    return 0
  fi

  warn "Found conflicting containers with global monitoring names: ${conflicts[*]}"
  if [ "$auto_clean" != "true" ]; then
    err "Auto-clean disabled (HORDE_FULLSTACK_AUTO_CLEAN_MONITORING_CONFLICTS=$auto_clean)."
    err "Remove conflicts manually, or rerun with HORDE_FULLSTACK_AUTO_CLEAN_MONITORING_CONFLICTS=true."
    return 1
  fi

  warn "Removing conflicting monitoring containers before startup ..."
  if ! docker rm -f "${conflicts[@]}" >/dev/null 2>&1; then
    err "Failed to remove one or more conflicting containers: ${conflicts[*]}"
    return 1
  fi

  log "Removed conflicting containers: ${conflicts[*]}"
}


probe_connectivity() {
  local failed=0

  # Probe 1: Frontpage via HAProxy
  info "Probe: GET http://localhost/ (frontpage via HAProxy)"
  local retries=5
  local fp_ok=false
  while [ $retries -gt 0 ]; do
    local http_code
    http_code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 http://localhost/ 2>/dev/null || true)
    if [ "$http_code" = "200" ]; then
      fp_ok=true
      break
    fi
    retries=$((retries - 1))
    sleep 3
  done
  if [ "$fp_ok" = true ]; then
    log "  Frontpage serves HTML through HAProxy"
  else
    err "  Frontpage not serving HTML through HAProxy"
    failed=$((failed + 1))
  fi

  # Probe 2: API via HAProxy
  info "Probe: GET http://localhost/api/v2/status/heartbeat"
  local api_code
  api_code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 http://localhost/api/v2/status/heartbeat 2>/dev/null || true)
  if [ "$api_code" = "200" ]; then
    log "  API heartbeat reachable through HAProxy"
  else
    err "  API heartbeat not reachable through HAProxy"
    failed=$((failed + 1))
  fi

  # Probe 3: Stats exporter via HAProxy (non-fatal)
  info "Probe: GET http://localhost/appstats/"
  if curl -sf --max-time 10 http://localhost/appstats/ >/dev/null 2>&1; then
    log "  Stats exporter reachable through HAProxy"
  else
    warn "  Stats exporter not reachable (may not be running)"
  fi

  if [ $failed -gt 0 ]; then
    err "$failed connectivity probe(s) failed."
    return 1
  fi
  log "All connectivity probes passed."
}


deploy_worker() {
  local worker_dir="$LOCAL_ROOT/worker"
  mkdir -p "$worker_dir"

  # Clone or update worker repo
  if [ -d "$worker_dir/horde-worker-regen/.git" ]; then
    log "Updating worker source ..."
    git -C "$worker_dir/horde-worker-regen" pull --quiet
  else
    log "Cloning horde-worker-regen ..."
    git clone https://github.com/Haidra-Org/horde-worker-regen.git \
      "$worker_dir/horde-worker-regen"
  fi

  # Render bridgeData.yaml pointing at local AI-Horde
  find_ansible
  local int_render="$REPO_ROOT/tests/integration/_render_bridge.yml"
  if [ ! -f "$int_render" ]; then
    warn "Worker bridge render playbook not found at $int_render — cannot deploy worker."
    return 1
  fi
  log "Rendering worker bridgeData.yaml ..."
  "$ANSIBLE_PLAYBOOK" -i "localhost," -c local --become \
    -e "worker_username=root" \
    -e "worker_runtime_dir=$worker_dir/horde-worker-regen" \
    -e "worker_clone_dir=$worker_dir/horde-worker-regen" \
    -e "horde_url=http://localhost:7001" \
    -e "api_key=0000000000" \
    -e "dreamer_name=fullstack-test-worker" \
    -e "max_power=8" \
    -e "max_threads=1" \
    -e 'models_to_load=["stable_diffusion"]' \
    -e 'models_to_skip=["pix2pix"]' \
    -e "nsfw=false" \
    -e "allow_img2img=true" \
    -e "allow_painting=true" \
    -e "allow_controlnet=false" \
    -e "allow_lora=false" \
    -e "safety_on_gpu=false" \
    -e '{"_worker_tasks": []}' \
    "$int_render" \
    -v

  # Set up worker runtime (skip if already set up)
  log "Setting up worker runtime (this may take a while on first run) ..."
  cd "$worker_dir/horde-worker-regen"
  if [ -d "conda/envs" ] && [ -f "conda/envs/linux/bin/python" ]; then
    log "Worker conda env already exists — skipping runtime setup."
  elif [ -d ".venv" ] && [ -f ".venv/bin/python" ]; then
    log "Worker venv already exists — skipping runtime setup."
  elif [ -f "update-runtime.sh" ]; then
    warn "Worker runtime not set up. Running update-runtime.sh (may be slow) ..."
    if ! timeout 600 bash update-runtime.sh 2>&1 | tail -10; then
      err "update-runtime.sh failed or timed out (10 min limit)."
      return 1
    fi
  else
    err "No update-runtime.sh found — cannot set up worker runtime."
    return 1
  fi

  # Start worker in background
  log "Starting worker ..."
  if [ -f "horde-bridge.sh" ]; then
    nohup bash horde-bridge.sh > "$worker_dir/worker.log" 2>&1 &
    echo $! > "$worker_dir/worker.pid"
    log "Worker started (PID: $(cat "$worker_dir/worker.pid"))"
  else
    err "horde-bridge.sh not found in worker repo."
    return 1
  fi

  # Wait for worker to register
  log "Waiting for worker to register with AI-Horde ..."
  local retries=60
  while [ $retries -gt 0 ]; do
    local workers
    workers=$(curl -sf http://127.0.0.1:7001/api/v2/workers 2>/dev/null || echo "[]")
    if echo "$workers" | grep -q "fullstack-test-worker"; then
      log "Worker registered successfully!"
      return 0
    fi
    retries=$((retries - 1))
    sleep 5
  done

  warn "Worker did not appear in /api/v2/workers within timeout."
  info "Worker log (last 20 lines):"
  tail -20 "$worker_dir/worker.log" 2>/dev/null || true
  return 1
}

stop_worker() {
  local worker_dir="$LOCAL_ROOT/worker"
  if [ -f "$worker_dir/worker.pid" ]; then
    local pid
    pid=$(cat "$worker_dir/worker.pid")
    if kill -0 "$pid" 2>/dev/null; then
      log "Stopping worker (PID: $pid) ..."
      kill -INT "$pid" 2>/dev/null || true
      sleep 5
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$worker_dir/worker.pid"
  fi
}


cmd_up() {
  check_fullstack_prerequisites

  # Tier 0: Infrastructure
  log "Creating external network: horde-stack"
  docker network create horde-stack 2>/dev/null || true

  log "Rendering configs via Ansible ..."
  render_configs
  clone_sources

  # Tier 1: Backend (AI-Horde + Postgres + Redis)
  log "═══ Tier 1: AI-Horde Backend ═══"
  log "Building AI-Horde Docker image ..."
  dc_backend build
  log "Starting AI-Horde backend ..."
  dc_backend up -d --scale aihorde="$INSTANCES"
  wait_for_url "http://127.0.0.1:7001/api/v2/status/heartbeat" "AI-Horde" 300 || {
    err "AI-Horde did not start. Dumping logs:"
    dc_backend logs --tail=50
    return 1
  }
  echo ""

  # Tier 2: Frontend (AiHordeFrontpage)
  log "═══ Tier 2: AiHordeFrontpage ═══"
  log "Building AiHordeFrontpage Docker image (this may take a few minutes) ..."
  dc_frontpage build
  log "Starting AiHordeFrontpage ..."
  dc_frontpage up -d
  wait_for_url "http://127.0.0.1:8006/" "Frontpage" 300 || {
    err "Frontpage did not start. Dumping logs:"
    dc_frontpage logs --tail=50
    return 1
  }
  echo ""

  # Tier 3: Monitoring (optional)
  if [ "$WITH_MONITORING" = true ]; then
    log "═══ Tier 3: Monitoring Stack ═══"
    cleanup_monitoring_container_name_conflicts || return 1

    # Load monitoring env for Garage/Grafana bootstrap variables.
    local mon_env="$LOCAL_ROOT/local-deploy.env"
    if [ -f "$mon_env" ]; then
      load_env "$mon_env"
    else
      warn "Monitoring env file not found at $mon_env — bootstrap steps will be skipped."
    fi

    # Phase 1: strip Org-2 provisioning before first Grafana boot.
    grafana_strip_org2_provisioning "$LOCAL_ROOT"

    log "Starting monitoring stack ..."
    dc_monitoring up -d

    # Bootstrap embedded Garage (import key, create buckets).
    bootstrap_embedded_garage

    wait_for_url "http://127.0.0.1:${MIMIR_PORT:-9009}/ready" "Mimir" 60 || true
    wait_for_url "http://127.0.0.1:${GRAFANA_PORT:-3000}/api/health" "Grafana" 200 || {
      warn "Grafana did not become healthy."
    }

    # Phase 2: create Org 2, restore full provisioning, restart Grafana.
    grafana_create_org2_and_restore "$LOCAL_ROOT" dc_monitoring
    echo ""
  fi

  # Tier 4: Application layer (Exporter + HAProxy)
  log "═══ Tier 4: HAProxy Edge Router ═══"

  # If monitoring is up, connect the exporter to the horde-stack network
  # so HAProxy can route /appstats/ to it.
  # We use `docker network connect` instead of a compose overlay because
  # re-running compose with a different network config on an already-running
  # project causes Docker to reconcile (remove+recreate) the monitoring
  # network, which fails while other containers are attached.
  if [ "$WITH_MONITORING" = true ]; then
    log "Connecting exporter to horde-stack network ..."
    docker network connect horde-stack horde-exporter 2>/dev/null || true
  fi

  log "Starting HAProxy ..."
  dc_haproxy up -d
  wait_for_url "http://127.0.0.1:80/" "HAProxy" 90 || {
    err "HAProxy did not start. Dumping logs:"
    dc_haproxy logs --tail=50
    return 1
  }
  echo ""

  # Connectivity probes
  log "═══ Connectivity Probes ═══"
  probe_connectivity || {
    err "Connectivity probes failed. Refusing to mark stack healthy."
    return 1
  }
  echo ""

  # Tier 5: Artbot (optional)
  if [ "$WITH_ARTBOT" = true ]; then
    log "═══ Tier 5: Artbot ═══"
    log "Building Artbot Docker image (this may take a few minutes) ..."
    dc_artbot build
    log "Starting Artbot ..."
    dc_artbot up -d
    wait_for_url "http://127.0.0.1:8080/" "Artbot" 300 || {
      warn "Artbot did not become healthy — check logs with: $0 logs artbot"
    }
    echo ""
  fi

  # Tier 6: GPU Worker (optional)
  if [ "$WITH_WORKER" = true ]; then
    log "═══ Tier 6: GPU Worker ═══"
    deploy_worker || warn "Worker deployment had issues (see above)."
    echo ""
  fi

  print_banner
}


cmd_down() {
  log "Tearing down full stack ..."

  # Reverse order — always attempt all tiers regardless of startup flags.
  # The user should not need to re-specify flags for teardown.
  stop_worker
  dc_artbot down --remove-orphans 2>/dev/null || true
  dc_haproxy down --remove-orphans 2>/dev/null || true
  dc_monitoring down --remove-orphans 2>/dev/null || true
  dc_frontpage down --remove-orphans 2>/dev/null || true
  dc_backend down --remove-orphans 2>/dev/null || true

  # Remove shared network (only if no containers are using it)
  docker network rm horde-stack 2>/dev/null || true

  log "Full stack torn down."
}


cmd_status() {
  echo ""
  info "─── AI-Horde Backend ───"
  dc_backend ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  (not running)"
  echo ""
  info "─── AiHordeFrontpage ───"
  dc_frontpage ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  (not running)"
  echo ""
  info "─── HAProxy ───"
  dc_haproxy ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  (not running)"
  echo ""
  info "─── Monitoring ───"
  dc_monitoring ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  (not running)"
  echo ""
  info "─── Artbot ───"
  dc_artbot ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  (not running)"
  echo ""
}


cmd_logs() {
  local service="${1:-}"
  case "$service" in
    backend|aihorde)
      dc_backend logs -f --tail=100
      ;;
    frontpage|frontend)
      dc_frontpage logs -f --tail=100
      ;;
    haproxy)
      dc_haproxy logs -f --tail=100
      ;;
    monitoring)
      dc_monitoring logs -f --tail=100
      ;;
    artbot)
      dc_artbot logs -f --tail=100
      ;;
    "")
      # Show logs from all compose projects interleaved
      info "Showing logs from all services (Ctrl+C to stop) ..."
      info "Tip: use '$0 logs <backend|frontpage|haproxy|monitoring|artbot>' for a single tier."
      # Tail the most recent logs from each project
      dc_backend logs --tail=20 2>/dev/null || true
      echo "---"
      dc_frontpage logs --tail=20 2>/dev/null || true
      echo "---"
      dc_haproxy logs --tail=20 2>/dev/null || true
      ;;
    *)
      warn "Unknown service: $service"
      echo "Usage: $0 logs [backend|frontpage|haproxy|monitoring|artbot]"
      exit 1
      ;;
  esac
}


print_banner() {
  echo ""
  log "═══════════════════════════════════════════════════════════"
  log "  Full Horde stack is running!"
  log "═══════════════════════════════════════════════════════════"
  info "  Frontpage:     http://localhost/"
  info "  API:           http://localhost/api/v2/status/heartbeat"
  if [ "$INSTANCES" -gt 1 ]; then
    local port_end=$(( 7001 + INSTANCES - 1 ))
    info "  API (direct):  http://localhost:7001–${port_end}  (${INSTANCES} instances)"
  else
    info "  API (direct):  http://localhost:7001/api/v2/status/heartbeat"
  fi
  info "  HAProxy stats: http://localhost:8404/stats"
  if [ "$WITH_MONITORING" = true ]; then
    info "  Grafana:       http://localhost:3000/"
    info "  Prometheus:    http://localhost:9090/"
  fi
  if [ "$WITH_ARTBOT" = true ]; then
    info "  Artbot:        http://localhost:8080/"
    info "  Artbot stats:  http://localhost:8484/stats"
  fi
  log "═══════════════════════════════════════════════════════════"
  echo ""
  info "Tear down:  $0 down"
  echo ""
}


main() {
  local cmd="${1:-up}"
  shift || true

  # Separate flags from positional arguments
  local -a positional=()
  for arg in "$@"; do
    case "$arg" in
      --with-monitoring) WITH_MONITORING=true ;;
      --with-worker)     WITH_WORKER=true ;;
      --with-artbot)     WITH_ARTBOT=true ;;
      --latest)          USE_LATEST_REFS=true ;;
      --all)             WITH_MONITORING=true; WITH_WORKER=true; WITH_ARTBOT=true ;;
      --instances=*)     INSTANCES="${arg#--instances=}" ;;
      -*)                warn "Unknown flag: $arg" ;;
      *)                 positional+=("$arg") ;;
    esac
  done

  case "$cmd" in
    up)
      cmd_up
      ;;
    down)
      cmd_down
      ;;
    status)
      cmd_status
      ;;
    logs)
      cmd_logs "${positional[0]:-}"
      ;;
    *)
      echo "Usage: $0 {up|down|status|logs} [--with-monitoring] [--with-worker] [--with-artbot] [--latest] [--all] [--instances=N]"
      exit 1
      ;;
  esac
}

main "$@"
