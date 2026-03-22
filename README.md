# Haidra Deployments

Ansible collection for deploying Haidra services — AI Horde workers, monitoring
infrastructure, and supporting applications.

## Usage

Install [Ansible](https://www.ansible.com/) (Linux only):

```bash
python -m pip install ansible
```

Ensure your control host can SSH to targets using key-based authentication via
an ssh-agent. If the remote user requires a sudo password, append `-K` to all
`ansible-playbook` commands.

Install this collection and its dependencies:

```bash
wget https://raw.githubusercontent.com/Haidra-Org/deployments/main/examples/requirements.yml
ansible-galaxy collection install -r requirements.yml
```

## Included Roles

Each role provides its own README with full variable documentation and examples.
Adjust an [example inventory](examples/) with your hostnames, then run the
corresponding example playbook — or build your own `site.yml`.

### Application Roles

| Role                                                     | Description                                  |
| -------------------------------------------------------- | -------------------------------------------- |
| [artbot](roles/artbot/README.md)                         | Web frontend for AI Horde                    |
| [artbot_revproxy](roles/artbot_revproxy/README.md)       | HAProxy reverse proxy for Artbot             |
| [horde_regen_worker](roles/horde_regen_worker/README.md) | AI Horde worker (Dreamer, Scribe, Alchemist) |
| [amd_gpu_drivers](roles/amd_gpu_drivers/README.md)       | AMD GPU driver and ROCm setup                |

### Monitoring Roles

| Role                                                         | Description                                               |
| ------------------------------------------------------------ | --------------------------------------------------------- |
| [horde_monitoring](roles/horde_monitoring/README.md)         | Mimir + Grafana + MinIO monitoring stack (Docker Compose) |
| [horde_stats_exporter](roles/horde_stats_exporter/README.md) | AI Horde API → Prometheus metrics exporter                |
| [horde_alloy](roles/horde_alloy/README.md)                   | Grafana Alloy telemetry collector for app hosts           |

See [MONITORING.md](MONITORING.md) for the architecture overview, quick start,
and how the monitoring roles work together.

## Documentation

| Document                                     | Contents                                          |
| -------------------------------------------- | ------------------------------------------------- |
| [Monitoring Guide](MONITORING.md)            | Architecture, quick start, troubleshooting        |
| [Observability Stack](docs/OBSERVABILITY.md) | Loki, Tempo, and Alloy deep-dive                  |
| [Backup & Restore](docs/BACKUP.md)           | RPO/RTO, backup configuration, restore procedures |
| [Credentials](docs/CREDENTIALS.md)           | Credential management and rotation                |
| [Upgrading](docs/UPGRADING.md)               | Component version upgrade procedures              |
| [Migration](docs/MIGRATION.md)               | Host migration runbook (planned and forced)       |
