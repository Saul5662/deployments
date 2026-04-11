# AI Horde Monitoring Deployment Guide

This guide covers the architecture, quick start, and operational reference for
the AI Horde monitoring infrastructure. Each Ansible role has its own README
with full variable documentation — this document focuses on how the pieces
fit together.

## Roles

| Role                                                | Purpose                                                                    | README                                         |
| --------------------------------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------- |
| [horde_monitoring](roles/horde_monitoring/)         | Mimir + Grafana + MinIO + optional Loki/Tempo/Pyroscope via Docker Compose | [README](roles/horde_monitoring/README.md)     |
| [horde_stats_exporter](roles/horde_stats_exporter/) | AI Horde API → Prometheus metrics exporter (systemd)                       | [README](roles/horde_stats_exporter/README.md) |
| [horde_alloy](roles/horde_alloy/)                   | Grafana Alloy telemetry collector on application hosts                     | [README](roles/horde_alloy/README.md)          |

Prometheus and Alertmanager are deployed directly using the
`prometheus.prometheus` community collection in your playbook — they are not
wrapped by these roles, giving you full control over TLS, scrape targets,
and `remote_write` configuration.

## Architecture

```
                              ┌──── Monitoring Host ──────────────────────────┐
AI Horde APIs                 │                                               │
     │                        │  Prometheus (native)                          │
     ▼                        │    ├─ scrapes horde-exporter, node, mimir … │
  horde-exporter (systemd)    │    └─ remote_write ──► Mimir (Docker)        │
     │ /metrics               │                           │                   │
     └────── scraped by ──────┘                       MinIO (S3)              │
                                                          │                   │
                              │                       Grafana (Docker)        │
                              │                           │ queries Mimir     │
                              └───────────────────────────┘
                                        ▲
┌──── App Hosts ──────────┐             │
│  Grafana Alloy           ├── logs/traces (and optional host metrics) ──┘
└──────────────────────────┘
```

- All services bind to `127.0.0.1` — use HAProxy for external access
- Mimir runs monolithic mode with multi-tenant retention
- Prometheus splits `remote_write` by job into separate tenants

## Quick Start

### 1. Install Dependencies

```bash
ansible-galaxy collection install -r examples/requirements.yml
```

### 2. Deploy the Full Stack

```bash
cp examples/inventory_monitoring.yml inventory.yml
# Edit inventory.yml — set hosts, passwords (use ansible-vault)

ansible-playbook -i inventory.yml examples/horde_monitoring_stack.yml -K
```

This runs a two-play playbook:

- **Play 1**: `node_exporter` on hosts that resolve to `node_exporter` source
- **Play 2**: Mimir + Grafana + Prometheus + Alertmanager + stats exporter
  on the monitoring host

### Host Metrics Source

- `horde_host_metrics_source: auto` (recommended)
  - If a host has `horde_alloy_enabled: true` or `horde_alloy_collect_metrics: true`,
    the playbook skips `node_exporter` on that host.
  - Otherwise, the playbook installs `node_exporter` on that host.
- `horde_host_metrics_source: node_exporter` forces install on all hosts.
- `horde_host_metrics_source: alloy` forces skip on all hosts.

This decision is made per host from inventory variables in Play 1 of
`examples/horde_monitoring_stack.yml`.

### 3. Deploy Stats Exporter Only

If you already have Prometheus and Grafana running elsewhere:

```bash
ansible-playbook -i inventory.yml examples/horde_stats_exporter.yml
```

### 4. Deploy Alloy on Application Hosts

To collect metrics, logs, and traces from application workers:

```bash
ansible-playbook -i inventory.yml examples/alloy_app_host.yml
```

### Minimal Inventory

```yaml
all:
  children:
    mimir:
      hosts:
        monitoring.example.com:
          ansible_host: 192.168.1.100
          grafana_admin_password: "{{ vault_grafana_admin_password }}"
          minio_root_password: "{{ vault_minio_root_password }}"
          monitoring_configure_haproxy: true
          exporter_port: 9150
```

