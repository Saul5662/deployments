# Credential Management

## Overview

The monitoring stack uses three sets of credentials:

| Credential                                | Where it appears                                           | Purpose                                                |
| ----------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------ |
| `horde_monitoring_s3_secret_key`          | `mimir.yaml`, `docker-compose.yml`, `mimir-backup.service` | S3 storage admin secret key (S3 API for block storage) |
| `horde_monitoring_grafana_admin_password` | `docker-compose.yml`                                       | Grafana admin UI login                                 |
| `horde_monitoring_s3_access_key`          | `mimir.yaml`, `docker-compose.yml`, `mimir-backup.service` | S3 storage admin access key (username)                 |

For production, the preferred deployment model is `horde_monitoring_s3_deployment_mode: external`
with a managed S3-compatible backend. Embedded Garage mode remains supported
for local/single-host setups.

## File Permissions

All files containing credentials are rendered with `mode: 0600` and
`owner: root`, `group: root`. Only root can read them. The Docker daemon
runs as root and can read these files for bind-mount purposes.

## Default Password Protection

The role includes fail-fast checks that prevent deploying with default
placeholder passwords when `horde_monitoring_start_services: true`. The checks:

- Fail if `horde_monitoring_s3_secret_key == "changeme-s3-secret"` (when S3 storage
  is enabled)
- Fail if `horde_monitoring_grafana_admin_password == "changeme"` (when Grafana is
  enabled)

These checks are **skipped** when `horde_monitoring_start_services: false`
(CI/test mode), since passwords are irrelevant when services aren't
started.

## Setting Credentials

Use Ansible Vault to encrypt credentials in your inventory:

```bash
# Create or edit a vault file
ansible-vault create group_vars/mimir/vault.yml

# Contents:
vault_s3_secret_key: "<strong-random-password>"
vault_grafana_admin_password: "<strong-random-password>"
```

Reference the vault variables in your playbook or group_vars:

```yaml
horde_monitoring_s3_secret_key: "{{ vault_s3_secret_key }}"
horde_monitoring_grafana_admin_password: "{{ vault_grafana_admin_password }}"
```

See `examples/horde_monitoring_stack.yml` for a working example.

## Credential Rotation

Changing credentials requires a full stack restart.

### S3 secret key rotation

The `horde_monitoring_s3_secret_key` appears in:

1. Mimir's `common.storage.s3.secret_access_key` (mimir.yaml)
2. Optional `s3-init` sidecar (`mc alias set`) when bucket management is enabled
3. Backup service `mc alias set` command (mimir-backup.service)
4. Embedded Garage keyring state (when `horde_monitoring_s3_deployment_mode: embedded`)

**Procedure:**

1. Update `horde_monitoring_s3_secret_key` in your vault/inventory
2. Run the playbook — Ansible re-renders all affected templates
3. In embedded Garage mode, rotate to a new key ID + secret pair if needed
   (for example, update both `horde_monitoring_s3_access_key` and
   `horde_monitoring_s3_secret_key` together), then rerun the playbook
4. The `restart monitoring stack` handler fires, pulling images and
   restarting containers with the updated client credentials
5. Verify S3 health:

- external mode: use your provider-specific health/availability checks
- embedded Garage mode:

```bash
curl http://127.0.0.1:3903/health
```

5. Verify Mimir health: `curl http://127.0.0.1:9009/ready`

### Grafana password rotation

The `horde_monitoring_grafana_admin_password` appears only in:

1. Grafana's `GF_SECURITY_ADMIN_PASSWORD` environment variable (Compose)

**Procedure:**

1. Update `horde_monitoring_grafana_admin_password` in your vault/inventory
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
output and `/proc/*/environ`. Grafana supports file-based credential loading:

- **Grafana:** `GF_SECURITY_ADMIN_PASSWORD__FILE`

Embedded Garage already uses file-backed server configuration (`/etc/garage.toml`),
but S3 client credentials are still rendered into backend configs and backup
runtime environments. Moving those client credentials to a secret-injection
pattern remains a future hardening opportunity.
