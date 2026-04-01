# Nginx proxy for hosted Symphony dashboard

`stream.cash.symphony-proxy.conf` is the versioned source of truth for the hosted Symphony
dashboard route on `stream.cash`.

## Assumptions

- Symphony listens on `127.0.0.1:4101`
- The runtime sets `SYMPHONY_SERVER_HOST=0.0.0.0`
- The runtime sets `SYMPHONY_SERVER_PATH=/proxy/symphony`
- The public endpoint uses `SYMPHONY_PUBLIC_PATH=/proxy/symphony`
- The dashboard and API stay mounted upstream at `/` and `/api/v1/*`

## Install on `stream.cash`

1. Copy the repo-managed include into nginx snippets:

   ```bash
   sudo install -D -m 0644 \
     elixir/deploy/nginx/stream.cash.symphony-proxy.conf \
     /etc/nginx/snippets/stream.cash-symphony-proxy.conf
   ```

2. Include it from the existing TLS vhost for `stream.cash`:

   ```nginx
   server {
       server_name stream.cash;
       include /etc/nginx/snippets/stream.cash-symphony-proxy.conf;
   }
   ```

3. Validate and reload nginx:

   ```bash
   sudo nginx -t
   sudo systemctl reload nginx
   ```

## Expected behavior

- `https://stream.cash/proxy/symphony` redirects to `/proxy/symphony/`
- `https://stream.cash/proxy/symphony/` proxies dashboard HTML and static assets to
  `http://127.0.0.1:4101/`
- `https://stream.cash/proxy/symphony/live/*` preserves websocket upgrade traffic for LiveView
- Forwarded headers stay intact: `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Host`,
  `X-Forwarded-Port`, `X-Forwarded-Proto`

## Repo-level validation

Run the versioned validation path from the repo root:

```bash
make symphony-dashboard-checks
make symphony-nginx-proxy-contract
make symphony-nginx-proxy-smoke
```

`make symphony-dashboard-checks` proves the Symphony dashboard emits `/proxy/symphony/...` asset and
LiveView URLs. `make symphony-nginx-proxy-contract` validates the committed nginx include on any
repo clone without requiring a local nginx install. `make symphony-nginx-proxy-smoke` replays the
HTTP path rewrite plus websocket upgrade through a disposable local nginx runtime and requires
either `nginx` on `PATH` or `NGINX_BIN` pointing at an executable nginx binary.
