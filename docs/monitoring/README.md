# Monitoring Documentation

> **New to the monitoring stack?** Start with [MONITORING.md](../../MONITORING.md) for
> architecture overview and first deployment.

## What are you trying to do?

| Goal                                                                | Go to                                                                      |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Deploy the monitoring stack for the first time                      | [MONITORING.md](../../MONITORING.md)                                       |
| Understand the full topology, signal backends, and alert coverage   | [OBSERVABILITY.md](OBSERVABILITY.md)                                       |
| Set up or rotate credentials                                        | [CREDENTIALS.md](CREDENTIALS.md)                                           |
| Configure and test offsite backups                                  | [BACKUP.md](BACKUP.md)                                                     |
| Recover from a host failure or migrate to a new host                | [MIGRATION.md](MIGRATION.md)                                               |
| Upgrade a component (Mimir, Grafana, Loki, Tempo, Pyroscope, Alloy) | [UPGRADING.md](UPGRADING.md)                                               |
| Configure the monitoring role variables                             | [roles/horde_monitoring/README.md](../../roles/horde_monitoring/README.md) |
| Configure Grafana Alloy on application hosts                        | [roles/horde_alloy/README.md](../../roles/horde_alloy/README.md)           |

## Document Map

```
MONITORING.md             ← deployment guide, architecture overview, quickstart
docs/monitoring/
  README.md               ← this file — navigation index
  OBSERVABILITY.md        ← full topology, component toggles, data flows, alerting coverage
  BACKUP.md               ← backup scope, configuration, restore procedure
  MIGRATION.md            ← host migration runbook (planned / forced-with-backup / no-backup)
  UPGRADING.md            ← per-component upgrade procedures and version variables
  CREDENTIALS.md          ← credential surfaces, rotation procedures
roles/
  horde_monitoring/README.md  ← role variables reference (Mimir, S3, Grafana, Loki, Tempo, Pyroscope)
  horde_alloy/README.md       ← Alloy collector role variables reference
```

## Quick Health Check

```bash
curl -sf http://127.0.0.1:9009/ready   && echo "Mimir OK"
curl -sf http://127.0.0.1:3903/health  && echo "S3 OK"
curl -sf http://127.0.0.1:3000/api/health && echo "Grafana OK"
```
