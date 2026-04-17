# HAProxy Topology Guidance

This document covers HAProxy topology decisions for the `ai_horde` role.
For variable reference and basic usage, see
[roles/ai_horde/README.md](../roles/ai_horde/README.md).

## conf.d Architecture

HAProxy configuration is managed via **conf.d drop-in fragments**. When
`ai_horde_install_haproxy: true`, the role:

1. Includes the shared `_haproxy_confd_bootstrap` micro-role to install
   HAProxy, create `/etc/haproxy/conf.d/`, and write a systemd override
   that loads all fragments from `conf.d/` alongside the main config.
2. Templates the AI-Horde frontend/backend block to
   `/etc/haproxy/conf.d/ai_horde.cfg`.
3. Restarts HAProxy when the fragment changes.

This approach is safe on shared hosts — each role drops its own fragment
into `conf.d/` without touching unrelated configuration.

## Topology Guidance

- **Shared hosts** with existing HAProxy config: use
  `ai_horde_install_haproxy: true` with a non-privileged ingress port
  (for example `8080`). The conf.d fragment coexists with other services.
- **Dedicated ingress hosts**: the same conf.d approach works; use
  privileged ports if appropriate.
- **Managed reverse proxy environments**: prefer upstream ingress and keep
  `ai_horde_install_haproxy: false` unless local HAProxy is explicitly needed.

## Privileged Binding

Binding ports below `1024` (for example `80/443`) is privileged and may
conflict with existing ingress services. Validate ownership, firewall rules,
and certificate strategy before enabling.

## Reverse-Proxy Layering

Copy/paste baseline for running AI-Horde behind an upstream reverse proxy:

```yaml
ai_horde_install_haproxy: true
ai_horde_haproxy_port: 8080
ai_horde_listen: "127.0.0.1"
```

In this pattern, your upstream reverse proxy owns `80/443` and forwards API
traffic to AI-Horde on `:8080`.

## Operator Decision Matrix

| Topology | HAProxy setup | Baseline ingress port | Notes |
| ---- | ---- | ---- | ---- |
| Single-host lab | `install_haproxy: true` | `8080` | Lowest-conflict local baseline; easy to place another proxy in front later. |
| Shared host with existing HAProxy | `install_haproxy: true` | `8080` | conf.d fragment coexists with other service configs. |
| Dedicated ingress host | `install_haproxy: true` | `80` (and/or `443` via external TLS strategy) | Full config ownership is acceptable when no other stack owns HAProxy. |
| Managed reverse proxy upstream | `install_haproxy: false` | Upstream-owned | Keep AI-Horde behind upstream ingress; avoid duplicate proxy ownership. |
