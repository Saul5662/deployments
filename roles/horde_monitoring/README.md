# horde_monitoring

Deploys a complete metrics storage and visualization stack for AI Horde via
Docker Compose, managed by a single systemd service.

## What This Role Deploys

| Component          | Purpose                                                                   | Toggle                              |
| ------------------ | ------------------------------------------------------------------------- | ----------------------------------- |
| **Grafana Mimir**  | Long-term metric storage (multi-tenant, S3-backed via MinIO)              | `horde_monitoring_install_mimir`          |
| **MinIO**          | S3-compatible object storage for Mimir blocks and ruler data              | `horde_monitoring_mimir_enable_minio`                |
| **Memcached**      | Query and metadata caching for Mimir                                      | `horde_monitoring_mimir_enable_memcached`            |
| **Grafana**        | Visualization and dashboarding (pre-provisioned datasources + dashboards) | `horde_monitoring_install_grafana`        |
| **Loki**           | Log aggregation (opt-in)                                                  | `horde_monitoring_install_loki`           |
| **Tempo**          | Distributed tracing (opt-in)                                              | `horde_monitoring_install_tempo`          |
| **Pyroscope**      | Continuous profiling (opt-in)                                             | `horde_monitoring_install_pyroscope`      |
| **Offsite backup** | Daily `mc mirror` of MinIO data to a remote S3 target                     | `horde_monitoring_mimir_backup_enabled`              |
| **Alerting rules** | Prometheus recording/alerting rules for stack self-monitoring             | `horde_monitoring_install_alerting_rules` |

> **Prometheus is NOT part of this role.** Deploy it directly in your playbook
> using `prometheus.prometheus.prometheus` for full control over TLS, scrape
> targets, and `remote_write` configuration.

## Architecture

```
Prometheus (native) ──remote_write──► Mimir (Docker)
                                          │
                                      MinIO (S3)
                                          │
                                      Grafana (Docker) ──query──► Mimir
```

All containers run on a shared `monitoring` Docker network. Every service
binds to `127.0.0.1` by default — use HAProxy or another reverse proxy for
external access.

Mimir operates in monolithic mode. Prometheus splits `remote_write` into
separate Mimir tenants (e.g., `ai-horde-app` for exporter metrics,
`infrastructure` for host metrics) so each tenant can have independent
retention policies.

## Requirements

- Docker Engine with the Compose V2 plugin
- Ansible 2.14+
- Collections: `prometheus.prometheus`, `grafana.grafana` (see [examples/requirements.yml](../../examples/requirements.yml))

## Quick Start

```yaml
- hosts: monitoring
  become: true
  roles:
    - role: haidra.deployments.horde_monitoring
      vars:
        horde_monitoring_grafana_admin_password: "{{ vault_grafana_password }}"
        horde_monitoring_minio_root_password: "{{ vault_minio_password }}"
        horde_monitoring_configure_haproxy: true
```

See [examples/horde_monitoring_stack.yml](../../examples/horde_monitoring_stack.yml) for a
full two-play example that also deploys Prometheus, Alertmanager, and the
stats exporter.

## Role Variables

### Core Settings

| Variable                        | Default | Description                                                |
| ------------------------------- | ------- | ---------------------------------------------------------- |
| `horde_monitoring_install_mimir`      | `true`  | Deploy Mimir + MinIO + Memcached                           |
| `horde_monitoring_install_grafana`    | `true`  | Include Grafana in the Docker stack                        |
| `horde_monitoring_configure_haproxy`  | `false` | Insert monitoring backends into an existing HAProxy config |
| `horde_monitoring_configure_firewall` | `false` | Open ports with UFW                                        |
| `horde_monitoring_start_services`     | `true`  | Start Docker Compose services (`false` for CI/test)        |

### Mimir

