# LET-673 Token Cost Reduction Plan

## Context

During LET-673 execution, one run accumulated very high token usage (dominantly input tokens) while cycling through validation-heavy phases. The main driver was high-volume command output streaming during `full validate` and repeated expensive validation gates inside one long-running turn.

## Goals

1. Reduce token burn per LET execution run.
2. Keep contract safety for handoff and merge-readiness.
3. Avoid reintroducing long expensive loops when retries/escalations fail.

## Scope

In scope:
- Workflow policy for when full validation is required.
- Validation verbosity and output handling.
- Polling behavior during CI wait.
- Duplicate local validation work in Make targets.

Out of scope:
- Weakening acceptance/handoff contract semantics.
- Removing critical checks (`test --cover`, `dialyzer`) without replacement policy.

## Plan

### P0: Fast Low-Risk Changes

1. Gate repeated `full validate` by tree change.
- Adjust workflow wording/logic so mandatory rerun is required only when `HEAD^{tree}` changed since last final validation checkpoint.
- Keep strict full validate before final merge-ready transition.

2. Increase CI polling interval.
- Use `github_wait_for_checks` with `poll_interval_ms: 30000` instead of 10000 in workflow paths.
- Keep timeout unchanged.

3. Remove local duplicate validation steps.
- Eliminate repeated expensive dependency checks in `validation-env-check`.
- Reassess top-level `make test` chaining to avoid redundant dashboard pass if already covered by full test suite.

### P1: Medium-Risk, High Payoff

1. Split `github_pr_snapshot` into lightweight and detailed modes.
- Default to lightweight summary fetch.
- Fetch reviews/comments/details only when required for a decision point.

2. Reduce command-output token amplification.
- For heavy validation commands, stream concise progress + failure snippets instead of full output delta into model context.
- Persist full raw output to artifacts/log files for debugging.

3. Throttle orchestration/UI update cadence for streaming events.
- Coalesce frequent stream-notification updates to bounded refresh intervals.

### P2: Hardening Against Recurrence

1. Strengthen retry dedupe for repeated expensive validation surfaces.
- Detect first duplicate expensive retry surface earlier for selected non-recoverable classes.

2. Persist milestone/comment dedupe state across retries.
- Avoid repeated write attempts/noise on resumptions.

## Retro Basis: Already Changed Files (LET-673 fix)

Core fix commit: `bf65a86` (`cf81052` on VPS cherry-pick)

- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `elixir/lib/symphony_elixir/handoff_check.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/test/symphony_elixir/core_test.exs`
- `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- `elixir/test/symphony_elixir/handoff_check_test.exs`

## Acceptance Criteria

1. No reoccurrence of PR-linked attachment being validated as uploaded artifact proof.
2. No unbounded expensive retry loop on escalation failure.
3. Median token usage for LET backend runs decreases measurably after P0.
4. Validation and handoff contracts still pass on representative LET runs.

## Rollout Order

1. Land P0.
2. Observe 3-5 LET runs and compare token/runtime baselines.
3. Land P1 changes incrementally behind safe defaults.
4. Land P2 hardening after validating failure-classification quality.
