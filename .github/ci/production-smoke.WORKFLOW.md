---
tracker:
  kind: memory
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
server:
  host: 0.0.0.0
---

Smoke-only workflow used by CI to verify that the production image starts and serves `/api/v1/state`.

