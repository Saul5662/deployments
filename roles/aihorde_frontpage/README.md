# aihorde_frontpage

Deploys the [AiHordeFrontpage](https://github.com/Haidra-Org/AiHordeFrontpage)
Angular SSR website via Docker Compose or as a native Node.js systemd service.

> **Scope:** This role deploys the AI Horde frontpage specifically. It is not a
> general-purpose Angular or Node.js deployment role. Use it to run the
> AiHordeFrontpage application as part of the AI Horde stack.

## Deploy Modes

| Mode | Description | Requires Docker |
| ---- | ----------- | --------------- |
| `docker` | Build and run inside a Docker container (default) | Yes |
| `native` | Install Node.js on the host, build and run directly | No |

Set `aihorde_frontpage_deploy_mode` to choose.

## Requirements

### Docker mode
- Docker Engine with Docker Compose V2 plugin
- Ansible 2.14+
- Git

### Native mode
- Debian/Ubuntu host
- Ansible 2.14+
- Git
- Node.js is installed automatically via the `geerlingguy.nodejs` dependency

## Role Variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `aihorde_frontpage_deploy_mode` | `docker` | `docker` or `native` |
| `aihorde_frontpage_repo` | `https://github.com/Haidra-Org/AiHordeFrontpage.git` | Git repo URL |
| `aihorde_frontpage_repo_version` | *(pinned SHA)* | Git ref (commit, tag, or branch) |
| `aihorde_frontpage_base_dir` | `/opt/aihorde-frontpage` | Working directory |
| `aihorde_frontpage_port` | `8006` | Host-side HTTP port |
| `aihorde_frontpage_listen` | `127.0.0.1` | Bind address |
| `aihorde_frontpage_allowed_hosts` | `[localhost, 127.0.0.1, ::1]` | Allowed Host header values for Angular SSR |
| `aihorde_frontpage_build_config` | `production` | Angular build configuration (`production`, `development`, `local`) |
| `aihorde_frontpage_start_services` | `true` | Set `false` for render-only mode (CI/test) |
| `aihorde_frontpage_force_build` | `false` | Force Docker image rebuild |
| `aihorde_frontpage_docker_build_on_service_start` | `false` | Run `docker compose build` on every service start |
| `aihorde_frontpage_user` | `aihorde-frontpage` | System user (native mode only) |
| `aihorde_frontpage_group` | `aihorde-frontpage` | System group (native mode only) |
| `aihorde_frontpage_node_major` | `24` | Node.js major version (native mode only) |

## Security Notes

- Native mode runs under a dedicated unprivileged user with systemd
  hardening (`NoNewPrivileges=true`, `ProtectSystem=strict`,
  `ProtectHome=true`).
- Environment file is mode `0640`.
- Source version is pinned by commit SHA for reproducibility.

## Example Playbook

```yaml
- name: Deploy AiHordeFrontpage
  hosts: frontpage
  become: true
  roles:
    - role: aihorde_frontpage
      vars:
        aihorde_frontpage_deploy_mode: docker
        aihorde_frontpage_port: 8006
        aihorde_frontpage_allowed_hosts:
          - aihorde.net
          - localhost
```

## Testing

```bash
./tests/run_tests.sh frontpage
```

## License

AGPL-3.0-or-later