| Variable                 | Default                | Description                                        |
| ------------------------ | ---------------------- | -------------------------------------------------- |
| `horde_monitoring_mimir_image`            | `grafana/mimir:2.15.0` | Mimir Docker image (pinned)                        |
| `horde_monitoring_mimir_port`             | `9009`                 | HTTP API port                                      |
| `horde_monitoring_mimir_config_dir`       | `/etc/mimir`           | Host path for rendered config                      |
| `horde_monitoring_mimir_data_dir`         | `/var/lib/mimir`       | WAL, TSDB, compactor work directory                |
| `horde_monitoring_mimir_compose_dir`      | `/opt/mimir`           | Docker Compose file location                       |
| `horde_monitoring_mimir_log_level`        | `warn`                 | Log verbosity                                      |
| `horde_monitoring_mimir_blocks_retention` | `""`                   | Global fallback retention (empty = use per-tenant) |
| `horde_monitoring_mimir_memory_limit`     | `3g`                   | Container memory limit                             |

### MinIO (S3 Backend)

| Variable              | Default                                    | Description                              |
| --------------------- | ------------------------------------------ | ---------------------------------------- |
| `horde_monitoring_mimir_enable_minio`  | `true`                                     | Deploy MinIO alongside Mimir             |
| `horde_monitoring_minio_image`         | `minio/minio:RELEASE.2025-09-07T16-13-09Z` | MinIO image (pinned)                     |
| `horde_monitoring_minio_root_user`     | `mimir`                                    | MinIO admin username                     |
| `horde_monitoring_minio_root_password` | `changeme-minio-secret`                    | MinIO admin password (**must override**) |
| `horde_monitoring_minio_data_dir`      | `/var/lib/minio-data`                      | Persistent data directory                |
| `horde_monitoring_minio_memory_limit`  | `512m`                                     | Container memory limit                   |

### Multi-Tenant Retention

| Variable                              | Default           | Description                          |
| ------------------------------------- | ----------------- | ------------------------------------ |
| `horde_monitoring_application_tenant_id`    | `ai-horde-app`    | Tenant for AI Horde exporter metrics |
| `horde_monitoring_application_retention`    | `0`               | Retention (`0` = infinite)           |
| `horde_monitoring_infrastructure_tenant_id` | `infrastructure`  | Tenant for host/infra metrics        |
| `horde_monitoring_infrastructure_retention` | `30d`             | Retention period                     |
| `horde_monitoring_public_tenant_id`         | `ai-horde-public` | Read-only public tenant              |
| `horde_monitoring_public_retention`         | `90d`             | Retention period                     |

### Grafana

| Variable                       | Default                  | Description                                         |
| ------------------------------ | ------------------------ | --------------------------------------------------- |
| `horde_monitoring_grafana_image`                | `grafana/grafana:12.4.1` | Grafana image (pinned)                              |
| `horde_monitoring_grafana_port`                 | `3000`                   | Web UI port                                         |
| `horde_monitoring_grafana_admin_password`       | `changeme`               | Admin password (**must override**)                  |
| `horde_monitoring_grafana_root_url`             | `""`                     | External URL (set when behind a reverse proxy)      |
| `horde_monitoring_grafana_anonymous_enabled`    | `true`                   | Enable anonymous access to public org               |
| `horde_monitoring_grafana_provision_dashboards` | `true`                   | Auto-provision dashboards from horde-exporters repo |
| `horde_monitoring_grafana_dashboards_repo_ref`  | `096c1fb8451b27e0a3dd0fc32092dda92e0e52e3` | Git ref for dashboard source                        |

### Offsite Backup

Backup is **enabled by default**. You must configure a remote S3 target or
explicitly set `horde_monitoring_mimir_backup_enabled: false`. See [docs/BACKUP.md](../../docs/BACKUP.md)
for RPO/RTO details and restore procedures.

| Variable                         | Default          | Description                         |
| -------------------------------- | ---------------- | ----------------------------------- |
| `horde_monitoring_mimir_backup_enabled`           | `true`           | Enable offsite backup               |
| `horde_monitoring_mimir_backup_schedule`          | `*-*-* 02:00:00` | systemd calendar spec               |
| `horde_monitoring_mimir_backup_target_endpoint`   | `""`             | Remote S3 endpoint                  |
| `horde_monitoring_mimir_backup_target_bucket`     | `""`             | Remote bucket name                  |
| `horde_monitoring_mimir_backup_target_access_key` | `""`             | Remote access key                   |
| `horde_monitoring_mimir_backup_target_secret_key` | `""`             | Remote secret key                   |
| `horde_monitoring_mimir_backup_grafana_db`        | `false`          | Include Grafana SQLite DB in backup |

### Loki (Opt-in)

