# PARITY-05 Evidence (2026-04-26)

## Ticket

- `PARITY-05` — Encode review/finalizer semantics explicitly
- Stream: `Stream 2` (GitHub / Review / Merge Semantics)
- Linear issue: `LET-640`
- Branch: `parity/parity-05-encode-review-finalizer-semantics`

## Delivered Artifacts

- Plan:
  - `docs/symphony-next/plans/PARITY-05_PLAN.md`
- Contract:
  - `docs/symphony-next/contracts/PARITY-05_FINALIZER_SEMANTICS_CONTRACT.md`
- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_05_finalizer_semantics_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_05_finalizer_semantics_live_sanitized.json`
- Live fixture generator:
  - `scripts/generate_parity_05_live_sanitized_fixture.sh`
- Executable suite:
  - `elixir/test/symphony_elixir/finalizer_semantics_parity_test.exs`

## Acceptance Matrix Mapping

- `PARITY-05-AM-01`:
  - deterministic case `DET-CHECKS-FAILED`
- `PARITY-05-AM-02`:
  - deterministic case `DET-CHECKS-PENDING`
- `PARITY-05-AM-03`:
  - deterministic case `DET-ACTIONABLE-FEEDBACK`
- `PARITY-05-AM-04`:
  - deterministic case `DET-HANDOFF-FAILED`
- `PARITY-05-AM-05`:
  - deterministic case `DET-SUCCESS`
- `PARITY-05-AM-06`:
  - deterministic case `DET-TRANSITION-FAILED`
- `PARITY-05-AM-07`:
  - deterministic case `DET-PROOF-GATE-MISSING`
- `PARITY-05-AM-08`:
  - deterministic case `DET-BLOCKED-REPLAY-GUARD`
- `PARITY-05-AM-09`:
  - live-sanitized `LIVE-*` cases from real LET issue comments
- `PARITY-05-AM-10`:
  - explicit contract-doc consistency assertion in
    `finalizer_semantics_parity_test.exs`

## Live Sampling Summary

- Linear query filters:
  - `comments contains "controller_finalizer"`
  - `comments contains "action_required"`
  - `comments contains "PR смержен"`
- Sampled issues: `18`
- Produced cases: `7`
  - `fallback`: `1`
  - `ok`: `6`
  - `retry`: `0`
  - `not_applicable`: `0`
- Live mapper preserves deterministic `outcome` + `controller_status` semantics,
  while allowing status/merge-marker inference when canonical reason strings are
  absent in operator worklogs.

## Validation Commands

Executed in `/private/tmp/symphony-parity-main`:

1. `scripts/generate_parity_05_live_sanitized_fixture.sh`
2. `make symphony-preflight`
3. `make symphony-acceptance-preflight`
4. `cd elixir && mise exec -- mix format --check-formatted`
5. `cd elixir && mise exec -- mix test test/symphony_elixir/finalizer_semantics_parity_test.exs`
6. `cd elixir && mise exec -- mix test test/symphony_elixir/finalizer_semantics_parity_test.exs test/symphony_elixir/controller_finalizer_test.exs test/symphony_elixir/pr_evidence_parity_test.exs`
7. `cd elixir && mise exec -- make all`

Result: all listed commands passed.

## Artifact Hashes (SHA256)

- `e38d65a96631e3a07fc705ec905419633d4006c26362dcc7c780fbd58d111b5c` —
  `docs/symphony-next/contracts/PARITY-05_FINALIZER_SEMANTICS_CONTRACT.md`
- `f3ccbce66e582a0b2a6d43e0d99f106c376744d1701747617b508b48bd8370f9` —
  `docs/symphony-next/plans/PARITY-05_PLAN.md`
- `8af67043895c89f64fac4da9da94c9b31fb4ecf05c1a30bfaa30a45027af40b6` —
  `elixir/test/fixtures/parity/parity_05_finalizer_semantics_matrix.json`
- `bad54e1c9a436db8a4cb8fed582c1e02e6f2bb0b64b3218643a8de1bc02eb8e7` —
  `elixir/test/fixtures/parity/parity_05_finalizer_semantics_live_sanitized.json`
- `fd0642990ff92cc85eab9f87237aa7624c52b04b19acb98793ba2e873663c200` —
  `elixir/test/symphony_elixir/finalizer_semantics_parity_test.exs`
- `faf1081aa83d86091990da2187b362e0a9236aa42b2b7c7d31541b148b401eaa` —
  `scripts/generate_parity_05_live_sanitized_fixture.sh`

## Blockers

- None on implementation/proof path for `PARITY-05`.
