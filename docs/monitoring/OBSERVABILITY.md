# Observability Stack - Metrics, Logs, Traces, and Profiles

This runbook documents the full observability topology used by this
repository, including:

- Core metrics plane: Prometheus, Mimir, Grafana, and horde-exporter
- Optional signal backends: Loki (logs), Tempo (traces), Pyroscope (profiles)
- Host-side telemetry collector: Grafana Alloy on application hosts

For deployment order and baseline setup, see [MONITORING.md](../../MONITORING.md).

## Topology At A Glance

```text
┌──────────────────────────── Application Hosts (N) ───────────────────────────┐
│                                                                              │
│     [ --- AI-Horde services / workers / sidecars --- ]                       │
│                                                                              │
│      │                    │                       │                          │
│      │ app metrics        │ logs                  │ traces (OTLP)            │
│      ▼                    ▼                       ▼                          │
│  optional scrape targets  journal/files/docker    Grafana Alloy OTLP receiver│
│      └────────────────────────────┬───────────────────────────┘              │
│                                   ▼                                          │
│                        Grafana Alloy pipelines                               │
│                   metrics -> Mimir, logs -> Loki, traces -> Tempo            │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │
                                    │ TLS/basic_auth if routed via HAProxy
                                    ▼
             ┌─────────────── Monitoring Host ────────────────────┐
             │                                                    │
             │ Native services (playbook-managed):                │
             │   Prometheus, Alertmanager, horde-exporter         │
             │                                                    │
             │ Docker Compose services (horde_monitoring role):   │
             │   Mimir <-> MinIO (+ Memcached) <-> Grafana        │
             │   + optional Loki / Tempo / Pyroscope              │
             │                                                    │
             │ Tenant model:                                      │
             │   ai-horde-app, infrastructure, ai-horde-public    │
             └────────────────────────────────────────────────────┘
```

## Role Ownership

| Role | What it owns |
| --- | --- |
| `horde_monitoring` | Mimir, MinIO, Memcached, Grafana, optional Loki/Tempo/Pyroscope, Grafana datasource provisioning, monitoring alert rules, optional HAProxy backend insertion |
| `horde_stats_exporter` | `horde-exporter` systemd service and optional downsampling timer |
| `horde_alloy` | App-host telemetry collection and forwarding (metrics/logs/traces) |
| `prometheus.prometheus.*` (playbook) | Prometheus, Alertmanager, and optional node_exporter (not managed by `horde_monitoring`) |

## Full Stack Components

| Component | Default | Toggle/Variable |
| --- | --- | --- |
| Mimir | enabled | `horde_monitoring_install_mimir: true` |
| Grafana | enabled | `horde_monitoring_install_grafana: true` |
| MinIO (Mimir object storage) | enabled | `horde_monitoring_mimir_enable_minio: true` |
| Memcached (Mimir cache) | enabled | `horde_monitoring_mimir_enable_memcached: true` |
| Loki | disabled | `horde_monitoring_install_loki: false` |
| Tempo | disabled | `horde_monitoring_install_tempo: false` |
| Pyroscope | disabled | `horde_monitoring_install_pyroscope: false` |

When MinIO is enabled, the compose init step creates buckets for enabled
components automatically (`mimir-blocks`, `mimir-ruler`, plus optional
Loki/Tempo/Pyroscope buckets).

## Enabling Optional Backends

```yaml
# Example play vars
horde_monitoring_install_loki: true
horde_monitoring_install_tempo: true
horde_monitoring_install_pyroscope: true
```

### Loki (logs)

| Variable | Default |
| --- | --- |
| `horde_monitoring_loki_image` | `grafana/loki:3.4.2` |
| `horde_monitoring_loki_port` | `3100` |
| `horde_monitoring_loki_retention_period` | `2160h` |
| `horde_monitoring_loki_retention_enabled` | `true` |
| `horde_monitoring_loki_auth_enabled` | `true` |
| `horde_monitoring_loki_chunks_bucket` | `loki-chunks` |

### Tempo (traces)

