# PARITY-07 Evidence (2026-04-26)

## Ticket

- `PARITY-07` — Close long-lived runtime recovery parity
- Stream: `Stream 3` (Runtime / Codex Depth)
- Linear issue: `LET-643`
- Branch: `parity/parity-07-long-lived-runtime-recovery`

## Delivered Artifacts

- Plan:
  - `docs/symphony-next/plans/PARITY-07_PLAN.md`
- Contract:
  - `docs/symphony-next/contracts/PARITY-07_RUNTIME_RECOVERY_CONTRACT.md`
- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_07_runtime_recovery_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_07_runtime_recovery_live_sanitized.json`
- Live fixture generator:
  - `scripts/generate_parity_07_live_sanitized_fixture.sh`
- Executable suite:
  - `elixir/test/symphony_elixir/runtime_recovery_parity_test.exs`

## Acceptance Matrix Mapping

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
  - live-sanitized `LIVE-*` cases from real LET runtime/retry traces
- `PARITY-07-AM-08`:
  - preflight + acceptance preflight + parity suite + full `symphony-validate`
- `PARITY-07-AM-09`:
  - contract-doc consistency assertion in `runtime_recovery_parity_test.exs`
- `PARITY-07-AM-10`:
  - post-merge sanity (required in post-merge update)

## Runtime Delta

- Product runtime code changes не потребовались: drift закрыт через
  contract-level deterministic/live parity proof.
- Исправлен live fixture generator:
  - jq no-match extraction теперь возвращает `null`, не `empty`,
    чтобы не терять resume-mode live cases.

## Live Sampling Summary

- Linear query filters:
  - `comments contains "resume_mode"`
  - `comments contains "Retry/failover decision (auto-classified)"`
- Sampled issues:
  - resume contour: `5`
  - retry/failover contour: `12`
- Produced live cases: `17`
  - `classified_handoff_stop`: `14`
  - `resume_checkpoint_recovery`: `2`
  - `fallback_reread_recovery`: `1`
- Replacement-scope `unknown` classes in live fixture: `0`
- Sampled identifiers:
  - `LET-473`, `LET-474`, `LET-518`, `LET-559`, `LET-577`, `LET-598`,
    `LET-599`, `LET-609`, `LET-610`, `LET-611`, `LET-638`

## Validation Commands

Executed in `/private/tmp/symphony-parity-main`:

1. `scripts/generate_parity_07_live_sanitized_fixture.sh`
2. `make symphony-preflight`
3. `make symphony-acceptance-preflight`
4. `cd elixir && mise exec -- mix test test/symphony_elixir/runtime_recovery_parity_test.exs`
5. `make symphony-validate`

Result: all listed commands passed.

## Artifact Hashes (SHA256)

- `44ae774aaa37d6d063af8f2e654093acf1b00815a51eee6ca49957c9133db3ee` —
  `docs/symphony-next/plans/PARITY-07_PLAN.md`
- `9538fd03bf3aac3043923ac4571d73dc575129e799b851ce6a79f2311938194f` —
  `docs/symphony-next/contracts/PARITY-07_RUNTIME_RECOVERY_CONTRACT.md`
- `45dc146010d80107a3d653fc80fc9b506add6e27ce80f41fce0a984ed8fa2e33` —
  `elixir/test/fixtures/parity/parity_07_runtime_recovery_matrix.json`
- `be851fccadda69c1b068c9bebd4e8ee61149685438e744cd2f8e9600a9814870` —
  `elixir/test/fixtures/parity/parity_07_runtime_recovery_live_sanitized.json`
- `36ac64b886a6b6f0812b8169b43b0dea1caee8a31fff285cc3bb5168806dbb38` —
  `elixir/test/symphony_elixir/runtime_recovery_parity_test.exs`
- `2578948e3d7f2a664713107eb76c2c7df9bbc31ab79866c05e375569d3b7d13b` —
  `scripts/generate_parity_07_live_sanitized_fixture.sh`

## Blockers

- None on implementation/proof path for `PARITY-07`.
