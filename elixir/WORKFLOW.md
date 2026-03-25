---
tracker:
  kind: linear
  # Set exactly one of project_slug or team_key.
  project_slug: "symphony-bd5bc5b51675"
  active_states:
    - Todo
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
  root: ~/code/symphony-workspaces
  cleanup_keep_recent: 5
  warning_threshold_bytes: 10737418240
hooks:
  after_create: |
    export GIT_TERMINAL_PROMPT=0
    git clone --depth 1 "${SYMPHONY_SOURCE_REPO_URL:-https://github.com/maximlafe/symphony.git}" .
    make symphony-bootstrap
  before_remove: |
    branch=$(git branch --show-current 2>/dev/null)
    if [ -n "$branch" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh pr list --head "$branch" --state open --json number --jq '.[].number' | while read -r pr; do
        [ -n "$pr" ] && gh pr close "$pr" --comment "Closing because the Linear issue for branch $branch entered a terminal state without merge."
      done
    fi
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
  accounts:
    - id: primary
      codex_home: ~/.codex-primary
    - id: backup
      codex_home: ~/.codex-backup
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Treat every retry as a context-budgeted continuation: prefer the current diff, `workpad.md`, and compact tool summaries over rereading full history.
- If available context is already low (`low-context`), finish at most one atomic action, sync the workpad, and prepare a classified checkpoint instead of starting a broad new investigation.
- Do not spend the remaining context budget restating prior work or retrying the same failing path without a materially new signal.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets or are making a classified `decision`/`human-action` handoff because further autonomous progress is no longer justified.
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
2. Only stop early for a true blocker or an explicitly classified handoff that the workflow allows (`decision` or `human-action`). If you stop, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".
4. Work only in the provided repository copy. Do not touch any other path.
5. Use the compact runtime tools when available:
   - `linear_graphql` for narrowly scoped Linear reads/writes.
   - `sync_workpad` for the live workpad comment; do not inline the workpad body into raw `commentCreate`/`commentUpdate` when `sync_workpad` is available.
   - `github_pr_snapshot` for compact PR status/feedback summaries.
   - `github_wait_for_checks` for CI waits outside the model loop.

## Operating rules

- Determine the current state first and follow the matching flow.
- Keep exactly one persistent workpad comment (`## Codex Workpad`) and use local `workpad.md` as the working copy for the implementation checklist and execution log.
- Treat the issue description as the tracker/task statement; do not turn it into a workpad, checklist, or marker-delimited plan block unless a repo-specific workflow explicitly requires a separate task-spec contract.
- Sync the live workpad only at bootstrap, meaningful milestones, and final handoff.
- Reproduce or capture the current signal before code changes when it materially improves confidence.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as mandatory acceptance input.
- Do not reread skill bodies in straightforward runs unless the workflow does not cover the needed behavior.
- Move state only when the matching quality bar is satisfied.

## Repository contract

- This workflow is reserved for the dedicated LetterL project `Symphony` (`symphony-bd5bc5b51675`). Do not retarget it to the shared platform project.
- Fresh workspace bootstrap is `git clone` of `maximlafe/symphony` followed by `make symphony-bootstrap`.
- Run `make symphony-preflight` once per run before treating auth or tooling gaps as blockers.
- Default validation gate is `make symphony-validate`; run `make symphony-live-e2e` only for explicit smoke or end-to-end tasks that should exercise real Linear and Codex services.
- Repo-local worker skills live in `.agents/skills/` and are part of the required target-repo contract.

## Status map

- `Backlog` -> out of scope; do not modify.
- `Todo` -> immediately move to `In Progress`, then bootstrap the workpad and execute.
- `In Progress` -> active implementation.
- `Human Review` -> classified human handoff; use `checkpoint_type` to distinguish normal `human-verify` review from `decision` or `human-action`.
- `Merging` -> approved by human; use the `land` skill and do not call `gh pr merge` directly.
- `Rework` -> start a fresh attempt from updated review feedback.
- `Done` -> terminal state; no further action required.

## Step 0: Route and recover

1. Fetch the issue by explicit ticket ID and read the current state.
2. Inspect only the minimal local repo state needed for routing (`branch`, `HEAD`, `git status` only when needed).
3. Route to the matching flow:
   - `Backlog` -> stop and wait for a human move to `Todo`.
   - `Todo` -> move to `In Progress`, then bootstrap the workpad and start execution.
   - `In Progress` -> resume execution, preferring minimal recovery over a full reread.
   - `Human Review` -> wait and poll for review decisions.
   - `Merging` -> use the `land` skill.
   - `Rework` -> run the rework flow.
   - `Done` -> do nothing and shut down.
4. Query GitHub for an existing PR only when at least one reuse signal exists:
   - current branch is not `main`;
   - the issue already references a PR in links, attachments, or comments;
   - the current state is `In Progress`, `Human Review`, `Rework`, or `Merging`.
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
   - track repeated fix loops for the same failing signal in the workpad and follow the auto-fix limit below;
6. Run the required validation for the scope:
   - run `make symphony-preflight` before concluding that auth or tooling is missing for the current task;
   - execute all ticket-provided validation/test-plan requirements when present;
   - prefer targeted proof for the changed behavior;
   - revert every temporary proof edit before commit or push;
   - if app-touching, capture runtime evidence and upload it to Linear.
7. Before every `git push`, rerun the required validation and confirm it passes.
8. Attach the PR URL to the issue and ensure the GitHub PR has label `symphony`.
9. Merge latest `origin/main` into the branch before final handoff, resolve conflicts, and rerun required validation.

## PR handoff protocol (required before Human Review)

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
   - fill the `Checkpoint` section in `workpad.md` with `checkpoint_type: human-verify`, a justified `risk_level`, and a one-line `summary`;
   - finalize local `workpad.md`;
   - sync the live workpad once;
   - ensure the issue still links to the PR;
   - move the issue to `Human Review`.
8. Do not repeat label or attachment checks in the same run unless the PR changed.
9. Do not fetch full GitHub feedback payloads when the summary snapshot shows no review activity.

## Classified checkpoint protocol

Use this whenever you pause, hand off, or stop because autonomous progress is no longer justified.

- Every handoff must include a compact checkpoint in local `workpad.md` before the final `sync_workpad`.
- The checkpoint must include:
  - `checkpoint_type`: exactly one of `human-verify`, `decision`, `human-action`
  - `risk_level`: exactly one of `low`, `medium`, `high`
  - `summary`: the minimum evidence-backed reason for the handoff
- `human-verify`:
  - use when implementation is complete enough for human review or manual verification;
  - keep it aligned with the normal PR -> `Human Review` flow;
  - do not use it when a product/technical choice or external action is still required first.
- `decision`:
  - use when progress depends on a product/technical choice, conflicting requirements, or multiple plausible fixes after repeated attempts;
  - include the viable options, your recommendation, and the consequence of choosing differently;
  - route to `Human Review` and wait for an explicit human decision instead of normal PR approval.
- `human-action`:
  - use when a human must do something outside the agent loop (grant access, add a secret, repair external state, run a deploy gate, provide missing input);
  - include the exact required action and why the agent cannot complete it alone;
  - route to `Human Review` and wait for that action.
- Classify risk conservatively:
  - `low` for localized, reversible changes with strong evidence;
  - `medium` for multi-file behavior changes or incomplete verification;
  - `high` for destructive operations, data correctness risk, auth/security changes, or unresolved uncertainty around user impact.
- Do not paste large raw logs into the checkpoint. Summarize the current signal and rely on compact tool outputs (`github_pr_snapshot`, `sync_workpad`) instead.

## Auto-fix loop discipline

- Count one auto-fix attempt each time you change code or config to resolve the same failing signal after you already captured a concrete reproduction, CI failure, or review finding.
- Limit yourself to 2 auto-fix attempts per distinct root cause or failing signal.
- If the second attempt does not clearly resolve the issue, stop speculative iteration, sync the workpad once, and hand off with a classified checkpoint.
- Use `checkpoint_type: decision` when multiple plausible fixes remain, `checkpoint_type: human-action` when an external dependency blocks progress, and `checkpoint_type: human-verify` only when the implementation is ready and the remaining uncertainty is human verification.
- A materially different failure mode resets the counter; blind reruns and cosmetic rewrites do not.

## Blocked-access escape hatch

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is not a valid blocker by default; try fallback publish/review strategies first.
- If a required non-GitHub tool or auth path is missing, record a concise blocker brief in the workpad with `checkpoint_type: human-action`, an appropriate `risk_level`, what is missing, why it blocks acceptance, and the exact human unblock action, then move the issue to `Human Review`.
- This blocker route is a classified handoff, not a PR-ready `human-verify` handoff, so satisfy the matching `Human Review` handoff bar below instead of the PR-ready bar.

## Step 2: Human Review and merge handling

1. In `Human Review`, do not code or change ticket content.
2. Poll for review updates as needed.
   - if the latest checkpoint is `decision` or `human-action`, wait for that explicit decision/action instead of treating the state like ordinary PR approval;
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

## Human Review handoff bar

- The single workpad comment accurately reflects the completed plan, acceptance criteria, validation, and handoff notes.
- The workpad contains a classified checkpoint with one of `checkpoint_type: human-verify`, `decision`, or `human-action`, and a justified `risk_level`.
- For `checkpoint_type: human-verify` handoffs:
  - required validation/tests are green for the latest commit;
  - the PR is pushed, linked on the issue, and labeled `symphony`;
  - actionable PR feedback is resolved;
  - PR checks are green;
  - runtime evidence is uploaded when the change is app-touching.
- For `checkpoint_type: decision` or `human-action` handoffs:
  - the workpad explains the blocking choice or required external action;
  - the summary makes clear why further autonomous progress is not justified yet;
  - PR publication, green checks, and review-ready validation are not required before moving to `Human Review`.

## Guardrails

- If issue state is `Backlog`, do not modify it.
- If state is terminal (`Done`), do nothing and shut down.
- Never emit an unclassified handoff; every pause or human gate must declare both `checkpoint_type` and `risk_level`.
- Use exactly one persistent workpad comment and sync it via `sync_workpad` whenever available.
- Pass the absolute path to local `workpad.md` when calling `sync_workpad`.
- Never inline the live workpad body into raw `commentCreate`/`commentUpdate` when `sync_workpad` is available.
- When context is low, prefer a classified checkpoint over a broad reread.
- After 2 unsuccessful auto-fix attempts on the same signal, do not start a third speculative fix.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- Out-of-scope improvements go to a separate Backlog issue instead of expanding current scope.
- Treat the matching `Human Review` handoff bar for the chosen `checkpoint_type` as a hard gate.

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

### Checkpoint

- `checkpoint_type`: `<human-verify|decision|human-action>` (fill only at handoff)
- `risk_level`: `<low|medium|high>` (fill only at handoff)
- `summary`: <short evidence-backed reason for the current handoff>

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
