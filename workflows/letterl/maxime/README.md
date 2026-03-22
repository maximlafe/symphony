# LetterL Maxime Workflows

These workflows route Symphony only to Maxime's tickets in the selected LetterL projects.

Linear assignee id:

- `4eb8c4a3-8050-4af2-aa2b-da38d903c941`

Projects:

- `izvlechenie-zadach-8209c2018e76` -> `izvlechenie-zadach.WORKFLOW.md`
- `platforma-i-integraciya-448570ee6438` -> `platforma-i-integraciya.WORKFLOW.md`
- `master-komand-dfbe2b1b972e` -> `master-komand.WORKFLOW.md`

Notes:

- `izvlechenie-zadach.WORKFLOW.md` now supports an experimental per-issue base-branch override from the Linear issue description:
  - add a `## Symphony` section;
  - add one line `Base branch: feature/...`;
  - if the line is missing, the worker stays unattended and falls back to the repo default branch;
  - if the line is invalid or the branch does not exist, the task moves into the blocker path instead of silently picking another branch.
- The other two workflow files keep the previous LetterL behavior and do not read `Base branch:` from the issue description.
- PR handoff uses `In Review` instead of `Human Review`.
- Auth and permission blockers move the issue to `Blocked`.
- Each Symphony process must use its own workspace root, logs root, and dashboard port.
- Worker bootstrap now runs `make symphony-bootstrap` inside the cloned `lead_status` repo, so the repo must expose that target on the branch Symphony clones.
- Docker on the VPS should mount `/srv/symphony/app/workflows/letterl/maxime` directly into `/srv/symphony/workflows`, so the active worker rules stay aligned with the checked-out repo.

Required `/etc/symphony/symphony.env` contract for these workers:

- Required: `LINEAR_API_KEY`, `GH_TOKEN`, `OPENAI_API_KEY`, `DATABASE_URL`
- Optional for Gemini-backed runtime flows only: `GEMINI_API_KEY` and related Gemini tuning env vars
- `GH_TOKEN` is the default unattended Git transport contract; the workflows no longer rely on a local `file://` fallback.

Suggested preflight before launch:

- `gh auth status`
- verify `git clone`/`git ls-remote` for the configured `SOURCE_REPO_URL` work without prompts
- confirm `DATABASE_URL` points to reachable PostgreSQL
- confirm Node/npm are installed in the container image
- confirm Playwright browser bootstrap can run in a fresh workspace

Suggested ports:

- `4101` -> `izvlechenie-zadach.WORKFLOW.md`
- `4102` -> `platforma-i-integraciya.WORKFLOW.md`
- `4103` -> `master-komand.WORKFLOW.md`

Launch template:

```bash
export LINEAR_API_KEY=...
export GH_TOKEN=...
export OPENAI_API_KEY=...
export DATABASE_URL=postgresql://...
export SYMPHONY_WORKSPACE_ROOT=/srv/symphony/workspaces/izvlechenie-zadach-maxime

cd /path/to/symphony/elixir
mise exec -- ./bin/symphony /path/to/repo/workflows/letterl/maxime/izvlechenie-zadach.WORKFLOW.md \
  --port 4101 \
  --logs-root /var/log/symphony/izvlechenie-zadach-maxime \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Repeat with a different `SYMPHONY_WORKSPACE_ROOT`, `--port`, `--logs-root`, and workflow path for the other two projects.