| Variable | Default |
| --- | --- |
| `horde_monitoring_tempo_image` | `grafana/tempo:2.7.1` |
| `horde_monitoring_tempo_http_port` | `3200` |
| `horde_monitoring_tempo_otlp_grpc_port` | `4317` |
| `horde_monitoring_tempo_otlp_http_port` | `4318` |
| `horde_monitoring_tempo_trace_retention` | `168h` |
| `horde_monitoring_tempo_metrics_generator_enabled` | `true` |
| `horde_monitoring_tempo_metrics_generator_tenant_id` | `infrastructure` |
| `horde_monitoring_tempo_traces_bucket` | `tempo-traces` |

Tempo metrics-generator output is remote-written to Mimir and powers Grafana
service-map/span-metrics views.

### Pyroscope (profiles)

| Variable | Default |
| --- | --- |
| `horde_monitoring_pyroscope_image` | `grafana/pyroscope:1.19.0` |
| `horde_monitoring_pyroscope_port` | `4040` |
| `horde_monitoring_pyroscope_auth_enabled` | `true` |
| `horde_monitoring_pyroscope_blocks_bucket` | `pyroscope-data` |
| `horde_monitoring_pyroscope_retention_period` | `0s` |
| `horde_monitoring_pyroscope_application_retention` | `0` |
| `horde_monitoring_pyroscope_infrastructure_retention` | `30d` |
| `horde_monitoring_pyroscope_public_retention` | `90d` |

Pyroscope per-tenant retention is rendered into runtime overrides, matching
the same tenant IDs used by Mimir datasources.

## Tenant Model And Datasource Provisioning

Default tenants:

- `horde_monitoring_application_tenant_id: ai-horde-app`
    - For core AI-Horde application metrics, currently indefinately retained
- `horde_monitoring_infrastructure_tenant_id: infrastructure`
    - For host and infrastructure metrics, retained for 30 days by default
- `horde_monitoring_public_tenant_id: ai-horde-public`
    - Downsampled and restricted metrics suitable for public dashboards.

Grafana datasource provisioning is automatic:

- Org 1: Mimir app + infrastructure datasources
    - Optional Org 1 datasources when enabled: Loki, Tempo, Pyroscope
- Org 2 (public, anonymous) datasource set when
  `horde_monitoring_grafana_anonymous_enabled: true`
    - Note that public dashboards should use the `ai-horde-public` tenant datasource, which has downsampled
      and restricted metrics to limit performance impact.

Cross-signal features auto-configure when components are enabled:

- Loki derived field links (`trace_id`/`traceID`/`traceId`) to Tempo
- Tempo trace-to-metrics service map to Mimir infrastructure datasource

## Alerting Coverage

When `horde_monitoring_install_alerting_rules: true`, the role renders
Prometheus rules for stack self-monitoring. Coverage includes:

- Core: `Watchdog`, `MimirDown`, `MimirRequestErrors`, `MimirIngestionStalled`
- MinIO: `MinIODown`, disk usage alerts
- Optional Loki: `LokiDown`, `LokiRequestErrors`, `LokiIngestionStalled`
- Optional Tempo: `TempoDown`, `TempoRequestErrors`, `TempoIngestionStalled`
- Optional Pyroscope: `PyroscopeDown`, `PyroscopeRequestErrors`, `PyroscopeIngestionStalled`
- Host disk alerts (require `node_filesystem_*` metrics): `HostDiskUsageCritical`, `HostDiskUsageHigh`

## Deploying Alloy On Application Hosts

`horde_alloy` is the host collector role for metrics, logs, and traces.

### Quick Start

```yaml
# group_vars / inventory vars
horde_alloy_mimir_endpoint: "https://mimir.example.com/api/v1/push"
horde_alloy_loki_endpoint: "https://loki.example.com/loki/api/v1/push"
horde_alloy_tempo_endpoint: "https://tempo.example.com:4318"
horde_alloy_tenant_id: "infrastructure"
horde_alloy_basic_auth_username: "alloy"
horde_alloy_basic_auth_password: "{{ vault_alloy_basic_auth_password }}"
horde_alloy_tls_ca_cert: "tls/ca.crt"
```

```yaml
- hosts: app_workers
  become: true
  roles:
    - haidra.deployments.horde_alloy
```

Complete example: [examples/alloy_app_host.yml](../../examples/alloy_app_host.yml)

### Interaction With node_exporter Deployment

In [examples/horde_monitoring_stack.yml](../../examples/horde_monitoring_stack.yml),
node_exporter installation is decided per host using
`horde_host_metrics_source`:

