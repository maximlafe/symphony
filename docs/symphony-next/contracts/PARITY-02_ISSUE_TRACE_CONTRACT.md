# PARITY-02: Canonical Issue Trace Contract

## Purpose

Freeze replacement-scope Linear issue trace semantics as an executable contract.

This contract is authoritative for trace channels that operators use in real
workflow triage:

- workpad comment traces
- artifact attachment traces
- handoff decision traces
- handoff milestone traces
- minimal timing/order invariants across trace events

## Canonical Trace Channels

1. `workpad_comment`
   - Signal: comment body contains `Codex Workpad` or `Рабочий журнал Codex`.
   - Required fields:
     - `created_at`
     - `author`
     - non-empty body
2. `artifact_attachment`
   - Signal: issue attachment has non-empty `title`.
   - Required fields:
     - `title`
     - `created_at`
     - `url` may be omitted only for legacy/incomplete records
3. `handoff_decision_comment`
   - Signal: comment contains `selected_action` and `checkpoint_type`.
   - Required fields:
     - `selected_action`
     - `checkpoint_type`
     - `created_at`
4. `handoff_milestone_comment`
   - Signal: comment contains `Symphony milestone` and a milestone marker.
   - Required fields:
     - milestone marker (for replacement scope, `handoff-ready` is canonical)
     - `created_at`
5. `trace_timing`
   - Invariant: trace events in a case must have parseable `created_at` values so
     deterministic chronological ordering can be reconstructed.

## Replacement Scope

- Team: `LET`
- Live filters:
  - workpad trace slice: `comments contains "Codex Workpad"`
  - handoff trace slice: `comments contains "selected_action"`
- Live data must be sanitized before committing fixtures.

## Sanitization Rules

1. Raw Linear responses must be normalized for control bytes before JSON parsing.
2. User identity fields are reduced to role-level labels (for example `operator`).
3. Issue identifiers are replaced by synthetic fixture identifiers.
4. Comment bodies are reduced to signal-preserving snippets.
5. Attachments retain only minimal trace fields (`title`, `subtitle`, `created_at`,
   `url`).

## Evidence Sources

- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_02_issue_trace_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_02_issue_trace_live_sanitized.json`
- Fixture generator:
  - `scripts/generate_parity_02_live_sanitized_fixture.sh`
- Executable proof:
  - `elixir/test/symphony_elixir/issue_trace_parity_test.exs`
