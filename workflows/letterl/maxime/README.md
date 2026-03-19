# LetterL Maxime Workflows

These workflows route Symphony only to Maxime's tickets in the selected LetterL projects.

Linear assignee id:

- `4eb8c4a3-8050-4af2-aa2b-da38d903c941`

Projects:

- `izvlechenie-zadach-8209c2018e76` -> `izvlechenie-zadach.WORKFLOW.md`
- `platforma-i-integraciya-448570ee6438` -> `platforma-i-integraciya.WORKFLOW.md`
- `master-komand-dfbe2b1b972e` -> `master-komand.WORKFLOW.md`

Notes:

- These files keep the current LetterL workflow unchanged.
- PR handoff uses `In Review` instead of `Human Review`.
- Auth and permission blockers move the issue to `Blocked`.
- Each Symphony process must use its own workspace root, logs root, and dashboard port.
- `gh auth status` is currently failing in this environment. Fix GitHub auth before launching unattended workers.

Suggested ports:

- `4101` -> `izvlechenie-zadach.WORKFLOW.md`
- `4102` -> `platforma-i-integraciya.WORKFLOW.md`
- `4103` -> `master-komand.WORKFLOW.md`

Launch template:

```bash
export LINEAR_API_KEY=...
export SYMPHONY_WORKSPACE_ROOT=/srv/symphony/workspaces/izvlechenie-zadach-maxime

cd /path/to/symphony/elixir
mise exec -- ./bin/symphony /path/to/repo/workflows/letterl/maxime/izvlechenie-zadach.WORKFLOW.md \
  --port 4101 \
  --logs-root /var/log/symphony/izvlechenie-zadach-maxime \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Repeat with a different `SYMPHONY_WORKSPACE_ROOT`, `--port`, `--logs-root`, and workflow path for the other two projects.
