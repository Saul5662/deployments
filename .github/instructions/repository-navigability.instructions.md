---
description: "Use when you need a high-level map of the deployments repository, including role ownership and where to find docs, examples, tests, and local-deploy assets."
---

# Deployments Repository Navigability

This document gives a fast mental model of the repository so contributors can
find the right folder before making changes.

## Top-level structure

| Path | What it contains | Use it when you need to... |
| ---- | ---------------- | -------------------------- |
| `roles/` | Ansible roles that implement deploy behavior | Change how services are installed, configured, or managed |
| `examples/` | Example playbooks and inventory templates | Start from a known-good playbook/inventory pattern |
| `docs/monitoring/` | Monitoring operations runbooks (backup, credentials, migration, upgrades) | Operate or troubleshoot observability stack behavior |
| `docs/plans/` | Design and implementation plans, audits, and follow-ups | Understand why changes were made and what remains |
| `tests/` | Render, integration, and full-stack test harness | Validate role output and cross-role behavior |
| `local-deploy/` | Local runtime layout for rendered configs, compose overlays, and local stack runs | Run integration/full-stack local deployments and inspect generated assets |
| `meta/` | Collection metadata and runtime metadata | Check collection-level metadata and compatibility |
| `.github/` | CI workflows and repository instructions | Update automation and contributor guidance |

## Role map

### Application and edge roles

| Role path | Purpose |
| --------- | ------- |
| `roles/ai_horde/` | AI Horde backend deployment (Docker or native systemd mode) |
| `roles/aihorde_frontpage/` | AiHordeFrontpage deployment |
| `roles/artbot/` | Artbot web frontend deployment |
| `roles/artbot_revproxy/` | HAProxy reverse proxy for Artbot |
| `roles/horde_regen_worker/` | AI Horde worker deployment |
| `roles/amd_gpu_drivers/` | AMD GPU driver and ROCm setup |

### Monitoring and telemetry roles

| Role path | Purpose |
| --------- | ------- |
| `roles/horde_monitoring/` | Monitoring stack deployment (Mimir, Grafana, and optional Loki/Tempo components) |
| `roles/horde_alloy/` | Grafana Alloy telemetry collection on application hosts |
| `roles/horde_stats_exporter/` | AI Horde API to Prometheus exporter service |

### Utility role

| Role path | Purpose |
| --------- | ------- |
| `roles/geerlingguy.swap/` | Third-party swap configuration role used as an infrastructure dependency |

## Meta folders to know first

### `examples/`

- Contains runnable playbooks for common scenarios (`ai_horde.yml`,
  `full_horde_stack.yml`, monitoring stack, worker, and frontpage).
- Includes inventory templates (`inventory.yml`, `inventory_monitoring.yml`) and
  collection requirements examples.

### `docs/`

- `docs/monitoring/` is operations-focused documentation for production care.
- `docs/plans/` contains implementation plans, architecture notes, and audits.
- Prefer docs in this folder for intent and operations; prefer `roles/*` for
  source-of-truth implementation behavior.

### `tests/`

- `tests/run_tests.sh` is the main entrypoint for render tests.
- Subfolders group scenarios by concern (`ai_horde/`, `monitoring/`,
  `integration/`, `full_stack/`, etc.).
- `tests/test-results/` stores timestamped logs and machine-readable summaries.

### `local-deploy/` (purpose and boundaries)

- Serves as the local deployment workspace used by integration and full-stack
  scripts (`tests/integration/local_deploy.sh`,
  `tests/full_stack/local_deploy.sh`).
- Holds rendered configuration outputs and Docker Compose topology files for
  local runs.
- May contain local checkouts under `*/src` and runtime artifacts during local
  testing.
- Treat role templates and tasks under `roles/` as authoritative for deployment
  logic; treat `local-deploy/` as the operational surface for local execution.

## Quick navigation by task

| If you need to... | Start in... |
| ----------------- | ----------- |
| Modify deployment behavior | `roles/<role_name>/` |
| Find variable defaults | `roles/<role_name>/defaults/main.yml` |
| See usage examples | `examples/` |
| Run or update tests | `tests/` |
| Run local stack orchestration | `tests/integration/` or `tests/full_stack/` and `local-deploy/` |
| Understand monitoring operations | `docs/monitoring/` |
| Review roadmap and implementation rationale | `docs/plans/` |

## Planning Artifact Placement

- Temporary action lists, triage notes, and punch lists belong in this
  directory (`docs/plans/`) or in the issue tracker — not at the
  repository root.
- Each plan set should have its own subdirectory with a `README.md` index
  (see `maintainability-gaps/` for the pattern).
- The repository root should contain only durable project-level files
  (README, LICENSE, CHANGELOG, config files).
