# Red Team Critique: symphony-refactor-plan Round 2

## Scope

- Цель раунда: проверить execution order, rollback/failure modes, migration safety, validation sequencing и достаточность test coverage для behavior-preserving refactor path.
- Этот раунд отличается от round 1: здесь фокус не на SSOT/preference boundaries, а на безопасном исполнении плана и достаточности proof path во время рефакторинга.
- Проверяемые поверхности:
  - `orchestrator`
  - `agent_runner`
  - `dynamic_tool`
  - `handoff_check`
  - `app_server`
  - `status_dashboard`
  - workflow
  - repo-local skills

## Critical Findings

### 1. `AgentRunner` полностью выпал из execution plan, хотя это ключевой safety boundary

**Тип:** `verified issue`

План перечисляет hotspot-модули и validation surfaces, но не включает `agent_runner.ex` ни в runtime hotspots, ни в phased extraction path, ни в validation matrix [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:24), [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:256), [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:464). Это небезопасно, потому что `orchestrator` зависит от `AgentRunner`, а `AgentRunner` сам оркестрирует:
- pre-run hook window,
- acceptance capability preflight,
- acceptance contract lock,
- lifecycle `AppServer.start_session/stop_session`,
- continuation/max-turn behavior,
- execution attempt token propagation
  [agent_runner.ex](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/lib/symphony_elixir/agent_runner.ex:54), [agent_runner.ex](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/lib/symphony_elixir/agent_runner.ex:68), [agent_runner.ex](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/lib/symphony_elixir/agent_runner.ex:184), [agent_runner.ex](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/lib/symphony_elixir/agent_runner.ex:201).

Дополнительно `runtime_smoke_test.exs` и `core_test.exs` уже защищают `AgentRunner.run(...)` path, включая hydration, fail-closed behavior и continuation loops. План, который обещает migration safety для `orchestrator`/`app_server`, но не называет `AgentRunner` как explicit migration surface, недооценивает реальный execution order risk.

### 2. Validation sequencing в плане не закрепляет cheap-gate -> final-gate порядок на уровне фаз

**Тип:** `verified issue`

План многократно ссылается на targeted proof и `make symphony-validate`, но validation matrix фактически делает `R9` repo-wide final gate обязательным `required_before=review` после каждой крупной фазы [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:472). Это слабо согласовано с repo contract:
- `final gate` требует успешный `cheap gate` на том же `HEAD`
  [project-contract.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/policy/project-contract.md:210);
- workflow differentiates change classes and mandates targeted/cheap proof before final gate
  [elixir/WORKFLOW.md](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/WORKFLOW.md:301), [elixir/WORKFLOW.md](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/WORKFLOW.md:317).

Сейчас план не задает phase-local sequencing вроде:
1. characterization/targeted proof,
2. phase cheap gate,
3. only then clean-HEAD final gate when phase is ready to publish or merge with later work.

Без этого документ обещает safety, но допускает две одинаково плохие интерпретации:
- либо `make symphony-validate` гоняется слишком рано и слишком часто, размывая failure signal;
- либо phase owners пропускают explicit cheap gate sequencing и считают финальный gate достаточным.

### 3. Rollback rules не покрывают частичные migration failures в workflow/skills/contract surfaces

**Тип:** `verified issue`

Round 1 исправил boundary ownership, но rollback logic остался главным образом кодоцентричным [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:488). Для execution safety этого мало. В частности, Phase 1 говорит про skill/workflow alignment и semantic boundary extraction [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:313), но rollback для Phase 1 описан только как откат helper/extractor [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:499).

Это оставляет непокрытыми опасные partial-failure cases:
- contract text changed, but repo-local skills still old;
- skill semantics changed, but workflow prose/examples/tests still old;
- workflow/runtime contract changed, but acceptance lock / execution-evidence path still validates old structure;
- handoff-facing contract changed, but only `make symphony-validate` runs, without explicit handoff/manifest safety checkpoint.

Для behavior-preserving migration план должен fail closed и на “semantic migration not fully propagated” cases, не только на обычных code regressions.

### 4. Migration safety around `orchestrator` / `app_server` / `AgentRunner` is under-specified

**Тип:** `verified issue`

Phase 3 and Phase 4 treat `app_server` and `orchestrator` as separable runtime hotspots [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:367), [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:394), but the plan still lacks a migration-safety rule for preserving the control-loop chain:

