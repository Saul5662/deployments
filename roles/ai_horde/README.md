# AI-Horde Deploy Role

Deploys the **AI-Horde backend** (Flask + PostgreSQL + Redis) as a standalone
Docker Compose stack natively managed via the Ansible `community.docker.docker_compose_v2` module.

> **Scope:** This role is purpose-built for the
> [AI-Horde](https://github.com/Haidra-Org/AI-Horde) application. It is not a
> general-purpose Flask, PostgreSQL, or Redis deployment role. 
> Schema migrations, backups, replication, and database tuning are explicitly out of scope.

## How It Works
The role pulls the configured backend image and renders a Docker Compose project with:
1. One or more AI-Horde backend containers (replica count from `ai_horde_replicas`).
2. A bundled local PostgreSQL container.
3. A bundled local Redis container.

The setup utilizes **Docker Compose native orchestration**. The system does not use `systemd` wrapper units for the container lifecycles, completely sidestepping daemon conflicts.

This role also configures the environment to automatically plumb OpenTelemetry and Pyroscope traffic via `host.docker.internal` directly out to your host (which expects an agent like Grafana Alloy listening on port 4318).

## Deploy Mode Overview
This role is Docker-only.

**Scaling note:** Replica count is applied by the Ansible
`community.docker.docker_compose_v2` module using `scale`.
The compose file intentionally does not rely on `deploy.replicas`.

If you set `ai_horde_replicas: 4`, the role publishes a host port range for
the backend (for example `7001-7004` mapped to container port `7001`).

## Requirements
- **Docker Compose V2** (V1 is end-of-life).
- **Ansible 2.14+**
- `community.docker` Ansible collection (`ansible-galaxy collection install community.docker`).

## HAProxy / LB (Bring Your Own Proxy)
The previous intricate marker-based text insertion (`safe_edit`) HAProxy automation has been removed for maintainability. 
This role exposes the AI Horde instances on the host (by default `127.0.0.1:7001`). You are expected to configure your own HAProxy, Nginx, or cloud LB to point traffic to these local ports.

## Core Role Variables
| Variable                  | Default                                       | Description                                      |
| ------------------------- | --------------------------------------------- | ------------------------------------------------ |
| `ai_horde_image`          | `ghcr.io/haidra-org/ai-horde:main`            | Docker image to deploy                           |
| `ai_horde_port`           | `7001`                                        | Base HTTP port                                   |
| `ai_horde_listen`         | `127.0.0.1`                                   | Bind address for host port mapping               |
| `ai_horde_replicas`       | `1`                                           | Number of backend container replicas             |
| `ai_horde_waitress_threads`| `45`                               | Number of Waitress threads per replica |

### Observability / Telemetry (observability branch)
Variables governing OpenTelemetry (traces/metrics), Pyroscope (continuous profiling), and Logfire.

| Variable                  | Default                                       | Description                                      |
| ------------------------- | --------------------------------------------- | ------------------------------------------------ |
| `ai_horde_otel_service_name` | `ai-horde`                                 | Override for grouping/tracing UI                 |
| `ai_horde_otel_sdk_disabled` | `"false"`                                  | Set to "true" to disable OTEL totally            |
| `ai_horde_pyroscope_enabled` | `"false"`                                  | Set to "true" to stream continuous profiling (requires pyroscope-io in the image) |
| `ai_horde_deployment_environment`| `production`                             | Tag for separating dev/staging clusters          |

### BYOP (Bring Your Own Proxy)

The `ai_horde` role relies on Docker Compose V2 for container orchestration.
Ports are bound to `127.0.0.1` by default using the `ai_horde_listen` variable (e.g., `127.0.0.1:7001` or `127.0.0.1:7001-7002` if replicas > 1).
You can then run a reverse proxy of your choice (HAProxy, Nginx, Caddy, etc) to front the application.

> **Note:** When OTEL is enabled (the default), containers send telemetry
> directly to the host Alloy agent via Docker's `host.docker.internal`
> bridge gateway. Alloy's OTLP receiver must be bound to an address
> reachable from Docker (the default `0.0.0.0` in `horde_alloy` handles
> this). No intermediate proxy is needed for telemetry traffic.

If you have HAProxy running locally (e.g. from the `proxies/haproxy` role), ensure it connects to the `ai_horde_listen` `ai_horde_port` addresses.

Example Nginx config:

```nginx
upstream horde {
  server 127.0.0.1:7001;
  server 127.0.0.1:7002;
}

server {
  listen 80;
  server_name horde.internal;
  
  location / {
    proxy_pass http://horde;
  }
}
```

