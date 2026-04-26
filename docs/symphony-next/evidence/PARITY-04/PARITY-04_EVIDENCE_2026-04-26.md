# PARITY-04 Evidence (2026-04-26)

## Ticket

- `PARITY-04` — Freeze PR evidence contract
- Stream: `Stream 2` (GitHub / Review / Merge Semantics)
- Linear issue: `LET-639`
- Branch: `parity/parity-04-freeze-pr-evidence-contract`

## Delivered Artifacts

- Contract:
  - `docs/symphony-next/contracts/PARITY-04_PR_EVIDENCE_CONTRACT.md`
- Plan:
  - `docs/symphony-next/plans/PARITY-04_PLAN.md`
- Resolver implementation:
  - `elixir/lib/symphony_elixir/pr_evidence.ex`
- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_04_pr_evidence_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_04_pr_evidence_live_sanitized.json`
- Live fixture generator:
  - `scripts/generate_parity_04_live_sanitized_fixture.sh`
- Executable suite:
  - `elixir/test/symphony_elixir/pr_evidence_parity_test.exs`
  - `elixir/test/symphony_elixir/pr_evidence_test.exs`

## Acceptance Matrix Mapping

- `PARITY-04-AM-01`:
  - deterministic case `DET-WORKSPACE-CHECKPOINT`
- `PARITY-04-AM-02`:
  - deterministic case `DET-WORKPAD-MARKER`
- `PARITY-04-AM-03`:
  - deterministic case `DET-ISSUE-COMMENT-URL` + live `LIVE-COMMENT-*`
- `PARITY-04-AM-04`:
  - deterministic cases `DET-ISSUE-ATTACHMENT-URL` / `DET-ISSUE-ATTACHMENT-MARKER` + live `LIVE-ATTACHMENT-*`
- `PARITY-04-AM-05`:
  - deterministic case `DET-BRANCH-LOOKUP` + live `LIVE-BRANCH-*`
- `PARITY-04-AM-06`:
  - deterministic case `DET-PRECEDENCE-WORKSPACE-WINS`
- `PARITY-04-AM-07`:
  - deterministic case `DET-FAIL-CLOSED-NONE` (`source=none`)
- `PARITY-04-AM-08`:
  - live-sanitized fixture generated from real LET issues and executed by the same parity runner
- `PARITY-04-AM-09`:
  - explicit contract-doc consistency assertion in `pr_evidence_parity_test.exs`

## Live Sampling Summary

- Linear query filter:
  - `comments contains "/pull/"`
- Live evidence channels in fixture:
  - `issue_comment`: `12` cases
  - `issue_attachment`: `12` cases
  - `branch_lookup`: `12` cases
- Sampled issues:
  - comment query: `80`
  - branch candidate query: `120`
- Branch lookup origin:
  - `issue_trace_url_fallback` for generated `LIVE-BRANCH-*` cases
  - reason: `gh pr list --head` returned no stable matches for sampled historical heads

## Validation Commands

Executed in `/private/tmp/symphony-parity-main`:

1. `scripts/generate_parity_04_live_sanitized_fixture.sh`
2. `make symphony-preflight`
3. `make symphony-acceptance-preflight`
4. `cd elixir && mise exec -- mix format --check-formatted`
5. `cd elixir && mise exec -- mix test test/symphony_elixir/pr_evidence_parity_test.exs test/symphony_elixir/linear_routing_parity_test.exs test/symphony_elixir/issue_trace_parity_test.exs test/symphony_elixir/resume_legacy_parity_test.exs`
6. `cd elixir && mise exec -- mix test test/symphony_elixir/telemetry_schema_test.exs test/symphony_elixir/resume_checkpoint_test.exs test/symphony_elixir/core_test.exs`
7. `cd elixir && mise exec -- make all`

Result: all listed commands passed.

## Artifact Hashes (SHA256)

- `f4e981b7d4bfd7f2e32c197d6854f74d07072e898012dc8e02a11e3a88d54433` — `docs/symphony-next/contracts/PARITY-04_PR_EVIDENCE_CONTRACT.md`
- `4c490ad538e5a3f77a827790ba28f36559064f507c986273cdb975f4304a24be` — `elixir/lib/symphony_elixir/pr_evidence.ex`
- `87ae73b0be785442f555a47bbabaf86cf81d3d622231ff259b797669b9167feb` — `elixir/test/fixtures/parity/parity_04_pr_evidence_matrix.json`
- `aac0ed2bf0a9954f403f2b9cab04fca3e7c889880149de7a68470f43f3ee87fa` — `elixir/test/fixtures/parity/parity_04_pr_evidence_live_sanitized.json`
- `f334dd79dbaed7a12362bc84abeded8016b6b0adf060df723f750d17a395a6c2` — `elixir/test/symphony_elixir/pr_evidence_test.exs`
- `051128459e5515c63dff636bb69c85bd072fc2ded5f5819ff819611af8ea76e1` — `elixir/test/symphony_elixir/pr_evidence_parity_test.exs`
- `46c4753274069691e220eacc1dd3ea6b9e8ddc8a4797d91d5f04e76d7c33de11` — `scripts/generate_parity_04_live_sanitized_fixture.sh`

## Blockers

- None on implementation/proof path for `PARITY-04`.
