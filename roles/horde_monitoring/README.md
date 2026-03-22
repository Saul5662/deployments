# horde_monitoring

Deploys a complete metrics storage and visualization stack for AI Horde via
Docker Compose, managed by a single systemd service.

## What This Role Deploys

| Component          | Purpose                                                                   | Toggle                              |
| ------------------ | ------------------------------------------------------------------------- | ----------------------------------- |
| **Grafana Mimir**  | Long-term metric storage (multi-tenant, S3-backed via MinIO)              | `monitoring_install_mimir`          |
| **MinIO**          | S3-compatible object storage for Mimir blocks and ruler data              | `mimir_enable_minio`                |
| **Memcached**      | Query and metadata caching for Mimir                                      | `mimir_enable_memcached`            |
| **Grafana**        | Visualization and dashboarding (pre-provisioned datasources + dashboards) | `monitoring_install_grafana`        |
| **Loki**           | Log aggregation (opt-in)                                                  | `monitoring_install_loki`           |
| **Tempo**          | Distributed tracing (opt-in)                                              | `monitoring_install_tempo`          |
| **Pyroscope**      | Continuous profiling (opt-in)                                             | `monitoring_install_pyroscope`      |
| **Offsite backup** | Daily `mc mirror` of MinIO data to a remote S3 target                     | `mimir_backup_enabled`              |
| **Alerting rules** | Prometheus recording/alerting rules for stack self-monitoring             | `monitoring_install_alerting_rules` |

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
        grafana_admin_password: "{{ vault_grafana_password }}"
        minio_root_password: "{{ vault_minio_password }}"
        monitoring_configure_haproxy: true
