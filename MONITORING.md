# AI Horde Monitoring Deployment Guide

This guide explains how to deploy the AI Horde monitoring infrastructure using Ansible.

## Overview

The monitoring infrastructure consists of:

1. **horde_stats_exporter** - Collects AI Horde API metrics and exposes them in Prometheus format
2. **horde_monitoring** - Deploys Prometheus, Grafana, and optionally InfluxDB using native packages

## Architecture

```
AI Horde APIs → horde_exporter.py → Prometheus → Grafana
                                          ↓
                                    (indefinite retention)
```

### Key Features

- **Prometheus-native metrics collection**: Pull-based scraping via `/metrics` endpoint
- **Zero-omission strategy**: 51% storage reduction while maintaining full entity coverage
- **Indefinite retention**: AI Horde API stats kept permanently
- **Uniform type labeling**: Consistent `type=image|text|interrogator` labels

## Quick Start

### 1. Install the Ansible Collection

```bash
wget https://raw.githubusercontent.com/Haidra-Org/deployments/main/examples/requirements.yml
ansible-galaxy collection install -r requirements.yml
```

### 2. Deploy Complete Monitoring Stack

```bash
# Copy and customize the example inventory
cp examples/inventory_monitoring.yml inventory.yml
# Edit inventory.yml with your host details

# Deploy the full stack
ansible-playbook -i inventory.yml examples/horde_monitoring_stack.yml
```

### 3. Deploy Stats Exporter Only

If you already have Prometheus/Grafana running:

```bash
ansible-playbook -i inventory.yml examples/horde_stats_exporter.yml
```

## Role: horde_stats_exporter

Deploys the AI Horde Prometheus exporter as a systemd service.

### Requirements

- Python 3.8+
- Source files from horde-grafana repository
- Systemd-based Linux distribution

### Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `exporter_user` | `horde-exporter` | System user for the exporter |
| `exporter_install_dir` | `/opt/horde-exporter` | Installation directory |
| `exporter_port` | `9100` | Port for metrics endpoint |
| `exporter_api_base_url` | `https://aihorde.net/api/v2` | AI Horde API base URL |
| `exporter_scrape_models` | `8` | Models scrape interval (seconds) |
| `exporter_scrape_workers` | `300` | Workers scrape interval (seconds) |
| `exporter_scrape_performance` | `2` | Performance scrape interval (seconds) |
| `exporter_enable_downsampling` | `true` | Enable daily downsampling |

### Example Usage

```yaml
- hosts: monitoring
  roles:
    - role: haidra.deployments.horde_stats_exporter
      vars:
        exporter_port: 9100
        exporter_enable_downsampling: true
```

### Verification

After deployment:

```bash
# Check service status
sudo systemctl status horde-exporter

# View logs
sudo journalctl -u horde-exporter -f

# Test metrics endpoint
curl http://localhost:9100/metrics
```

## Role: horde_monitoring

Deploys a complete monitoring stack with Prometheus, Grafana, and optionally InfluxDB.

### Components

- **Prometheus**: Time-series database for metrics storage
- **Grafana**: Visualization and dashboarding
- **InfluxDB** (optional): Legacy InfluxDB support for migration

### Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `monitoring_install_prometheus` | `true` | Install Prometheus |
| `monitoring_install_grafana` | `true` | Install Grafana |
| `monitoring_install_influxdb` | `false` | Install InfluxDB (for migration) |
| `prometheus_version` | `2.45.0` | Prometheus version to install |
| `prometheus_port` | `9090` | Prometheus web interface port |
| `prometheus_retention_time` | `100y` | Data retention time (e.g. `15d`, `90d`, `100y` for indefinite) |
| `grafana_port` | `3000` | Grafana web interface port |
| `grafana_admin_password` | `changeme` | Grafana admin password |

### Example Usage

```yaml
- hosts: monitoring
  roles:
    - role: haidra.deployments.horde_monitoring
      vars:
        prometheus_retention_time: "100y"  # Indefinite retention for horde stats
        grafana_admin_password: "{{ vault_grafana_password }}"
        monitoring_install_influxdb: false
```

## Complete Deployment Example

### Inventory File

