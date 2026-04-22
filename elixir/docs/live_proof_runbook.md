# Symphony Live Proof Runbook

This runbook defines the smallest sufficient live proof for each external surface in Symphony.

## Policy

- Use a local-first order. New behavior should not be proven for the first time on production.
- Start with the cheapest sufficient proof. Only add a heavier surface when the change really
  touches that contract.
- Live proof is additive. It does not replace deterministic tests, targeted reproductions, or the
  normal repo validation gate.
- When a change touches multiple external contracts, run one proof per contract.

## Runtime Smoke Then Live Proof

- Treat `runtime smoke` as the first runtime proof on the same `HEAD` for runtime, infra,
  workflow-contract, and handoff changes.
- Add live proof only when the same change also touches an external contract that local runtime
  smoke does not prove by itself.
- Do not swap one for the other: runtime smoke proves the local contract path first; live proof
  proves the specific external surface after the local proof is already green.

## Order Of Operations

1. Run the local repo gate for the change, including the targeted proof and any required local
   runtime smoke from the validation matrix.

   ```bash
   make symphony-preflight
   make symphony-validate
   ```

2. Add the smallest live proof from the matrix below.
3. Deploy only after the local and live proofs pass.
4. Run post-deploy proof only for production-specific surfaces.

## Surface Matrix

| Surface | Run Where | Use When | Command / Procedure | Pass Signal |
| --- | --- | --- | --- | --- |
| Linear + real Codex end-to-end | Local machine | A change touches real Linear polling, issue state transitions, issue comments, or requires a real `codex app-server` turn | `cd elixir && export LINEAR_API_KEY=... && SYMPHONY_RUN_LIVE_E2E=1 make e2e` | The test creates a disposable Linear project and issue, runs a real agent turn, writes the expected workspace file, posts the expected Linear comment, and moves the issue to a completed state |
| Review-ready / handoff / PR state | Local machine | A change touches `symphony_handoff_check`, verification manifests, review-ready transitions, workpad digest enforcement, or PR-linked handoff behavior | `ISSUE_ID=LET-... WORKPAD_FILE=/abs/path/workpad.md REPO=maximlafe/symphony PR_NUMBER=123 make symphony-handoff-check` | The command exits `0` and prints a successful manifest for the current workpad / issue / PR combination |
| Dashboard and observability API | Local machine | A change touches dashboard rendering, presenter payloads, observability API output, or `server.path` handling | `make symphony-dashboard-checks` | The dashboard-focused deterministic slice passes |
| Hosted nginx proxy contract | Local machine | A change touches the reverse-proxy include, public path rewriting, websocket upgrade handling, or hosted dashboard assumptions | `make symphony-nginx-proxy-contract` and, when `nginx` is available, `make symphony-nginx-proxy-smoke` | The committed nginx include validates and the disposable replay proves redirect, HTTP rewrite, and websocket upgrade behavior |
| Production image startup contract | GitHub Actions CI | A change touches Docker image startup, runtime boot, release metadata, or image-level runtime contract | Let `.github/workflows/release-image.yml` run | The workflow builds the production image and the image exposes `/api/v1/state` during CI smoke |
| Production deploy health contract | GitHub Actions -> VPS | A change touches deploy wiring, Compose/runtime env, remote health checks, required Codex accounts, or digest-pinned rollout behavior | Let `.github/workflows/deploy-production.yml` run after local proof passes and approve the `production` environment when needed | The deploy workflow completes, the remote health check responds successfully, required `codex_accounts` validate, and the deployed `/api/v1/state` release block matches the deployed image contract |
| Public reverse-proxy URL | Manual post-deploy check | A change touches the public host, TLS vhost, public URL routing, or production reverse-proxy behavior | Fetch the public dashboard URL and the public state URL, for example `curl -fsS "${SYMPHONY_DEPLOY_PUBLIC_URL%/}/api/v1/state"` when the public base URL already includes `/proxy/symphony` | The public route serves the dashboard and the public state endpoint responds with the expected release metadata |

## Surface Notes

### 1. Linear + Real Codex End-To-End

- This is a local run, not a VPS run.
- `AgentRunner.run(...)` executes on the machine where you launch `make e2e`.
- The test uses real Linear resources and a real `codex app-server`, but it writes a temporary
  `WORKFLOW.md` and disposable workspace under `System.tmp_dir!()`.
- By default the live test uses the disposable Linear team key `SYME2E`. Override with
  `SYMPHONY_LIVE_LINEAR_TEAM_KEY` only when you intentionally want another dedicated test team.

### 2. Review-Ready / Handoff / PR State

- This is the smallest sufficient proof when the risky part is the review-ready contract, not the
  full issue polling lifecycle.
- It requires real identifiers for the Linear issue and the GitHub PR because the contract reads
  live issue context and PR-linked verification inputs.
- Re-run it after changing the workpad because the workpad digest is part of the handoff manifest.

### 3. Dashboard And Observability API

- This is the right proof for dashboard, presenter, and API payload changes.
- It is still local-first and cheaper than a hosted smoke because it does not depend on live
  external services.
- If the change also touches nginx or public-path routing, add the hosted nginx proxy proof.

### 4. Hosted Nginx Proxy Contract

- `make symphony-nginx-proxy-contract` is the required contract check.
- `make symphony-nginx-proxy-smoke` is the local replay when you have `nginx` available or set
  `NGINX_BIN`.
- Use both when a change affects `/proxy/symphony`, websocket upgrades, or versioned nginx config.

### 5. Production Image Startup Contract

- This is not a replacement for local proof. It is the first CI-level external proof after local
  validation passes.
- Use it when the risk sits in the image or runtime boot path rather than in Linear or handoff.

### 6. Production Deploy Health Contract

- This proof only belongs after local-first checks are green.
- It validates the remote host path that local tests cannot prove: SSH rollout, remote Compose
  wiring, env-backed runtime config, remote health endpoint, and required Codex accounts.
- The deploy contract is not complete until the deployed `/api/v1/state` echoes the expected
  `git_sha`, `image_tag`, and `image_digest`.

### 7. Public Reverse-Proxy URL

- This is currently a manual post-deploy proof. The repository backlog still calls out a future
  dedicated synthetic smoke for the public reverse-proxy URL.
- Use it only for production-specific routing proof after deploy, never as the first proof for new
  behavior.

## Choosing The Smallest Sufficient Proof

- Hooks, retry, stalled detection, resume checkpoints, workflow reload:
  stay local-first. Run local deterministic proof and the required `runtime smoke` first; add live
  proof only if the change also touches a real external contract.
- Linear lifecycle changes:
  add the Linear + real Codex end-to-end proof.
- Handoff / review-ready / PR-tail changes:
  add the handoff proof.
- Dashboard / observability payload changes:
  add dashboard checks.
- Proxy / public-path changes:
  add nginx proxy proof.
- Docker / deploy / remote runtime changes:
  add CI image startup proof and deploy proof.
- Public host routing changes:
  add the manual public reverse-proxy check after deploy.

## Current Gaps

- There is no dedicated reusable synthetic smoke yet for the public production reverse-proxy URL.
- There is no separate reusable GitHub-only live smoke outside the handoff contract; use
  `make symphony-handoff-check` when the review-ready path is the risky surface.
