# PARITY-03 Evidence (2026-04-26)

## Ticket

- `PARITY-03` — Prove old-trace resume compatibility
- Stream: `Stream 1` (Tracker / Linear replacement proof)
- Linear issue: `LET-638`
- Branch: `parity/parity-03-prove-old-trace-resume-compatibility`

## Delivered Artifacts

- Contract:
  - `docs/symphony-next/contracts/PARITY-03_LEGACY_RESUME_COMPATIBILITY_CONTRACT.md`
- Plan:
  - `docs/symphony-next/plans/PARITY-03_PLAN.md`
- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_03_resume_legacy_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_03_resume_legacy_live_sanitized.json`
- Live fixture generator:
  - `scripts/generate_parity_03_live_sanitized_fixture.sh`
- Executable suite:
  - `elixir/test/symphony_elixir/resume_legacy_parity_test.exs`
- Runtime fail-closed fix:
  - `elixir/lib/symphony_elixir/telemetry_schema.ex`
  - `elixir/test/symphony_elixir/telemetry_schema_test.exs`

## Acceptance Matrix Mapping

- `PARITY-03-AM-01..04`:
  - Covered by deterministic cases in `parity_03_resume_legacy_matrix.json`
  - Executed by `resume_legacy_parity_test.exs`
- `PARITY-03-AM-05..06`:
  - Covered by live-sanitized cases from real LET traces (`LET-474`, `LET-559`)
  - Executed by `resume_legacy_parity_test.exs`
- `PARITY-03-AM-07`:
  - Runtime payload assertions in `resume_legacy_parity_test.exs`
- `PARITY-03-AM-08`:
  - Contract doc fields and assertions aligned with suite expectations

## Live Sampling Summary

- Query filter: `comments contains "resume_mode"`
- Sampled issues: `LET-474`, `LET-559`
- Sampled trace count: `2`
- Sanitization:
  - control-byte stripping before JSON parsing
  - redacted trace excerpts only (no full raw comment bodies)

## Validation Commands

Executed in `/private/tmp/symphony-parity-main`:

1. `make symphony-preflight`
2. `make symphony-acceptance-preflight`
3. `cd elixir && mise exec -- mix format --check-formatted`
4. `cd elixir && mise exec -- mix test test/symphony_elixir/resume_legacy_parity_test.exs test/symphony_elixir/telemetry_schema_test.exs test/symphony_elixir/resume_checkpoint_test.exs test/symphony_elixir/core_test.exs`
5. `cd elixir && mise exec -- mix test test/symphony_elixir/linear_routing_parity_test.exs test/symphony_elixir/issue_trace_parity_test.exs test/symphony_elixir/resume_legacy_parity_test.exs`

Result: all listed commands passed.

## Artifact Hashes (SHA256)

- `4175fb877aec0c4ae0d5b4771cc14094b65ac42152bdbe0a37960dacebaf215d` — `elixir/test/fixtures/parity/parity_03_resume_legacy_matrix.json`
- `a109912102a08db6a099a911e3105235301e1b2866294a12719ed12ebae1bc86` — `elixir/test/fixtures/parity/parity_03_resume_legacy_live_sanitized.json`
- `616c1b7193a067806bf509790bddbfe07a8969522a24fef93603dd8afe95e543` — `docs/symphony-next/contracts/PARITY-03_LEGACY_RESUME_COMPATIBILITY_CONTRACT.md`
- `b68d4818bd2c39f27da05a743a5605270ca580aa6bfc7a063e233e9981e8d09a` — `elixir/test/symphony_elixir/resume_legacy_parity_test.exs`
- `19da81994cabb5732d8c3f7fca28e776124c2a492b89099f829bcae66455bae3` — `scripts/generate_parity_03_live_sanitized_fixture.sh`

## Notable Finding / Fix

- Before fix, legacy payload with `resume_mode=resume_checkpoint` and
  `resume_ready=false` could produce ambiguous recovery metadata.
- Applied fail-closed normalization in `TelemetrySchema.derive_resume_mode/2`:
  - if checkpoint is not ready, mode is forced to `fallback_reread`
  - fallback reason remains machine-readable.

## Blockers

- None on implementation/proof path for `PARITY-03`.
