---
tracker:
  kind: linear
  project_slug: "platforma-i-integraciya-448570ee6438"
  assignee: "4eb8c4a3-8050-4af2-aa2b-da38d903c941"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
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
5. Use the compact runtime tools when available:
   - `linear_graphql` for narrowly scoped Linear reads/writes.
   - `sync_workpad` for the live workpad comment; do not inline the workpad body into raw `commentCreate`/`commentUpdate` when `sync_workpad` is available.
   - `github_pr_snapshot` for compact PR status/feedback summaries.
   - `github_wait_for_checks` for CI waits outside the model loop.
6. For Team Master UI/backend/runtime work, use the repo-local `launch-app` skill for live verification after the validation matrix passes.

## Operating rules

- Determine the current state first and follow the matching flow.
- Keep exactly one persistent workpad comment (`## Codex Workpad`) and use local `workpad.md` as the working copy for the implementation checklist and execution log.
- Treat the issue description as the tracker/task statement; do not turn it into a workpad, checklist, or marker-delimited plan block unless a repo-specific workflow explicitly requires a separate task-spec contract.
- Sync the live workpad only at bootstrap, meaningful milestones, and final handoff.
- Reproduce or capture the current signal before code changes when it materially improves confidence.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as mandatory acceptance input.
- Run `make symphony-preflight` before treating auth/env/tooling gaps as blockers, and use the validation matrix below instead of ad-hoc test selection.
- Do not reread skill bodies in straightforward runs unless the workflow does not cover the needed behavior.
- Move state only when the matching quality bar is satisfied.

## Status map

- `Backlog` -> out of scope; do not modify.
- `Todo` -> immediately move to `In Progress`, then bootstrap the workpad and execute.
- `In Progress` -> active implementation.
- `In Review` -> PR is attached and validated; wait for human review.
- `Merging` -> approved by human; use the `land` skill and do not call `gh pr merge` directly.
- `Rework` -> start a fresh attempt from updated review feedback.
- `Blocked` -> human action is required before execution can continue.
- `Done` -> terminal state; no further action required.

## Step 0: Route and recover

1. Fetch the issue by explicit ticket ID and read the current state.
2. Inspect only the minimal local repo state needed for routing (`branch`, `HEAD`, `git status` only when needed).
3. Route to the matching flow:
   - `Backlog` -> stop and wait for a human move to `Todo`.
   - `Todo` -> move to `In Progress`, then bootstrap the workpad and start execution.
   - `In Progress` -> resume execution, preferring minimal recovery over a full reread.
   - `In Review` -> wait for human review decisions.
   - `Merging` -> use the `land` skill.
   - `Rework` -> run the rework flow.
   - `Blocked` -> stop and wait for a human unblock.
   - `Done` -> do nothing and shut down.
4. Query GitHub for an existing PR only when at least one reuse signal exists:
   - current branch is not `main`;
   - the issue already references a PR in links, attachments, or comments;
   - the current state is `In Progress`, `In Review`, `Rework`, or `Merging`.
   - For fresh `Todo` runs on `main` with no PR signal, skip branch PR lookup and do not log placeholder notes.
5. Minimal recovery for straightforward `In Progress` runs:
   - if `.workpad-id` exists and the live workpad is available, read only the current state, live workpad, current branch/HEAD, and PR link or attachment if present;
   - reread full comment/history context only for missing workpad, state/content mismatch, `Rework`, or real ambiguity.
6. If the existing branch PR is already closed or merged, do not reuse that branch. Create a fresh branch from `origin/main` and continue as a new attempt.

## Step 1: Execute (Todo or In Progress)

1. Find or create a single persistent workpad comment:
   - search active comments for `## Codex Workpad`;
   - reuse it if found;
   - otherwise create it once and persist its ID in `.workpad-id`.
2. Keep local `workpad.md` as the execution source of truth:
   - bootstrap the live workpad once if missing;
   - pass the absolute path to local `workpad.md` when calling `sync_workpad`;
   - keep subsequent edits local until a meaningful milestone or final handoff.
3. Maintain the workpad with a compact environment stamp, plan, acceptance criteria, validation checklist, and notes.
4. Before code edits, run the `pull` skill to sync with latest `origin/main`, then record the result in `Notes` with merge source, outcome (`clean` or `conflicts resolved`), and resulting short SHA.
5. Implement against the checklist, keep completed items checked, and sync the live workpad only after meaningful milestones or before handoff.
6. Run the required validation for the scope:
   - execute all ticket-provided validation/test-plan requirements when present;
   - prefer targeted proof for the changed behavior;
   - revert every temporary proof edit before commit or push;
   - if app-touching, capture runtime evidence and upload it to Linear.
