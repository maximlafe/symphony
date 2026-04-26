# PARITY-05: Review/Finalizer Semantics Contract

## Purpose

Freeze replacement-scope controller finalizer decisions so review/handoff/merge
semantics cannot silently drift.

`Symphony-next` must keep deterministic decisions for checks, actionable review
feedback, proof gate, handoff validation, and state-transition behavior.

## Canonical Decision Surface

Canonical outcomes:

- `ok`
- `retry`
- `fallback`
- `not_applicable`

Canonical checkpoint fields:

- `controller_finalizer.status`
- `controller_finalizer.reason`
- `controller_finalizer.blocked_reason`
- `controller_finalizer.blocked_pr_number`
- `controller_finalizer.blocked_head`

## Canonical Reason Mapping

Deterministic contract reasons:

- `pull request checks failed`
- `pull request checks are still pending`
- `pull request has actionable feedback`
- `symphony_handoff_check failed`
- `required proof checks are missing before handoff`
- `failed to transition issue state`
- `controller finalizer completed successfully`

## Live Trace Mapping Rules

Live traces may carry either canonical reasons or compact status markers from
real issue worklogs. For live parity we accept both:

1. Canonical reason strings (exact mapping).
2. Explicit status markers:
   - `controller_finalizer.status=action_required` -> `fallback`
   - `controller_finalizer.status=waiting` -> `retry`
   - `controller_finalizer.status=not_applicable` -> `not_applicable`
3. Merge confirmation marker:
   - `merge commit observed in live task report` -> `ok`

Live mapping must still produce deterministic `outcome` + `controller_status`.

## Acceptance Mapping

- `PARITY-05-AM-01`:
  - deterministic case `DET-CHECKS-FAILED`.
- `PARITY-05-AM-02`:
  - deterministic case `DET-CHECKS-PENDING`.
- `PARITY-05-AM-03`:
  - deterministic case `DET-ACTIONABLE-FEEDBACK`.
- `PARITY-05-AM-04`:
  - deterministic case `DET-HANDOFF-FAILED`.
- `PARITY-05-AM-05`:
  - deterministic case `DET-SUCCESS`.
- `PARITY-05-AM-06`:
  - deterministic case `DET-TRANSITION-FAILED`.
- `PARITY-05-AM-07`:
  - deterministic case `DET-PROOF-GATE-MISSING`.
- `PARITY-05-AM-08`:
  - deterministic case `DET-BLOCKED-REPLAY-GUARD`.
- `PARITY-05-AM-09`:
  - live cases `LIVE-*` produced from real LET issue comments via
    `scripts/generate_parity_05_live_sanitized_fixture.sh`.
- `PARITY-05-AM-10`:
  - this contract document is asserted by
    `finalizer_semantics_parity_test.exs`.

## Sanitization Rules

1. Strip control bytes from raw Linear payload before JSON parsing.
2. Keep only minimal proof fields:
   - sampled issue identifier/state,
   - sampled comment timestamp,
   - short redacted excerpt,
   - normalized observed/expected decision tuple.
3. Do not store full raw comments or sensitive run payloads.

## Evidence Sources

- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_05_finalizer_semantics_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_05_finalizer_semantics_live_sanitized.json`
- Fixture generator:
  - `scripts/generate_parity_05_live_sanitized_fixture.sh`
- Runtime surface:
  - `elixir/lib/symphony_elixir/controller_finalizer.ex`
- Executable proof:
  - `elixir/test/symphony_elixir/finalizer_semantics_parity_test.exs`
