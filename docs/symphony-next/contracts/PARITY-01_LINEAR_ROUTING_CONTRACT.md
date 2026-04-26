# PARITY-01: Canonical Linear Routing Contract

## Purpose

Freeze replacement-scope Linear routing semantics as an executable contract.

This contract is authoritative for:

- polling scope interpretation (`project_slug` vs `team_key`)
- assignee routing filter
- active/manual/terminal state behavior for dispatch
- `Todo` blocker gating
- label behavior relevant to routing

## Canonical Rules

1. Polling scope is exclusive:
   - use `project_slug` when configured
   - otherwise use `team_key`
   - both at once is invalid config
2. Candidate dispatch state is allowed only when:
   - state is in `tracker.active_states`
   - state is not in `tracker.terminal_states`
   - issue is routed to current worker via assignee filter
3. `Todo` issues are additionally blocked from dispatch when any blocker is non-terminal.
4. `tracker.manual_intervention_state` (LET: `Blocked`) is non-active unless explicitly added to `active_states`.
5. Labels are metadata for downstream flows; they do not override dispatch eligibility in this contract.
6. Contract closure requires both:
   - fixture-backed deterministic matrix
   - live-sanitized Linear sample passing the same matrix runner

## Replacement Scope (LET baseline)

- Active states:
  - `Todo`
  - `Spec Prep`
  - `In Progress`
  - `Merging`
  - `Rework`
- Manual intervention:
  - `Blocked`
- Terminal states:
  - `Closed`
  - `Cancelled`
  - `Canceled`
  - `Duplicate`
  - `Done`

## Evidence Sources

- Deterministic matrix fixture:
  - `elixir/test/fixtures/parity/parity_01_linear_routing_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_01_linear_routing_live_sanitized.json`
- Fixture generator:
  - `scripts/generate_parity_01_live_sanitized_fixture.sh`
- Executable proof:
  - `elixir/test/symphony_elixir/linear_routing_parity_test.exs`
