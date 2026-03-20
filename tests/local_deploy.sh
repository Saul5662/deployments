#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Local deployment of the full horde monitoring + exporter stack for
# manual validation.  Renders configs via Ansible, adds Prometheus and
# the AI Horde stats exporter, then starts everything via Docker Compose.
#
# Usage:
#   ./tests/local_deploy.sh up       # render configs + start full stack
#   ./tests/local_deploy.sh down     # tear down stack + remove files
#   ./tests/local_deploy.sh status   # show running containers
#   ./tests/local_deploy.sh logs     # tail compose logs
#
# After "up", access:
#   Grafana admin  →  http://localhost:3000  (admin / localdev)
#   Grafana anon   →  http://localhost:3000  (switch to "AI Horde Public" org)
#   Mimir API      →  http://localhost:9009/ready
#   Prometheus     →  http://localhost:9090
#   Alertmanager   →  http://localhost:9093
#   Exporter raw   →  http://localhost:9150/metrics
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_ROOT="$REPO_ROOT/local-deploy"
COMPOSE_DIR="$LOCAL_ROOT/compose"
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
ALERTMANAGER_PORT=9093
EXPORTER_PORT=9150

# Pinned image versions for local-deploy reproducibility (Plan 012)
ALERTMANAGER_IMAGE="${ALERTMANAGER_IMAGE:-prom/alertmanager:v0.31.1}"
PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-prom/prometheus:v3.10.0}"
EXPORTER_BASE_IMAGE="${EXPORTER_BASE_IMAGE:-python:3.12-bookworm}"

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

# Helper: run docker compose with all files
dc() {
  local args="-f $COMPOSE_DIR/docker-compose.yml"
  if [ -f "$COMPOSE_DIR/docker-compose.local.yml" ]; then
    args="$args -f $COMPOSE_DIR/docker-compose.local.yml"
  fi
  # shellcheck disable=SC2086
  docker compose $args "$@"
}

# ── Prerequisite checks ──────────────────────────────────────────────
check_prerequisites() {
  local missing=0
  for cmd in docker curl python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Required command not found: $cmd"
      missing=$((missing + 1))
    fi
  done
  if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose V2 plugin is required. Install it: https://docs.docker.com/compose/install/"
    missing=$((missing + 1))
  fi
  if [ $missing -gt 0 ]; then
    err "$missing prerequisite(s) missing — cannot continue."
    exit 1
  fi
  log "Prerequisites verified (docker, curl, python3, docker compose)."
}

# ── Locate ansible-playbook ─────────────────────────────────────────
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

# ── Render configs via Ansible ───────────────────────────────────────
render_configs() {
  find_ansible
  log "Rendering monitoring stack configs into $LOCAL_ROOT ..."
  ANSIBLE_CONFIG="$SCRIPT_DIR/ansible.cfg" \
    "$ANSIBLE_PLAYBOOK" \
      -i "localhost," \
      "$SCRIPT_DIR/local_deploy.yml" \
      --become \
      -v
  log "Config rendering complete."
}

# ── Wait helper ───────────────────────────────────────────────────────
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

# ── Generate Prometheus + Exporter configs ───────────────────────────
generate_local_configs() {
  log "Generating Prometheus + exporter configs ..."

  # ── Prometheus config ─────────────────────────────────────────────
  mkdir -p "$LOCAL_ROOT/prometheus"
  cat > "$LOCAL_ROOT/prometheus/prometheus.yml" <<'PROMEOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.rules

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'mimir'
    static_configs:
      - targets: ['mimir:9009']

  - job_name: 'horde-exporter'
    scrape_interval: 15s
    static_configs:
      - targets: ['horde-exporter:9150']

remote_write:
  - url: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: ai-horde-app
  - url: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: infrastructure
    write_relabel_configs:
      - source_labels: [job]
        regex: "prometheus|mimir"
        action: keep
  - url: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: ai-horde-public
    write_relabel_configs:
      - source_labels: [job]
        regex: horde-exporter
        action: keep
PROMEOF

  # ── AI Horde Stats Exporter config ────────────────────────────────
  mkdir -p "$LOCAL_ROOT/exporter"
  cat > "$LOCAL_ROOT/exporter/config.yaml" <<'EXPEOF'
scrape_intervals:
  models: 8
  workers: 300
  performance: 2
  stats: 120
  modes: 30
  teams: 300

api:
  base_url: "https://aihorde.net/api/v2"
  user_agent: "horde_prometheus_exporter/local-dev"
  timeout: 10

exporter:
  port: 9150
  log_level: INFO
EXPEOF

  # ── Alertmanager config ───────────────────────────────────────────
  mkdir -p "$LOCAL_ROOT/alertmanager"
  cat > "$LOCAL_ROOT/alertmanager/alertmanager.yml" <<'AMEOF'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'job']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: default
  routes:
    - matchers:
        - alertname="Watchdog"
      receiver: "null"
      repeat_interval: 5m

