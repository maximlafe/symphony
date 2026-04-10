# LetterL Maxime Workflow

This workflow routes Symphony only to Maxime's tickets in LetterL. `let.WORKFLOW.md` is the single team-scoped runner and resolves the target repository from structured Linear metadata instead of a `Repository:` line in the issue description.

Linear assignee id:

- `4eb8c4a3-8050-4af2-aa2b-da38d903c941`

Project routing:

- `symphony-bd5bc5b51675` -> `maximlafe/symphony`
- `izvlechenie-zadach-8209c2018e76` -> `maximlafe/lead_status`
- `master-komand-dfbe2b1b972e` -> `maximlafe/lead_status`
- `telegram-full-export-v2-a6212aeb565c` -> `maximlafe/tg_live_export`
- `platforma-i-integraciya-448570ee6438` -> requires one explicit repo label on the Linear issue:
  - `repo:lead_status`
  - `repo:symphony`
  - `repo:tg_live_export`

Notes:

- `let.WORKFLOW.md` polls LetterL by `tracker.team_key: LET` and routes workspaces by Linear project metadata:
  - fixed project mapping:
    - `Symphony` -> `maximlafe/symphony`
    - `Извлечение задач` -> `maximlafe/lead_status`
    - `Мастер команд` -> `maximlafe/lead_status`
    - `Telegram Full Export v2` -> `maximlafe/tg_live_export`
  - ambiguous project:
    - `Платформа и интеграция` requires exactly one repo label on the issue: `repo:lead_status`, `repo:symphony`, or `repo:tg_live_export`;
  - conflicting fixed-project mapping and repo label move the task into the blocker path;
  - unknown projects also move the task into the blocker path.
- `let.WORKFLOW.md` still supports per-issue base-branch routing from the Linear issue description:
  - add a `## Symphony` section;
  - keep `Repo: owner/name`, `Base branch: feature/...`, and optional `Working branch: feature/...` in that section whenever the description is normalized into task-spec form;
  - `Repo:` is an audit mirror of the resolved repository and must match the routing implied by project metadata and any required `repo:*` label;
  - if `Base branch:` is missing, the worker stays unattended and falls back to that repository's default branch;
  - if `Base branch:` is invalid or that branch does not satisfy the `make symphony-bootstrap` contract, the task moves into the blocker path instead of silently picking another branch or failing inside the workspace hook.
- `Todo` routing is label-driven:
  - `mode:research` -> `Todo -> Spec Prep -> Spec Review -> In Progress`;
  - `mode:plan` -> `Todo -> Spec Prep -> Spec Review -> In Progress`;
  - no `mode:*` -> `Todo -> In Progress`;
  - if both `mode:research` and `mode:plan` are present, `mode:research` wins;
  - once a ticket enters `In Progress`, `mode:*` labels no longer change the flow.
- `Spec Prep` and `Spec Review` remain as the opt-in analysis-only path for `mode:research`, `mode:plan`, and legacy spec-prep tickets; implementation-ready issues should skip them.
- `research-mode` and `plan-mode` are authored as repo-local Symphony skills and should be loaded from `.agents/skills/...` when present; for workspaces cloned from other LET-managed repos, fallback to the bundled copies under `$CODEX_HOME/skills/...`.
- When a run creates a fresh working branch, use `Working branch:` exactly when it is set; otherwise name it `Symphony/<lowercase issue identifier>-<short-kebab-summary>` instead of reusing Linear `gitBranchName` values such as `cycloid-yips0i/...`, and record branch lineage as `Новая ветка <branch> создана от origin/<base>`.
- PR titles for unattended runs should stay short and outcome-oriented in the form `<ISSUE-ID>: <clear shipped outcome>`.
- PR handoff uses `In Review` instead of `Human Review`.
- Auth and permission blockers move the issue to `Blocked`.
- `Blocked` is a manual gate: after a `decision` or `human-action` handoff is resolved, resume only when a human moves the issue back to `In Progress`; comments alone do not resume work.
- Live LetterL workflows are expected to run with `agent.max_concurrent_agents: 10`; dropping to `1` is only a temporary debugging override and should not remain in VPS runtime files.
- Each Symphony process must use its own workspace root, logs root, and dashboard port.
- Worker bootstrap now runs `make symphony-bootstrap` inside the selected allowlisted repo, so each supported repo must expose that target on the branch Symphony clones.
- Docker on the VPS should mount `/srv/symphony/app/workflows/letterl/maxime` directly into `/srv/symphony/workflows`, so the active worker rules stay aligned with the checked-out repo.
- `let.required_codex_accounts.txt` is the production account contract for `let.WORKFLOW.md`; CI and post-deploy smoke both fail if any listed account disappears from the workflow or `/api/v1/state`.
- Supported production shape is a single Docker-based `symphony-let` runner using `let.WORKFLOW.md`; legacy `symphony-task-extract`, `symphony-team-master`, and `symphony-platform` `systemd` units should stay retired so host-side `.WORKFLOW.md` copies cannot drift from the repo checkout.

Required `/etc/symphony/symphony.env` contract for these workers:

- Required: `LINEAR_API_KEY`, `GH_TOKEN`, `OPENAI_API_KEY`, `DATABASE_URL`
- Optional for Gemini-backed runtime flows only: `GEMINI_API_KEY` and related Gemini tuning env vars
- `GH_TOKEN` is the default unattended Git transport contract; the workflows no longer rely on a local `file://` fallback.

Suggested preflight before launch:

- `gh auth status`
- verify `git clone`/`git ls-remote` for all three allowlisted GitHub repos work without prompts
- run `make symphony-bootstrap` in a fresh clone of each allowlisted repo and confirm reruns stay unattended and leave no tracked changes
- verify Linear triage can apply the `repo:*` labels for `Платформа и интеграция`
- confirm `DATABASE_URL` points to reachable PostgreSQL
- confirm Node/npm are installed in the container image
- confirm Playwright browser bootstrap can run in a fresh workspace

Suggested port:

- `4101` -> `symphony-let` (`let.WORKFLOW.md`)

Launch template:

```bash
export LINEAR_API_KEY=...
export GH_TOKEN=...
export OPENAI_API_KEY=...
export DATABASE_URL=postgresql://...
export SYMPHONY_WORKSPACE_ROOT=/srv/symphony/workspaces/let

cd /path/to/symphony/elixir
mise exec -- ./bin/symphony /path/to/repo/workflows/letterl/maxime/let.WORKFLOW.md \
  --port 4101 \
  --logs-root /var/log/symphony/let \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Issue examples:

```md
## Symphony
Repo: maximlafe/lead_status
Base branch: feature/task-routing
```

Use that when the issue belongs to `Извлечение задач`, `Мастер команд`, or `Telegram Full Export v2` and the project mapping is sufficient.

```md
Labels:
- repo:symphony

## Symphony
Repo: maximlafe/symphony
Base branch: main
```

Use that for `Платформа и интеграция`, where the project itself is intentionally ambiguous and the repo label is required.

```md
Labels:
- repo:symphony
- mode:research

## Symphony
Repo: maximlafe/symphony
Base branch: main
```

Use `mode:research` when the ticket still needs evidence-backed root-cause analysis, ranked hypotheses, and a normalized spec before planning or execution. Use `mode:plan` when the task is already understood conceptually but still needs a stable implementation-ready engineering spec, updated Linear description, and explicit validation plan. Leave both labels absent when the issue description is already execution-ready.