```yaml
# inventory.yml
all:
  children:
    monitoring:
      hosts:
        monitoring.example.com:
          ansible_host: 192.168.1.100
          ansible_user: admin

          # Monitoring stack configuration
          prometheus_version: "2.45.0"
          prometheus_retention_time: "100y"
          grafana_admin_password: "secure_password_here"

          # Stats exporter configuration
          exporter_source_dir: "/path/to/horde-grafana"
          exporter_enable_downsampling: true
```

### Playbook

```yaml
# deploy_monitoring.yml
- name: Deploy AI Horde Monitoring
  hosts: monitoring
  become: yes

  roles:
    - haidra.deployments.horde_monitoring
    - haidra.deployments.horde_stats_exporter

  post_tasks:
    - name: Display access information
      debug:
        msg:
          - "Prometheus: http://{{ ansible_host }}:9090"
          - "Grafana: http://{{ ansible_host }}:3000 (admin / {{ grafana_admin_password }})"
          - "Metrics: http://{{ ansible_host }}:9100/metrics"
```

### Run Deployment

```bash
ansible-playbook -i inventory.yml deploy_monitoring.yml -K
```

## Data Retention Policy

- **AI Horde API metrics** (from horde_exporter): **Indefinite retention** (default: `100y`)
- **System metrics** (postgres_exporter, node_exporter): Time-limited (15d raw, 90d downsampled)

Configure retention in Prometheus:

```yaml
prometheus_retention_time: "100y"  # Effectively indefinite for horde stats
prometheus_retention_size: "0"     # "0" = no size limit (flag omitted)
```

## Metrics Exposed

### Models Metrics
- `horde_models_queued_total{type="image|text"}` - Total requests queued
- `horde_model_queued{model="...", type="..."}` - Per-model queue depth
- `horde_model_workers_count{model="...", type="..."}` - Workers supporting model
- And more...

### Workers Metrics
- `horde_workers_active_total{type="image|text"}` - Total active workers
- `horde_worker_requests_fulfilled_total{worker="...", type="..."}` - Worker request count
- `horde_worker_kudos_rewards{worker="...", type="..."}` - Worker kudos earned
- And more...

### Performance Metrics
- `horde_performance_queued_requests{type="image|text"}` - Global queue depth
- `horde_performance_worker_count{type="image|text|interrogator"}` - Workers by type
- And more...

## Grafana Dashboard Setup

After deployment, access Grafana at `http://your-host:3000`:

1. Log in with admin credentials
2. Add Prometheus data source:
   - URL: `http://localhost:9090`
   - Access: Server (default)
3. Import or create dashboards using the horde metrics

## Troubleshooting

### Exporter Issues

```bash
# Check exporter status
sudo systemctl status horde-exporter

# View logs
sudo journalctl -u horde-exporter -f

# Test metrics endpoint
curl http://localhost:9100/metrics | head -20

# Run health check
cd /opt/horde-exporter && ./health-check.sh
```

### Prometheus Issues

```bash
# Check Prometheus status
sudo systemctl status prometheus

# View logs
sudo journalctl -u prometheus -f

# Check configuration
promtool check config /etc/prometheus/prometheus.yml

# Test Prometheus API
curl http://localhost:9090/api/v1/status/config
```

### Grafana Issues

```bash
# Check Grafana status
sudo systemctl status grafana-server

# View logs
sudo journalctl -u grafana-server -f

# Reset admin password
grafana-cli admin reset-admin-password new_password
```

## Prometheus Backup and Restore

The monitoring stack includes automated backup capabilities for Prometheus TSDB data.

### Backup Architecture

The backup system uses Prometheus' native snapshot API to create consistent point-in-time backups:

- **Daily backups**: Automatic snapshots retained for 7 days
- **Monthly backups**: First of month snapshots retained for 12 months
- **Compression**: gzip or zstd compression (configurable)
- **Retention**: Configurable per backup type
- **Optional remote sync**: Rsync to remote storage

### Enabling Backups

Backups are enabled by default. To configure:

