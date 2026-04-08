# Artbot RevProxy

Deploys an HAProxy reverse proxy with TLS termination for the Artbot service.

> **Scope:** This role manages both the reverse proxy (HAProxy) and TLS
> certificates (Let's Encrypt or self-signed) because the Artbot topology
> always co-locates them. It is not a general-purpose HAProxy or certificate
> management role. If you already have your own reverse proxy or TLS setup,
> skip this role and point your existing proxy at the Artbot port.

The reverse proxy config is separated from the artbot service deployment code
in different roles, in case you want to provide your own haproxy configuration
or other reverse proxy configuration.

# Instructions

1. Register a domain
1. Point a DNS A-record to your server which will run the artbot revproxy.
   If this is not the same server where [artbot](../artbot/README.md) service will be running, you'll need to pass the relevant `artbot_server` variable in your `vars`
1. Make a playbook to call the relevant roles. An example `examples/artbot.yml` playbook has been provided where you can adjust only what's needed to run an artbot and revproxy together.
1. Create an ansible inventory `inventory.yml` with your host address. An example has been provided in `examples/inventory.yml` which you can copy and modify
1. Run the ansible-playbook

```bash
ansible-playbook artbot.yml -i inventory.yml
```
