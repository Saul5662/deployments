# Observability Stack — Logs, Traces, and Alloy

This document covers the Loki (logs), Tempo (traces), and Alloy (telemetry
collector) components added to the monitoring stack. For the core
Mimir + Grafana + Prometheus setup, see [MONITORING.md](../MONITORING.md).

## Architecture Overview

```
┌─────────────────── App Host (N hosts) ──────────────────┐
│                                                         │
│  ┌─── Your App ───┐       ┌──── Grafana Alloy ───────┐ │
│  │  OTLP traces   │──────>│ otelcol.receiver.otlp    │ │
│  │  /metrics       │       │ prometheus.exporter.unix  │ │
│  └────────────────┘       │ loki.source.journal       │ │
│                            └───────┬──────────────────┘ │
└────────────────────────────────────┼────────────────────┘
                                     │ TLS + basic_auth
                    ┌────────────────┼────────────────────┐
                    ▼                ▼                     ▼
┌──────────── Monitoring Host ──────────────────────────────────┐
│ HAProxy (TLS termination / basic_auth)                        │
│ ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────────┐ │
│ │  Mimir   │  │   Loki   │  │  Tempo   │  │    Grafana    │ │
│ │ (metrics)│  │  (logs)  │  │ (traces) │  │  (dashboards) │ │
│ └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────┬───────┘ │
│      └──────┬──────┴─────┬───────┘                │         │
│             ▼            ▼                         │         │
│         ┌──────────┐ ┌──────────┐                  │         │
│         │  MinIO   │ │Memcached │                  │         │
│         │  (S3)    │ │ (cache)  │                  │         │
│         └──────────┘ └──────────┘                  │         │
│                                                    │         │
│  Prometheus (native) ──remote_write──> Mimir ◄─────┘         │
└──────────────────────────────────────────────────────────────┘
```

**Data flows:**

- **Metrics**: Alloy's `prometheus.exporter.unix` → `remote_write` → Mimir
- **Logs**: Alloy's journal/file/docker sources → Loki push API
- **Traces**: App → OTLP → Alloy → Tempo OTLP HTTP
- **Trace→metrics**: Tempo's `metrics_generator` → `remote_write` → Mimir
  (service graphs + span metrics)

## Enabling Loki and Tempo

Both components are **opt-in** and do not deploy unless enabled:

```yaml
# In your playbook vars:
monitoring_install_loki: true
monitoring_install_tempo: true
```

This adds Loki and Tempo containers to the existing Docker Compose stack.
MinIO buckets are created automatically by the init container.

### Loki Configuration

| Variable                         | Default              | Description                       |
| -------------------------------- | -------------------- | --------------------------------- |
| `monitoring_install_loki`        | `false`              | Enable Loki deployment            |
| `loki_image`                     | `grafana/loki:3.4.2` | Loki Docker image                 |
| `loki_port`                      | `3100`               | HTTP listen port                  |
| `loki_retention_period`          | `2160h`              | How long to keep log data (90d)   |
| `loki_retention_enabled`         | `true`               | Enable compactor retention        |
| `loki_ingestion_rate_mb`         | `10`                 | Per-tenant ingestion rate (MB/s)  |
| `loki_ingestion_burst_size_mb`   | `20`                 | Per-tenant burst size (MB)        |
| `loki_allow_structured_metadata` | `true`               | Enable for OTLP trace correlation |
| `loki_chunks_bucket`             | `loki-chunks`        | MinIO bucket name                 |

### Tempo Configuration

| Variable                            | Default               | Description                        |
| ----------------------------------- | --------------------- | ---------------------------------- |
| `monitoring_install_tempo`          | `false`               | Enable Tempo deployment            |
| `tempo_image`                       | `grafana/tempo:2.7.1` | Tempo Docker image                 |
| `tempo_http_port`                   | `3200`                | HTTP API port                      |
| `tempo_otlp_grpc_port`              | `4317`                | OTLP gRPC receiver port            |
| `tempo_otlp_http_port`              | `4318`                | OTLP HTTP receiver port            |
| `tempo_trace_retention`             | `168h`                | Trace block retention (7d)         |
| `tempo_metrics_generator_enabled`   | `true`                | Generate metrics from traces       |
| `tempo_metrics_generator_tenant_id` | `infrastructure`      | Mimir tenant for generated metrics |
| `tempo_traces_bucket`               | `tempo-traces`        | MinIO bucket name                  |

