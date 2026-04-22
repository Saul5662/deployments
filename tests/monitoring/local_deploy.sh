#!/usr/bin/env bash

# Local deployment of the full horde monitoring + exporter stack for
# manual validation.  Renders ALL configs via Ansible (including
# Prometheus, Alertmanager, Exporter, Alloy, and the Compose overlay),
# then starts everything via Docker Compose.
#
# All ports, image versions, and configuration values are defined once
# in tests/monitoring/local_deploy.yml.  The Ansible playbook renders them into
# config files and a local-deploy.env that this script sources.
# Nothing is hardcoded here.
#
# Usage:
#   ./tests/monitoring/local_deploy.sh up       # render configs + start full stack
#   ./tests/monitoring/local_deploy.sh down     # tear down stack + remove files
#   ./tests/monitoring/local_deploy.sh restart  # equivalent to: down + up
#   ./tests/monitoring/local_deploy.sh render   # render configs only (no docker)
#   ./tests/monitoring/local_deploy.sh status   # show running containers
#   ./tests/monitoring/local_deploy.sh logs     # tail compose logs
#
# After "up", access the URLs printed by the banner (ports come from
# local_deploy.yml and are displayed after stack startup).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib.sh
source "$REPO_ROOT/tests/lib.sh"

export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles"
export ANSIBLE_HOST_KEY_CHECKING=False
LOCAL_ROOT="$REPO_ROOT/local-deploy/runtime"
COMPOSE_DIR="$LOCAL_ROOT/compose"
ENV_FILE="$LOCAL_ROOT/local-deploy.env"

# Compose project name. Pinned (rather than letting Docker derive it from
# $COMPOSE_DIR's basename) so that subsequent `up` / `down` invocations
# — or the parent full_stack/local_deploy.sh script, which uses the same
# name — always target the same set of containers.
MONITORING_PROJECT="horde-monitoring"

# Containers in this stack use fixed `container_name:` values (see
# roles/horde_monitoring/templates/docker-compose.monitoring.yml.j2 and
# tests/monitoring/templates/local-deploy/docker-compose.local.yml.j2).
# Listed here so we can detect orphans from prior runs whose project
# label differs from MONITORING_PROJECT.
MONITORING_CONTAINER_NAMES=(
  s3-store s3-init memcached mimir grafana loki tempo pyroscope
  alertmanager prometheus horde-exporter alloy
)

# Helper: run docker compose with all files
dc() {
  local args="-f $COMPOSE_DIR/docker-compose.yml"
  if [ -f "$COMPOSE_DIR/docker-compose.local.yml" ]; then
    args="$args -f $COMPOSE_DIR/docker-compose.local.yml"
  fi
  # shellcheck disable=SC2086
  docker compose $args --project-name "$MONITORING_PROJECT" "$@"
}


render_configs() {
  find_ansible
  log "Rendering monitoring stack configs into $LOCAL_ROOT ..."
  "$ANSIBLE_PLAYBOOK" \
      -i "localhost," \
      "$SCRIPT_DIR/local_deploy.yml" \
      --become \
      -v
  log "Config rendering complete."
}


