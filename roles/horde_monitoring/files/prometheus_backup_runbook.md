# Prometheus Backup Runbook

Quick reference guide for managing Prometheus backups and responding to alerts.

## Quick Commands

```bash
# Check backup status
systemctl status prometheus-backup.timer
systemctl status prometheus-backup.service

# View recent backup logs
journalctl -u prometheus-backup.service -n 100

# Verify backups
sudo /usr/local/bin/prometheus_verify_backup.sh

# Manual backup
sudo -u prometheus /usr/local/bin/prometheus_backup.sh

# List backups
ls -lh /var/backups/prometheus/daily/
ls -lh /var/backups/prometheus/monthly/

# Check backup metrics
curl -s http://localhost:9090/api/v1/query?query=prometheus_backup_last_success_timestamp | jq .
```

## Alert Response Procedures

### PrometheusBackupFailed (CRITICAL)

**Symptoms:** No successful backup in >25 hours

**Investigation:**
```bash
# 1. Check backup service status
systemctl status prometheus-backup.service

# 2. View recent logs
journalctl -u prometheus-backup.service --since "24 hours ago"

# 3. Check Prometheus health
curl http://localhost:9090/-/healthy

# 4. Check disk space
df -h /var/backups/prometheus
df -h /var/lib/prometheus

# 5. Check backup script permissions
ls -la /usr/local/bin/prometheus_backup.sh
```

**Common Causes & Solutions:**

1. **Disk Full**
   ```bash
   # Check space
   df -h /var/backups

   # Emergency cleanup (remove oldest dailies beyond minimum)
   find /var/backups/prometheus/daily -name "prometheus-*.tar.*" -type f -mtime +3 -delete

   # Or expand storage
   ```

2. **Prometheus Unhealthy**
   ```bash
   systemctl status prometheus
   journalctl -u prometheus -n 50

   # Fix Prometheus first, then retry backup
   sudo -u prometheus /usr/local/bin/prometheus_backup.sh
   ```

3. **Permission Issues**
   ```bash
   # Re-run ansible to fix permissions
   ansible-playbook -i inventory.yml playbook.yml --tags backup
   ```

4. **Timer Not Running**
   ```bash
   systemctl enable prometheus-backup.timer
   systemctl start prometheus-backup.timer
   systemctl list-timers prometheus-backup.timer
   ```

---

### PrometheusBackupValidationFailed (WARNING)

**Symptoms:** Backup completed but failed validation

**Investigation:**
```bash
# Check what failed
journalctl -u prometheus-backup.service -n 200 | grep -i "validation\|error"

# Manually validate latest backup
LATEST=$(ls -t /var/backups/prometheus/daily/prometheus-*.tar.* | head -1)
echo "Checking: $LATEST"

# Test archive integrity
gzip -t "$LATEST" && tar -tzf "$LATEST" >/dev/null && echo "Archive OK" || echo "Archive CORRUPTED"

# Check size
ls -lh "$LATEST"
```

**Resolution:**
```bash
# 1. If corrupted, run manual backup immediately
sudo -u prometheus /usr/local/bin/prometheus_backup.sh

# 2. If size issues, check Prometheus TSDB
du -sh /var/lib/prometheus

# 3. Monitor next scheduled backup
```

---

### PrometheusBackupSlow (WARNING)

**Symptoms:** Backup taking >1 hour

**Investigation:**
```bash
# Check backup duration trend
# In Prometheus UI: prometheus_backup_duration_seconds

# Check system I/O performance
iostat -x 5 3

# Check Prometheus TSDB size
du -sh /var/lib/prometheus

# Check compression method
grep "COMPRESSION=" /usr/local/bin/prometheus_backup.sh
```

**Resolution:**

1. **Growing Dataset** - Expected as data accumulates
   - Monitor trend
   - Ensure backup window is sufficient

2. **I/O Bottleneck**
   ```bash
   # Consider rescheduling to off-peak hours
   # Edit in inventory and re-run ansible:
   prometheus_backup_schedule: "*-*-* 03:00:00"
   ```

3. **Compression Too Slow**
   ```bash
   # Switch to faster compression (if using zstd)
   prometheus_backup_compression: "gzip"
   # Re-run ansible to apply
   ```

---

## Common Operations

### Restore from Backup

**Pre-requisites:**
- Root access
- Approved downtime window
- Backup file identified and verified

**Procedure:**
```bash
# 1. List available backups
ls -lh /var/backups/prometheus/daily/
ls -lh /var/backups/prometheus/monthly/

# 2. Verify backup (optional but recommended)
sudo /usr/local/bin/prometheus_verify_backup.sh

# 3. DRY RUN first
BACKUP="/var/backups/prometheus/daily/prometheus-2025-11-19.tar.gz"
sudo /usr/local/bin/prometheus_restore.sh --dry-run "$BACKUP"

# 4. Perform actual restore
sudo /usr/local/bin/prometheus_restore.sh "$BACKUP"

# 5. Verify Prometheus started
systemctl status prometheus
curl http://localhost:9090/-/healthy

# 6. Check Grafana dashboards for data
```

