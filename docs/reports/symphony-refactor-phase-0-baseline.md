# Symphony Refactor Phase 0 Baseline

## Context

- Worktree: `/private/tmp/symphony-refactor-wt`
- Branch: `codex/symphony-refactor`
- Git HEAD: `c59f961`
- Isolation status: separate worktree created; no edits in source worktree; existing service instance untouched.

## Input Artifacts Status

Required artifacts were missing in this branch because they were not committed in source history. They were imported as baseline inputs from the original local worktree and verified for consistency against current `HEAD`:

- `docs/plans/symphony-refactor-plan.md`
- `docs/reports/symphony-refactor-plan-red-team-round-1.md`
- `docs/reports/symphony-refactor-plan-red-team-round-2.md`
- `docs/reports/symphony-refactor-plan-red-team-round-3.md`

Consistency check results:

- referenced hotspot files and test files exist;
- hotspot line counts match plan values for major modules;
- no obvious stale references to removed surfaces were found.

## Zoom-Out Call/Dependency Map

### 1) `orchestrator.ex`

Primary runtime control-plane:

- poll/tick loop -> issue selection/dispatch -> worker lifecycle supervision;
- account and retry/failover decisions;
- verification/handoff signal ingestion from tool updates;
- workspace cleanup and dashboard notifications.

Key chain:

- `Orchestrator` dispatches -> `AgentRunner.run/3` -> codex app-server turns -> updates return to `Orchestrator`.

Hot coupling:

- retry/failover policy mixed with state transitions and telemetry;
- parsing of tool-result payloads influences verification state;
- stale workspace reconciliation on dispatch path.

### 2) `agent_runner.ex`

Execution control boundary between orchestration and codex session:

- workspace before/after hooks;
- acceptance capability preflight;
- acceptance contract lock write;
- app-server session start/turn loop/stop;
- continuation and max-turn behavior;
- execution attempt token propagation.

Key invariants:

- lock freeze before codex turns;
- hook sequencing and teardown must remain deterministic;
- fail-closed semantics preserved on classified failures.

### 3) `codex/dynamic_tool.ex`

Tool execution and guard boundary:

- tool schema + argument normalization + execution dispatch;
- review-ready and execution transition guards;
- contract/spec/handoff guard integration (`symphony_handoff_check`, `symphony_spec_check`);
- background command wrappers and github PR/check wait wrappers.

Key coupling:

- heavy overlap with `handoff_check`/`spec_check` semantics;
- guard decisions influence workflow transitions directly.

### 4) `handoff_check.ex`

Proof/acceptance contract engine:

- parsing acceptance matrix/proof mapping/checkpoint/execution evidence;
- two-layer `mode:plan` validation (`plan_revision`, `artifact_path`, `artifact_revision`);
- fail-closed blocking divergence semantics;
- manifest/lock write + transition-allow checks.

Key coupling:

- consumed by dynamic tool review-ready/execution guards;
- tied to validation gate metadata and proof-state freshness.

## Cross-Surface Inventory (Contract / Workflow / Skills / Runtime)

Canonical ownership:

1. `docs/policy/project-contract.md` for delivery/proof/handoff semantics.
2. `workflows/letterl/maxime/let.WORKFLOW.md` for LET routing/state machine.
3. repo-local skills under `.agents/skills/` as execution adapters; they must not drift from canon.
4. `elixir/WORKFLOW.md` as runtime prompt/config consumer with runtime-owned fields.

Drift touchpoints:

- `decision`/`human-action` transition semantics across contract/workflow/runtime guards;
- `mode:plan` two-layer fields and acceptance matrix enforcement;
- execution evidence and proof-state freshness interpretation;
- capability taxonomy and transition gating expectations in dynamic tool.

## Candidate Safe Slices (Bounded)

### Slice 1 (Phase 1a): Canonical boundary wording alignment

- Scope: `elixir/WORKFLOW.md` + contract/workflow wording tests only.
- Goal: align consumer wording to canonical semantics without runtime behavior change.
- Rollback boundary: docs and related contract tests only.

### Slice 2 (Phase 1b): Drift guards hardening

- Scope: smallest runtime guard improvements plus tests for transition parity.
- Goal: prevent semantic drift between prose contract/workflow and runtime guard logic.
- Rollback boundary: guard modules/tests only.

### Slice 3 (Phase 2a minimal): Handoff extraction seam

- Scope: behavior-preserving extraction in `handoff_check` (parse/evaluate split) with zero interface change.
- Goal: isolate contract engine seam before wider Phase 2/3 work.
- Rollback boundary: extracted helper + handoff tests only.

Deferred from this run budget:

- deeper Phase 2b and Phase 3b/3c unless Slice 1-3 remain clean and cheap.

## Baseline Proof Signals

Executed local targeted proofs:

- `mise exec -- mix test test/symphony_elixir/let_workflow_contract_test.exs` -> pass
- `mise exec -- mix test test/symphony_elixir/handoff_check_test.exs:6 test/symphony_elixir/handoff_check_test.exs:49` -> pass
- `mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs:15 test/symphony_elixir/dynamic_tool_test.exs:81` -> pass
- `make symphony-runtime-smoke SCENARIO=workflow_contract` -> pass

Environment note:

- `mise.toml` trust was required in the new worktree.
- dependencies were installed via `mise exec -- mix deps.get`.

## Blocking Unknowns

- exact internal cut map for `orchestrator.ex` remains large and high risk;
- dynamic payload variability from codex app-server event stream may constrain deeper extraction;
- large `core_test.exs` concentration can hide coupling if slices are too wide.

These are treated as managed unknowns for bounded slices and do not block Slice 1-3.

## Phase 0 Decision

`NARROW`

Rationale:

- baseline proofs are green for contract/workflow/handoff/dynamic-tool entry surfaces;
- risk concentration remains high in deep orchestrator and cross-cutting execution paths;
- safest value-per-risk path is to proceed with exactly three small slices:
  1) Phase 1a, 2) Phase 1b, 3) minimal Phase 2a.

Execution guardrails:

- max 2 attempts per slice;
- stop and defer slice if still red after 2 attempts;
- run targeted proof + cheap gate per slice;
- run `make symphony-runtime-smoke SCENARIO=all` and `make symphony-validate` after every second green slice or earlier on boundary shifts.
