# Staging Setup On Shared VPS

This runbook prepares a separate `staging` Symphony stack on the same VPS where production already runs.

## 1. Create staging directories and env files on VPS

Run on host (`root`):

```bash
mkdir -p /srv/symphony-staging/{deploy,codex-home,workflows,workspaces,logs} /etc/symphony-staging
install -m 0600 /etc/symphony/symphony.env /etc/symphony-staging/symphony.env
install -m 0600 /etc/symphony/compose.env /etc/symphony-staging/compose.env
```

Then replace `/etc/symphony-staging/compose.env` with
`elixir/deploy/docker/compose.staging.env.example` values.

Minimum required differences from production:

- `SYMPHONY_COMPOSE_PROJECT=symphony-staging`
- `SYMPHONY_CONTAINER_NAME=symphony-staging`
- `SYMPHONY_PORT=4102`
- `SYMPHONY_SERVER_PATH=/proxy/symphony-staging`
- `SYMPHONY_PUBLIC_PATH=/proxy/symphony-staging`
- `SYMPHONY_CODEX_HOME_HOST_PATH=/srv/symphony-staging/codex-home`
- `SYMPHONY_WORKFLOW_HOST_PATH=/srv/symphony-staging/workflows`
- `SYMPHONY_WORKSPACE_HOST_PATH=/srv/symphony-staging/workspaces`
- `SYMPHONY_LOGS_HOST_PATH=/srv/symphony-staging/logs`
- `SYMPHONY_RUNTIME_ENV_FILE=/etc/symphony-staging/symphony.env`

## 2. Configure reverse proxy path

Add staging location(s) to nginx so
`/proxy/symphony-staging/` proxies to `127.0.0.1:4102`.

## 3. GitHub environment values

`staging` environment values should stay:

- `SYMPHONY_DEPLOY_COMPOSE_FILE=/srv/symphony-staging/deploy/docker-compose.yml`
- `SYMPHONY_DEPLOY_ENV_FILE=/etc/symphony-staging/compose.env`
- `SYMPHONY_DEPLOY_HEALTHCHECK_URL=http://127.0.0.1:4102/api/v1/state`
- `SYMPHONY_DEPLOY_PUBLIC_URL=https://stream.cash/proxy/symphony-staging/`
- `SYMPHONY_DEPLOY_HOST=185.170.198.69`
- `SYMPHONY_DEPLOY_USER=root`
- `SYMPHONY_DEPLOY_SSH_PORT=22`

`SYMPHONY_DEPLOY_ENABLED=false` until host setup and nginx are complete.

## 4. First deploy check

1. Run `deploy-staging` manually with a known good `image_tag` + `image_digest`.
2. Confirm `http://127.0.0.1:4102/api/v1/state` on host returns `200`.
3. Confirm public URL path responds through nginx.
4. Set `SYMPHONY_DEPLOY_ENABLED=true` for staging.