**Rollback:**
If restore fails, the script automatically backs up current data to:
```
/var/lib/prometheus.backup-YYYYMMDD-HHMMSS
```

To rollback:
```bash
systemctl stop prometheus
mv /var/lib/prometheus /var/lib/prometheus.failed-restore
mv /var/lib/prometheus.backup-YYYYMMDD-HHMMSS /var/lib/prometheus
systemctl start prometheus
```

---

### Manual Backup

```bash
# Run as prometheus user
sudo -u prometheus /usr/local/bin/prometheus_backup.sh

# Or as root
sudo /usr/local/bin/prometheus_backup.sh

# Check result
journalctl -u prometheus-backup.service -n 20
```

---

### Adjust Retention

Edit inventory:
```yaml
prometheus_backup_daily_retention: "7"     # days
prometheus_backup_monthly_retention: "12"  # months
```

Re-run ansible:
```bash
ansible-playbook -i inventory.yml playbook.yml
```

---

### Enable Remote Backups

Edit inventory:
```yaml
prometheus_backup_remote_enabled: true
prometheus_backup_remote_dest: "user@backup-server:/backups/prometheus"
```

Setup SSH keys:
```bash
# As prometheus user
sudo -u prometheus ssh-keygen -t ed25519
sudo -u prometheus ssh-copy-id user@backup-server
```

Test:
```bash
sudo -u prometheus rsync -avz --dry-run /var/backups/prometheus/ user@backup-server:/backups/prometheus/
```

Re-run ansible:
```bash
ansible-playbook -i inventory.yml playbook.yml
```

---

## Monitoring

### Key Metrics

```promql
# Time since last successful backup (hours)
(time() - prometheus_backup_last_success_timestamp) / 3600

# Backup success rate (last 7 days)
avg_over_time(prometheus_backup_success[7d])

# Backup duration trend
prometheus_backup_duration_seconds

# Storage usage
prometheus_backup_total_size_bytes

# Backup count
prometheus_backup_daily_count + prometheus_backup_monthly_count
```

### Grafana Queries

Import these into a dashboard:

**Backup Status Panel** (Stat):
```promql
prometheus_backup_success
```

**Time Since Last Backup** (Stat):
```promql
(time() - prometheus_backup_last_success_timestamp) / 3600
```

**Backup Duration** (Graph):
```promql
prometheus_backup_duration_seconds
```

**Storage Used** (Graph):
```promql
prometheus_backup_total_size_bytes / 1024 / 1024 / 1024
```

---

## Troubleshooting

### Metrics Not Appearing

```bash
# 1. Check metrics file exists
ls -la /var/lib/prometheus/textfile_collector/prometheus_backup.prom

# 2. Check file permissions
# Should be readable by prometheus user

# 3. Check node_exporter is collecting textfiles
curl http://localhost:9100/metrics | grep prometheus_backup

# 4. If node_exporter not installed, metrics won't be exported
# Install node_exporter separately or adjust metrics path
```

### Backup Timer Not Firing

```bash
# Check timer is enabled and active
systemctl status prometheus-backup.timer
systemctl is-enabled prometheus-backup.timer

# View timer schedule
systemctl list-timers prometheus-backup.timer

# Check logs
journalctl -u prometheus-backup.timer

# Restart timer
systemctl restart prometheus-backup.timer
```

### Snapshot API Not Available

```bash
# Check if admin API is enabled
curl -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot

# If 404, admin API not enabled
# Re-run ansible to enable it:
monitoring_enable_prometheus_backup: true
```

---

## Emergency Procedures

### Complete Backup System Failure

If all backups are lost/corrupted:

1. **Stop further damage**
   ```bash
   systemctl stop prometheus-backup.timer
   ```

2. **Assess Prometheus health**
   ```bash
   systemctl status prometheus
   curl http://localhost:9090/-/healthy
   ```

3. **Create immediate manual backup** (if Prometheus healthy)
   ```bash
   sudo -u prometheus /usr/local/bin/prometheus_backup.sh
   ```

4. **Notify team** - Data may need to be restored from alternative sources

5. **Root cause analysis** - Review logs, check storage

---

## Contacts

- Primary: Operations Team (#prometheus-ops)
- Escalation: Platform Team
- Documentation: https://docs.example.com/prometheus-backup

---

**Last Updated:** 2025-11-19
**Owner:** Platform/SRE Team
