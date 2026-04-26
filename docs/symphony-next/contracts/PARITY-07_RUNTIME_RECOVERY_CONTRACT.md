# PARITY-07: Runtime Recovery Contract

## Purpose

Freeze replacement-scope runtime recovery behavior so long-lived restart/retry
paths stay deterministic and fail closed.

`Symphony-next` must preserve stable recovery behavior under repeated polling,
stalled worker restarts, and replay of the same runtime event sequence.

## Canonical Recovery Rules

1. Stalled worker restart:
   - when activity exceeds stall timeout, worker is terminated and retry is
     scheduled with transient classification.
2. Pre-run hook guard:
   - active pre-run hook window must not be treated as stalled work.
3. Resume checkpoint reload priority:
   - when loaded checkpoint is `resume_ready=true`, it overrides stale fallback
     retry checkpoint input.
4. Orphaned retry claim reconcile:
   - missing retry token + no running entry + no retry entry must release claim.
5. Replay stability:
   - replaying the same codex event log over the same baseline must yield the
     same normalized runtime snapshot fields.

## Fail-Closed Rule

- Any unstable replay result for the same event sequence is a parity failure.
- Replacement-scope runtime recovery cannot be marked done if replay class is
  `unknown`.

## Canonical Live Recovery Classes

- `resume_checkpoint_recovery`
- `fallback_reread_recovery`
- `classified_handoff_stop`

`unknown` is non-acceptable for replacement-scope live evidence.

## Acceptance Mapping

- `PARITY-07-AM-01`:
  - deterministic case `DET-STALL-RETRY-BACKOFF`
- `PARITY-07-AM-02`:
  - deterministic case `DET-PRE-RUN-HOOK-GUARD`
- `PARITY-07-AM-03`:
  - deterministic case `DET-RETRY-TERMINAL-RECONCILE`
- `PARITY-07-AM-04`:
  - deterministic case `DET-RESUME-CHECKPOINT-RELOAD`
- `PARITY-07-AM-05`:
  - deterministic case `DET-ORPHANED-CLAIM-RECONCILE`
- `PARITY-07-AM-06`:
  - deterministic case `DET-REPLAY-STABILITY`
- `PARITY-07-AM-07`:
  - live `LIVE-*` cases from
    `scripts/generate_parity_07_live_sanitized_fixture.sh`
- `PARITY-07-AM-08`:
  - validation matrix execution in evidence doc
- `PARITY-07-AM-09`:
  - contract-doc consistency assertion in
    `runtime_recovery_parity_test.exs`
- `PARITY-07-AM-10`:
  - post-merge sanity execution log in evidence doc

## Sanitization Rules

1. Strip control bytes from raw Linear payload before parse.
2. Keep only:
   - sampled issue metadata,
   - observed recovery markers (`resume_mode`, `selected_rule`,
     `selected_action`),
   - expected canonical class.
3. Do not store full raw comments or unrelated operator context.

## Evidence Sources

- Runtime logic:
  - `elixir/lib/symphony_elixir/orchestrator.ex`
  - `elixir/lib/symphony_elixir/resume_checkpoint.ex`
  - `elixir/lib/symphony_elixir/run_phase.ex`
- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_07_runtime_recovery_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_07_runtime_recovery_live_sanitized.json`
- Fixture generator:
  - `scripts/generate_parity_07_live_sanitized_fixture.sh`
- Executable proof:
  - `elixir/test/symphony_elixir/runtime_recovery_parity_test.exs`