compose_up() {
  if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    err "No docker-compose.yml found — run '$0 up' first."
    exit 1
  fi

  # Sweep up any name-collision orphans from a previous run with a
  # different compose project (e.g. the directory-default `compose`
  # before MONITORING_PROJECT was pinned, or stale containers left
  # behind by a partial teardown).
  cleanup_known_container_name_conflicts "$MONITORING_PROJECT" "${MONITORING_CONTAINER_NAMES[@]}"

  # Phase 1 — Boot Grafana without any Org-2 provisioning.
  grafana_strip_org2_provisioning "$LOCAL_ROOT"

  log "Starting Docker Compose stack ..."
  dc up -d

  bootstrap_embedded_garage

  wait_for_url "http://127.0.0.1:${MIMIR_PORT}/ready" "Mimir" 60 || true
  wait_for_url "http://127.0.0.1:${GRAFANA_PORT}/api/health" "Grafana" 60 || true

  # Phase 2 — Create Org 2, restore full provisioning, restart Grafana.
  grafana_create_org2_and_restore "$LOCAL_ROOT" dc

  # Phase 3 — Wait for the rest of the pipeline.
  wait_for_url "http://127.0.0.1:${PROMETHEUS_PORT}/-/ready" "Prometheus" 60 || true
  wait_for_url "http://127.0.0.1:${ALERTMANAGER_PORT}/-/ready" "Alertmanager" 60 || true
  wait_for_url "http://127.0.0.1:${LOKI_PORT}/ready" "Loki" 60 || true
  wait_for_url "http://127.0.0.1:${TEMPO_HTTP_PORT}/ready" "Tempo" 60 || true
  wait_for_url "http://127.0.0.1:${ALLOY_HTTP_PORT}/-/healthy" "Alloy" 60 || true

  log "Waiting for exporter to start (installs on first run) ..."
  wait_for_url "http://127.0.0.1:${EXPORTER_PORT}/metrics" "Exporter" 180 || true
}


print_banner() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Grafana (admin)   →  http://localhost:${GRAFANA_PORT}  (admin / ${GRAFANA_ADMIN_PASSWORD})"
  info "Grafana (anon)    →  http://localhost:${GRAFANA_PORT}  (switch to '${GRAFANA_PUBLIC_ORG_NAME}' org)"
  info "Prometheus        →  http://localhost:${PROMETHEUS_PORT}"
  info "Alertmanager      →  http://localhost:${ALERTMANAGER_PORT}"
  info "Mimir readiness   →  http://localhost:${MIMIR_PORT}/ready"
  info "Loki readiness    →  http://localhost:${LOKI_PORT}/ready"
  info "Tempo readiness   →  http://localhost:${TEMPO_HTTP_PORT}/ready"
  info "Alloy UI          →  http://localhost:${ALLOY_HTTP_PORT}"
  info "Exporter metrics  →  http://localhost:${EXPORTER_PORT}/metrics"
  echo ""
  info "OTLP endpoints (via Alloy):"
  info "  gRPC  →  localhost:${TEMPO_OTLP_GRPC_PORT}"
  info "  HTTP  →  http://localhost:${TEMPO_OTLP_HTTP_PORT}"
  echo ""
  info "Dashboards are provisioned from horde-exporters."
  info "  Org 1 (admin): 'AI Horde' + 'Infrastructure' folders"
  info "  Org 2 (public): anonymous Viewer access, limited queries"
  echo ""
  info "Live data pipeline:"
  info "  horde-exporter → Prometheus → Mimir → Grafana"
  info "  Prometheus → Alertmanager (alerts visible in Grafana Alerting UI)"
  info "  Alloy → Loki (container logs, explore in Grafana)"
  info "  App → Alloy → Tempo (traces, explore in Grafana)"
  info "  Metrics should appear in dashboards within ~30s."
  echo ""
  info "Tear down:  $0 down"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}


main() {
  local cmd="${1:-up}"

  case "$cmd" in
    up)
      check_prerequisites python3
      render_configs
      load_env "$ENV_FILE"
      compose_up
      print_banner
      ;;
    down)
      compose_down "$LOCAL_ROOT" "$MONITORING_PROJECT"
      ;;
    restart)
      compose_down "$LOCAL_ROOT" "$MONITORING_PROJECT"
      check_prerequisites python3
      render_configs
      load_env "$ENV_FILE"
      compose_up
      print_banner
      ;;
    render)
      check_prerequisites python3
      render_configs
      log "Rendered configs are at $LOCAL_ROOT (no containers started)."
      ;;
    status)
      compose_status "$COMPOSE_DIR/docker-compose.yml"
      ;;
    logs)
      compose_logs "$COMPOSE_DIR/docker-compose.yml"
      ;;
    *)
      echo "Usage: $0 {up|down|restart|render|status|logs}"
      exit 1
      ;;
  esac
}

main "$@"
