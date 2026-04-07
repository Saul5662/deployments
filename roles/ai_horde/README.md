# AI-Horde Deploy Role

Deploys the **AI-Horde backend** (Flask + PostgreSQL + Redis) as either a
Docker Compose stack or a native bare-metal service managed by systemd.

## Deploy Modes

| Mode | Description | Multi-instance | Requires Docker |
| ---- | ----------- | -------------- | --------------- |
| `docker` | Docker Compose stack with bundled PostgreSQL + Redis (default) | No | Yes |
| `native` | Python venv + systemd template instances, external DB/Redis | Yes | No |

Set `ai_horde_deploy_mode` to choose.

### Docker Mode (default)

Runs AI-Horde, PostgreSQL, and Redis as Docker containers managed by a
single `ai-horde.service` systemd unit. Self-contained — good for
development and testing.

### Native Mode

Runs AI-Horde directly on the host using a Python virtualenv managed by
[uv](https://docs.astral.sh/uv/). Deploys N instances via systemd template
units (`ai-horde@7001.service`, `ai-horde@7002.service`, etc.) to work
around Python's GIL by spreading load across CPU cores.

Ownership and permission model in native mode:

- `{{ ai_horde_base_dir }}` is `root:{{ ai_horde_group }}` with `0750` so the
  service user can traverse runtime paths while keeping access restricted.
- `{{ ai_horde_base_dir }}/src` and `{{ ai_horde_venv_dir }}` are owned by
  `{{ ai_horde_user }}:{{ ai_horde_group }}`.
- `{{ ai_horde_base_dir }}/.env` is `root:{{ ai_horde_group }}` with `0640`
  so secrets remain root-owned but readable by the service group.

PostgreSQL and Redis are expected to be external by default. Set
`ai_horde_install_postgres` and/or `ai_horde_install_redis` to optionally
provision them locally.

## Host-Class Sizing (Native Mode)

In native mode, the role passes `--waitress_threads` and
`--waitress_connection_limit` to the AI-Horde server process via systemd. The
role emits advisory warnings when the instance count exceeds 1 per vCPU or when
the projected DB pool footprint (instances × `ai_horde_db_pool_size_per_instance`)
exceeds 200 connections.

| Variable | Default | Effect |
| ---- | ---- | ---- |
| `ai_horde_waitress_threads` | `45` | Passed to `--waitress_threads` on each instance |
| `ai_horde_waitress_connection_limit` | `1024` | Passed to `--waitress_connection_limit` on each instance |
| `ai_horde_db_pool_size_per_instance` | `50` | SQLAlchemy pool_size per instance (advisory projection only) |

Suggested starting points by host class:

| Host class | Typical vCPU range | Suggested initial `ai_horde_instance_count` | Ramp guidance |
| ---- | ---- | ---- | ---- |
| Small | 2-4 | `1-2` | Increase one instance at a time while checking CPU saturation and DB connection pressure. |
| Medium | 6-8 | `2-4` | Validate p95 latency and DB headroom before each increment. |
| Large | 12+ | `4-8` | Scale in staged increments with continuous monitoring; avoid jumps directly to high double-digit instance counts. |

## Requirements

### Docker mode
- **Docker** + **Docker Compose V2** (the role verifies both are present)
- **Ansible 2.14+**
- **Git** (to clone the AI-Horde source for the Docker build)

### Native mode
- **Python 3** + **python3-venv** + build tools (installed by the role)
- **Ansible 2.14+**
- **Git**
- External PostgreSQL and Redis (or set `ai_horde_install_*` flags)

## Deterministic Defaults

- `ai_horde_repo_version` is pinned to a specific commit by default.
- `ai_horde_postgres_image` is pinned by digest in Docker mode.
- Native uv installer checksum verification is enforced by default.

These defaults are intentionally reproducible. Treat version bumps as planned
change events, not ambient upgrades.

## How It Works

1. **Validate** — Fails fast if `ai_horde_postgres_password` or
   `ai_horde_secret_key` are not set, or if `ai_horde_deploy_mode` is invalid.
2. **Dispatch** — Includes `docker.yml` or `native.yml` based on mode.

### Docker path
3. Clones AI-Horde source for the Docker build context.
4. Templates `.env`, `docker-compose.yml`, and a systemd unit.
5. Rebuilds and restarts when source/compose inputs change.
6. Starts the compose stack and waits for health checks.

### Native path
3. Optionally provisions local PostgreSQL and/or Redis.
4. Installs system packages, uv, and creates a dedicated service user.
5. Clones AI-Horde source and creates a Python virtualenv with uv.
6. Templates `.env` and a systemd template unit (`ai-horde@.service`).
7. Enables N instances (`ai-horde@7001` through `ai-horde@700N`).
8. Stops any stale previously-enabled instances outside the desired range.
9. Normalizes native `POSTGRES_URL` as `host[:port]/db` (or uses
  `ai_horde_postgres_url_override` when set).
10. Fails fast on unsupported DB/Redis combinations (for example,
   non-6379 Redis port expectations in native mode).
11. Optionally configures HAProxy for load-balancing instances.
    HAProxy supports two management modes:
    - `safe_edit` (default): marker-bounded insertion that preserves
      unrelated HAProxy config on shared hosts. Creates timestamped
      backups, validates before promoting, and reloads safely.
    - `standalone`: full-file ownership — templates the entire
      `haproxy.cfg` in apply mode. Only safe on dedicated hosts.
      In render-only mode, standalone writes a preview config to
      `ai_horde_haproxy_render_preview_path` and does not touch live
      HAProxy config.
12. Waits for each instance's heartbeat endpoint.

When `ai_horde_start_services: false`, the role runs in render-only mode:

- Skips service start/restart and health-check waits.
- Skips runtime preparation steps that require network/package operations
  (for example source checkout and native dependency installation).
- Still renders role-managed configuration files.

## Role Variables

### Required (no default — fail-fast)

| Variable                     | Description                          |
| ---------------------------- | ------------------------------------ |
| `ai_horde_postgres_password` | PostgreSQL password                  |
| `ai_horde_secret_key`        | Flask secret key for session signing |

### Core Settings

| Variable                  | Default                                       | Description                                      |
| ------------------------- | --------------------------------------------- | ------------------------------------------------ |
| `ai_horde_deploy_mode`   | `docker`                                      | `docker` or `native`                             |
| `ai_horde_repo`           | `https://github.com/Haidra-Org/AI-Horde.git`  | Git repo URL                                     |
| `ai_horde_repo_version`   | `af0a85a78613cdba9863e16bbec0c179a4b2b132`    | Git ref (branch, tag, or SHA)                    |
| `ai_horde_port`           | `7001`                                        | Base HTTP port                                   |
| `ai_horde_listen`         | `127.0.0.1`                                   | Bind address for host port mapping               |
| `ai_horde_backend_host`   | `127.0.0.1`                                   | Local probe/upstream host for HAProxy and health checks |
| `ai_horde_horde_type`     | `stable`                                      | Horde type identifier                            |
| `ai_horde_verbosity`      | `-vvvvi`                                      | Application log verbosity                        |
| `ai_horde_base_dir`       | `/opt/ai-horde`                               | Working directory for compose and source         |
| `ai_horde_data_dir`       | `/var/lib/ai-horde`                           | Persistent data directory                        |
| `ai_horde_admins`         | `[]`                                          | List of admin usernames (written to .env ADMINS) |
| `ai_horde_env_overrides`  | `{}`                                          | Dict of extra env vars merged into .env          |
| `ai_horde_start_services` | `true`                                        | Set false to render configs without starting     |
| `ai_horde_force_build`    | `false`                                       | Force Docker image rebuild                       |
| `ai_horde_docker_build_on_service_start` | `false`                        | If true, systemd service start runs `docker compose build --pull` before `up -d` |

### Database / Redis Connection

| Variable                  | Default        | Description                          |
| ------------------------- | -------------- | ------------------------------------ |
| `ai_horde_postgres_user`  | `postgres`     | PostgreSQL username                  |
| `ai_horde_postgres_db`    | `postgres`     | PostgreSQL database name             |
| `ai_horde_postgres_host`  | `127.0.0.1`   | PostgreSQL host (native mode)        |
| `ai_horde_postgres_port`  | `5432`         | PostgreSQL port (native mode)        |
| `ai_horde_postgres_url_override` | `""`   | Advanced override for `POSTGRES_URL` fragment (`host[:port]/db[?options]`) |
| `ai_horde_redis_host`     | `127.0.0.1`   | Redis host (native mode)             |
| `ai_horde_redis_port`     | `6379`         | Must remain `6379` in native mode (AI-Horde runtime currently assumes fixed Redis port) |

Native `POSTGRES_URL` rendering contract:

- Default path: `POSTGRES_URL=<host>[:<port>]/<db>`.
- If `ai_horde_postgres_port` is `5432`, the port is omitted.
- If `ai_horde_postgres_url_override` is set, it is used verbatim as the
  fragment after `@` in SQLAlchemy URL construction.
- Override values must not include a scheme (`postgres://`, `postgresql://`)
  or embedded credentials.

### Docker Mode Only

| Variable                  | Default                                       | Description                                      |
| ------------------------- | --------------------------------------------- | ------------------------------------------------ |
| `ai_horde_postgres_image` | `ghcr.io/haidra-org/ai-horde-postgres@sha256:25984d05fdb328d3283166222efd569303c0221736fc332b8f4be1b8ff37e1e4` | PostgreSQL Docker image                          |
| `ai_horde_redis_image`    | `redis:7-alpine@sha256:8b81dd...` (pinned digest) | Redis Docker image                               |
| `ai_horde_log_driver`     | `local`                                       | Docker log driver                                |
| `ai_horde_log_max_size`   | `50m`                                         | Max log file size per container                  |
| `ai_horde_log_max_file`   | `5`                                           | Number of rotated log files to keep              |

### Native Mode Only

| Variable                    | Default                          | Description                                       |
| --------------------------- | -------------------------------- | ------------------------------------------------- |
| `ai_horde_instance_count`   | `1`                              | Number of instances (ports 7001–700N)             |
| `ai_horde_waitress_threads` | `45`                            | Waitress thread count per instance (`--waitress_threads`) |
| `ai_horde_waitress_connection_limit` | `1024`                | Waitress connection limit per instance (`--waitress_connection_limit`) |
| `ai_horde_db_pool_size_per_instance` | `50`                  | SQLAlchemy pool_size per instance (advisory projection only) |
| `ai_horde_user`             | `aihorde`                        | System user for Python processes                  |
| `ai_horde_group`            | `aihorde`                        | System group for Python processes                 |
| `ai_horde_venv_dir`         | `{{ ai_horde_base_dir }}/venv`   | Virtualenv location                               |
| `ai_horde_uv_version`       | `0.11.2`                         | Pinned uv version (installed via `_uv_bootstrap` micro-role) |
| `ai_horde_uv_installer_checksum` | `sha256:a6ccba649ac029ce18500400019d60de389838d13a6751aa2908ede1b2aa3a87` | Enforced checksum for installer script |
| `ai_horde_uv_allow_unverified_installer` | `false`           | Explicit opt-in to skip installer checksum verification |
| `ai_horde_install_postgres` | `false`                          | Optionally provision local PostgreSQL             |
| `ai_horde_install_redis`    | `false`                          | Optionally provision local Redis                  |
| `ai_horde_install_haproxy`  | `false`                          | Optionally install HAProxy for load balancing     |
| `ai_horde_haproxy_port`     | `8080`                           | HAProxy frontend listen port (`8080` shared-host baseline; use `80/443` only on dedicated ingress hosts) |
| `ai_horde_haproxy_mode`     | `safe_edit`                      | `safe_edit` (marker-bounded, shared hosts) or `standalone` (full-file ownership) |
| `ai_horde_haproxy_backup_dir` | `/var/backups/haproxy`          | Backup directory for HAProxy config snapshots (safe_edit mode) |
| `ai_horde_haproxy_backup_retention_count` | `20`           | Number of safe-edit backups to retain (newest first, `0` disables pruning) |
| `ai_horde_haproxy_config_path` | `/etc/haproxy/haproxy.cfg`    | Path to the live HAProxy configuration file       |
| `ai_horde_haproxy_timeout_server` | `300000`                  | HAProxy server timeout in milliseconds (default 300s for long AI requests) |
| `ai_horde_haproxy_render_preview_path` | `{{ ai_horde_base_dir }}/rendered/haproxy.cfg` | Standalone render-only preview target when `ai_horde_start_services=false` |

### HAProxy Mode Selection (native mode)

Two management modes are supported with explicit support tiers:

| Tier | Mode | Use Case | Behavior |
|------|------|----------|----------|
| **Tier 1** | `safe_edit` (default) | Shared hosts, multi-service HAProxy | Marker-bounded insertion; only manages its own config block |
| **Tier 2** | `standalone` | Dedicated AI-Horde hosts, labs | Full-file templating; takes ownership of entire `haproxy.cfg` |

Decision guide:

- **Multiple services behind HAProxy?** → Use `safe_edit` (won't overwrite
  other service configs).
- **Dedicated host, single-purpose HAProxy?** → Either mode works;
  `standalone` is simpler, `safe_edit` is safer.
- **CI / render-only testing?** → Either mode supports
  `ai_horde_start_services=false` for offline validation.

### Database Schema Migrations

This role does not manage database schema migrations. The upstream
[AI-Horde](https://github.com/Haidra-Org/AI-Horde) repository ships
versioned SQL files in `sql_statements/`. Apply them with your preferred
migration tooling (for example `psql`, Flyway, or a wrapper script) as a
separate operational step before deploying new application versions that
depend on schema changes.

## Security Notes

- Base-directory ownership is mode-specific by design:
  - Docker mode: `{{ ai_horde_base_dir }}` is `root:root` `0750`.
  - Native mode: `{{ ai_horde_base_dir }}` is `root:{{ ai_horde_group }}` `0750`
    so the service account can traverse to `src` and `.env`.
- The `.env` file is rendered with mode `0600` (Docker mode) or `0640`
  (native mode, root-owned and group-readable by the service group) since it
  contains database credentials and the Flask secret key.
- The `docker-compose.yml` is also `0600` to protect the image references.
- The role **refuses to run** if `ai_horde_postgres_password` or
  `ai_horde_secret_key` are undefined or empty — no silent fallback to
  insecure defaults.
- In native mode, the role also fails fast on unsupported contract
  combinations (for example: non-6379 Redis port, or `ai_horde_install_postgres=true`
  with a non-local PostgreSQL host).
- Native mode emits advisory capacity warnings based on host vCPU count
  and projected DB pool footprint.
- Native mode uses systemd security hardening: `ProtectSystem=strict`,
  `ProtectHome=true`, `NoNewPrivileges=true`, `PrivateTmp=true`.
- Local PostgreSQL provisioning (when enabled) uses `scram-sha-256`
  authentication. No destructive operations are performed by the role.
- Native uv installer fetch is checksum-verified by default. Unverified
  installer usage requires explicit opt-in via
  `ai_horde_uv_allow_unverified_installer=true`.
- Docker service starts default to a fast path (`docker compose up -d`)
  without implicit rebuild. Enable `ai_horde_docker_build_on_service_start`
  only when build-on-start behavior is explicitly desired.

## Example Playbooks

### Docker mode (dev/test)

```yaml
- name: Deploy AI-Horde backend (Docker)
  hosts: horde_server
  become: true
  roles:
    - role: ai_horde
      vars:
        ai_horde_deploy_mode: docker
        ai_horde_repo_version: "af0a85a78613cdba9863e16bbec0c179a4b2b132"
        ai_horde_postgres_image: "ghcr.io/haidra-org/ai-horde-postgres@sha256:25984d05fdb328d3283166222efd569303c0221736fc332b8f4be1b8ff37e1e4"
        ai_horde_postgres_password: "{{ vault_ai_horde_pg_password }}"
        ai_horde_secret_key: "{{ vault_ai_horde_secret_key }}"
        ai_horde_listen: "127.0.0.1"
        ai_horde_admins: ["admin_user#1"]
```

### Native mode (shared-host baseline, non-privileged ingress)

```yaml
- name: Deploy AI-Horde backend (native, conservative baseline)
  hosts: horde_server
  become: true
  roles:
    - role: ai_horde
      vars:
        ai_horde_deploy_mode: native
        ai_horde_repo_version: "af0a85a78613cdba9863e16bbec0c179a4b2b132"
        ai_horde_instance_count: 2
        ai_horde_postgres_password: "{{ vault_ai_horde_pg_password }}"
        ai_horde_secret_key: "{{ vault_ai_horde_secret_key }}"
        ai_horde_postgres_host: "db.internal"
        ai_horde_redis_host: "redis.internal"
        ai_horde_listen: "127.0.0.1"
        ai_horde_admins: ["admin_user#1"]
        ai_horde_install_haproxy: true
        ai_horde_haproxy_mode: safe_edit
        ai_horde_haproxy_port: 8080
```

### Native mode (dedicated ingress host, privileged ingress)

```yaml
- name: Deploy AI-Horde backend (native, dedicated ingress)
  hosts: horde_server
  become: true
  roles:
    - role: ai_horde
      vars:
        ai_horde_deploy_mode: native
        ai_horde_repo_version: "af0a85a78613cdba9863e16bbec0c179a4b2b132"
        ai_horde_instance_count: 4
        ai_horde_postgres_password: "{{ vault_ai_horde_pg_password }}"
        ai_horde_secret_key: "{{ vault_ai_horde_secret_key }}"
        ai_horde_postgres_host: "db.internal"
        ai_horde_redis_host: "redis.internal"
        ai_horde_install_haproxy: true
        ai_horde_haproxy_mode: standalone
        ai_horde_haproxy_port: 80
```

Before using privileged ingress (`80/443`), ensure all are true:

- No conflicting service already binds `80/443`.
- Host firewall/security groups explicitly allow the intended sources.
- TLS termination and certificate lifecycle are explicitly configured.

### Native mode with local services (single-host testing)

```yaml
- name: Deploy AI-Horde backend (native, self-contained)
  hosts: horde_server
  become: true
  roles:
    - role: ai_horde
      vars:
        ai_horde_deploy_mode: native
        ai_horde_repo_version: "af0a85a78613cdba9863e16bbec0c179a4b2b132"
        ai_horde_instance_count: 4
        ai_horde_install_postgres: true
        ai_horde_install_redis: true
        ai_horde_install_haproxy: true
        ai_horde_haproxy_mode: safe_edit
        ai_horde_haproxy_port: 8080
        ai_horde_postgres_password: "{{ vault_ai_horde_pg_password }}"
        ai_horde_secret_key: "{{ vault_ai_horde_secret_key }}"
```

## Deterministic Upgrade and Rollback Checklist

1. Choose target pins for source and runtime artifacts:
   - `ai_horde_repo_version` (commit/tag)
   - `ai_horde_postgres_image` (digest/tag)
   - `ai_horde_uv_installer_checksum` (if uv version changes)
2. Apply the new pins in staging and run role tests.
3. Validate runtime health (`/api/v2/status/heartbeat`).
4. Promote the same pinned values to production.
5. For rollback, redeploy with the previous known-good pins and re-run health checks.

## Upstream Runtime Tunability

Waitress thread count and connection limit are now configurable via upstream
CLI arguments (`--waitress_threads`, `--waitress_connection_limit`). The role
passes these values from `ai_horde_waitress_threads` and
`ai_horde_waitress_connection_limit` to each systemd instance.

Database pool tuning (SQLAlchemy `pool_size`) remains hardcoded upstream.
Tracking for further upstream runtime follow-ups is maintained in:

- `docs/plans/ai-native-gaps-followup/upstream-runtime-tunability-tracking.md`

### HAProxy Safe-Edit Mode

When `ai_horde_haproxy_mode=safe_edit` (default), the role:

1. In apply mode (`ai_horde_start_services=true`), checks that `haproxy.cfg`
  already exists and `haproxy` validation binary is present (fails fast with
  remediation guidance if not).
2. Performs a port-collision preflight on unmanaged config content and fails
  fast when the selected `ai_horde_haproxy_port` is already bound by an
  unmanaged listener.
3. Creates a temporary working copy.
4. Inserts AI-Horde frontend/backend blocks inside `# BEGIN/END ANSIBLE
   MANAGED - AI-HORDE BACKENDS` markers.
5. Compares working-copy checksum to live config checksum.
6. If and only if content differs, validates the working copy with
  `haproxy -c`, creates a timestamped backup, promotes the candidate, and
  reloads HAProxy.
7. Prunes old backups beyond `ai_horde_haproxy_backup_retention_count`
  (newest backups are kept).

In render-only mode (`ai_horde_start_services=false`), safe-edit does not
touch live HAProxy state or require existing host HAProxy files/binaries.

Standalone render-only behavior:

- With `ai_horde_haproxy_mode=standalone` and
  `ai_horde_start_services=false`, the role renders HAProxy config to
  `ai_horde_haproxy_render_preview_path`.
- Live `ai_horde_haproxy_config_path` is only written in apply mode
  (`ai_horde_start_services=true`), with `haproxy -c` validation.

Existing config outside the markers is never modified. To roll back,
copy the most recent backup from `ai_horde_haproxy_backup_dir` back to
`/etc/haproxy/haproxy.cfg` and reload HAProxy.

Safe-edit scope note: it injects a dedicated AI-Horde frontend/backend block.
It does not merge AI-Horde ACLs into an existing shared frontend tree. If your
HAProxy design requires deep integration into pre-existing frontends/ACLs,
manage those rules explicitly and consider `ai_horde_install_haproxy=false`.

Use `ai_horde_haproxy_mode=standalone` only on dedicated hosts where
nothing else manages HAProxy.

A standalone safe-edit script is also deployed to
`/usr/local/bin/ai-horde-haproxy-safe-edit.sh` for manual operations.

## HAProxy Topology Guidance

See [docs/ai-horde-haproxy-topology.md](../../docs/ai-horde-haproxy-topology.md)
for mode selection guidance, reverse-proxy layering patterns, and the
operator decision matrix.

## Relationship to Other Roles

The AI-Horde backend is the hub that workers and frontends connect to:

```
Worker (horde_regen_worker)  ──[horde_url]──▶  AI-Horde  ◀──[API]──  Artbot
```

- **`horde_regen_worker`** connects via `horde_url` in `bridgeData.yaml`.
  Deploy AI-Horde first, then point workers at it.
- **`artbot`** connects via the public API URL.
- **`horde_stats_exporter`** scrapes the public API for Prometheus metrics.

## Testing

```bash
# All AI-Horde tests (Docker + native render, logic)
./tests/run_tests.sh ai_horde

# Docker mode render + credential fail-fast tests
./tests/run_tests.sh ai_horde/test_ai_horde_render

# Native mode render + contract guardrail fail-fast tests
./tests/run_tests.sh ai_horde/test_ai_horde_native_render

# Native logic checks (stale-instance detection, HAProxy backend rendering,
# safe-edit block insertion, validation non-promotion)
./tests/run_tests.sh ai_horde/test_ai_horde_native_logic

# Integration smoke test (config coherence)
./tests/run_tests.sh integration

# Local deploy — Docker mode (requires Docker)
./tests/ai_horde/local_deploy.sh up
./tests/ai_horde/local_deploy.sh down

# Full integration with probe
./tests/integration/local_deploy.sh up
./tests/integration/local_deploy.sh down
```

## License

AGPL-3.0-or-later