receivers:
  - name: default
  - name: "null"

inhibit_rules:
  - source_matchers:
      - severity="critical"
    target_matchers:
      - severity="warning"
    equal: ['alertname', 'job']
AMEOF

  # ── Docker Compose override: Prometheus + Alertmanager + Exporter ─
  cat > "$COMPOSE_DIR/docker-compose.local.yml" <<COMPEOF
# Auto-generated by local_deploy.sh — adds Prometheus + Alertmanager + AI Horde Exporter
services:
  alertmanager:
    image: ${ALERTMANAGER_IMAGE}
    container_name: alertmanager
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
      - '--web.listen-address=:9093'
    volumes:
      - $LOCAL_ROOT/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    ports:
      - "127.0.0.1:${ALERTMANAGER_PORT}:9093"
    restart: unless-stopped
    networks:
      - monitoring

  prometheus:
    image: ${PROMETHEUS_IMAGE}
    container_name: prometheus
    volumes:
      - $LOCAL_ROOT/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - $LOCAL_ROOT/prometheus/rules:/etc/prometheus/rules:ro
    ports:
      - "127.0.0.1:${PROMETHEUS_PORT}:9090"
    restart: unless-stopped
    networks:
      - monitoring
    depends_on:
      - mimir
      - alertmanager

  horde-exporter:
    image: ${EXPORTER_BASE_IMAGE}
    container_name: horde-exporter
    entrypoint: ["sh", "-c"]
    command:
      - |
        set -e
        if [ ! -f /opt/exporter-venv/bin/horde-exporter ]; then
          echo "Installing ai-horde-stats-exporter (first run) ..."
          python -m venv /opt/exporter-venv
          /opt/exporter-venv/bin/pip install --quiet \\
            "ai-horde-stats-exporter @ git+https://github.com/Haidra-Org/horde-exporters@main#subdirectory=packages/ai-horde-stats-exporter"
        else
          echo "Exporter already installed, starting ..."
        fi
        exec /opt/exporter-venv/bin/horde-exporter --config /etc/exporter/config.yaml
    volumes:
      - exporter-venv:/opt/exporter-venv
      - $LOCAL_ROOT/exporter/config.yaml:/etc/exporter/config.yaml:ro
    ports:
      - "127.0.0.1:${EXPORTER_PORT}:9150"
    restart: unless-stopped
    networks:
      - monitoring

volumes:
  exporter-venv:
COMPEOF

  log "Local configs generated."
}