7. Before every `git push`, rerun the required validation and confirm it passes.
8. Attach the PR URL to the issue and ensure the GitHub PR has label `symphony`.
9. Merge latest `origin/main` into the branch before final handoff, resolve conflicts, and rerun required validation.

## Validation preflight

Run `make symphony-preflight` once per run before treating auth/env/tooling gaps as blockers. If it fails, record the exact failing check and whether it blocks the ticket's required validation.

## Validation matrix

- Backend-only changes: run targeted pytest for the touched modules and at least `make test-unit`.
- Stateful, `task_v3`, database, or schema changes: run targeted pytest, `poetry run pytest tests/integration/test_task_v3_stateful_repeatability.py -v -m integration`, and `poetry run alembic upgrade head`.
- Hosted UI or frontend changes: run `make team-master-ui-e2e`; if the change is app-touching, use the `launch-app` skill, verify `/health` and `/api/dashboard`, and capture runtime evidence.
- Repo-wide infra or runtime changes: run `make test` plus the relevant targeted smoke checks.
- Ticket-authored validation or test-plan steps are mandatory on top of this matrix.
- Only move to `Blocked` when the ticket requires a matrix item that still cannot run after `make symphony-preflight` identifies the missing capability.

## PR handoff protocol (required before In Review)

1. Identify the PR number from issue links or attachments.
2. Run `github_pr_snapshot` once with default summary output.
3. Only if the summary shows reviews, top-level comments, inline comments, or actionable feedback:
   - run `github_pr_snapshot` with `include_feedback_details: true`;
   - treat every actionable item as blocking until code/docs/tests are updated or an explicit justified pushback reply is posted;
   - update the workpad checklist with the feedback items and their resolution status;
   - rerun required validation after feedback-driven changes.
4. Use `github_wait_for_checks` to wait for CI outside the model loop.
5. When checks complete, run `github_pr_snapshot` again.
6. If checks are not green or actionable feedback remains, continue the fix/validate loop.
7. If checks are green and no actionable feedback remains:
   - finalize local `workpad.md`;
   - sync the live workpad once;
   - ensure the issue still links to the PR;
   - move the issue to `In Review`.
8. Do not repeat label or attachment checks in the same run unless the PR changed.
9. Do not fetch full GitHub feedback payloads when the summary snapshot shows no review activity.

## Blocked-access escape hatch

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is not a valid blocker by default; try fallback publish/review strategies first.
- Run `make symphony-preflight` before using this escape hatch.
- If a required non-GitHub tool or auth path is missing, record a concise blocker brief in the workpad with what is missing, why it blocks acceptance, and the exact human unblock action, then move the issue to `Blocked`.

## Step 2: In Review and merge handling

1. In `In Review`, do not code or change ticket content.
2. Wait for human review decisions.
3. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
4. If approved, a human moves the issue to `Merging`.
5. In `Merging`, use the `land` skill until the PR is merged, then move the issue to `Done`.

## Step 3: Rework handling

1. Treat `Rework` as a fresh attempt, not incremental patching on top of stale execution state.
2. Re-read the issue body and human review feedback, explicitly identify what changes this attempt.
3. Close the existing PR tied to the issue.
4. Remove the existing `## Codex Workpad` comment.
5. Create a fresh branch from `origin/main`.
6. Bootstrap a new workpad and execute the normal flow again.

## Completion bar before In Review

- The single workpad comment accurately reflects the completed plan, acceptance criteria, validation, and handoff notes.
- Required validation/tests are green for the latest commit.
- The PR is pushed, linked on the issue, and labeled `symphony`.
- Actionable PR feedback is resolved.
- PR checks are green.
- Runtime evidence is uploaded when the change is app-touching.

## Guardrails

- If issue state is `Backlog`, do not modify it.
- If state is terminal (`Done`), do nothing and shut down.
- Use exactly one persistent workpad comment and sync it via `sync_workpad` whenever available.
- Pass the absolute path to local `workpad.md` when calling `sync_workpad`.
- Never inline the live workpad body into raw `commentCreate`/`commentUpdate` when `sync_workpad` is available.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- Out-of-scope improvements go to a separate Backlog issue instead of expanding current scope.
- Treat the completion bar before `In Review` as a hard gate.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