### Grafana Integration

When Loki and/or Tempo are enabled, the role automatically provisions:

- **Loki datasources** per tenant (app, infrastructure, public) with
  `X-Scope-OrgID` headers
- **Tempo datasource** with trace-to-logs correlation (links to Loki),
  trace-to-metrics (links to Mimir), service map, and node graph
- **Log-to-trace** derived fields: clicking a `traceID` in Loki logs
  opens the corresponding trace in Tempo

### Alerting

Self-monitoring alerts are added automatically:

- `LokiDown` / `LokiRequestErrors` / `LokiIngestionStalled`
- `TempoDown` / `TempoRequestErrors` / `TempoIngestionStalled`

### Backup

The MinIO backup service automatically mirrors Loki and Tempo buckets
to the offsite target when those components are enabled.

## Deploying Alloy on Application Hosts

Grafana Alloy replaces `node_exporter` on hosts where it is deployed,
providing metrics collection, log shipping, and trace forwarding in a
single agent.

### Quick Start

```yaml
# In your inventory group_vars:
alloy_mimir_endpoint: "https://mimir.example.com/api/v1/push"
alloy_loki_endpoint: "https://loki.example.com/loki/api/v1/push"
alloy_tempo_endpoint: "https://tempo.example.com:4318"
alloy_tenant_id: "infrastructure"
alloy_basic_auth_username: "alloy"
alloy_basic_auth_password: "{{ vault_alloy_basic_auth_password }}"
alloy_tls_ca_cert: "tls/ca.crt"
```

```yaml
# In your playbook:
- hosts: app_workers
  become: true
  roles:
    - haidra.deployments.horde_alloy
```

See [examples/alloy_app_host.yml](../examples/alloy_app_host.yml) for a
complete example playbook.

### What Alloy Collects

| Pipeline | Source                                    | Destination | Toggle                       |
| -------- | ----------------------------------------- | ----------- | ---------------------------- |
| Metrics  | `prometheus.exporter.unix` (host metrics) | Mimir       | `alloy_collect_metrics`      |
| Metrics  | Extra scrape targets                      | Mimir       | `alloy_extra_scrape_targets` |
| Logs     | systemd journal                           | Loki        | `alloy_collect_journal`      |
| Logs     | Log file globs                            | Loki        | `alloy_collect_log_files`    |
| Logs     | Docker container logs                     | Loki        | `alloy_collect_docker_logs`  |
| Traces   | OTLP gRPC/HTTP receiver                   | Tempo       | `alloy_collect_traces`       |

### Alloy Variables Reference

| Variable                    | Default          | Description                           |
| --------------------------- | ---------------- | ------------------------------------- |
| `alloy_version`             | `1.8.1`          | Pinned Alloy version                  |
| `alloy_config_dir`          | `/etc/alloy`     | Configuration directory               |
| `alloy_data_dir`            | `/var/lib/alloy` | Persistent data directory             |
| `alloy_http_listen_address` | `127.0.0.1`      | Health/UI endpoint bind               |
| `alloy_http_port`           | `12345`          | Health/UI endpoint port               |
| `alloy_scrape_interval`     | `15s`            | Metrics scrape interval               |
| `alloy_external_labels`     | `{}`             | Extra labels on all metrics           |
| `alloy_collect_journal`     | `true`           | Collect systemd journal logs          |
| `alloy_journal_max_age`     | `24h`            | Max journal entry age on first start  |
| `alloy_collect_log_files`   | `[]`             | Glob patterns for file log collection |
| `alloy_collect_docker_logs` | `false`          | Collect Docker container logs         |
| `alloy_log_labels`          | `{}`             | Extra labels on all log streams       |
| `alloy_otlp_listen_address` | `127.0.0.1`      | OTLP receiver bind address            |
| `alloy_otlp_grpc_port`      | `4317`           | OTLP gRPC port                        |
| `alloy_otlp_http_port`      | `4318`           | OTLP HTTP port                        |
| `alloy_trace_batch_timeout` | `5s`             | Batch processor flush interval        |
| `alloy_trace_batch_size`    | `8192`           | Max batch size (spans)                |

