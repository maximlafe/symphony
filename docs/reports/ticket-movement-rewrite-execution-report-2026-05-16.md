# Ticket Movement Rewrite Execution Report (2026-05-16)

## Base
- Base PR: `#201` — <https://github.com/maximlafe/symphony/pull/201>
- Base branch: `codex/symphony-refactor`
- Base head verified at start: `9d4fc34937312239d0f9c0055a2332fad7a6fa54`
- Working branch for this run: `codex/tm-reroute-clean`

## Linear test issue (required pre-slice gate)
- `LET-736` — <https://linear.app/letterl/issue/LET-736/ticket-movement-rewrite-smokee2e-test-checklist>

## Phase-local execution plan (with rollback boundaries)
1. Slice A (characterization baseline): run named proof targets from plan matrix, no behavior changes.
   - Rollback boundary: no code edits.
2. Slice B (`changed_paths` fail-closed semantics): tighten pre-handoff fallback behavior only for explicit `changed_files` checkpoints with empty fallback diff.
   - Rollback boundary: rollback only touched files (`controller_finalizer.ex`, `controller_finalizer_test.exs`) if not green in 2 attempts.
3. Slice C (`changed_paths` fail-closed semantics, dynamic tool path): enforce fail-closed class resolution for empty handoff fallback diff in `symphony_handoff_check` validation context.
   - Rollback boundary: rollback only touched files (`dynamic_tool.ex`, `dynamic_tool_test.exs`) if not green in 2 attempts.
4. Slice D (inventory + boundary map artifact): lock concrete lifecycle/guard/Linear-side-effect inventory and `current state -> target state` mapping as execution evidence.
   - Rollback boundary: rollback only touched docs artifacts if gate sequence does not stay green.
5. Service boundary gate: isolated local instance check (`/health`, `/api/dashboard`, crash-loop/port conflict checks).
6. Broader runtime validation on boundary shift and green-slice cadence: `make symphony-runtime-smoke SCENARIO=all` and `make symphony-validate`.

## Plan step status (artifact-aligned)
1. Re-scope: completed in source plan artifact (used as execution baseline).
2. Characterization gate: completed (Slice A named regression proof targets all green).
3. Inventory and mapping: completed (Slice D artifact `ticket-movement-rewrite-inventory-map-2026-05-16.md`).
4. Boundary contracts and ownership: completed (Slice D artifact + code anchors for `ValidationGate`/`ExecutionContract`/`HandoffCheck`/`ControllerFinalizer`/`Tracker`).
5. Canonical pipeline and guard cleanup: accepted as already-present runtime shape from base PR #201; no additional behavior change introduced in this branch.
6. `changed_paths` fallback semantics: completed via Slice B (`controller_finalizer`) and Slice C (`dynamic_tool`) with explicit fail-closed regression coverage.
7. Retry/failover simplification with baseline numbers: accepted as already satisfied in base runtime (`ExecutionContract` + `Orchestrator`) and verified through characterization and full validation gates.
8. Idempotent Linear wrapper: accepted as already present for ticket-movement runtime writes (`Tracker` -> `Linear.Adapter`); no duplicate wrapper introduced.
9. Validation gate map with named proof targets: completed via Slice A characterization map + targeted slice proofs recorded in this report.

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

### Slice C (green)
- Type: bounded behavior fix on `dynamic_tool` handoff validation fallback semantics
- Goal: when `changed_paths` fallback is empty/unclassifiable in `symphony_handoff_check`, fail-close into `runtime_contract` instead of ambiguous empty class set.
- Files changed:
  - `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
  - `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- Proof targets:
  - `dynamic_tool_test.exs` full touched-surface suite (`59 tests, 0 failures`)
  - New regression target: `symphony_handoff_check fail-closes empty changed_paths fallback to runtime_contract`
- Cheap gate:
  - `make symphony-runtime-smoke SCENARIO=workflow_contract` -> `1 test, 0 failures`

### Slice D (green)
- Type: bounded documentation/inventory slice (plan preconditions evidence)
- Goal: fix and persist concrete inventory of lifecycle paths, guard paths, Linear side effects, and state mapping against real runtime surfaces.
- Files changed:
  - `docs/reports/ticket-movement-rewrite-inventory-map-2026-05-16.md`
- Proof target (document):
  - `docs/reports/ticket-movement-rewrite-inventory-map-2026-05-16.md` contains concrete module/function anchors for `Plan -> Execute -> Review -> Done/Blocked`.
- Cheap gate:
  - `make symphony-runtime-smoke SCENARIO=workflow_contract` -> `1 test, 0 failures`

## Broader runtime validation (boundary shifts)
- After Slice B boundary shift:
  - `make symphony-runtime-smoke SCENARIO=all` -> `5 tests, 0 failures`
  - `make symphony-validate`:
    - first run failed on dialyzer warning from intermediate guard shape in `controller_finalizer.ex`;
    - fixed in-slice and rerun passed fully (`contracts`, `build`, `format`, `lint`, `test --cover`, `dialyzer`).
- After Slice C boundary shift:
  - `make symphony-runtime-smoke SCENARIO=all` -> `5 tests, 0 failures`
  - `make symphony-validate` -> passed fully (`contracts`, `build`, `format`, `lint`, `test --cover`, `dialyzer`).
- After Slice D (4th consecutive green slice cadence gate):
  - `make symphony-runtime-smoke SCENARIO=all` -> `5 tests, 0 failures`
  - `make symphony-validate` -> passed fully (`contracts`, `build`, `format`, `lint`, `test --cover`, `dialyzer`).

## Changed files
- `elixir/lib/symphony_elixir/controller_finalizer.ex`
- `elixir/test/symphony_elixir/controller_finalizer_test.exs`
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- `docs/reports/ticket-movement-rewrite-inventory-map-2026-05-16.md`

## Deferred / rollback notes
- No open deferred slices.
- No hidden carry-over from failed attempt: over-broad first attempt was replaced in-slice by narrowed condition before final green state.

## Residual risks
- Scope intentionally limited to bounded fallback semantics on `controller_finalizer` and `dynamic_tool` handoff paths plus inventory/report artifacts.
- Other ticket-movement surfaces from the broader rewrite plan were not modified in this slice set.

## Publish ledger
- Commits:
  - `a9b2949` — `controller_finalizer: fail-close explicit changed_files empty fallback`
  - `979c0a1` — `docs: add ticket movement rewrite execution report`
  - `71f866e` — `docs: finalize ticket movement rewrite publish ledger`
  - `d666c46` — `dynamic_tool: fail-close empty changed_paths to runtime_contract`
  - `ed76ef4` — `docs: record slice C dynamic_tool fallback validation`
  - `2b74c64` — `docs: add ticket movement inventory map and slice D evidence`
- Push:
  - Branch `codex/tm-reroute-clean` pushed to `origin`
- PR:
  - pending publication on `codex/tm-reroute-clean`
