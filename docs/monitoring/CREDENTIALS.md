# Credential Management

## Overview

The monitoring stack uses three sets of credentials:

| Credential               | Where it appears                                           | Purpose                                             |
| ------------------------ | ---------------------------------------------------------- | --------------------------------------------------- |
| `minio_root_password`    | `mimir.yaml`, `docker-compose.yml`, `mimir-backup.service` | MinIO admin access (S3 API for Mimir block storage) |
| `grafana_admin_password` | `docker-compose.yml`                                       | Grafana admin UI login                              |
| `minio_root_user`        | `mimir.yaml`, `docker-compose.yml`, `mimir-backup.service` | MinIO admin username                                |

## File Permissions

All files containing credentials are rendered with `mode: 0600` and
`owner: root`, `group: root`. Only root can read them. The Docker daemon
runs as root and can read these files for bind-mount purposes.

## Default Password Protection

The role includes fail-fast checks that prevent deploying with default
placeholder passwords when `monitoring_start_services: true`. The checks:

- Fail if `minio_root_password == "changeme-minio-secret"` (when MinIO
  is enabled)
- Fail if `grafana_admin_password == "changeme"` (when Grafana is
  enabled)

These checks are **skipped** when `monitoring_start_services: false`
(CI/test mode), since passwords are irrelevant when services aren't
started.

## Setting Credentials

Use Ansible Vault to encrypt credentials in your inventory:

```bash
# Create or edit a vault file
ansible-vault create group_vars/mimir/vault.yml

# Contents:
vault_minio_root_password: "<strong-random-password>"
vault_grafana_admin_password: "<strong-random-password>"
```

Reference the vault variables in your playbook or group_vars:

```yaml
minio_root_password: "{{ vault_minio_root_password }}"
grafana_admin_password: "{{ vault_grafana_admin_password }}"
```

See `examples/horde_monitoring_stack.yml` for a working example.

## Credential Rotation

Changing credentials requires a full stack restart. There is no rolling
rotation support — this is acceptable for a single-host monitoring stack
where the credentials are internal (loopback network only).

### MinIO password rotation

The `minio_root_password` appears in:

1. MinIO's `MINIO_ROOT_PASSWORD` environment variable (Compose)
2. Mimir's `common.storage.s3.secret_access_key` (mimir.yaml)
3. The `minio-init` sidecar's `mc alias set` command (Compose)
4. The backup service's `mc alias set` command (mimir-backup.service)

**Procedure:**

1. Update `minio_root_password` in your vault/inventory
2. Run the playbook — Ansible re-renders all affected templates
3. The `restart monitoring stack` handler fires, pulling images and
   restarting all containers with the new credential
4. Verify MinIO health: `curl http://127.0.0.1:9000/minio/health/live`
5. Verify Mimir health: `curl http://127.0.0.1:9009/ready`

### Grafana password rotation

The `grafana_admin_password` appears only in:

1. Grafana's `GF_SECURITY_ADMIN_PASSWORD` environment variable (Compose)

**Procedure:**

1. Update `grafana_admin_password` in your vault/inventory
2. Run the playbook — Ansible re-renders the Compose template
3. The handler restarts the Compose stack
4. Verify Grafana health: `curl http://127.0.0.1:3000/api/health`

**Note:** Grafana's `GF_SECURITY_ADMIN_PASSWORD` only sets the password
on first startup (when the Grafana database is empty). To change the
password after initial setup, use the Grafana API:

```bash
curl -X PUT http://127.0.0.1:3000/api/admin/users/1/password \
  -u admin:<old-password> \
  -H "Content-Type: application/json" \
  -d '{"password":"<new-password>"}'
```

## Future: Docker Secrets

A potential improvement is migrating from environment variables to Docker
Compose secrets, which would remove credentials from `docker inspect`
output and `/proc/*/environ`. Both MinIO and Grafana support file-based
credential loading:

- **MinIO:** `MINIO_ROOT_PASSWORD_FILE`
- **Grafana:** `GF_SECURITY_ADMIN_PASSWORD__FILE`

This is tracked as decision D4 in the plan README.
