# Docker deploy contract

`docker-compose.yml` is now a production-oriented runtime contract. The host no longer builds the
application image locally; it only pulls a CI-validated image reference (`tag` + immutable
`digest`) produced by GitHub Actions.

## Files

- `docker-compose.yml` uses portable env-backed mount points, workflow paths, runtime roots, and
  image references.
- `compose.env.example` documents the host-side variables used by `docker compose`.
- `symphony.runtime.env.example` documents the container runtime secrets that must stay outside the
  repository.

## Required host files

1. Copy the compose interpolation example and fill the host-specific values:

   ```bash
   sudo install -D -m 0600 \
     elixir/deploy/docker/compose.env.example \
     /etc/symphony/compose.env
   ```

2. Copy the runtime secret example and fill the secrets:

   ```bash
   sudo install -D -m 0600 \
     elixir/deploy/docker/symphony.runtime.env.example \
     /etc/symphony/symphony.env
   ```

3. Ensure the deploy user can create or overwrite the configured compose path
   (`SYMPHONY_DEPLOY_COMPOSE_FILE`). `deploy-production` now syncs the checked-in
   `docker-compose.yml` to that remote path on every deploy, so you do not need a separate
   manual copy step for contract updates.

## CI/CD flow

1. `release-image` builds the production image with `MIX_ENV=prod`.
2. CI smoke-tests `/api/v1/state` from the built image.
3. On `main`, CI pushes the exact validated image to GHCR and uploads
   `production-image-contract.json`.
4. `deploy-production` downloads that contract, waits on the `production` GitHub Environment, and
   runs `scripts/symphony_deploy.sh`.
5. The deploy script validates the checked-in workflow contract, syncs both the active workflow
   file and the checked-in compose contract to the host, pulls the digest-pinned image, recreates
   the Compose service, and verifies the post-deploy health endpoint plus required
   `codex_accounts`.
6. The post-release proof is complete only after `/api/v1/state` echoes the deployed `release`
   block (`git_sha`, `image_tag`, `image_digest`) that matches the published image contract.

## Environment approvals

Use a `production` GitHub Environment with required reviewers and environment-scoped secrets or
variables:

- `SYMPHONY_DEPLOY_ENABLED=true`
- `SYMPHONY_DEPLOY_HOST`
- `SYMPHONY_DEPLOY_USER`
- `SYMPHONY_DEPLOY_SSH_PORT`
- `SYMPHONY_DEPLOY_COMPOSE_FILE`
- `SYMPHONY_DEPLOY_ENV_FILE`
- `SYMPHONY_DEPLOY_HEALTHCHECK_URL`
- `SYMPHONY_DEPLOY_PUBLIC_URL`
- `SYMPHONY_DEPLOY_KNOWN_HOSTS` (secret)
- `SYMPHONY_DEPLOY_SSH_KEY` (secret)
- `SYMPHONY_REGISTRY_USERNAME` (secret)
- `SYMPHONY_REGISTRY_PASSWORD` (secret)

Optional hooks:

- `SYMPHONY_DEPLOY_PRE_UP_COMMAND`
- `SYMPHONY_DEPLOY_POST_UP_COMMAND`

`SYMPHONY_DEPLOY_PRE_UP_COMMAND` is where a future schema or migration step should run. The
current Symphony runtime does not have an application database migration, so the default remains a
no-op.

## Rollout order

1. Review the `production-image-contract.json` artifact from the `release-image` workflow.
2. Approve the `production` environment in GitHub.
3. Let `deploy-production` sync the checked-in compose contract, pull the digest-pinned image, and
   run `docker compose up -d`.
4. Confirm the workflow artifact shows a successful health response.
5. Confirm `/api/v1/state` returns a `release` block that matches the deployed contract.
6. If nginx fronts the dashboard, keep the versioned include from `../nginx/README.md` in sync.

## Rollback

Rollback is the same deployment path with an older contract:

1. Find the previous `production-image-contract.json` artifact.
2. Re-run `deploy-production` via `workflow_dispatch` with that artifact's `image_tag` and
   `image_digest`.
3. The workflow reuses the same SSH, Compose, and health-check path, so rollback is auditable and
   symmetric with forward deploys.
