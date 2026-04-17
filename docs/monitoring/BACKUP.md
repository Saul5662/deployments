# Backup & Restore

## Overview

The monitoring stack uses S3-compatible storage in **single-node single-drive mode** — there
is no erasure coding and no redundancy. A drive failure or filesystem
corruption causes permanent data loss without a working backup.

The `horde_monitoring` role includes an offsite backup mechanism via systemd
timer and `mc mirror`.

- In `embedded` S3 mode, backup is enabled by default and enforced when services start.
- In `external` S3 mode, backup unit management is opt-in.

## RPO / RTO Characteristics

| Scenario                   | RPO (data loss)      | RTO (recovery time)                        | Notes                                      |
| -------------------------- | -------------------- | ------------------------------------------ | ------------------------------------------ |
| Disk failure, daily backup | ≤ 24h of metrics     | Hours (depends on data volume + bandwidth) | Restore via `mc mirror` from remote        |
| Disk failure, no backup    | **Total loss**       | N/A — data is gone                         | Only Prometheus's local WAL (~2h) survives |
| Mimir WAL corruption       | ~2h of inflight data | Minutes (restart Mimir)                    | Blocks already flushed to S3 storage are safe |
| Host failure               | Same as disk failure | Same + host provisioning time              | Full stack redeploy + data restore         |

## Backup Configuration

### Required variables

```yaml
horde_monitoring_mimir_backup_enabled: true # default
horde_monitoring_mimir_backup_target_endpoint: "https://s3.example.com"
horde_monitoring_mimir_backup_target_bucket: "mimir-backup"
horde_monitoring_mimir_backup_target_access_key: "{{ vault_backup_access_key }}"
horde_monitoring_mimir_backup_target_secret_key: "{{ vault_backup_secret_key }}"
```

When using `horde_monitoring_s3_deployment_mode: external`, also set:

```yaml
horde_monitoring_mimir_backup_external_mode_enabled: true
```

### Optional variables

```yaml
horde_monitoring_mimir_backup_schedule: "*-*-* 02:00:00" # systemd calendar spec (default: daily 02:00 UTC)
horde_monitoring_mimir_backup_target_insecure: false # allow non-TLS endpoint
horde_monitoring_mimir_backup_remove_deleted: false # see "Divergence Strategies" below
```

### Disabling backup

Set `horde_monitoring_mimir_backup_enabled: false`. A warning task will fire during playbook
runs in embedded mode reminding you that local S3 storage has no redundancy.

If you leave `horde_monitoring_mimir_backup_enabled: true` (the default) but don't configure
a target endpoint, the deploy will **fail** with an actionable error message when
backup management is active for the current mode.

## What Gets Backed Up

| Bucket                        | Contents                                         | Backed up? |
| ----------------------------- | ------------------------------------------------ | ---------- |
| `mimir-blocks`                | Compacted TSDB blocks (long-term metric storage) | ✔          |
| `mimir-ruler`                 | Recording and alerting rules stored in Mimir     | ✔          |
| `mimir-ruler/grafana-backup/` | Grafana SQLite database (`grafana.db`)           | ✔ (opt-in) |

The backup service mirrors both buckets to the remote target as
`<target-bucket>-blocks` and `<target-bucket>-ruler` respectively.

### Grafana DB Backup

Grafana stores user preferences, annotations, API keys, and any manual
dashboard edits in `/var/lib/grafana/grafana.db`. Provisioned resources
(orgs, datasources, dashboard JSON from the repo) are re-created by the
Ansible playbook and don't need backup — but anything created manually
through the Grafana UI is not reproducible without the database.

To include `grafana.db` in the backup scope:

```yaml
horde_monitoring_mimir_backup_grafana_db: true
```

When enabled, the backup service copies `grafana.db` into the
`mimir-ruler` S3 bucket (under `grafana-backup/`) before running
`mc mirror`. This means it is automatically included in the offsite
mirror with no additional infrastructure.

> **Note:** The copy is not crash-consistent if Grafana is writing at
> the exact moment of the copy, but SQLite uses WAL mode and the copy
> will be usable. For critical deployments, consider stopping Grafana
> briefly during the backup window or using `sqlite3 .backup`.

## Backup Consistency

Mimir writes blocks to S3 storage atomically: data files are written first, and
the `meta.json` (which makes a block discoverable) is written last. Because
`mc mirror` copies complete objects, and a block without its `meta.json` is
ignored by Mimir, there is **no risk of copying a half-written block**.

A mirror that runs concurrently with ingestion will either include a complete
block or skip it entirely (to be picked up on the next run). **No downtime is
required for backup.**

## Monitoring Backup Health

The backup service is `Type=oneshot` — it runs, succeeds or fails, and
exits. There is no long-running process to monitor. On success, the
service writes a timestamp file at `/var/lib/mimir-backup/.backup-last-success`.

### Quick health check

```bash
# Last successful backup time
stat -c '%y' /var/lib/mimir-backup/.backup-last-success

# Service status (shows last run result)
systemctl status mimir-backup

# Recent logs
journalctl -u mimir-backup --since "24 hours ago" --no-pager
```

### Automated monitoring options

