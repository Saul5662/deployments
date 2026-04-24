---
description: "Use when creating or updating Ansible role tests, test playbooks, or local test harness files under tests/ and related role changes."
applyTo: "tests/**/*.yml,tests/**/*.sh,roles/**/tasks/*.yml,roles/**/defaults/*.yml"
---

# Ansible Role Testing Conventions

- Name automated test playbooks `test_*.yml` and place them in the matching domain folder under `tests/` (for example `tests/ai_horde/` or `tests/monitoring/`).
- Keep each test focused on one behavior slice (render contract, runtime health, policy contract, or cross-role integration).
- Default expectation is idempotency: test playbooks are re-run by `tests/run_tests.sh` and must report zero changed tasks on the second pass.
- Only skip idempotency when needed. If skip is intentional, add `# idempotency: skip` in the first 5 lines and explain the non-idempotent behavior in task names.
- If a test requires a Docker daemon inside the test container, mark it with `# requires: docker-daemon` in the first 5 lines so the harness can skip cleanly when unavailable.
- Prefer render-only tests by default (`start_services: false`) and assert outputs with `ansible.builtin.stat`, `ansible.builtin.slurp`, and `ansible.builtin.assert`.
- Use runtime tests (`start_services: true`) only for behavior that cannot be proven by rendering, and use explicit readiness checks (`ansible.builtin.uri` with retries and `until`).
- Validate security and contract invariants directly in tests (ports, bind addresses, auth settings, image pinning, permissions, ownership, and template content markers).
- Local developer orchestration belongs in `local_deploy.yml` plus `local_deploy.sh`; those files support manual validation and are not discovered by `tests/run_tests.sh`.
- Keep test logs analyzable. `tests/run_tests.sh` already writes per-test logs and `summary.txt` to `tests/test-results/<timestamp>/`; inspect those logs before re-running long suites.

# Existing Test Playbooks And Purpose

- `tests/ai_horde/test_ai_horde_render.yml`: Validates Docker mode rendering, security-sensitive compose/env contracts, and fail-fast password/key validation.
- `tests/ai_horde/test_ai_horde_integration.yml`: Validates Docker-mode rendering with service start, heartbeat checks, and end-to-end contract (requires docker-daemon).
- `tests/ai_horde/test_ai_horde_policy_contracts.yml`: Enforces reproducibility and policy contracts (pinned refs/digests, installer verification, readiness semantics).
- `tests/artbot/test_artbot_render.yml`: Validates Artbot rendering and HAProxy/certbot contract output.
- `tests/frontpage/test_frontpage_render.yml`: Validates Frontpage Docker-mode render contracts, env keys, healthcheck wiring, ports, and log rotation.
- `tests/frontpage/test_native_deploy.yml`: Validates Frontpage native deployment and systemd behavior.
- `tests/full_stack/test_fullstack_render.yml`: Validates full-stack render compatibility across AI Horde, Frontpage, and shared network assumptions.
- `tests/integration/test_integration_smoke.yml`: Validates basic cross-role integration contract between AI Horde and worker bridge configuration.
- `tests/monitoring/test_alloy_role.yml`: Validates Alloy role rendering for metrics/logs/traces collection and scrape/auth configuration.
- `tests/monitoring/test_backup_zstd.yml`: Validates monitoring retention, backup timer/service rendering, and related override behavior.
- `tests/monitoring/test_full_stack.yml`: Validates monitoring stack render outputs for full component topology and expected configuration content.
- `tests/monitoring/test_prometheus_only.yml`: Validates Mimir/Prometheus-focused deployment mode without full Grafana stack assumptions.
- `tests/monitoring/test_runtime_services.yml`: Validates runtime service health and live metrics push behavior for monitoring components.
- `tests/monitoring/test_stats_exporter_render.yml`: Validates horde_stats_exporter template rendering for config, systemd service unit, and logrotate.
- `tests/model_reference/test_model_reference_render.yml`: Validates horde_model_reference Docker Compose and env template rendering, including PRIMARY/REPLICA/multi-worker variants and fail-fast guards.
- `tests/model_reference/test_model_reference_policy_contracts.yml`: Enforces horde_model_reference policy contracts (defaults, port/bind safety, health-check semantics, secret hygiene, template markers).
- `tests/model_reference/test_model_reference_integration.yml`: Validates live horde_model_reference PRIMARY deployment — heartbeat and replicate_mode HTTP assertions (requires docker-daemon).
- `tests/regen_worker/test_regen_worker_render.yml`: Validates regen worker rendering contracts for bridge data and systemd unit output.

# Related Non-Discovered Harness Files

- `tests/ansible.cfg`: Performance-tuned Ansible configuration scoped to tests only. Sets `gathering = explicit` (no auto fact collection), `pipelining = True` (fewer round-trips per task), and `interpreter_python = auto_silent`. These settings are unsafe in production because several roles depend on gathered facts (`ansible_os_family`, `ansible_hostname`, `ansible_kernel`, `ansible_facts.processor_*`). The harness exports `ANSIBLE_CONFIG` pointing here; contributors who run `ansible-playbook` directly should either use `run_tests.sh` or set the env var manually.

# Test Coverage Map

All test playbooks are mapped to operator-risk categories in
`docs/plans/maintainability-gaps/test-coverage-map.md`. When adding or
modifying tests, include the applicable risk category in the test file header
and update the coverage map.

Risk categories: deploy-safety, security, fail-fast, reproducibility,
data-integrity, operational.

# Fact-Gathering Policy

The harness uses `gathering = explicit` in `tests/ansible.cfg`. Facts are NOT collected unless a play explicitly sets `gather_facts: true`.

- Test playbooks that exercise fact-dependent code paths MUST set `gather_facts: true` in the relevant play.
- Render-only tests that do not exercise fact-dependent logic should omit `gather_facts` (inheriting the explicit/off default) for speed.
- Roles that depend on gathered facts should include a guard assertion that fails clearly when required facts are missing.
- Known fact dependencies in roles:
  - `ansible_os_family`: `horde_alloy` (install.yml) — platform-conditional package installation.
  - `ansible_hostname`: `horde_alloy` (config.alloy.j2) — instance label in telemetry config.
  - `ansible_kernel`: `amd_gpu_drivers` (main.yml) — kernel header package names.
  - `ansible_facts.processor_*`: `ai_horde` (native.yml) — capacity advisory (defaults to 1 when absent).
- `tests/*/local_deploy.yml` and `tests/*/local_deploy.sh`: Local render and orchestration workflows for manual stack validation.
- `tests/integration/_render_bridge.yml`: Integration helper playbook used by shell harness scripts.
- `tests/Dockerfile.systemd` and `tests/inventory_docker.ini`: Containerized systemd test environment and inventory used by `tests/run_tests.sh`.