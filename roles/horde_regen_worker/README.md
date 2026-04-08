# AI Horde regen Worker

Deploys all the necessary components to turn a Debian-based Linux server into
an [AI Horde worker](https://github.com/Haidra-Org/horde-worker-regen)
instance running via systemd.

> **Scope:** This role deploys the AI Horde worker specifically. It is not a
> general-purpose GPU workload or Python service role. GPU drivers (CUDA or
> ROCm) must be installed separately before running this role. The worker
> runs as an unprivileged systemd user service and does not require root
> access at runtime.

The default variables contain all the arguments required for a worker's [bridgeData](https://github.com/Haidra-Org/horde-worker-regen/blob/main/bridgeData_template.yaml) so you can provide any of them in your role variables to override the defaults from the template.

In addition you can pass the following 2 vars

- `horde_regen_worker_username`: The worker service runs in userspace via systemd under this account. It does not need root or sudo access.
- `horde_regen_worker_environment`: Optional environment variables passed to the worker process (for example `ROCR_VISIBLE_DEVICES=0`).

The role fails fast if `horde_regen_worker_api_key` is left at its default placeholder value. Set a real worker API key in inventory or vault variables.

# Instructions

1. Prepare a debian-based linux server with a GPU.
1. Make a playbook to call the relevant roles. An example `examples/regen_worker.yml` playbook has been provided.
1. Create an ansible inventory `inventory.yml` with your host address and worker variables. An example has been provided in `examples/inventory.yml` which you can copy and modify
1. Run the ansible-playbook

```bash
ansible-playbook regen_worker.yml -i inventory.yml
```
