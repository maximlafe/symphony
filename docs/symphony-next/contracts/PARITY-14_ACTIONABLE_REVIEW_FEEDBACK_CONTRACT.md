# PARITY-14: Actionable Review Feedback Classification Contract

## Purpose

Freeze explicit review-feedback classification semantics and bind them to
workflow decisions.

`Symphony-next` must not rely on an implicit bool-only interpretation when a
typed decision-state is available.

## Canonical Classification

`github_pr_snapshot` must emit:

1. `review_state_summary`:
   - `changes_requested`
   - `approved`
   - `commented`
   - `dismissed`
   - `pending`
   - `unknown`
2. `actionable_feedback_state`:
   - `changes_requested`
   - `actionable_comments`
   - `none`

## Canonical Decision Mapping

Workflow interpretation is:

- `actionable_feedback_state=changes_requested` -> blocking
- `actionable_feedback_state=actionable_comments` -> blocking
- `actionable_feedback_state=none` -> non-blocking

When `actionable_feedback_state` is missing, fallback to legacy
`has_actionable_feedback` bool.

## Author/Intent Resolution Rules

1. Exclude non-actionable system authors:
   - `github-actions`
   - `linear`
2. Exclude untrusted bot actors.
3. Include trusted review bots:
   - `chatgpt-codex[bot]`
   - `chatgpt-codex-connector[bot]`
   - `openai-codex[bot]`
   - `openai-codex-connector[bot]`
4. Exclude acknowledgement/noise intent patterns:
   - `thanks`, `thank you`, `lgtm`, `sgtm`, `resolved`, `fixed`, `done`,
     `addressed`
   - `updated|applied|implemented in <sha>`
   - `build details:`
5. Inline replies (`in_reply_to_id`) are non-actionable.

## Workflow Tie-In

- `ControllerFinalizer` blocks handoff when classification is blocking.
- `HandoffCheck` emits
  `pull request still has actionable feedback` when classification is blocking.
- Manifest stores `pull_request.actionable_feedback_state`.

## Acceptance Mapping

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
  - live `LIVE-*` cases from
    `scripts/generate_parity_14_live_sanitized_fixture.sh`
- `PARITY-14-AM-09`:
  - contract-doc consistency assertion in
    `actionable_feedback_parity_test.exs`
- `PARITY-14-AM-10`:
  - validation matrix run log in evidence doc

## Sanitization Rules

1. Do not store raw full review threads.
2. Keep only:
   - repo/pr references,
   - normalized classification signals,
   - expected workflow-blocking decision.
3. Strip control bytes from intermediate payload files.

## Evidence Sources

- Runtime classification source:
  - `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- Workflow guards:
  - `elixir/lib/symphony_elixir/controller_finalizer.ex`
  - `elixir/lib/symphony_elixir/handoff_check.ex`
- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_14_actionable_feedback_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_14_actionable_feedback_live_sanitized.json`
- Fixture generator:
  - `scripts/generate_parity_14_live_sanitized_fixture.sh`
- Executable proof:
  - `elixir/test/symphony_elixir/actionable_feedback_parity_test.exs`