# ── Start the stack ──────────────────────────────────────────────────
compose_up() {
  if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    err "No docker-compose.yml found — run '$0 up' first."
    exit 1
  fi

  local dashboard_cfg="$LOCAL_ROOT/grafana/provisioning/dashboards/default.yml"
  local datasource_cfg="$LOCAL_ROOT/grafana/provisioning/datasources/mimir.yml"

  # Phase 1 — Boot Grafana without any Org-2 provisioning.
  # Grafana crashes if a provider or datasource references an orgId that
  # does not exist yet.
  if [ -f "$dashboard_cfg" ]; then
    cp -a "$dashboard_cfg" "${dashboard_cfg}.full"
    printf 'apiVersion: 1\nproviders: []\n' > "$dashboard_cfg"
    chown 472:472 "$dashboard_cfg"
  fi
  if [ -f "$datasource_cfg" ]; then
    cp -a "$datasource_cfg" "${datasource_cfg}.full"
    python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
cfg['datasources'] = [d for d in cfg.get('datasources', []) if d.get('orgId', 1) == 1]
with open(sys.argv[1], 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
" "$datasource_cfg"
  fi
  log "Using Org-1-only provisioning for initial boot."

  log "Starting Docker Compose stack ..."
  dc up -d

  wait_for_url "http://127.0.0.1:9009/ready" "Mimir" 60 || true
  wait_for_url "http://127.0.0.1:${GRAFANA_PORT}/api/health" "Grafana" 60 || true

  # Phase 2 — Create Org 2, restore full provisioning, restart Grafana.
  log "Ensuring public Grafana organization exists ..."
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:${GRAFANA_PORT}/api/orgs" \
    -u "admin:localdev" \
    -H "Content-Type: application/json" \
    -d '{"name":"AI Horde Public"}' 2>/dev/null || echo "000")
  case "$http_code" in
    200) log "Created Org 2 (AI Horde Public)." ;;
    409) info "Org 2 already exists." ;;
    *)   warn "Org creation returned HTTP $http_code — anonymous org may not work." ;;
  esac

  local need_restart=false
  if [ -f "${dashboard_cfg}.full" ]; then
    mv "${dashboard_cfg}.full" "$dashboard_cfg"
    need_restart=true
  fi
  if [ -f "${datasource_cfg}.full" ]; then
    mv "${datasource_cfg}.full" "$datasource_cfg"
    need_restart=true
  fi
  if [ "$need_restart" = true ]; then
    log "Restored full provisioning; restarting Grafana ..."
    dc restart grafana
    wait_for_url "http://127.0.0.1:${GRAFANA_PORT}/api/health" "Grafana (post-restart)" 60 || true
  fi

  # Phase 3 — Wait for the rest of the pipeline.
  wait_for_url "http://127.0.0.1:${PROMETHEUS_PORT}/-/ready" "Prometheus" 60 || true

  wait_for_url "http://127.0.0.1:${ALERTMANAGER_PORT}/-/ready" "Alertmanager" 60 || true

  log "Waiting for exporter to start (installs on first run) ..."
  wait_for_url "http://127.0.0.1:${EXPORTER_PORT}/metrics" "Exporter" 180 || true
}

# ── Tear down ────────────────────────────────────────────────────────
compose_down() {
  if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    log "Stopping Docker Compose stack ..."
    dc down -v --remove-orphans 2>/dev/null || true
  fi

  if [ -d "$LOCAL_ROOT" ]; then
    log "Removing $LOCAL_ROOT ..."
    sudo rm -rf "$LOCAL_ROOT"
  fi

  log "Local deployment cleaned up."
}

# ── Status ───────────────────────────────────────────────────────────
compose_status() {
  if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    info "No local deployment found."
    return
  fi
  dc ps
}

# ── Logs ─────────────────────────────────────────────────────────────
compose_logs() {
  if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    err "No local deployment found."
    exit 1
  fi
  dc logs -f --tail=100
}

# ── Print access info ───────────────────────────────────────────────
print_banner() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Grafana (admin)   →  http://localhost:${GRAFANA_PORT}  (admin / localdev)"
  info "Grafana (anon)    →  http://localhost:${GRAFANA_PORT}  (switch to 'AI Horde Public' org)"
  info "Prometheus        →  http://localhost:${PROMETHEUS_PORT}"
  info "Alertmanager      →  http://localhost:${ALERTMANAGER_PORT}"
  info "Mimir readiness   →  http://localhost:9009/ready"
  info "Exporter metrics  →  http://localhost:${EXPORTER_PORT}/metrics"
  echo ""
  info "Dashboards are provisioned from horde-exporters."
  info "  Org 1 (admin): 'AI Horde' + 'Infrastructure' folders"
  info "  Org 2 (public): anonymous Viewer access, limited queries"
  echo ""
  info "Live data pipeline:"
  info "  horde-exporter → Prometheus → Mimir → Grafana"
  info "  Prometheus → Alertmanager (alerts visible in Grafana Alerting UI)"
  info "  Metrics should appear in dashboards within ~30s."
  echo ""
  info "Tear down:  $0 down"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-up}"

  case "$cmd" in
    up)
      check_prerequisites
      render_configs
      generate_local_configs
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
      echo "Usage: $0 {up|down|status|logs}"
      exit 1
      ;;
  esac
}

main "$@"
