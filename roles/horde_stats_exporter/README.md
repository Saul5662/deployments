# horde_stats_exporter

Deploys the [AI Horde Prometheus exporter](https://github.com/Haidra-Org/horde-exporters)
as a systemd service. The exporter polls the AI Horde public API and exposes
metrics at a `/metrics` endpoint for Prometheus to scrape.

## What This Role Deploys

- **horde-exporter** systemd service — polls the AI Horde API and serves
  Prometheus metrics on the configured port
- **horde-downsample** systemd timer (opt-in) — runs daily downsampling from
  the application Mimir tenant into a public tenant at reduced resolution
- **logrotate** config — rotates exporter log files

The exporter runs under a dedicated unprivileged system user and uses
[uv](https://docs.astral.sh/uv/) to manage its own Python 3.12 environment.

## Requirements

- Python 3.x on the target host (for Ansible modules)
- systemd-based Linux distribution
- Network access to `https://aihorde.net` (or the configured API base URL)
- [uv](https://docs.astral.sh/uv/) is installed automatically by the role

## Quick Start

```yaml
- hosts: monitoring
  become: true
  roles:
    - role: haidra.deployments.horde_stats_exporter
      vars:
        exporter_port: 9150
```

Then configure Prometheus to scrape it:

```yaml
prometheus_scrape_configs:
  - job_name: horde-exporter
    static_configs:
      - targets: ["localhost:9150"]
```

See [examples/horde_stats_exporter.yml](../../examples/horde_stats_exporter.yml) for a
standalone example, or [examples/horde_monitoring_stack.yml](../../examples/horde_monitoring_stack.yml)
for the full integrated stack.

## Role Variables

### Exporter Settings

| Variable               | Default                                         | Description                          |
| ---------------------- | ----------------------------------------------- | ------------------------------------ |
| `exporter_user`        | `horde-exporter`                                | Unprivileged system user             |
| `exporter_install_dir` | `/opt/horde-exporter`                           | Installation directory               |
| `exporter_repo_url`    | `https://github.com/Haidra-Org/horde-exporters` | Git repository                       |
| `exporter_repo_ref`    | `main`                                          | Git ref (branch, tag, or commit SHA) |
| `exporter_port`        | `9150`                                          | Metrics endpoint port                |
| `exporter_log_level`   | `INFO`                                          | Log verbosity                        |
| `exporter_log_file`    | `/var/log/horde-stats/exporter.log`             | Log file path                        |

For reproducible deployments, pin `exporter_repo_ref` to a release tag or
commit SHA.

### API Configuration

| Variable                | Default                      | Description                   |
| ----------------------- | ---------------------------- | ----------------------------- |
| `exporter_api_base_url` | `https://aihorde.net/api/v2` | AI Horde API base URL         |
| `exporter_api_timeout`  | `10`                         | API request timeout (seconds) |
| `exporter_user_agent`   | `horde_prometheus_exporter`  | HTTP User-Agent header        |

### Scrape Intervals

Each metric group is polled on its own interval (seconds):

| Variable                      | Default | What It Collects                      |
| ----------------------------- | ------- | ------------------------------------- |
| `exporter_scrape_models`      | `8`     | Model queue depths and worker counts  |
| `exporter_scrape_workers`     | `300`   | Individual worker stats               |
| `exporter_scrape_performance` | `2`     | Global queue and performance counters |
| `exporter_scrape_stats`       | `120`   | Historical generation statistics      |
| `exporter_scrape_modes`       | `30`    | Heartbeat and maintenance mode flags  |
| `exporter_scrape_teams`       | `300`   | Team-level statistics                 |

### Downsampling (Opt-in)

The downsampling timer reads high-resolution data from the application Mimir
tenant and writes a lower-resolution copy to the public tenant, suitable for
public-facing dashboards.

| Variable                            | Default                 | Description                     |
| ----------------------------------- | ----------------------- | ------------------------------- |
| `exporter_enable_downsampling`      | `true`                  | Enable daily downsampling timer |
| `exporter_downsample_schedule`      | `daily`                 | systemd calendar spec           |
| `exporter_prometheus_url`           | `http://localhost:9090` | Prometheus read endpoint        |
| `exporter_downsample_source_tenant` | `ai-horde-app`          | Source Mimir tenant             |
| `exporter_downsample_target_tenant` | `ai-horde-public`       | Target Mimir tenant             |
| `exporter_downsample_mimir_url`     | `http://localhost:9009` | Mimir write endpoint            |
| `exporter_downsample_resolution`    | `5m`                    | Output resolution               |

## Metrics Exposed

### Models

- `horde_models_queued_total{type}` — Total requests queued
- `horde_model_queued{model, type}` — Per-model queue depth
- `horde_model_workers_count{model, type}` — Workers supporting each model

### Workers

- `horde_workers_active_total{type}` — Total active workers
- `horde_worker_requests_fulfilled_total{worker, type}` — Completed requests
- `horde_worker_kudos_rewards{worker, type}` — Kudos earned

### Performance

- `horde_performance_queued_requests{type}` — Global queue depth
- `horde_performance_worker_count{type}` — Workers by type (image/text/interrogator)

All metrics use consistent `type=image|text|interrogator` labels.

## Verification

```bash
# Service status
sudo systemctl status horde-exporter

# Logs
sudo journalctl -u horde-exporter -f

# Test metrics endpoint
curl -s http://localhost:9150/metrics | head -20

# Downsampling timer (if enabled)
systemctl list-timers horde-downsample*
```

## Related Documentation

- [Monitoring Deployment Guide](../../MONITORING.md) — Full stack architecture and quick start
- [horde_monitoring role](../horde_monitoring/README.md) — Mimir + Grafana stack
- [Full stack example](../../examples/horde_monitoring_stack.yml) — Complete playbook

## License

AGPL-3.0
