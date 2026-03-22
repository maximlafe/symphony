---
tracker:
  kind: linear
  project_slug: "master-komand-dfbe2b1b972e"
  assignee: "4eb8c4a3-8050-4af2-aa2b-da38d903c941"
  active_states:
    - Todo
    - Planning
    - In Progress
    - Merging
    - Rework
  manual_intervention_state: Blocked
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  timeout_ms: 600000
  after_create: |
    export GIT_TERMINAL_PROMPT=0
    export SOURCE_REPO_URL="${SOURCE_REPO_URL:-https://github.com/maximlafe/lead_status.git}"
    if [ -z "${GH_TOKEN:-}" ]; then
      echo "GH_TOKEN is required for unattended lead_status clone/push access." >&2
      exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
      echo "`gh` is required for unattended lead_status clone/push access." >&2
      exit 1
    fi
    gh auth status >/dev/null 2>&1 || {
      echo "GitHub auth is unavailable. Export GH_TOKEN in /etc/symphony/symphony.env." >&2
      exit 1
    }
    gh auth setup-git >/dev/null 2>&1 || {
      echo "Failed to configure git credentials via gh auth setup-git." >&2
      exit 1
    }
    git clone --depth 1 "$SOURCE_REPO_URL" .
    make symphony-bootstrap
  before_remove: |
    branch=$(git branch --show-current 2>/dev/null)
    if [ -n "$branch" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh pr list --head "$branch" --state open --json number --jq '.[].number' | while read -r pr; do
        [ -n "$pr" ] && gh pr close "$pr" --comment "Closing because the Linear issue for branch $branch entered a terminal state without merge."
      done
    fi
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
  accounts:
    - id: "furrow.03-offline@icloud.com"
      codex_home: /root/.codex-furrow
    - id: "rebeccakirby3711@outlook.com"
      codex_home: /root/.codex-rebecca
    - id: Deborah
      codex_home: /root/.codex-deborah
  minimum_remaining_percent: 5
  monitored_windows_mins: [300, 10080]
server:
  host: "0.0.0.0"
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".
4. Work only in the provided repository copy. Do not touch any other path.
5. Everything written to Linear must be in Russian.
6. Every timestamp written to Linear must use Moscow time in the format `DD.MM.YYYY HH:MM MSK`.
7. Use the compact runtime tools when available:
   - `linear_graphql` for narrowly scoped Linear reads/writes.
   - `sync_workpad` for the live workpad comment; do not inline the workpad body into raw `commentCreate`/`commentUpdate` when `sync_workpad` is available.
   - `github_pr_snapshot` for compact PR status/feedback summaries.
   - `github_wait_for_checks` for CI waits outside the model loop.
8. For Team Master UI/backend/runtime work, use the repo-local `launch-app` skill for live verification after the validation matrix passes.

## Operating rules

- Start by determining the current state, then follow the matching flow.
- Keep the issue description as the canonical task-spec and exactly one persistent workpad comment as the implementation plan and execution log.
- Use local `workpad.md` as the working copy and sync the live workpad only at bootstrap, meaningful milestones, and final handoff.
- Before each automated stage (`Planning`, `In Progress`, `Rework`, `Merging`), post one separate top-level stage-start comment before the first live workpad sync of that stage.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as mandatory acceptance input.
- Run `make symphony-preflight` before treating auth/env/tooling gaps as blockers, and use the validation matrix below instead of ad-hoc test selection.
- Do not reread skill bodies in straightforward runs unless the workflow does not cover the needed behavior.
- Move state only when the matching quality bar is satisfied.

## Status map

- `Backlog` -> вне этого workflow; не изменяй.
- `Todo` -> сразу переводи в `Planning`.
- `Planning` -> приведи issue description к русскому task-spec и подготовь детальный русский workpad; продуктовый код не меняй.
- `Plan Review` -> человеческий гейт для плана; не кодируй.
- `In Progress` -> активная реализация.
- `In Review` -> PR приложен и провалидирован; ждём человеческий тест/ревью.
- `Merging` -> одобрено человеком; используй `land` skill и не вызывай `gh pr merge` напрямую.
- `Rework` -> новый заход после review feedback с новой веткой и новым PR.
- `Blocked` -> автономный прогресс упёрся во внешнее ограничение.
- `Done` -> терминальное состояние.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID and read the current state.
2. Inspect only the minimal local repo state needed for routing (`branch`, `HEAD`, `git status` only when needed).
3. Route to the matching flow:
   - `Backlog` -> stop and wait for a human move to `Todo`.
   - `Todo` -> move to `Planning`, post the `Planning` start comment, bootstrap the workpad, then start planning.
   - `Planning` -> continue planning.
   - `Plan Review` -> wait and poll; do not code or change the repo.
   - `In Progress` -> continue execution with minimal recovery when possible.
   - `In Review` -> wait and poll for review decisions.
   - `Merging` -> post the `Merging` start comment, then use the `land` skill.
   - `Rework` -> run the rework flow.
   - `Blocked` -> wait and poll for human unblock action; do not code or change the repo.
   - `Done` -> do nothing and shut down.
4. Query GitHub for an existing PR only when at least one reuse signal exists:
   - current branch is not `main`;
   - the issue already references a PR in links, attachments, or comments;
   - the current state is `In Progress`, `In Review`, `Rework`, or `Merging`.
   - For fresh `Todo` or `Planning` runs on `main` with no PR signal, skip branch PR lookup and do not log placeholder notes.
5. Minimal recovery for straightforward `In Progress` runs:
   - if `.workpad-id` exists and the issue is already in `In Progress`, read only the current state, the issue-description task-spec, the live workpad, the current branch/HEAD, and the PR link or attachment if present;
   - reread full comment/history context only for missing workpad, state/content mismatch, `Rework`, missing PR context, or real ambiguity.
6. If the existing branch PR is already closed or merged, do not reuse that branch. Create a fresh branch from `origin/main` and continue as a new attempt.

## Step 1: Planning phase (Todo or Planning -> Plan Review)

1. If arriving from `Todo`, the issue should already be in `Planning` and the separate planning start comment should already exist before workpad bootstrap begins.
2. Ensure exactly one separate top-level stage-start comment exists for the current automated stage:
   - `Planning` -> `Начал планирование задачи: <DD.MM.YYYY HH:MM MSK>`
   - `In Progress` -> `Начал выполнение задачи: <DD.MM.YYYY HH:MM MSK>`
   - `Rework` -> `Начал доработку задачи: <DD.MM.YYYY HH:MM MSK>`
   - `Merging` -> `Начал слияние задачи: <DD.MM.YYYY HH:MM MSK>`
3. Find or create a single persistent workpad comment:
   - search active comments for `## Рабочий журнал Codex`;
   - reuse legacy `## Codex Workpad` if it already exists and rename it on the next sync;
   - ignore resolved comments;
   - persist the comment ID in `.workpad-id`.
4. `Planning` is analysis-only:
   - do not edit product code, commit, or push;
   - read the issue body, only the relevant comments and PR context, and inspect the codebase;
   - capture a reproduction or investigation signal only when it materially sharpens the plan.
5. Keep local `workpad.md` as the planning source of truth:
   - bootstrap the live workpad once if missing;
   - after bootstrap, keep planning edits local until the final plan is ready;
   - sync the live workpad at most one final time before `Plan Review`;
   - always pass the absolute path to local `workpad.md` when calling `sync_workpad`.
6. Update the issue-description task-spec only when required sections are missing or the task contract materially changed:
   - use canonical Russian headings `Проблема`, `Цель`, `Скоуп`, `Критерии приемки`;
   - add `Вне скоупа`, `Зависимости`, `Заметки` only when they materially help the task contract;
   - preserve all material user facts, constraints, and acceptance intent, but allow full reformatting into the canonical sections;
   - do not write checklists, managed markers, or workpad-style progress notes into the description.
7. Maintain the Russian workpad with a compact environment stamp, hierarchical plan, `Критерии приемки`, `Проверка`, and `Заметки`.
8. Before moving to `Plan Review`, do one final planning handoff:
   - ensure the task-spec issue description is current;
   - ensure the final local `workpad.md` is synced exactly once;
   - record notes such as `на этапе Planning продуктовые файлы не изменялись` locally before that final sync, not through an extra sync cycle.
9. Move the issue to `Plan Review`.
10. Do not begin implementation until a human moves the issue to `In Progress`.

## Validation preflight

Run `make symphony-preflight` once per run before treating auth/env/tooling gaps as blockers. If it fails, record the exact failing check and whether it blocks the ticket's required validation.

## Validation matrix

- Backend-only changes: run targeted pytest for the touched modules and at least `make test-unit`.
- Stateful, `task_v3`, database, or schema changes: run targeted pytest, `poetry run pytest tests/integration/test_task_v3_stateful_repeatability.py -v -m integration`, and `poetry run alembic upgrade head`.
- Hosted UI or frontend changes: run `make team-master-ui-e2e`; if the change is app-touching, use the `launch-app` skill, verify `/health` and `/api/dashboard`, and capture runtime evidence.
- Repo-wide infra or runtime changes: run `make test` plus the relevant targeted smoke checks.
- Ticket-authored validation or test-plan steps are mandatory on top of this matrix.
- Only move to `Blocked` when the task requires a matrix item that still cannot run after `make symphony-preflight` identifies the missing capability.

## PR feedback and checks protocol (required before In Review)

1. Identify the PR number from issue links or attachments.
2. Run `github_pr_snapshot` once with default summary output.
3. Only if the summary shows reviews, top-level comments, inline comments, or actionable feedback:
   - run `github_pr_snapshot` with `include_feedback_details: true`;
   - treat every actionable item as blocking until code/docs/tests are updated or an explicit justified pushback reply is posted;
   - reflect each feedback item and its resolution status in the workpad;
   - rerun the required validation after feedback-driven changes.
4. Use `github_wait_for_checks` to wait for CI outside the model loop.
5. When checks complete, run `github_pr_snapshot` again.
6. If checks are not green or actionable feedback remains, continue the fix/validate loop.
7. Do not fetch full GitHub feedback payloads when the summary snapshot shows no review activity.

## Blocked-access escape hatch

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is not a valid blocker by default; try fallback publish/review strategies first.
- Use `Blocked` only when no further autonomous progress is possible because of an external limitation.
- Run `make symphony-preflight` before using this escape hatch.
- Before moving to `Blocked`, record a concise Russian blocker brief in the workpad with what is missing, why it blocks acceptance, and the exact human unblock action.

## Step 2: Execution phase (In Progress -> In Review or Blocked)

1. On entry to `In Progress`, first create the separate top-level comment `Начал выполнение задачи: <DD.MM.YYYY HH:MM MSK>` before any repo-changing command or the first live workpad sync of that stage.
2. Recover from the existing task-spec description and workpad using the minimal-recovery rules unless the issue requires a full reread.
3. Run the `pull` skill before code edits, then record the result in `Заметки` with merge source, outcome (`clean` or `conflicts resolved`), and resulting short SHA.
4. Use the issue description as the canonical task contract and local `workpad.md` as the implementation plan and detailed execution log.
5. Implement against the checklist, keep completed items checked, and sync the live workpad only after meaningful milestones or before final handoff.
6. Run the required validation for the scope:
   - run `make symphony-preflight` before concluding that auth/env/tooling is missing for the current task;
   - apply the validation matrix above instead of picking tests heuristically;
   - execute every ticket-provided validation/test-plan requirement when present;
   - prefer targeted proof for the changed behavior;
   - revert every temporary proof edit before commit or push;
   - if app-touching, capture runtime evidence and upload it to Linear.
7. Before every `git push`, rerun the required validation and confirm it passes.
8. Attach the PR URL to the issue and ensure the GitHub PR has label `symphony`.
9. Merge latest `origin/main` into the branch before final handoff, resolve conflicts, and rerun required validation.
10. Before moving to `In Review`, use the compact PR/check flow:
   - run the PR feedback and checks protocol above;
   - if checks are green and no actionable feedback remains, first rewrite every final checklist item so it is already true before the state transition (for example, `PR checks зелёные; задача готова к переводу в In Review` instead of `задача переведена в In Review`), then close all satisfied parent and child checkboxes, finalize local `workpad.md`, sync the live workpad once, update the task-spec description once if the task contract changed, and only then move the issue to `In Review`;
   - do not repeat label or attachment checks in the same run unless the PR changed.
11. If PR publication or handoff is blocked by missing required non-GitHub tools/auth/permissions after all fallbacks, move the issue to `Blocked` with the blocker brief and explicit unblock action.

## Step 3: In Review and merge handling

1. In `In Review`, do not code or change ticket content.
2. Poll for updates as needed.
3. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
4. If approved, a human moves the issue to `Merging`.
5. In `Merging`, first create the separate top-level comment `Начал слияние задачи: <DD.MM.YYYY HH:MM MSK>`, then use the `land` skill until the PR is merged.
6. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a fresh attempt, not incremental patching on top of stale execution state.
2. First create the separate top-level comment `Начал доработку задачи: <DD.MM.YYYY HH:MM MSK>`.
3. Re-read the issue body task-spec, human comments, and PR feedback; explicitly identify what changes this attempt.
4. Close the existing PR tied to the issue.
5. Remove the existing `## Рабочий журнал Codex` comment.
6. Create a fresh branch from `origin/main`.
7. Create a new bootstrap `## Рабочий журнал Codex` comment.
8. Refresh the task-spec description if the task contract changed for the new attempt, then rewrite the new workpad in Russian.
9. Execute the normal flow again and return the issue to `In Review`.

## Completion bar before Plan Review

- The issue description contains an up-to-date Russian task-spec with `Проблема`, `Цель`, `Скоуп`, and `Критерии приемки`.
- The workpad comment exists and mirrors the detailed plan in Russian.
- Required `Критерии приемки` and `Проверка` checklists are explicit and reviewable.
- Any important reproduction or investigation signal is recorded in the workpad.
- No product code changes, commits, or PR publication happened during `Planning`.

## Completion bar before In Review

- The workpad accurately reflects the completed plan, acceptance criteria, validation, and handoff notes.
- Every final checklist item in the workpad is phrased as a pre-transition fact or readiness statement, so it can be truthfully checked before the move to `In Review`.
- The Russian task-spec description reflects the delivered scope.
- Required validation/tests are green for the latest commit.
- Actionable PR feedback is resolved.
- PR checks are green.
- The PR is pushed, linked on the issue, and labeled `symphony`.
- Runtime evidence is uploaded when the change is app-touching.

## Guardrails

- If issue state is `Backlog`, do not modify it.
- If state is terminal (`Done`), do nothing and shut down.
- Preserve all material user-authored facts and constraints when normalizing the issue description; full reformatting into canonical sections is allowed.
- Use exactly one persistent workpad comment and sync it via `sync_workpad` whenever available.
- Pass the absolute path to local `workpad.md` when calling `sync_workpad`.
- Stage-start announcements must be separate top-level comments and must be posted before the first live workpad sync of that stage.
- Never inline the live workpad body into raw `commentCreate` or `commentUpdate` when `sync_workpad` is available.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- Out-of-scope improvements go to a separate Backlog issue instead of expanding current scope.
- Treat the completion bars for `Plan Review` and `In Review` as hard gates.
- In `Plan Review`, `In Review`, and `Blocked`, do not change the repo.

## Task-spec issue description

Use this structure when creating a new issue description or normalizing an existing one:

````md
## Проблема

Коротко опиши, что сейчас не так и почему это важно.

## Цель

Коротко опиши желаемый результат.

## Скоуп

- Основная граница 1
- Основная граница 2

## Критерии приемки

- Критерий 1
- Критерий 2

## Вне скоупа

- Добавляй только если есть явные non-goals

## Зависимости

- Добавляй только если есть внешние или межтасковые зависимости

## Заметки

- Добавляй только если нужны rollout/context notes
````

Do not use checkboxes, managed markers, or progress logs in the issue description.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Рабочий журнал Codex

```text
<hostname>:<abs-path>@<short-sha>
```

### План

- [ ] 1\. Основной шаг
  - [ ] 1.1 Подшаг
  - [ ] 1.2 Подшаг
- [ ] 2\. Основной шаг

### Критерии приемки

- [ ] Критерий 1
- [ ] Критерий 2

### Проверка

- [ ] целевая проверка: `<command>`

### Заметки

- <короткая заметка с временем по Москве>

### Неясности

- <добавляй только если что-то действительно было неясно>
````

For the final handoff to `In Review`, phrase checklist items so they are true before the state change. Good: `PR checks зелёные; задача готова к переводу в In Review`. Bad: `Задача переведена в In Review`.