## Instrumenting Applications with OTLP

Applications running on Alloy hosts can send traces (and optionally metrics
and logs) via OTLP to the local Alloy receiver.

### Environment Variables

The standard OpenTelemetry SDK environment variables configure any
OTEL-instrumented application:

```bash
# Point the SDK at the local Alloy OTLP receiver
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"

# Required resource attributes
export OTEL_SERVICE_NAME="my-service"
export OTEL_RESOURCE_ATTRIBUTES="service.namespace=ai-horde,deployment.environment=production"
```

### Python (opentelemetry-sdk)

```bash
pip install opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp-proto-http
```

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource

resource = Resource.create({"service.name": "my-service"})
provider = TracerProvider(resource=resource)
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint="http://127.0.0.1:4318/v1/traces"))
)
trace.set_tracer_provider(provider)

tracer = trace.get_tracer(__name__)
with tracer.start_as_current_span("my-operation"):
    pass  # your code here
```

### Node.js (@opentelemetry/sdk-node)

```bash
npm install @opentelemetry/sdk-node @opentelemetry/exporter-trace-otlp-http
```

```javascript
const { NodeSDK } = require("@opentelemetry/sdk-node");
const {
  OTLPTraceExporter,
} = require("@opentelemetry/exporter-trace-otlp-http");

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: "http://127.0.0.1:4318/v1/traces",
  }),
  serviceName: "my-service",
});

sdk.start();
```

### Correlating Logs and Traces

To link logs to traces in Grafana, include the trace ID in your log output.
Most OTEL SDKs inject `trace_id` and `span_id` into the logging context
automatically when using the appropriate log bridge.

For manual correlation, extract the trace context and include it:

```python
import logging
from opentelemetry import trace

span = trace.get_current_span()
ctx = span.get_span_context()
logging.info("Processing request", extra={
    "trace_id": format(ctx.trace_id, '032x'),
    "span_id": format(ctx.span_id, '016x'),
})
```

Loki's derived field `traceID` (configured automatically by the role)
will turn these into clickable links to Tempo in Grafana.

## Retention Summary

| Signal            | Component  | Default Retention      | Variable                       |
| ----------------- | ---------- | ---------------------- | ------------------------------ |
| Metrics           | Mimir      | Per-tenant (0/30d/90d) | `monitoring_*_retention`       |
| Logs              | Loki       | 90 days                | `loki_retention_period`        |
| Traces            | Tempo      | 7 days                 | `tempo_trace_retention`        |
| Metrics (on-host) | Prometheus | 48 hours               | `prometheus_storage_retention` |

## Health Checks

```bash
# Loki
curl -s http://127.0.0.1:3100/ready

# Tempo
curl -s http://127.0.0.1:3200/ready

# Alloy (on app host)
curl -s http://127.0.0.1:12345/-/healthy
```

## Troubleshooting

### Alloy can't reach Loki/Tempo/Mimir

1. Verify the endpoint URLs are correct and include the protocol scheme.
2. Check that HAProxy is configured with backends for Loki and Tempo
   (`monitoring_configure_haproxy: true`).
3. Verify the CA certificate was deployed: `ls /etc/alloy/ca.crt`
4. Test connectivity from the app host:
   ```bash
   curl -v --cacert /etc/alloy/ca.crt -u alloy:password https://loki.example.com/ready
   ```

### No logs appearing in Grafana

1. Check Alloy status: `systemctl status alloy`
2. Check Alloy logs: `journalctl -u alloy -f`
3. Verify Loki is accepting pushes:
   ```bash
   curl -s http://127.0.0.1:3100/ready
   ```
4. Check Loki ingestion metrics in Grafana (Mimir datasource):
   `loki_distributor_bytes_received_total`

### No traces appearing

1. Verify the app is sending to the correct OTLP endpoint.
2. Check Alloy logs for exporter errors: `journalctl -u alloy -f | grep otelcol`
3. Verify Tempo is ready: `curl -s http://127.0.0.1:3200/ready`
4. Check `tempo_distributor_spans_received_total` in Grafana.
