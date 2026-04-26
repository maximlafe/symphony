# PARITY-14 Evidence (2026-04-26)

## Ticket

- `PARITY-14` — Complete actionable review feedback classification
- Stream: `Stream 2` (GitHub / Review / Merge Semantics)
- Linear issue: `LET-642`
- Branch: `parity/parity-14-actionable-feedback-classification`

## Delivered Artifacts

- Plan:
  - `docs/symphony-next/plans/PARITY-14_PLAN.md`
- Contract:
  - `docs/symphony-next/contracts/PARITY-14_ACTIONABLE_REVIEW_FEEDBACK_CONTRACT.md`
- Runtime updates:
  - `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
  - `elixir/lib/symphony_elixir/controller_finalizer.ex`
  - `elixir/lib/symphony_elixir/handoff_check.ex`
- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_14_actionable_feedback_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_14_actionable_feedback_live_sanitized.json`
- Live fixture generator:
  - `scripts/generate_parity_14_live_sanitized_fixture.sh`
- Executable suite:
  - `elixir/test/symphony_elixir/actionable_feedback_parity_test.exs`

## Acceptance Matrix Mapping

- `PARITY-14-AM-01`:
  - deterministic case `DET-STATE-CHANGES-REQUESTED`
- `PARITY-14-AM-02`:
  - deterministic case `DET-STATE-ACTIONABLE-COMMENTS`
- `PARITY-14-AM-03`:
  - deterministic case `DET-STATE-NONE`
- `PARITY-14-AM-04`:
  - deterministic case `DET-REVIEW-SUMMARY-MIXED`
- `PARITY-14-AM-05`:
  - deterministic case `DET-WORKFLOW-FINALIZER-BLOCKS-CHANGES-REQUESTED`
- `PARITY-14-AM-06`:
  - deterministic case `DET-WORKFLOW-HANDOFF-CLEAR-NONE`
- `PARITY-14-AM-07`:
  - deterministic case `DET-WORKFLOW-LEGACY-FALLBACK`
- `PARITY-14-AM-08`:
  - live-sanitized `LIVE-*` cases (real GitHub PR review/comment traces)
- `PARITY-14-AM-09`:
  - contract-doc consistency assertion in `actionable_feedback_parity_test.exs`
- `PARITY-14-AM-10`:
  - full validation matrix run (`make all` green, including coverage/dialyzer)

## Runtime Delta

- Added explicit snapshot classification fields:
  - `review_state_summary`
  - `actionable_feedback_state`
- Added item-level `classification` for actionable feedback entries.
- Workflow guards now use explicit state when available:
  - `ControllerFinalizer`
  - `HandoffCheck`
- Kept backward compatibility:
  - fallback to legacy bool `has_actionable_feedback` when state is absent.

## Live Sampling Summary

- Source repos:
  - `maximlafe/symphony`
  - `maximlafe/lead_status`
  - `facebook/react`
- Produced live cases: `21`
  - `changes_requested`: `5`
  - `actionable_comments`: `8`
  - `none`: `8`
- Live fixture is sanitized and stores only normalized classification + workflow
  decision signals.

## Validation Commands

Executed in `/private/tmp/symphony-parity-main`:

1. `scripts/generate_parity_14_live_sanitized_fixture.sh`
2. `make symphony-preflight`
3. `make symphony-acceptance-preflight`
4. `cd elixir && mise exec -- mix format --check-formatted`
5. `cd elixir && mise exec -- mix test test/symphony_elixir/actionable_feedback_parity_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/handoff_check_test.exs test/symphony_elixir/controller_finalizer_test.exs`
6. `cd elixir && mise exec -- make all`

Result: all listed commands passed.

## Artifact Hashes (SHA256)

- `0e9c495f37e9350f2f3881c9b1897f1e8c7b8138e7d3e7365c27b39efbdaa4d2` —
  `docs/symphony-next/plans/PARITY-14_PLAN.md`
- `a587a2e7b002718feedbaeacf76a5d0a557a58bf080821663d835a556ec89994` —
  `docs/symphony-next/contracts/PARITY-14_ACTIONABLE_REVIEW_FEEDBACK_CONTRACT.md`
- `3146b2b672b692a22e185a9814f91c69975d7e97c3b89c2cf2798019937d184c` —
  `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `8c888db3424d9a87a664e2ceaecac9fffdd1a4bf7d4437cf47508121a116817a` —
  `elixir/lib/symphony_elixir/controller_finalizer.ex`
- `6867a29daa5a3b1a6f58ae6fc7b495cad231f192397be93bf3a503af85ace20f` —
  `elixir/lib/symphony_elixir/handoff_check.ex`
- `0f944987facc3595b0ab78d276af8b1b81bddcb39274552a93c090cec267994d` —
  `elixir/test/fixtures/parity/parity_14_actionable_feedback_matrix.json`
- `d1ce049ce6dc1fbd87dbdd7bbaab397398c62c8e5f04b35978dc02cc5fea3be0` —
  `elixir/test/fixtures/parity/parity_14_actionable_feedback_live_sanitized.json`
- `5a478f4aaed8f360b77ba23cde5e33eb60c4f4c17997301d43ffdf55d4d9ab57` —
  `elixir/test/symphony_elixir/actionable_feedback_parity_test.exs`
- `20432c5753e303ae3b74e2f1784aa50cf17f5c9de1578e864ac8594e27ad12f5` —
  `scripts/generate_parity_14_live_sanitized_fixture.sh`

## Blockers

- None on implementation/proof path for `PARITY-14`.
