# Local Deploy Workspace Layout

This folder is split into committed vs generated content.

- `local-deploy/static/`
  - Version-controlled files used by local deploy scripts/tests.
  - Contains network overlays and static HAProxy configuration.
- `local-deploy/runtime/`
  - Generated configs, cloned source trees, secrets, and runtime data.
  - Created/updated by `tests/*/local_deploy.sh` scripts.
  - Safe to delete when you want a clean local deploy state.

Quick reset:

```bash
rm -rf local-deploy/runtime
```

If you still have legacy generated directories directly under `local-deploy/`
from older workflows, remove everything except `static/` and this README:

```bash
find local-deploy -mindepth 1 -maxdepth 1 ! -name static ! -name README.md -exec rm -rf {} +
```

After reset, re-run any local deploy script (for example
`./tests/full_stack/local_deploy.sh up`) to re-render and restart.