```yaml
# In your inventory or playbook
monitoring_enable_prometheus_backup: true

# Backup configuration (optional, these are defaults)
prometheus_backup_dir: "/var/backups/prometheus"
prometheus_backup_daily_retention: "7"     # days
prometheus_backup_monthly_retention: "12"  # months
prometheus_backup_compression: "gzip"      # or "zstd"
prometheus_backup_schedule: "*-*-* 02:00:00"  # Daily at 2 AM

# Optional: remote backup sync
prometheus_backup_remote_enabled: false
prometheus_backup_remote_dest: "user@backup-server:/backups/prometheus"
```

### Available Commands

After deployment, the following backup management commands are available:

#### Manual Backup

```bash
# Create a backup immediately
sudo -u prometheus /usr/local/bin/prometheus_backup.sh

# View backup logs
sudo journalctl -u prometheus-backup.service -f
```

#### Verify Backups

```bash
# Run comprehensive backup verification
sudo /usr/local/bin/prometheus_verify_backup.sh

# This checks:
# - Backup directory structure
# - Backup count and age
# - Archive integrity
# - Disk space
# - Timer status
```

#### Restore from Backup

```bash
# List available backups
ls -lh /var/backups/prometheus/daily/
ls -lh /var/backups/prometheus/monthly/

# Restore from latest daily backup
sudo /usr/local/bin/prometheus_restore.sh \
  $(ls -t /var/backups/prometheus/daily/prometheus-*.tar.* | head -1)

# Restore from specific monthly backup
sudo /usr/local/bin/prometheus_restore.sh \
  /var/backups/prometheus/monthly/prometheus-2025-11.tar.gz

# Dry run (see what would happen without actually restoring)
sudo /usr/local/bin/prometheus_restore.sh --dry-run <backup-file>

# Restore without restarting Prometheus
sudo /usr/local/bin/prometheus_restore.sh --no-restart <backup-file>
```

#### Monitor Backup Status

```bash
# Check backup timer status
systemctl status prometheus-backup.timer

# View next scheduled backup time
systemctl list-timers prometheus-backup.timer

# View backup history
sudo journalctl -u prometheus-backup.service --since "7 days ago"

# Check backup storage usage
du -sh /var/backups/prometheus/
```

### Backup Storage Requirements

For a ~5GB Prometheus database:
- Compressed backup size: ~2-3GB (with gzip)
- 7 daily backups: ~15-20GB
- 12 monthly backups: ~25-35GB
- **Total storage needed**: ~50GB recommended

### Disaster Recovery

In case of complete data loss:

1. Stop Prometheus:
   ```bash
   sudo systemctl stop prometheus
   ```

2. Restore from backup:
   ```bash
   sudo /usr/local/bin/prometheus_restore.sh /path/to/backup.tar.gz
   ```

3. The restore script will:
   - Backup current data (if any)
   - Extract the backup
   - Set correct permissions
   - Start Prometheus automatically
   - Wait for health check

4. Verify restoration:
   ```bash
   curl http://localhost:9090/-/healthy
   # Check data in Grafana
   ```

### Backup Best Practices

1. **Test restores regularly**: Monthly test restores verify backup integrity
2. **Monitor backup success**: Set up alerts for backup failures
3. **Remote backups**: Enable remote sync for off-site copies
4. **Disk space**: Monitor `/var/backups` disk usage
5. **Retention tuning**: Adjust retention based on your needs

### Disabling Backups

To disable backup automation:

```yaml
monitoring_enable_prometheus_backup: false
```

Then re-run the playbook:

```bash
ansible-playbook -i inventory.yml examples/horde_monitoring_stack.yml
```

## Migration from Legacy Setup

If migrating from the old InfluxDB-based `horde.py` collector:

1. Deploy new monitoring stack with `monitoring_install_influxdb: true`
2. Run both collectors in parallel for validation
3. Optionally migrate historical data from InfluxDB to Prometheus
4. Decommission `horde.py` after validation

See the horde-grafana repository README for migration details.

## Security Considerations

- Change default Grafana admin password
- Configure firewall rules (set `monitoring_configure_firewall: true`)
- Use TLS/HTTPS for production deployments
- Restrict Prometheus remote_write if using distributed setup
- Consider using Ansible Vault for sensitive variables

## Further Reading

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [AI Horde API Documentation](https://aihorde.net/api/)
- [horde-grafana Repository](https://github.com/Haidra-Org/horde-grafana)
