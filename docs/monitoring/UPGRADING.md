# Upgrading the Monitoring Stack

This document describes how to safely upgrade each component of the
monitoring stack deployed by the `horde_monitoring` Ansible role.

## General Procedure

1. **Check the upstream release notes** for the component you're upgrading
   (links below).
2. **Update the version** in `roles/horde_monitoring/defaults/main.yml`
   (or override in your playbook vars).
3. **Preview changes** with `ansible-playbook --diff --check` before applying.
4. **Deploy** with `ansible-playbook` — the role's handler will pull the new
   image and restart the stack.
5. **Verify** the service is healthy (see per-component checks below).

> **Tip:** Back up persistent state before any upgrade. Grafana's SQLite
> database in particular is migrated on first startup and is not easily
> rolled back. See [Plan 006](plans/006-backup-strategy.md) for the
> backup strategy.

> **Galaxy collections:** When bumping Ansible Galaxy collection versions,
> update both `galaxy.yml` (dependencies) and `examples/requirements.yml`
> together so version constraints stay in sync.

---

## Mimir

**Variable:** `mimir_image` (default: `grafana/mimir:2.15.0`)

**Upgrade guide:**
[Grafana Mimir upgrade guide](https://grafana.com/docs/mimir/latest/set-up/migrate/)

**Key considerations:**

- Read the upgrade guide for the target version — config keys are sometimes
  renamed or removed between minor versions.
- The monolithic deployment (`-target=all`) means all components upgrade
  atomically. There is no rolling upgrade concern.
- After upgrading, verify `/ready` returns HTTP 200:
  ```bash
  curl -s http://127.0.0.1:9009/ready
  ```
- Check `journalctl -u mimir-monitoring` for deprecation warnings.
- If the upgrade fails, revert `mimir_image` to the previous version and
  re-run the playbook. Mimir's WAL and TSDB are forward-compatible within
  the same major version.

---

## MinIO

**Variables:** `minio_image`, `minio_mc_image`

**Release notes:**
[MinIO releases](https://github.com/minio/minio/releases)

**Key considerations:**

- MinIO uses date-based release tags (e.g., `RELEASE.2025-09-07T16-13-09Z`).
- MinIO is generally backward-compatible, but major feature releases
  occasionally change on-disk format or default behaviors.
- Keep the `mc` (MinIO Client) image roughly contemporary with the server
  image — large version gaps can cause API incompatibilities.
- After upgrading, verify the health endpoint:
  ```bash
  curl -s http://127.0.0.1:9000/minio/health/live
  ```
- MinIO data at `/var/lib/minio-data` is persistent and survives upgrades.

---

## Grafana

**Variable:** `grafana_image` (default: `grafana/grafana:12.4.1`)

**Upgrade guide:**
[Grafana upgrade guide](https://grafana.com/docs/grafana/latest/upgrade-guide/)

**Key considerations:**

- **Back up `/var/lib/grafana/grafana.db` before upgrading.** Grafana's
  SQLite database is migrated on first startup with the new version. This
  migration is **not easily reversible**.
- Read the upgrade guide for the target version. Pay attention to:
  - Provisioning format changes
  - Authentication and org model changes
  - Dashboard schema changes (especially across major versions)
- After upgrading, verify Grafana loads at `http://127.0.0.1:3000` and
  check that dashboards render correctly.
- Grafana major version upgrades (e.g., v11→v12) carry higher risk than
  patch upgrades. Test in a non-production environment first.

---

## Memcached

**Variable:** `mimir_memcached_image` (default: `memcached:1.6.41-alpine`)

**Release notes:**
[Memcached releases](https://github.com/memcached/memcached/wiki/ReleaseNotes)

**Key considerations:**

- Memcached is stateless (cache only). Upgrading is effectively zero-risk —
  the cache is simply empty after restart and repopulated by Mimir queries.
- No special verification needed beyond confirming the container starts.

---

## Prometheus & Alertmanager

**Managed by:** `prometheus.prometheus.prometheus` and
`prometheus.prometheus.alertmanager` community roles.

**Variables:** Set by the community role (e.g., `prometheus_version`,
`alertmanager_version`). See the
[prometheus.prometheus collection docs](https://prometheus-community.github.io/ansible/branch/main/).

**Key considerations:**

- These are native binaries managed by the community role, not Docker
  containers managed by this role.
- The community role handles downloading, installing, and restarting.
- Read the [Prometheus upgrade notes](https://prometheus.io/docs/prometheus/latest/migration/)
  and [Alertmanager changelog](https://github.com/prometheus/alertmanager/blob/main/CHANGELOG.md)
  before bumping versions.

---

## Ansible Galaxy Collections

**File:** `galaxy.yml` (dependency constraints), `examples/requirements.yml`
(pinned versions for reproducible installs)

The role depends on:

- `prometheus.prometheus` (constrained to `>=0.16.0,<1.0.0`)
- `grafana.grafana` (constrained to `>=6.0.0,<7.0.0`)

**Key considerations:**

- Ansible Galaxy doesn't have lockfiles. The constraints in `galaxy.yml`
  provide guardrails, but for reproducible deployments, pin exact versions
  in your `requirements.yml`.
- Before updating collection versions, review the collection changelogs for
  breaking changes in role parameters or module interfaces.
- Test with `ansible-playbook --check` after updating collections.

---

## Loki

**Variable:** `loki_image` (default: `grafana/loki:3.4.2`)

**Upgrade guide:**
[Grafana Loki upgrade guide](https://grafana.com/docs/loki/latest/setup/upgrade/)

**Key considerations:**

- Loki schema versions are forward-only. The role uses TSDB v13 — ensure
  the target version supports this schema.
- Read the upgrade guide for breaking config changes (field renames,
  removed options).
- After upgrading, verify `/ready` returns HTTP 200:
  ```bash
  curl -s http://127.0.0.1:3100/ready
  ```
- Check for compactor and ingester errors in container logs:
  ```bash
  docker logs loki 2>&1 | tail -50
  ```

---

## Tempo

**Variable:** `tempo_image` (default: `grafana/tempo:2.7.1`)

**Upgrade guide:**
[Grafana Tempo upgrade guide](https://grafana.com/docs/tempo/latest/setup/upgrade/)

**Key considerations:**

- Tempo's block format changes between major versions. The compactor
  handles block migration, but read the upgrade notes carefully.
- If `tempo_metrics_generator_enabled` is true, verify that generated
  metrics continue to appear in Mimir after upgrading.
- After upgrading, verify `/ready` returns HTTP 200:
  ```bash
  curl -s http://127.0.0.1:3200/ready
  ```

---

## Pyroscope

**Variable:** `pyroscope_image` (default: `grafana/pyroscope:1.19.0`)

**Upgrade guide:**
[Grafana Pyroscope releases](https://github.com/grafana/pyroscope/releases)

**Key considerations:**

- Pyroscope stores profile data in MinIO. Block format changes between major
  versions are handled by the compactor, but read release notes carefully.
- The monolithic deployment (`-target=all`) means all components upgrade
  atomically.
- After upgrading, verify `/ready` returns HTTP 200:
  ```bash
  curl -s http://127.0.0.1:4040/ready
  ```
- Check container logs for deprecation warnings:
  ```bash
  docker logs pyroscope 2>&1 | tail -50
  ```

---

## Grafana Alloy

**Variable:** `alloy_version` (default: `1.8.1`)

**Release notes:**
[Grafana Alloy releases](https://github.com/grafana/alloy/releases)

**Key considerations:**

- Alloy is installed as a native package (APT/RPM), not a Docker container.
  The role pins the exact version.
- River configuration syntax may change between versions. Review release
  notes for deprecated or renamed component blocks.
- After upgrading, verify the health endpoint on each app host:
  ```bash
  curl -s http://127.0.0.1:12345/-/healthy
  ```
- Check Alloy logs for config validation errors:
  ```bash
  journalctl -u alloy --since "5 min ago"
  ```