- `auto` (recommended): skip node_exporter when the host has
  `horde_alloy_enabled: true` or `horde_alloy_collect_metrics: true`;
  otherwise install node_exporter.
- `node_exporter`: force install on all hosts.
- `alloy`: force skip on all hosts.

### Alloy Pipeline Toggles

| Signal | Main toggle | Supporting toggles |
| --- | --- | --- |
| Metrics | `horde_alloy_collect_metrics` | `horde_alloy_extra_scrape_targets`, `horde_alloy_external_labels` |
| Logs | `horde_alloy_collect_logs` | `horde_alloy_collect_journal`, `horde_alloy_collect_log_files`, `horde_alloy_collect_docker_logs`, `horde_alloy_log_labels` |
| Traces | `horde_alloy_collect_traces` | `horde_alloy_otlp_listen_address`, `horde_alloy_otlp_grpc_port`, `horde_alloy_otlp_http_port` |
| OTLP metrics forwarding | `horde_alloy_forward_otlp_metrics` | `horde_alloy_otlp_metrics_tenant_id` |

Role validation fails fast if enabled pipelines do not have endpoints, or if
`horde_alloy_basic_auth_password` is left at `changeme-alloy`.

## End-To-End Data Flows

- Exporter metrics: `horde-exporter` -> Prometheus scrape -> Mimir
- Host metrics: node_exporter -> Prometheus scrape or Alloy `prometheus.exporter.unix` -> Mimir remote_write
- Logs: Alloy journal/file/docker sources -> Loki push API
- Traces: app OTLP -> Alloy OTLP receiver -> Tempo OTLP HTTP exporter
- Trace-derived metrics: Tempo metrics generator -> Mimir remote_write
- Profiles: app profiler SDK/agent -> Pyroscope HTTP ingest endpoint

Note: profile ingestion is not handled by `horde_alloy` today; applications
push profiles directly to Pyroscope.

## Retention Defaults

| Signal | Storage backend | Default retention | Variable |
| --- | --- | --- | --- |
| Mimir application tenant | Mimir | infinite (`0`) | `horde_monitoring_application_retention` |
| Mimir infrastructure tenant | Mimir | `30d` | `horde_monitoring_infrastructure_retention` |
| Mimir public tenant | Mimir | `90d` | `horde_monitoring_public_retention` |
| Logs | Loki | `2160h` (90 days) | `horde_monitoring_loki_retention_period` |
| Traces | Tempo | `168h` (7 days) | `horde_monitoring_tempo_trace_retention` |
| Profiles (global default) | Pyroscope | `0s` (infinite) | `horde_monitoring_pyroscope_retention_period` |
| Profiles (application tenant) | Pyroscope | `0` | `horde_monitoring_pyroscope_application_retention` |
| Profiles (infrastructure tenant) | Pyroscope | `30d` | `horde_monitoring_pyroscope_infrastructure_retention` |
| Profiles (public tenant) | Pyroscope | `90d` | `horde_monitoring_pyroscope_public_retention` |
| Prometheus local TSDB | Prometheus | `48h` in example playbook | `prometheus_storage_retention` |

## HAProxy Integration Notes

When `horde_monitoring_configure_haproxy: true`, the role inserts backends for:

- Grafana
- Mimir
- Loki (when enabled)
- Tempo OTLP HTTP ingest (`horde_monitoring_tempo_otlp_http_port`) when enabled

Pyroscope backend/frontends are not auto-inserted by the role; add those in
your HAProxy config if you need proxied profile ingest/query access.

## Health Checks

```bash
# Core
curl -sf http://127.0.0.1:9009/ready             # Mimir
curl -sf http://127.0.0.1:9000/minio/health/live # MinIO
curl -sf http://127.0.0.1:3000/api/health        # Grafana

# Optional
curl -sf http://127.0.0.1:3100/ready             # Loki
curl -sf http://127.0.0.1:3200/ready             # Tempo
curl -sf http://127.0.0.1:4040/ready             # Pyroscope

# App host
curl -sf http://127.0.0.1:12345/-/healthy        # Alloy
```
## Related Documents

- [MONITORING.md](../../MONITORING.md)
- [BACKUP.md](BACKUP.md)
- [CREDENTIALS.md](CREDENTIALS.md)
- [UPGRADING.md](UPGRADING.md)
- [examples/horde_monitoring_stack.yml](../../examples/horde_monitoring_stack.yml)