## Data Retention

| Layer                          | Default        | Purpose                                 |
| ------------------------------ | -------------- | --------------------------------------- |
| Prometheus (local)             | `48h`          | Buffer for `remote_write` — short-lived |
| Mimir `ai-horde-app` tenant    | Infinite (`0`) | AI Horde application metrics            |
| Mimir `infrastructure` tenant  | `30d`          | Host and infrastructure metrics         |
| Mimir `ai-horde-public` tenant | `90d`          | Public-facing dashboard metrics         |
| Loki (opt-in)                  | `90d`          | Log retention                           |
| Tempo (opt-in)                 | `7d`           | Trace retention                         |

Prometheus splits data by job: `horde-exporter` → app tenant, everything else
→ infrastructure tenant. See the
[example playbook](examples/horde_monitoring_stack.yml) for the exact
`write_relabel_configs`.

## Security

- All services bind to `127.0.0.1` — not exposed without a reverse proxy
- Default passwords are blocked at deploy time (fail-fast assertions)
- Use [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/) for credentials
- HAProxy integration uses backup → validate → promote workflow
- Container images are pinned to immutable version tags

See [docs/monitoring/CREDENTIALS.md](docs/monitoring/CREDENTIALS.md) for credential rotation
procedures.

## Grafana Dashboards

Dashboards are auto-provisioned from the
[horde-exporters](https://github.com/Haidra-Org/horde-exporters) repository.
The role clones the repo, copies dashboard JSON into per-org directories, and
patches datasource UIDs to match the provisioned Mimir datasources.

To add custom dashboards, place JSON files in `grafana_dashboard_dir`
(default: `/etc/grafana/dashboards`) on the target host.

## Troubleshooting

### Quick Health Checks

```bash
curl -sf http://127.0.0.1:9009/ready   && echo "Mimir OK"
curl -sf http://127.0.0.1:3000/api/health && echo "Grafana OK"
curl -sf http://127.0.0.1:9000/minio/health/live && echo "MinIO OK"
curl -sf http://localhost:9150/metrics | head -5 && echo "Exporter OK"
systemctl status prometheus --no-pager
```

### Prometheus

```bash
journalctl -u prometheus -f
promtool check config /etc/prometheus/prometheus.yml
curl -s http://127.0.0.1:9090/api/v1/status/config | grep -A20 remote_write
```

### Mimir

```bash
docker logs mimir
curl http://127.0.0.1:9009/runtime_config
curl http://127.0.0.1:9009/api/v1/user_limits -H 'X-Scope-OrgID: ai-horde-app'
```

### Grafana

```bash
docker logs grafana
systemctl restart mimir-monitoring   # restarts entire Docker Compose stack
```

### Configuration Drift

```bash
ansible-playbook -i inventory.yml site.yml --check --diff
```

Any `changed` tasks indicate drift from the Ansible-managed state.

## Operational Guides

| Topic                                  | Document                                       |
| -------------------------------------- | ---------------------------------------------- |
| Logs, traces, and Alloy deep-dive      | [docs/monitoring/OBSERVABILITY.md](docs/monitoring/OBSERVABILITY.md) |
| Backup & restore (RPO/RTO, procedures) | [docs/monitoring/BACKUP.md](docs/monitoring/BACKUP.md)               |
| Credential management and rotation     | [docs/monitoring/CREDENTIALS.md](docs/monitoring/CREDENTIALS.md)     |
| Component version upgrades             | [docs/monitoring/UPGRADING.md](docs/monitoring/UPGRADING.md)         |
| Host migration (planned and forced)    | [docs/monitoring/MIGRATION.md](docs/monitoring/MIGRATION.md)         |

## Further Reading

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Mimir Documentation](https://grafana.com/docs/mimir/)
- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/)
- [AI Horde API](https://aihorde.net/api/)
