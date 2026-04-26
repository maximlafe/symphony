# PARITY-06 Evidence (2026-04-26)

## Ticket

- `PARITY-06` — Prove merge gating parity
- Stream: `Stream 2` (GitHub / Review / Merge Semantics)
- Linear issue: `LET-641`
- Branch: `parity/parity-06-prove-merge-gating-parity`

## Delivered Artifacts

- Plan:
  - `docs/symphony-next/plans/PARITY-06_PLAN.md`
- Contract:
  - `docs/symphony-next/contracts/PARITY-06_MERGE_GATING_CONTRACT.md`
- Runtime update:
  - `elixir/lib/symphony_elixir/handoff_check.ex`
- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_06_merge_gating_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_06_merge_gating_live_sanitized.json`
- Live fixture generator:
  - `scripts/generate_parity_06_live_sanitized_fixture.sh`
- Executable suite:
  - `elixir/test/symphony_elixir/merge_gating_parity_test.exs`

## Acceptance Matrix Mapping

- `PARITY-06-AM-01`:
  - deterministic case `DET-MERGE-READY-CLEAN`
- `PARITY-06-AM-02`:
  - deterministic case `DET-NOT-READY-CHECKS-FAILED`
- `PARITY-06-AM-03`:
  - deterministic case `DET-NOT-READY-PENDING`
- `PARITY-06-AM-04`:
  - deterministic case `DET-NOT-READY-ACTIONABLE`
- `PARITY-06-AM-05`:
  - deterministic cases:
    - `DET-NOT-READY-MERGE-UNSTABLE`
    - `DET-NOT-READY-MERGE-MISSING`
- `PARITY-06-AM-06`:
  - deterministic case `DET-TRANSITION-STALE-HEAD`
- `PARITY-06-AM-07`:
  - deterministic case `DET-TRANSITION-STALE-WORKPAD`
- `PARITY-06-AM-08`:
  - deterministic case `DET-TRANSITION-FRESH`
- `PARITY-06-AM-09`:
  - live-sanitized `LIVE-*` cases from real LET comments with
    merge/check signals
- `PARITY-06-AM-10`:
  - contract-doc consistency assertion in `merge_gating_parity_test.exs`

## Runtime Delta

- Merge-ready rule switched to fail-closed allowlist in `HandoffCheck`:
  - allowed: `CLEAN`, `HAS_HOOKS`
  - non-allowlist / missing / ambiguous merge states => not ready
- This removes replacement-scope fail-open behavior for ambiguous
  `merge_state_status`.

## Live Sampling Summary

- Linear query filter:
  - `comments contains "merge_state_status"`
- Sampled issues: `16`
- Produced live cases: `2`
  - `merge_ready=true`: `1`
  - `merge_ready=false`: `1`
- Live fixture is sanitized and stores only observed merge/check fields plus
  expected canonical decision.

## Validation Commands

Executed in `/private/tmp/symphony-parity-main`:

1. `scripts/generate_parity_06_live_sanitized_fixture.sh`
2. `make symphony-preflight`
3. `make symphony-acceptance-preflight`
4. `cd elixir && mise exec -- mix format --check-formatted`
5. `cd elixir && mise exec -- mix test test/symphony_elixir/merge_gating_parity_test.exs`
6. `cd elixir && mise exec -- mix test test/symphony_elixir/merge_gating_parity_test.exs test/symphony_elixir/handoff_check_test.exs test/symphony_elixir/finalizer_semantics_parity_test.exs`
7. `cd elixir && mise exec -- make all`

Result: all listed commands passed.

## Artifact Hashes (SHA256)

- `f6dee4f7edbaf655791b2963d648d1944c18e891bba1d9a15fe0c97e7661ce32` —
  `elixir/lib/symphony_elixir/handoff_check.ex`
- `ac752e7a357a4fb6f8011b39ff8afe4daea5e76664ed5139e3d0b0a5645f46b4` —
  `docs/symphony-next/contracts/PARITY-06_MERGE_GATING_CONTRACT.md`
- `dc8a0b99dc74c29abd7d8ffb355be9f270ba3bb9697df234649f975d166d564c` —
  `docs/symphony-next/plans/PARITY-06_PLAN.md`
- `1f354fc4f3ce2cd8cea21ef31f1eb29104fcff63b957bc8061a20677037278ab` —
  `elixir/test/fixtures/parity/parity_06_merge_gating_matrix.json`
- `de8e9a03721fd9eb8fa464e05387e49e2f195982fa7e72f2765611628f9cc337` —
  `elixir/test/fixtures/parity/parity_06_merge_gating_live_sanitized.json`
- `5761299f22aa98e6523821aaa160e018ba1a0d4c70d6d67a3bf52c1d435fd303` —
  `elixir/test/symphony_elixir/merge_gating_parity_test.exs`
- `95f47d32692643606e6ceb61cce9d96823ff0a917f3b2ad851e16d8f8fd45ff3` —
  `scripts/generate_parity_06_live_sanitized_fixture.sh`

## Blockers

- None on implementation/proof path for `PARITY-06`.