```

See [examples/horde_monitoring_stack.yml](../../examples/horde_monitoring_stack.yml) for a
full two-play example that also deploys Prometheus, Alertmanager, and the
stats exporter.

## Role Variables

### Core Settings

| Variable                        | Default | Description                                                |
| ------------------------------- | ------- | ---------------------------------------------------------- |
| `monitoring_install_mimir`      | `true`  | Deploy Mimir + MinIO + Memcached                           |
| `monitoring_install_grafana`    | `true`  | Include Grafana in the Docker stack                        |
| `monitoring_configure_haproxy`  | `false` | Insert monitoring backends into an existing HAProxy config |
| `monitoring_configure_firewall` | `false` | Open ports with UFW                                        |
| `monitoring_start_services`     | `true`  | Start Docker Compose services (`false` for CI/test)        |

### Mimir

| Variable                 | Default                | Description                                        |
| ------------------------ | ---------------------- | -------------------------------------------------- |
| `mimir_image`            | `grafana/mimir:2.15.0` | Mimir Docker image (pinned)                        |
| `mimir_port`             | `9009`                 | HTTP API port                                      |
| `mimir_config_dir`       | `/etc/mimir`           | Host path for rendered config                      |
| `mimir_data_dir`         | `/var/lib/mimir`       | WAL, TSDB, compactor work directory                |
| `mimir_compose_dir`      | `/opt/mimir`           | Docker Compose file location                       |
| `mimir_log_level`        | `warn`                 | Log verbosity                                      |
| `mimir_blocks_retention` | `""`                   | Global fallback retention (empty = use per-tenant) |
| `mimir_memory_limit`     | `3g`                   | Container memory limit                             |

### MinIO (S3 Backend)

| Variable              | Default                                    | Description                              |
| --------------------- | ------------------------------------------ | ---------------------------------------- |
| `mimir_enable_minio`  | `true`                                     | Deploy MinIO alongside Mimir             |
| `minio_image`         | `minio/minio:RELEASE.2025-09-07T16-13-09Z` | MinIO image (pinned)                     |
| `minio_root_user`     | `mimir`                                    | MinIO admin username                     |
| `minio_root_password` | `changeme-minio-secret`                    | MinIO admin password (**must override**) |
| `minio_data_dir`      | `/var/lib/minio-data`                      | Persistent data directory                |
| `minio_memory_limit`  | `512m`                                     | Container memory limit                   |

### Multi-Tenant Retention

| Variable                              | Default           | Description                          |
| ------------------------------------- | ----------------- | ------------------------------------ |
| `monitoring_application_tenant_id`    | `ai-horde-app`    | Tenant for AI Horde exporter metrics |
| `monitoring_application_retention`    | `0`               | Retention (`0` = infinite)           |
| `monitoring_infrastructure_tenant_id` | `infrastructure`  | Tenant for host/infra metrics        |
| `monitoring_infrastructure_retention` | `30d`             | Retention period                     |
| `monitoring_public_tenant_id`         | `ai-horde-public` | Read-only public tenant              |
| `monitoring_public_retention`         | `90d`             | Retention period                     |

### Grafana

| Variable                       | Default                  | Description                                         |
| ------------------------------ | ------------------------ | --------------------------------------------------- |
| `grafana_image`                | `grafana/grafana:12.4.1` | Grafana image (pinned)                              |
| `grafana_port`                 | `3000`                   | Web UI port                                         |
| `grafana_admin_password`       | `changeme`               | Admin password (**must override**)                  |
| `grafana_root_url`             | `""`                     | External URL (set when behind a reverse proxy)      |
| `grafana_anonymous_enabled`    | `true`                   | Enable anonymous access to public org               |
| `grafana_provision_dashboards` | `true`                   | Auto-provision dashboards from horde-exporters repo |
| `grafana_dashboards_repo_ref`  | `main`                   | Git ref for dashboard source                        |

### Offsite Backup

Backup is **enabled by default**. You must configure a remote S3 target or
explicitly set `mimir_backup_enabled: false`. See [docs/BACKUP.md](../../docs/BACKUP.md)
for RPO/RTO details and restore procedures.

| Variable                         | Default          | Description                         |
| -------------------------------- | ---------------- | ----------------------------------- |
| `mimir_backup_enabled`           | `true`           | Enable offsite backup               |
| `mimir_backup_schedule`          | `*-*-* 02:00:00` | systemd calendar spec               |
| `mimir_backup_target_endpoint`   | `""`             | Remote S3 endpoint                  |
| `mimir_backup_target_bucket`     | `""`             | Remote bucket name                  |
| `mimir_backup_target_access_key` | `""`             | Remote access key                   |
| `mimir_backup_target_secret_key` | `""`             | Remote secret key                   |
| `mimir_backup_grafana_db`        | `false`          | Include Grafana SQLite DB in backup |

### Loki (Opt-in)

| Variable                  | Default              | Description             |
| ------------------------- | -------------------- | ----------------------- |
| `monitoring_install_loki` | `false`              | Enable Loki             |
| `loki_image`              | `grafana/loki:3.4.2` | Loki image (pinned)     |
| `loki_port`               | `3100`               | HTTP API port           |
| `loki_retention_period`   | `2160h`              | Log retention (90 days) |

### Tempo (Opt-in)

| Variable                          | Default               | Description                  |
| --------------------------------- | --------------------- | ---------------------------- |
| `monitoring_install_tempo`        | `false`               | Enable Tempo                 |
| `tempo_image`                     | `grafana/tempo:2.7.1` | Tempo image (pinned)         |
| `tempo_http_port`                 | `3200`                | HTTP API port                |
| `tempo_trace_retention`           | `168h`                | Trace retention (7 days)     |
| `tempo_metrics_generator_enabled` | `true`                | Generate metrics from traces |

### Pyroscope (Opt-in)

| Variable                       | Default                    | Description              |
| ------------------------------ | -------------------------- | ------------------------ |
| `monitoring_install_pyroscope` | `false`                    | Enable Pyroscope         |
| `pyroscope_image`              | `grafana/pyroscope:1.19.0` | Pyroscope image (pinned) |
| `pyroscope_port`               | `4040`                     | HTTP API port            |

### HAProxy Integration

When `monitoring_configure_haproxy: true`, the role:

1. Creates a timestamped backup of the current HAProxy config
2. Inserts `grafana_backend` and `mimir_backend` into a working copy
3. Validates with `haproxy -c`
4. Promotes to live only if validation passes
5. Deploys `/usr/local/bin/haproxy_safe_edit.sh` for manual use

You still need frontend ACL rules in your HAProxy config to route to these
backends.

## Credential Management

The role enforces non-default passwords when `monitoring_start_services: true`.
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