`Orchestrator -> AgentRunner -> Workspace hooks / acceptance preflight / acceptance lock -> AppServer session lifecycle`

That chain is what actually makes refactors behavior-preserving in this subsystem. Right now the plan protects `orchestrator_status_test.exs`, `core_test.exs`, and runtime smoke generically, but does not require that any phase touching `orchestrator`, `agent_runner`, or `app_server` preserve:
- issue hydration,
- classified run failure semantics,
- continuation/max-turn behavior,
- pre-run and after-run hook sequencing,
- session teardown on failure.

Those are not cosmetic internals; they are migration-critical operator behaviors.

### 5. Test coverage adequacy is overstated for workflow/skills and runtime-control refactors

**Тип:** `verified issue`

The validation matrix covers `core_test`, `orchestrator_status_test`, `dynamic_tool_test`, `handoff_check_test`, runtime smoke, and repo-wide validate [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:464). But for this round’s safety focus it is still incomplete:

- `AgentRunner` is protected mainly through `core_test.exs` and `runtime_smoke_test.exs`, yet no row isolates its execution-control semantics.
- workflow/skills changes have no explicit requirement for a targeted proof slice beyond generic “contract-sensitive tests.”
- `json_formatter_test.exs` references `SymphonyElixir.AgentRunner` logging/metadata path, which can break silently during runner refactors.
- the plan never states when runtime smoke alone is insufficient and a narrower targeted control-loop test is required before broader gates.

Result: the matrix still reads like “important tests exist somewhere,” not “this migration path is safe because these exact behaviors are proven in this order.”

## Lower-Priority Findings

### 6. Phase ordering for `status_dashboard` and `workflow/skills` still lacks a safety trigger

**Тип:** `bounded concern`

The plan now classifies some interfaces as runtime-contract-reflecting, but it still does not explicitly say when dashboard or workflow/skill changes are blocked on stabilization of upstream runtime-control behavior. That is less severe than the missing `AgentRunner` path, but it can still produce confusing mixed-signal regressions during late phases.

### 7. Rollback language is still too generic for validation-artifact failures

**Тип:** `working criticism`

The plan talks about rollback after broken behavior, but not enough about rollback after invalid proof state:
- stale acceptance lock,
- stale execution evidence,
- broken attachment/proof mapping,
- mismatched clean-HEAD assumptions after a phase-local green proof.

These are migration safety failures even when product behavior appears unchanged.

## Recommendations

1. Add `agent_runner.ex` as a first-class migration surface in hotspots, execution ordering, and validation matrix.
2. Encode explicit per-phase validation sequencing:
   - targeted characterization proof,
   - phase cheap gate,
   - clean-HEAD final gate only when the phase is ready for publishable integration.
3. Expand rollback rules to fail closed on partial semantic migrations across contract/workflow/skills/runtime validators.
4. Add a control-loop migration safety subsection for `orchestrator` + `agent_runner` + `app_server`.
5. Add dedicated validation rows for `AgentRunner` behavior and for workflow/skills migration safety.

## Compact Fix List For Repair Round

1. Add `agent_runner` to the plan’s hotspot, phase, and validation surfaces.
2. Define explicit cheap-gate -> final-gate sequencing per phase, not only generic targeted proof plus repo-wide validate.
3. Extend rollback/failure rules for partial workflow/skills/contract/runtime migration failures.
4. Add explicit migration-safety invariants for the `orchestrator` -> `AgentRunner` -> `AppServer` control loop.
5. Expand validation/test coverage to include `AgentRunner`-specific behavior, workflow/skills targeted proof, and proof-state failure cases.

## Ledger

- **Target document:** `docs/plans/symphony-refactor-plan.md`
- **Focus used:** execution order, rollback/failure modes, migration safety, validation sequencing, and test coverage adequacy for behavior-preserving refactors of orchestrator, agent_runner, dynamic_tool, handoff_check, app_server, status_dashboard, workflow, and skills
- **Main findings:** `agent_runner` omitted from migration plan; phase validation sequencing does not encode cheap-gate -> final-gate order; rollback is insufficient for partial semantic migrations; orchestrator/app-server control-loop safety is underspecified; test coverage plan still overclaims adequacy
- **Exact ordered fix list for repair round:** `1) add agent_runner`, `2) phase validation sequencing`, `3) rollback/failure-mode expansion`, `4) control-loop migration invariants`, `5) validation/test coverage expansion`
