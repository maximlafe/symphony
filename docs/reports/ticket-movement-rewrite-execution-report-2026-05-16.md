# Ticket Movement Rewrite Execution Report (2026-05-16)

## Base
- Base PR: `#201` — <https://github.com/maximlafe/symphony/pull/201>
- Base branch: `codex/symphony-refactor`
- Base head verified at start: `9d4fc34937312239d0f9c0055a2332fad7a6fa54`
- Working branch for this run: `codex/ticket-movement-rewrite`

## Linear test issue (required pre-slice gate)
- `LET-736` — <https://linear.app/letterl/issue/LET-736/ticket-movement-rewrite-smokee2e-test-checklist>

## Phase-local execution plan (with rollback boundaries)
1. Slice A (characterization baseline): run named proof targets from plan matrix, no behavior changes.
   - Rollback boundary: no code edits.
2. Slice B (`changed_paths` fail-closed semantics): tighten pre-handoff fallback behavior only for explicit `changed_files` checkpoints with empty fallback diff.
   - Rollback boundary: rollback only touched files (`controller_finalizer.ex`, `controller_finalizer_test.exs`) if not green in 2 attempts.
3. Service boundary gate: isolated local instance check (`/health`, `/api/dashboard`, crash-loop/port conflict checks).
4. Broader runtime validation on boundary shift: `make symphony-runtime-smoke SCENARIO=all` and `make symphony-validate`.

## Slice ledger

### Slice A (green)
- Type: characterization gate
- Behavior changes: none
- Proof targets:
  - `validation_gate_test.exs: "classifies changed paths deterministically and fails closed for unknown paths"`
  - `execution_contract_test.exs: "classify_admission_failure normalizes payload and defaults with non-map input"`
  - `execution_contract_test.exs: "retry budget status/open/outcome handles nil, cooldown, expiry and unknown outcomes"`
  - `handoff_check_test.exs: "evaluate passes with matching attachment, checklist, and green PR"`
  - `handoff_check_test.exs: "evaluate normalizes validation gate errors and git changed paths for invalid change classes"`
  - `app_server_test.exs: "app server dedupes repeated validation exec_background launches while the same surface is running"`
  - `app_server_test.exs: "app server allows validation rerun when workspace diff changes after green and never dedupes distinct bundles"`
  - `core_test.exs: "recoverable symphony_handoff_check drift escalates after bounded retry budget is exhausted"`
- Result: `8 tests, 0 failures`.
- Cheap gate (quick touched-surface check): baseline targeted suite passed.

### Service boundary gate (required timeline step)
- Isolated local instance command:
  - `cd elixir && mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md --port 4106`
- Checks:
  - Startup success: pass
  - `GET /health`: `{"status":"ok"}`
  - `GET /api/dashboard`: `200` with JSON payload
  - Crash-loop: not observed during repeated dashboard refresh polling
  - Port conflict: not observed on `4106`
- Dashboard URL during check: `http://127.0.0.1:4106/`

### Slice B (green)
- Type: bounded behavior fix on `changed_paths` fallback semantics
- Goal: fail-close explicit checkpoint `changed_files` paths when fallback diff is empty.
- Files changed:
  - `elixir/lib/symphony_elixir/controller_finalizer.ex`
  - `elixir/test/symphony_elixir/controller_finalizer_test.exs`
- Attempt log:
  1. Attempt 1 introduced over-broad fail-closed behavior and failed `controller_finalizer_test` (10 failures).
  2. Attempt 2 narrowed fail-closed condition to explicit `checkpoint["changed_files"]` contexts; suite returned green.
- Proof targets:
  - `controller_finalizer_test.exs` full touched-surface suite (`42 tests, 0 failures`)
  - New regression target: `run/3 fail-closes changed_paths fallback when git diff is empty`
- Cheap gate:
  - `make symphony-runtime-smoke SCENARIO=workflow_contract` -> `1 test, 0 failures`

## Broader runtime validation (boundary shift)
- `make symphony-runtime-smoke SCENARIO=all` -> `5 tests, 0 failures`
- `make symphony-validate`:
  - First run failed on dialyzer warning from intermediate guard shape in `controller_finalizer.ex`.
  - Fixed in same slice; reran `controller_finalizer_test.exs` green.
  - Final rerun passed fully (`contracts`, `build`, `format`, `lint`, `test --cover`, `dialyzer`).

## Changed files
- `elixir/lib/symphony_elixir/controller_finalizer.ex`
- `elixir/test/symphony_elixir/controller_finalizer_test.exs`

## Deferred / rollback notes
- No open deferred slices.
- No hidden carry-over from failed attempt: over-broad first attempt was replaced in-slice by narrowed condition before final green state.

## Residual risks
- Scope intentionally limited to `controller_finalizer` pre-handoff fallback semantics and regression coverage.
- Other ticket-movement surfaces from the broader rewrite plan were not modified in this slice set.

## Publish ledger
- Commits:
  - `a9b2949` — `controller_finalizer: fail-close explicit changed_files empty fallback`
  - `979c0a1` — `docs: add ticket movement rewrite execution report`
- Push:
  - Branch `codex/ticket-movement-rewrite` pushed to `origin`
- PR:
  - `#202` — <https://github.com/maximlafe/symphony/pull/202>
