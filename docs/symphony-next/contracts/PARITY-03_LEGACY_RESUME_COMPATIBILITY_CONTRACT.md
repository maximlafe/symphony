# PARITY-03: Legacy Resume Compatibility Contract

## Purpose

Freeze replacement-scope resume compatibility for legacy issue traces.

`Symphony-next` must continue in-flight legacy issues without ambiguous recovery
decisions when checkpoint surfaces are partial or stale.

## Canonical Resume Decision Surface

1. `resume_mode`
   - Allowed values:
     - `resume_checkpoint`
     - `fallback_reread`
2. `resume_fallback_reason`
   - Required when `resume_mode=fallback_reread`.
   - Must be machine-readable (snake_case code).
3. `resume_ready`
   - `true` only for a ready checkpoint surface.
   - If `resume_ready=false`, decision must fail closed to `fallback_reread`.

## No-Ambiguity Rule

A resume trace is considered ambiguous (and therefore invalid for parity) if any
of these conditions hold:

1. `resume_mode` is missing or outside allowed values.
2. `resume_mode=resume_checkpoint` while `resume_ready != true`.
3. `resume_mode=fallback_reread` with missing/blank `resume_fallback_reason`.

## Legacy Compatibility Inputs

Contract coverage must include both:

1. Deterministic legacy checkpoint shapes (matrix fixture).
2. Real sanitized historical LET traces with explicit `resume_mode` signals.

## Required Fallback Reason Mapping

Legacy textual fallback causes must normalize to canonical reason codes:

- `resume checkpoint is unavailable` -> `resume_checkpoint_unavailable`
- `workspace is unavailable for retry checkpoint capture` -> `workspace_unavailable`
- `resume checkpoint capture failed: ...` -> `checkpoint_capture_failed`
- `resume checkpoint ... mismatch ...` -> `checkpoint_mismatch`
- `missing ... in resume checkpoint` -> `checkpoint_missing_required_field`
- unknown textual cause -> `checkpoint_not_ready`

## Replacement Scope

- Team: `LET`
- Live filter for fixture generation:
  - `comments contains "resume_mode"`

## Sanitization Rules

1. Strip control bytes from raw Linear payload before JSON parsing.
2. Replace issue identifiers with synthetic fixture case identifiers in
   executable assertions.
3. Keep only minimal trace evidence:
   - sampled identifier (reference),
   - state,
   - created timestamp,
   - redacted `resume_mode` excerpt.
4. Do not commit full raw comment bodies from live issues.

## Evidence Sources

- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_03_resume_legacy_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_03_resume_legacy_live_sanitized.json`
- Fixture generator:
  - `scripts/generate_parity_03_live_sanitized_fixture.sh`
- Executable proof:
  - `elixir/test/symphony_elixir/resume_legacy_parity_test.exs`
