# PARITY-06: Merge Gating Contract

## Purpose

Freeze replacement-scope merge-readiness behavior so review/handoff merge
decisions stay deterministic and fail closed.

`Symphony-next` must not treat ambiguous PR merge state as merge-ready.

## Canonical Merge-Ready Decision

A PR is `merge_ready=true` only when all conditions are true:

1. `all_checks_green == true`
2. `has_pending_checks == false`
3. `has_actionable_feedback == false`
4. `merge_state_status` is allowlisted (`CLEAN` or `HAS_HOOKS`)

If any condition fails, `merge_ready=false`.

## Fail-Closed Rule

- `merge_state_status` missing, empty, unknown, or non-allowlist -> not ready.
- Replacement-scope `unknown` merge state is never treated as ready.

## Stale-Proof Transition Rule

`review_ready_transition_allowed?` must fail closed when:

1. validation gate final proof metadata is stale/incomplete for current git HEAD;
2. workpad SHA changed after successful handoff check.

Only fresh manifest + fresh git + unchanged workpad may pass.

## Canonical Not-Ready Reasons

- `pull request checks are not fully green`
- `pull request still has pending checks`
- `pull request still has actionable feedback`
- `pull request is not merge-ready`

## Acceptance Mapping

- `PARITY-06-AM-01`:
  - deterministic case `DET-MERGE-READY-CLEAN`
- `PARITY-06-AM-02`:
  - deterministic case `DET-NOT-READY-CHECKS-FAILED`
- `PARITY-06-AM-03`:
  - deterministic case `DET-NOT-READY-PENDING`
- `PARITY-06-AM-04`:
  - deterministic case `DET-NOT-READY-ACTIONABLE`
- `PARITY-06-AM-05`:
  - deterministic cases `DET-NOT-READY-MERGE-UNSTABLE`,
    `DET-NOT-READY-MERGE-MISSING`
- `PARITY-06-AM-06`:
  - deterministic case `DET-TRANSITION-STALE-HEAD`
- `PARITY-06-AM-07`:
  - deterministic case `DET-TRANSITION-STALE-WORKPAD`
- `PARITY-06-AM-08`:
  - deterministic case `DET-TRANSITION-FRESH`
- `PARITY-06-AM-09`:
  - live `LIVE-*` cases from
    `scripts/generate_parity_06_live_sanitized_fixture.sh`
- `PARITY-06-AM-10`:
  - contract-doc consistency assertion in
    `merge_gating_parity_test.exs`

## Sanitization Rules

1. Strip control bytes from raw Linear payload before parse.
2. Keep only:
   - sampled issue metadata,
   - observed merge/check fields,
   - expected merge-ready decision.
3. Do not store full raw comments or non-essential operator text.

## Evidence Sources

- Runtime gate:
  - `elixir/lib/symphony_elixir/handoff_check.ex`
- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_06_merge_gating_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_06_merge_gating_live_sanitized.json`
- Fixture generator:
  - `scripts/generate_parity_06_live_sanitized_fixture.sh`
- Executable proof:
  - `elixir/test/symphony_elixir/merge_gating_parity_test.exs`