1. **systemd timer status:** The simplest check — if the timer is active
   and the service isn't in a `failed` state, backups are working:

   ```bash
   systemctl is-active mimir-backup.timer && ! systemctl is-failed mimir-backup
   ```

2. **Timestamp staleness:** Alert if `.backup-last-success` is older than
   your backup interval plus a margin. Example cron/monitoring check:

   ```bash
   find /var/lib/mimir-backup/.backup-last-success -mmin +1500 -exec echo "STALE" \;
   ```

   (1500 minutes ≈ 25 hours, appropriate for a daily schedule)

3. **Host metrics systemd collector:** If host metrics collection is configured
   with a systemd collector (Alloy `prometheus.exporter.unix` or legacy
   node_exporter with `--collector.systemd`), it exposes
   `node_systemd_unit_state{name="mimir-backup.service",state="failed"}`.
   An alert on this metric provides Prometheus-native backup monitoring.

## Divergence Strategies

The role defaults to **append-only** mode (`--overwrite` without `--remove`).
This has important implications:

| Strategy                  | Variable                                                              | Remote growth                                                      | Propagates deletions?                     |
| ------------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------- |
| **Append-only** (default) | `horde_monitoring_mimir_backup_remove_deleted: false`                                  | Unbounded — remote retains blocks deleted locally by the compactor | No — safest option                        |
| **Parity**                | `horde_monitoring_mimir_backup_remove_deleted: true`                                   | Matches local — compactor deletions propagate                      | Yes — accidental deletions also propagate |
| **Versioned** (ideal)     | `horde_monitoring_mimir_backup_remove_deleted: false` + S3 versioning on remote target | Bounded by version policy                                          | Soft — versions retained                  |

**Recommendation:** Use append-only (the default) unless your remote target
has S3 object versioning enabled. With append-only + bounded local retention
(e.g. `365d`), the remote effectively serves as extended "cold" backup with
the full history beyond the live query window.

If your remote target supports S3 object versioning with a lifecycle policy,
that's the ideal setup: deletions are soft, space is bounded by the version
expiry policy, and accidental deletions can be recovered.

## Restore Procedure

### Prerequisites

- A working monitoring stack deployment on the new/repaired host (same Ansible
  config as the original)
- S3 backend configured and reachable
- Network access to the remote backup target

### Steps

1. **Deploy the monitoring stack** on the new host with the same inventory:

   ```bash
   ansible-playbook -i inventory.yml horde_monitoring_stack.yml
   ```

2. **Wait for S3 storage to be healthy/reachable:**

   - Embedded Garage default:

   ```bash
   curl -f http://127.0.0.1:3903/health
   ```

   - External mode: use your provider-specific health check, or verify connectivity with `mc alias set` against your external endpoint.

3. **Restore blocks and ruler data from backup:**

   ```bash
   docker run --rm --network host minio/mc:RELEASE.2025-08-13T08-35-41Z /bin/sh -c "\
       mc alias set local <s3-endpoint> <s3-access-key> <s3-secret-key>; \
     mc alias set remote <backup-endpoint> <access-key> <secret-key>; \
     mc mirror remote/<bucket>-blocks local/mimir-blocks; \
     mc mirror remote/<bucket>-ruler local/mimir-ruler; \
   "
   ```

    Replace `<s3-endpoint>`, `<s3-access-key>`, `<s3-secret-key>`, `<backup-endpoint>`,
   `<access-key>`, `<secret-key>`, and `<bucket>` with your actual values.
    In embedded mode, `<s3-endpoint>` is typically `http://127.0.0.1:3900`.

4. **Restart Mimir** to pick up restored blocks:

   ```bash
   systemctl restart mimir-monitoring
   ```

5. **Restore Grafana DB** (if `horde_monitoring_mimir_backup_grafana_db` was enabled):

   ```bash
   # Stop Grafana (part of the compose stack)
   docker compose -f /opt/mimir/docker-compose.yml stop grafana

    # Extract grafana.db from the restored ruler bucket to host /tmp
    docker run --rm --network host -v /tmp:/host-tmp minio/mc:RELEASE.2025-08-13T08-35-41Z /bin/sh -c "\
       mc alias set local <s3-endpoint> <s3-access-key> <s3-secret-key>; \
       mc cp local/mimir-ruler/grafana-backup/grafana.db /host-tmp/grafana.db; \
   "
    cp /tmp/grafana.db /var/lib/grafana/grafana.db
   chown 472:472 /var/lib/grafana/grafana.db

   # Start Grafana back up
   docker compose -f /opt/mimir/docker-compose.yml start grafana
   ```

   If `horde_monitoring_mimir_backup_grafana_db` was not enabled, skip this step — Grafana
   will start with a fresh database and reprovisioned resources.

6. **Verify** via Grafana that historical data is queryable. Check the
   earliest available data point matches your expectation based on backup age.

### Post-restore notes

- If using append-only backup (the default), the restored data may contain
  blocks older than the configured retention period. The Mimir compactor will
  garbage-collect these on its next run — this is expected.
- The compactor deletion delay (`12h` by default) means the extra blocks
  won't be removed immediately. This gives you time to query the extended
  history if needed.
