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
| 7. Retry/failover simplification | `verified-existing` | Baseline constants retained: `@max_continuation_attempts_default 3`, `@failure_retry_base_ms 10_000`, `@linear_rate_limit_poll_backoff_ms 60_000`, `@tracker_escalation_infra_dedupe_ttl_ms 300_000`, `@tracker_retry_budget_ttl_ms 300_000` in `elixir/lib/symphony_elixir/orchestrator.ex:39`, `:40`, `:47`, `:54`, `:55`; retry-budget behavior proof at `elixir/test/symphony_elixir/execution_contract_test.exs:117` and `elixir/test/symphony_elixir/core_test.exs:5738` |
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

### Cheap and broader gates
- `make symphony-runtime-smoke SCENARIO=workflow_contract` -> `1 test, 0 failures`
- `make symphony-runtime-smoke SCENARIO=all` -> `5 tests, 0 failures`
- `make symphony-validate`:
  - first non-escalated attempt failed with sandbox write denial to `~/.hex/cache.ets` (`:eaccess`)
  - rerun with escalated permissions passed (`contracts`, `build`, `format`, `lint`, `test --cover`, `dialyzer`; test phase `782 tests, 0 failures, 1 skipped`; dialyzer `Total errors: 0`)

## Live autonomous e2e on LET-738
### Runtime and service boundary
- Runtime launched with isolated workflow file and isolated port:
  - workflow: `/private/tmp/let738-live.WORKFLOW.md`
  - port: `4114`
  - dashboard URL: `http://127.0.0.1:4114/proxy/symphony/`
- Health/API checks:
  - `GET /health` -> `{"status":"ok"}`
  - `GET /api/dashboard` -> `200` with JSON payload
- No port conflict observed on `4114`.

### E2E outcome (current)
- Issue is picked by runtime but autonomous flow does not reach `Done`/`Blocked` because Linear API calls are externally rate-limited.
- Dashboard proof snapshot (`2026-05-17T09:00:33Z`):
  - `counts.running=0`, `counts.retrying=1`
  - retry entry for `LET-738`: `attempt=6`, `error="retry poll failed: {:linear_api_status, 429}"`
  - `error_signature="failed_to_escalate_let_738_to_blocked_linear_api_status_429"`
  - next retry scheduled at `due_at="2026-05-17T09:03:44Z"`

## Rollback/defer ledger
- Rollback: none required in this run.
- Deferred item:
  - Live e2e completion for `LET-738` is deferred by external Linear `429` quota state, not by handoff/contract/proof logic.
- Hidden carry-over:
  - none; all in-progress code edits are explicit in tracked files.

## Definition-of-done status
- Plan steps 1..9: closed (`verified-existing` or `completed-now`) with proof anchors.
- Mandatory gates: green after escalated validate rerun.
- Canonical live e2e `Plan -> Execute -> Review -> Done/Blocked` on new issue `LET-738`: **not yet completed** due external Linear `429` rate limit.

Final status for this run: **NOT DONE** (blocked externally by Linear API rate limiting during live autonomous e2e completion).

## Residual risks
- Until Linear quota recovers, runtime may stay in retry loops and cannot prove final autonomous transition on LET-738.
- No new in-scope behavioral risk introduced by the assignee-id GraphQL type fix; regression tests for both assignee-id query shapes are now explicit.
