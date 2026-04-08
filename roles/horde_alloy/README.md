# horde_alloy

Deploys [Grafana Alloy](https://grafana.com/docs/alloy/) on application hosts
as a unified telemetry collector for metrics, logs, and traces. Alloy replaces
the need for separate `node_exporter`, log shippers, and trace forwarders.

## What This Role Deploys

- **Grafana Alloy** as a native systemd package (APT or DNF)
- A fully templated Alloy River configuration with three pipelines:
  - **Metrics** — `prometheus.exporter.unix` host metrics + optional extra scrape targets → Mimir
  - **Logs** — systemd journal, file globs, and/or Docker container logs → Loki
  - **Traces** — OTLP gRPC/HTTP receiver for application-emitted traces → Tempo
- TLS CA certificate deployment for secure communication with the central stack

## Architecture

```
┌──── Application Host ────────────────────────────────┐
│                                                      │
│  Your App ─── OTLP ──► Grafana Alloy                │
│                          ├─ host metrics  ──► Mimir  │
│                          ├─ journal logs  ──► Loki   │
│                          └─ traces        ──► Tempo  │
└──────────────────────────────────────────────────────┘
```

Each pipeline is independently toggleable. Alloy binds its health/UI
endpoint to `127.0.0.1` by default.

## Requirements

- Debian/Ubuntu or RHEL/CentOS 8+ target
- Ansible 2.14+
- A running monitoring stack with reachable Mimir, Loki, and/or Tempo endpoints
  (see [horde_monitoring role](../horde_monitoring/README.md))

## Quick Start

```yaml
- hosts: app_workers
  become: true
  roles:
    - role: haidra.deployments.horde_alloy
      vars:
        horde_alloy_mimir_endpoint: "https://mimir.example.com/api/v1/push"
        horde_alloy_loki_endpoint: "https://loki.example.com/loki/api/v1/push"
        horde_alloy_tempo_endpoint: "https://tempo.example.com:4318"
        horde_alloy_tenant_id: "infrastructure"
        horde_alloy_basic_auth_username: "alloy"
        horde_alloy_basic_auth_password: "{{ vault_horde_alloy_basic_auth_password }}"
        horde_alloy_tls_ca_cert: "tls/ca.crt"
```

See [examples/alloy_app_host.yml](../../examples/alloy_app_host.yml) for a
complete example playbook.

## Role Variables

### General

| Variable                    | Default          | Description                             |
| --------------------------- | ---------------- | --------------------------------------- |
| `horde_alloy_version`             | `1.8.1`          | Pinned Alloy package version            |
| `horde_alloy_config_dir`          | `/etc/alloy`     | Configuration directory                 |
| `horde_alloy_data_dir`            | `/var/lib/alloy` | Persistent data (WAL, positions)        |
| `horde_alloy_log_level`           | `warn`           | Log verbosity                           |
| `horde_alloy_http_listen_address` | `127.0.0.1`      | Health/UI bind address                  |
| `horde_alloy_http_port`           | `12345`          | Health/UI port                          |
| `horde_alloy_start_service`       | `true`           | Start the service (`false` for CI/test) |

### Authentication

| Variable                    | Default          | Description                                                  |
| --------------------------- | ---------------- | ------------------------------------------------------------ |
| `horde_alloy_tenant_id`           | `infrastructure` | Mimir/Loki tenant ID                                         |
| `horde_alloy_basic_auth_username` | `alloy`          | Basic auth username for all endpoints                        |
| `horde_alloy_basic_auth_password` | `changeme-alloy` | Basic auth password (**must override**)                      |
| `horde_alloy_tls_ca_cert`         | `""`             | Path to CA cert on the Ansible controller (empty = skip TLS) |

### Metrics Pipeline

| Variable                     | Default | Description                                          |
| ---------------------------- | ------- | ---------------------------------------------------- |
| `horde_alloy_mimir_endpoint`       | `""`    | Mimir remote_write URL (required if metrics enabled) |
| `horde_alloy_collect_metrics`      | `true`  | Enable host metrics collection                       |
| `horde_alloy_scrape_interval`      | `15s`   | Metrics scrape interval                              |
| `horde_alloy_external_labels`      | `{}`    | Extra labels added to all metrics                    |
| `horde_alloy_extra_scrape_targets` | `[]`    | Additional scrape targets (list of `{job, targets}`) |

### Logs Pipeline

| Variable                    | Default | Description                                 |
| --------------------------- | ------- | ------------------------------------------- |
| `horde_alloy_loki_endpoint`       | `""`    | Loki push URL (required if logs enabled)    |
| `horde_alloy_collect_logs`        | `true`  | Enable log collection                       |
| `horde_alloy_collect_journal`     | `true`  | Collect systemd journal                     |
| `horde_alloy_journal_max_age`     | `24h`   | Max journal entry age on first start        |
| `horde_alloy_collect_log_files`   | `[]`    | Glob patterns for file-based log collection |
| `horde_alloy_collect_docker_logs` | `false` | Collect Docker container logs               |
| `horde_alloy_log_labels`          | `{}`    | Extra labels on all log streams             |

### Traces Pipeline

| Variable                     | Default     | Description                                      |
| ---------------------------- | ----------- | ------------------------------------------------ |
| `horde_alloy_tempo_endpoint`       | `""`        | Tempo OTLP endpoint (required if traces enabled) |
| `horde_alloy_collect_traces`       | `true`      | Enable OTLP trace receiver                       |
| `horde_alloy_otlp_listen_address`  | `127.0.0.1` | OTLP receiver bind address                       |
| `horde_alloy_otlp_grpc_port`       | `4317`      | OTLP gRPC port                                   |
| `horde_alloy_otlp_http_port`       | `4318`      | OTLP HTTP port                                   |
| `horde_alloy_trace_batch_timeout`  | `5s`        | Batch flush interval                             |
| `horde_alloy_trace_batch_size`     | `8192`      | Max batch size (spans)                           |
| `horde_alloy_forward_otlp_metrics` | `true`      | Forward OTLP metrics to Mimir                    |

## Validation

The role asserts at the start of execution that:

- Endpoint URLs are configured for each enabled pipeline
- `horde_alloy_basic_auth_password` is not the insecure default

## Instrumenting Applications

Applications on Alloy hosts can send traces via OTLP to the local receiver:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
export OTEL_SERVICE_NAME="my-service"
```

See [docs/OBSERVABILITY.md](../../docs/OBSERVABILITY.md) for Python and
Node.js instrumentation examples and trace-log correlation setup.

## Verification

```bash
# Service status
systemctl status alloy

# Logs
journalctl -u alloy -f

# Health check
curl -s http://127.0.0.1:12345/-/healthy

# Alloy UI (if accessible)
# http://127.0.0.1:12345
```

## Related Documentation

- [Observability Stack](../../docs/OBSERVABILITY.md) — Loki, Tempo, Alloy architecture and OTLP instrumentation
- [horde_monitoring role](../horde_monitoring/README.md) — Central Mimir + Grafana stack
- [Alloy example playbook](../../examples/alloy_app_host.yml)

## License

AGPL-3.0
