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
LOCAL_ROOT="$REPO_ROOT/local-deploy"
COMPOSE_DIR="$LOCAL_ROOT/compose"
ENV_FILE="$LOCAL_ROOT/local-deploy.env"

# Helper: run docker compose with all files
dc() {
  local args="-f $COMPOSE_DIR/docker-compose.yml"
  if [ -f "$COMPOSE_DIR/docker-compose.local.yml" ]; then
    args="$args -f $COMPOSE_DIR/docker-compose.local.yml"
  fi
  # shellcheck disable=SC2086
  docker compose $args "$@"
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


garage_exec() {
  docker exec s3-store /garage -c /etc/garage.toml "$@"
}


bootstrap_embedded_garage() {
  local retries=15
  local health_code
  local node_id
  local garage_secret_key
  local output
  local -a garage_buckets

  if ! docker ps --format '{{.Names}}' | grep -qx 's3-store'; then
    warn "s3-store container is not running; skipping embedded Garage bootstrap."
    return 0
  fi

  if [[ -z "${GARAGE_S3_ACCESS_KEY_ID:-}" || -z "${GARAGE_S3_ACCESS_KEY_NAME:-}" || -z "${GARAGE_S3_SECRET_KEY_FILE:-}" ]]; then
    err "Missing embedded Garage bootstrap variables in $ENV_FILE."
    return 1
  fi

  if [[ ! -f "$GARAGE_S3_SECRET_KEY_FILE" ]]; then
    err "Garage secret key file not found at $GARAGE_S3_SECRET_KEY_FILE. Re-run '$0 up' to regenerate."
    return 1
  fi

  garage_secret_key="$(tr -d '[:space:]' < "$GARAGE_S3_SECRET_KEY_FILE" | tr '[:upper:]' '[:lower:]')"

  if [[ ! "$GARAGE_S3_ACCESS_KEY_ID" =~ ^GK[0-9a-fA-F]{24}$ ]]; then
    err "GARAGE_S3_ACCESS_KEY_ID must match GK + 24 hex chars."
    return 1
  fi

  if [[ ! "$garage_secret_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
    err "Garage secret key in $GARAGE_S3_SECRET_KEY_FILE is invalid (expected 64 hex chars)."
    return 1
  fi

  log "Bootstrapping embedded Garage (layout, key, buckets) ..."
  while [[ $retries -gt 0 ]]; do
    if garage_exec status >/dev/null 2>&1; then
      break
    fi
    retries=$((retries - 1))
    sleep 2
  done

  if [[ $retries -eq 0 ]]; then
    err "Embedded Garage CLI did not become ready in time."
    return 1
  fi

  health_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GARAGE_S3_ADMIN_PORT}/health" || echo "000")
  if [[ "$health_code" != "200" ]]; then
    node_id="$(garage_exec node id | sed -nE 's/^([0-9a-f]{16,64})@.*$/\1/p' | head -1)"
    if [[ -z "$node_id" ]]; then
      node_id="$(garage_exec status | sed -nE 's/^([0-9a-f]{16,64})[[:space:]].*/\1/p' | head -1)"
    fi
    if [[ -z "$node_id" ]]; then
      err "Could not parse embedded Garage node ID for layout assignment."
      return 1
    fi

    garage_exec layout assign "$node_id" --zone dc1 --capacity "$GARAGE_S3_CAPACITY_BYTES" >/dev/null
    garage_exec layout apply --version 1 >/dev/null
  fi

  if ! output="$(garage_exec key import --yes -n "$GARAGE_S3_ACCESS_KEY_NAME" "$GARAGE_S3_ACCESS_KEY_ID" "$garage_secret_key" 2>&1)"; then
    if [[ "$output" == *"KeyAlreadyExists"* ]]; then
      if ! garage_exec key info "$GARAGE_S3_ACCESS_KEY_ID" >/dev/null 2>&1; then
        if [[ -n "${GARAGE_S3_ACCESS_KEY_SUFFIX_FILE:-}" ]]; then
          rm -f "$GARAGE_S3_ACCESS_KEY_SUFFIX_FILE"
          err "Embedded Garage key ID $GARAGE_S3_ACCESS_KEY_ID cannot be reused (tombstoned)."
          err "Removed $GARAGE_S3_ACCESS_KEY_SUFFIX_FILE to force a new key ID on next render."
          err "Re-run '$0 up' to regenerate credentials and restart the local stack."
        else
          err "Embedded Garage key ID $GARAGE_S3_ACCESS_KEY_ID cannot be reused (tombstoned)."
          err "Re-run '$0 up' after regenerating local key ID metadata."
        fi
        return 1
      fi
    else
      err "Failed to import embedded Garage S3 key."
      err "$output"
      return 1
    fi
  fi

  garage_buckets=(
    "$GARAGE_S3_BLOCKS_BUCKET"
    "$GARAGE_S3_RULER_BUCKET"
    "$GARAGE_S3_ALERTMANAGER_BUCKET"
  )
  if [[ -n "${GARAGE_S3_LOKI_BUCKET:-}" ]]; then
    garage_buckets+=("$GARAGE_S3_LOKI_BUCKET")
  fi
  if [[ -n "${GARAGE_S3_TEMPO_BUCKET:-}" ]]; then
    garage_buckets+=("$GARAGE_S3_TEMPO_BUCKET")
  fi
  if [[ -n "${GARAGE_S3_PYROSCOPE_BUCKET:-}" ]]; then
    garage_buckets+=("$GARAGE_S3_PYROSCOPE_BUCKET")
  fi

  for bucket in "${garage_buckets[@]}"; do
    if ! output="$(garage_exec bucket create "$bucket" 2>&1)"; then
      if [[ "$output" != *"BucketAlreadyExists"* ]]; then
        err "Failed to create Garage bucket '$bucket'."
        err "$output"
        return 1
      fi
    fi

    garage_exec bucket allow --read --write --owner "$bucket" --key "$GARAGE_S3_ACCESS_KEY_ID" >/dev/null
  done

  wait_for_url "http://127.0.0.1:${GARAGE_S3_ADMIN_PORT}/health" "Embedded Garage" 60 || return 1
}


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

  bootstrap_embedded_garage

  wait_for_url "http://127.0.0.1:${MIMIR_PORT}/ready" "Mimir" 60 || true
  wait_for_url "http://127.0.0.1:${GRAFANA_PORT}/api/health" "Grafana" 60 || true

  # Phase 2 — Create Org 2, restore full provisioning, restart Grafana.
  log "Ensuring public Grafana organization exists ..."
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:${GRAFANA_PORT}/api/orgs" \
    -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${GRAFANA_PUBLIC_ORG_NAME}\"}" 2>/dev/null || echo "000")
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
      compose_down "$LOCAL_ROOT"
      ;;
    status)
      compose_status "$COMPOSE_DIR/docker-compose.yml"
      ;;
    logs)
      compose_logs "$COMPOSE_DIR/docker-compose.yml"
      ;;
    *)
      echo "Usage: $0 {up|down|status|logs}"
      exit 1
      ;;
  esac
}

main "$@"