| Variable                  | Default              | Description             |
| ------------------------- | -------------------- | ----------------------- |
| `horde_monitoring_install_loki` | `false`              | Enable Loki             |
| `horde_monitoring_loki_image`              | `grafana/loki:3.4.2` | Loki image (pinned)     |
| `horde_monitoring_loki_port`               | `3100`               | HTTP API port           |
| `horde_monitoring_loki_retention_period`   | `2160h`              | Log retention (90 days) |

### Tempo (Opt-in)

| Variable                          | Default               | Description                  |
| --------------------------------- | --------------------- | ---------------------------- |
| `horde_monitoring_install_tempo`        | `false`               | Enable Tempo                 |
| `horde_monitoring_tempo_image`                     | `grafana/tempo:2.7.1` | Tempo image (pinned)         |
| `horde_monitoring_tempo_http_port`                 | `3200`                | HTTP API port                |
| `horde_monitoring_tempo_trace_retention`           | `168h`                | Trace retention (7 days)     |
| `horde_monitoring_tempo_metrics_generator_enabled` | `true`                | Generate metrics from traces |

### Pyroscope (Opt-in)

| Variable                       | Default                    | Description              |
| ------------------------------ | -------------------------- | ------------------------ |
| `horde_monitoring_install_pyroscope` | `false`                    | Enable Pyroscope         |
| `horde_monitoring_pyroscope_image`              | `grafana/pyroscope:1.19.0` | Pyroscope image (pinned) |
| `horde_monitoring_pyroscope_port`               | `4040`                     | HTTP API port            |

### HAProxy Integration

When `horde_monitoring_configure_haproxy: true`, the role:

1. Creates a timestamped backup of the current HAProxy config
2. Inserts `grafana_backend` and `mimir_backend` into a working copy
3. Validates with `haproxy -c`
4. Promotes to live only if validation passes
5. Deploys `/usr/local/bin/haproxy_safe_edit.sh` for manual use

You still need frontend ACL rules in your HAProxy config to route to these
backends.

Backup retention for safe-edit snapshots is controlled by
`horde_monitoring_haproxy_backup_retention_count` (default: `20`).

## Credential Management

The role enforces non-default passwords when `horde_monitoring_start_services: true`.
Deploying with `changeme` or `changeme-minio-secret` will fail with an
actionable error. Use Ansible Vault:

```bash
ansible-vault create group_vars/mimir/vault.yml
# Add: vault_minio_root_password, vault_grafana_admin_password
```

See [docs/CREDENTIALS.md](../../docs/CREDENTIALS.md) for rotation procedures.

## Verification

```bash
# MinIO
curl -sf http://127.0.0.1:9000/minio/health/live && echo OK

# Mimir
curl -sf http://127.0.0.1:9009/ready && echo OK

# Grafana
curl -sf http://127.0.0.1:3000/api/health && echo OK

# Loki (if enabled)
curl -sf http://127.0.0.1:3100/ready && echo OK

# Tempo (if enabled)
curl -sf http://127.0.0.1:3200/ready && echo OK

# Monitoring stack systemd service
systemctl status mimir-monitoring
```

## Troubleshooting

```bash
# Container status
docker ps --format 'table {{.Names}}\t{{.Status}}'

# Container logs
docker logs mimir
docker logs grafana

# Mimir runtime config
curl http://127.0.0.1:9009/runtime_config

# Tenant-specific limits
curl http://127.0.0.1:9009/api/v1/user_limits -H 'X-Scope-OrgID: ai-horde-app'

# Systemd service logs
journalctl -u mimir-monitoring -f

# Configuration drift detection
ansible-playbook -i inventory.yml site.yml --check --diff
```

## Related Documentation

- [Monitoring Deployment Guide](../../MONITORING.md) — Architecture overview and quick start
- [Observability Stack](../../docs/OBSERVABILITY.md) — Loki, Tempo, and Alloy deep-dive
- [Backup & Restore](../../docs/BACKUP.md) — RPO/RTO, restore procedures
- [Credentials](../../docs/CREDENTIALS.md) — Credential management and rotation
- [Upgrading](../../docs/UPGRADING.md) — Component version upgrades
- [Migration](../../docs/MIGRATION.md) — Host migration runbook

## License

AGPL-3.0
