# Ticket Movement Rewrite Final E2E Report (2026-05-17)

## Canon and base
- Canon priority used in this run:
  1. `/goal` contract from 2026-05-17
  2. `docs/plans/ticket-movement-rewrite-plan.md`
  3. `docs/reports/ticket-movement-rewrite-plan-red-team-round-3.md`
  4. `docs/reports/ticket-movement-rewrite-plan-red-team-round-2.md`
  5. older execution artifacts only as context
- Base PR: `#202` (`codex/ticket-movement-rewrite`)
- Base verification command: `gh pr view 202 --json headRefName,headRefOid`
- Base branch verified: `codex/ticket-movement-rewrite`
- Base head verified: `fe1be899294e990b69992bd56e00eca801eb049a`
- Working branch for this run: `codex/ticket-movement-rewrite-final-e2e`
- Working branch was created from `origin/codex/ticket-movement-rewrite` (not from PR #201)

## Required new autonomous e2e issue
- Linear issue: `LET-738`
- URL: <https://linear.app/letterl/issue/LET-738/ticket-movement-rewrite-final-canonical-e2e-on-pr-202-base>
- Created specifically for this run (not `LET-736` reuse)
- Contains checklist and plan links for autonomous e2e

## Gap audit (plan steps 1..9)
Status values follow contract: `missing` / `verified-existing` / `completed-now`.

| Step | Status | Proof (code anchors + named tests / gate) |
| --- | --- | --- |
| 1. Re-scope | `verified-existing` | Plan re-scope and retired migration-first framing are present in `docs/plans/ticket-movement-rewrite-plan.md:190`, `docs/plans/ticket-movement-rewrite-plan.md:263` |
| 2. Characterization gate | `verified-existing` | Named characterization tests present at `elixir/test/symphony_elixir/validation_gate_test.exs:18`, `elixir/test/symphony_elixir/execution_contract_test.exs:23`, `elixir/test/symphony_elixir/execution_contract_test.exs:117`; rerun result: `11 tests, 0 failures` with full targeted set (see “Gate results”) |
| 3. Inventory and mapping | `verified-existing` | Concrete lifecycle/guard/Linear inventory documented with code anchors in `docs/reports/ticket-movement-rewrite-inventory-map-2026-05-16.md:7`, `docs/reports/ticket-movement-rewrite-inventory-map-2026-05-16.md:22`, `docs/reports/ticket-movement-rewrite-inventory-map-2026-05-16.md:37`, mapping table at `docs/reports/ticket-movement-rewrite-inventory-map-2026-05-16.md:48` |
| 4. Boundary contracts and ownership | `verified-existing` | Plan boundary seam: `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:655`; execution boundary seam: `elixir/lib/symphony_elixir/orchestrator.ex:4140`; review boundary seam: `elixir/lib/symphony_elixir/controller_finalizer.ex:53` and `elixir/lib/symphony_elixir/handoff_check.ex:302`; Linear boundary wrapper: `elixir/lib/symphony_elixir/tracker.ex:35` -> `elixir/lib/symphony_elixir/linear/adapter.ex:53` |
| 5. Canonical pipeline and guard cleanup | `verified-existing` | Pipeline entry/continuation in `ControllerFinalizer.run/3` (`elixir/lib/symphony_elixir/controller_finalizer.ex:53`) and review contract in `HandoffCheck.evaluate/2` (`elixir/lib/symphony_elixir/handoff_check.ex:302`); fail-closed guard paths proven by `controller_finalizer_test.exs:1108` and `dynamic_tool_test.exs:2266` rerun green |
| 6. `changed_paths` fallback semantics | `verified-existing` | Fail-closed fallback in review path: `elixir/lib/symphony_elixir/controller_finalizer.ex:744`; fail-closed fallback in handoff validation context: `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:804`; tests: `controller_finalizer_test.exs:1108`, `dynamic_tool_test.exs:2266` (green) |
| 7. Retry/failover simplification | `completed-now` | Added per-milestone 429 retry cooldown to stop repeated Linear write attempts while preserving pending milestones: `elixir/lib/symphony_elixir/orchestrator.ex:6822`, `:6829`, `:6854`, `:6881`, `:6896`; plus continuation-safe 429 refresh handoff in `elixir/lib/symphony_elixir/agent_runner.ex:378`, `:391`; plus assignee-filtered state polling scope in `elixir/lib/symphony_elixir/linear/client.ex:482`, `:507`; regression proof with `orchestrator_status_test.exs: "orchestrator retries milestone commentary after transient tracker failures"` (`elixir/test/symphony_elixir/orchestrator_status_test.exs:862`), `orchestrator_status_test.exs: "orchestrator throttles milestone commentary retries after linear 429"` (`elixir/test/symphony_elixir/orchestrator_status_test.exs:1025`), and `core_test.exs: "agent runner treats issue state refresh 429 as continuation handoff instead of worker failure"` (`elixir/test/symphony_elixir/core_test.exs:7018`) |
| 8. Idempotent Linear wrapper | `verified-existing` | Single tracker boundary calls: `elixir/lib/symphony_elixir/tracker.ex:35`, `elixir/lib/symphony_elixir/tracker.ex:40`; Linear adapter implementation: `elixir/lib/symphony_elixir/linear/adapter.ex:53`, `elixir/lib/symphony_elixir/linear/adapter.ex:65`; dedupe/idempotent behavior proof by app-server tests `elixir/test/symphony_elixir/app_server_test.exs:1332`, `elixir/test/symphony_elixir/app_server_test.exs:1626` (green) |
| 9. Validation gate map | `completed-now` | Matrix row updates in `docs/plans/ticket-movement-rewrite-plan.md:250` aligned with actual named tests (including `workspace_and_config_test` assignee-id query tests at `elixir/test/symphony_elixir/workspace_and_config_test.exs:2219` and `:2263`) |

## Completed-now slice in this run (blocker root-cause fix)
### Slice: assignee-id GraphQL contract mismatch fix
- Problem observed in live run: assignee-filtered poll query variable type mismatch (`String!` vs expected `ID!`) blocked issue pickup.
- Files changed:
  - `elixir/lib/symphony_elixir/linear/client.ex`
  - `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- Code changes:
  - `SymphonyLinearPollByAssigneeId` now declares `$assigneeId: ID!` at `elixir/lib/symphony_elixir/linear/client.ex:102`
  - `SymphonyLinearTeamPollByAssigneeId` now declares `$assigneeId: ID!` at `elixir/lib/symphony_elixir/linear/client.ex:255`
- Regression proof:
  - `elixir/test/symphony_elixir/workspace_and_config_test.exs:2219` asserts team-scope query contains `$assigneeId: ID!`
  - `elixir/test/symphony_elixir/workspace_and_config_test.exs:2263` asserts project-scope query contains `$assigneeId: ID!`
  - targeted rerun result: `2 tests, 0 failures`

### Slice: milestone retry throttle for Linear 429
- Problem observed in live run (`Todo + mode:plan` route): while Linear was globally rate-limited, milestone publishing retried on every runtime update (`code-ready`, `validation-running`) and produced repeated `{:linear_api_status, 429}` write attempts.
- Files changed:
  - `elixir/lib/symphony_elixir/orchestrator.ex`
  - `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Code changes:
  - milestone publish path now checks per-milestone retry cooldown before reattempt: `elixir/lib/symphony_elixir/orchestrator.ex:6822`
  - 429 failures now mark milestone pending and schedule deferred retry instead of immediate repeated writes: `elixir/lib/symphony_elixir/orchestrator.ex:6881`
  - backoff source is configurable for tests and defaults to Linear poll backoff: `elixir/lib/symphony_elixir/orchestrator.ex:6896`
- Regression proof:
  - existing transient retry behavior preserved: `elixir/test/symphony_elixir/orchestrator_status_test.exs:862`
  - new 429-specific throttle behavior: `elixir/test/symphony_elixir/orchestrator_status_test.exs:1025`
  - targeted rerun result: `3 tests, 0 failures`

### Slice: issue-state refresh 429 handoff + assignee-filtered state polling
- Problem observed in live run: a completed Codex turn could still fail the worker with `{:issue_state_refresh_failed, {:linear_api_status, 429}}`, and terminal cleanup/state polling used a broader fetch path than routing-assignee scope.
- Files changed:
  - `elixir/lib/symphony_elixir/agent_runner.ex`
  - `elixir/lib/symphony_elixir/linear/client.ex`
  - `elixir/test/symphony_elixir/core_test.exs`
- Code changes:
  - `continue_with_issue?/2` now treats infra refresh failures (`429` / `>=500`) as continuation handoff instead of worker failure: `elixir/lib/symphony_elixir/agent_runner.ex:378`, `:391`
  - `fetch_issues_by_states/1` now applies `routing_assignee_filter()` before `do_fetch_by_states`, preserving assignee-scoped polling on this path: `elixir/lib/symphony_elixir/linear/client.ex:482`, `:507`
- Regression proof:
  - new test `elixir/test/symphony_elixir/core_test.exs:7018`
  - targeted rerun result: `3 tests, 0 failures` (`core_test.exs:7018` + `workspace_and_config_test.exs:2219` + `workspace_and_config_test.exs:2263`)

## Gate results
### Targeted regression suite
Command:
- `mise exec -- mix test test/symphony_elixir/validation_gate_test.exs:18 ... test/symphony_elixir/controller_finalizer_test.exs:1108`

Result:
- `11 tests, 0 failures`

### Assignee-id query contract tests
Command:
- `mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs:2219 test/symphony_elixir/workspace_and_config_test.exs:2263`

Result:
- `2 tests, 0 failures`

### Agent-runner + assignee-scope targeted tests
Command:
- `mise exec -- mix test test/symphony_elixir/core_test.exs:7018 test/symphony_elixir/workspace_and_config_test.exs:2219 test/symphony_elixir/workspace_and_config_test.exs:2263`

Result:
- `3 tests, 0 failures`

### Cheap and broader gates
- `make symphony-runtime-smoke SCENARIO=workflow_contract` -> `1 test, 0 failures`
- `make symphony-runtime-smoke SCENARIO=all` -> `5 tests, 0 failures`
- `mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs:720 test/symphony_elixir/orchestrator_status_test.exs:862 test/symphony_elixir/orchestrator_status_test.exs:1025` -> `3 tests, 0 failures`
- `make symphony-validate`:
  - final rerun after `agent_runner` and `linear/client` updates is fully green (`contracts`, `build`, `format`, `lint`, `test --cover`, `dialyzer`; test phase `784 tests, 0 failures, 1 skipped`; dialyzer `Total errors: 0`)

## Live autonomous e2e on LET-738
### Runtime and service boundary
- Runtime launched with isolated workflow file and isolated ports:
  - workflow: `/private/tmp/let738-live.WORKFLOW.md`
  - run A port: `4119`, dashboard URL: `http://127.0.0.1:4119/proxy/symphony/`
  - run B port: `4120`, dashboard URL: `http://127.0.0.1:4120/proxy/symphony/`
  - run C workflow: `/private/tmp/let738-live-run6.WORKFLOW.md`
  - run C port: `4124`, dashboard URL: `http://127.0.0.1:4124/proxy/symphony/`
- Health/API checks:
  - `GET /health` -> `{"status":"ok"}`
  - `GET /api/dashboard` -> `200` with JSON payload
- No port conflict observed on `4119` / `4120` / `4124`.

### E2E outcome (current)
- Routing precondition applied per request: `LET-738` moved to `Todo` and labeled `mode:plan` before rerun.
- Run A (`4119`) reached active execution (`LET-738` in runtime `Todo / editing`, token growth beyond `500k`), proving route startup through `Todo + mode:plan`.
- During run A, external Linear quota (`429`) prevented state refresh and milestone writes. Root-cause signal:
  - `Linear GraphQL request failed status=429 ... "Rate limit exceeded. Only 2500 requests are allowed per 1 hour"` (`/private/tmp/symphony-let738-run-20260517-1/logs/log/symphony.log.1`)
- After applying milestone retry throttle, run B (`4120`) under the same global quota window no longer entered milestone retry storm; it fail-closed earlier at dispatch with explicit 429 signals:
  - `Skipping dispatch; issue refresh failed ... {:linear_api_status, 429}`
  - `Failed to fetch from Linear: {:linear_api_status, 429}`
- Run C (`4124`, corrected local `codex_home` mapping) dispatched `LET-738` from `Todo + mode:plan` and executed a full Codex turn (`in 409,482 / out 2,740 / total 412,222` in status panel), then completed `AgentRunner.run` without fatal `issue_state_refresh_failed`:
  - dispatch + run start: `/private/tmp/symphony-let738-run-20260517-6/logs/log/symphony.log.1:10`, `:11`
  - codex session completed: `/private/tmp/symphony-let738-run-20260517-6/logs/log/symphony.log.1:38`
  - completed agent run: `/private/tmp/symphony-let738-run-20260517-6/logs/log/symphony.log.1:39`
  - graceful 429 handoff (new behavior): `/private/tmp/symphony-let738-run-20260517-6/logs/log/symphony.log.1:41` (`Issue state refresh temporarily unavailable ... returning control to orchestrator for continuation retry`)
  - retry loop remains bounded/transient under cooldown: `/private/tmp/symphony-let738-run-20260517-6/logs/log/symphony.log.1:54` (retry in 10s), `/private/tmp/symphony-let738-run-20260517-6/logs/log/symphony.log.1:60` (retry in 20s)
- Canonical terminal completion on Linear (`Done`/`Blocked`) is still blocked until quota window recovers.

## Rollback/defer ledger
- Rollback: none required in this run.
- Deferred item:
  - Live e2e completion for `LET-738` is deferred by external Linear `429` quota state (global hourly window), not by handoff/contract/proof logic.
- Hidden carry-over:
  - none; all in-progress code edits are explicit in tracked files.

## Definition-of-done status
- Plan steps 1..9: closed (`verified-existing` or `completed-now`) with proof anchors.
- Mandatory gates: green after escalated validate rerun.
- Canonical live e2e `Plan -> Execute -> Review -> Done/Blocked` on new issue `LET-738`: **not yet completed** due external Linear `429` rate limit.
- `Todo + mode:plan` routing requirement is applied and verified in live runtime startup.

Final status for this run: **NOT DONE** (blocked externally by Linear API rate limiting during live autonomous e2e completion).

## Residual risks
- Until Linear quota recovers, runtime may stay in retry loops and cannot prove final autonomous transition on LET-738.
- Milestone 429 retry storm risk is reduced by per-milestone cooldown; residual blocker remains upstream Linear quota availability.
