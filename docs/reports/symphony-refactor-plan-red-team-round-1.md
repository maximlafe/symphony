# Red Team Critique: symphony-refactor-plan Round 1

## Scope

- Цель раунда: проверить полноту и корректность зависимостей, prerequisites, interface impacts и source-of-truth boundaries в [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md).
- Фокус ограничен связкой:
  - runtime / orchestrator;
  - workflow / repo-local skills;
  - `docs/policy/project-contract.md`;
  - защитные тесты.

## Critical Findings

### 1. Граница SSOT для skills описана некорректно и ломает механизм change control

**Тип:** `verified issue`

План говорит, что в `Phase 1` skills должны только потреблять semantics и не переопределять их [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:281). Но текущий контракт фиксирует другую иерархию: при расхождении сначала идет `docs/policy/project-contract.md`, затем repo-local stage/ops skills, и только потом workflow prose examples [project-contract.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/policy/project-contract.md:24). Дополнительно `Change Control` требует обновлять затронутые skills вместе с contract changes [project-contract.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/policy/project-contract.md:244).

Проблема не словесная, а механическая: если repair round сохранит модель “skills only consume”, план будет недооценивать skills как второй по приоритету слой канона и как обязательную часть зависимостей первой фазы.

### 2. План смешивает file-level и semantic-level ownership и из-за этого неполно задает prerequisites

**Тип:** `verified issue`

В документе сказано:
- `workflows/letterl/maxime/let.WORKFLOW.md` — SSOT для LET routing/state machine [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:16);
- `elixir/WORKFLOW.md` — runtime/config contract [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:17);
- `project-contract` — SSOT для delivery/proof/handoff [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:15).

Это в целом согласуется с repo context, но в текущем виде plan не разделяет ownership по semantic domains внутри `elixir/WORKFLOW.md`. Сам workflow прямо требует трактовать `delivery:tdd`, `Acceptance Matrix`, `Proof Mapping`, `Checkpoint` и handoff gate semantics как канонизированные в `project-contract` [elixir/WORKFLOW.md](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/WORKFLOW.md:180), а также сам содержит runtime-owned contract fields вроде `Execution Evidence` и repository contract rules [elixir/WORKFLOW.md](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/WORKFLOW.md:186).

Из-за этого текущая формулировка ownership boundaries в плане слишком крупнозернистая: она говорит “этот файл SSOT для runtime/config”, но не фиксирует, какие поля в нем являются локальным каноном, а какие только consumer/projection чужого канона. Для repair round это критично, потому что иначе Phase 1 не сможет корректно отделить parser extraction от semantic rewrites.

### 3. Dependency chain между `handoff_check` и `dynamic_tool` занижена

**Тип:** `verified issue`

План ставит `Phase 2` как extraction `handoff_check.ex` [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:299) и `Phase 3` как decomposition `dynamic_tool.ex` / `app_server.ex` [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:316), при этом допускает параллелизм поздней `Phase 2` и `Phase 3` при “independent ownership slices” [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:398).

Но текущая тестовая поверхность показывает, что `dynamic_tool` уже несет часть contract enforcement и напрямую пересекается с `handoff_check`: в `dynamic_tool_test.exs` есть acceptance/plan-contract cases и ссылки на `handoff_check_test.exs` как proof target, а в `handoff_check_test.exs` встречаются proof targets на `dynamic_tool_test.exs` [rg summary](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/test/symphony_elixir/dynamic_tool_test.exs), [rg summary](/Users/lafe/.codex/worktrees/3410/Symphony/elixir/test/symphony_elixir/handoff_check_test.exs). Это означает, что критерий “independent ownership slices” сейчас не доказан и в плане не задан как обязательный preflight gate.

Иначе говоря: план признает contract drift главным риском, но dependency order все еще выглядит так, будто `handoff_check` и `dynamic_tool` можно развязать административным решением. По имеющимся тестам это пока не подтверждено.

### 4. Validation matrix не покрывает skill/workflow alignment как обязательный acceptance surface первой фазы

**Тип:** `verified issue`

Для `R2` план указывает `let_workflow_contract_test.exs` плюс “contract-sensitive tests” [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:408), но не требует явного proof, что repo-local skills после Phase 1 остаются синхронизированы с обновленным contract boundary. Это конфликтует с contract `Change Control`, где skills обязательны наряду с workflow references и tests [project-contract.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/policy/project-contract.md:244).

План правильно признает skills частью репо-контракта [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:22), но validation matrix не превращает это в проверяемую фазовую зависимость. В repair round это надо сделать явно, иначе первая фаза останется частично “green on paper”.

## Lower-Priority Findings

### 5. Phase 0 inventory недобирает prerequisites по workflow/skills interface map

**Тип:** `bounded concern`

Phase 0 требует call map только для `orchestrator.ex`, `dynamic_tool.ex`, `handoff_check.ex` [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:249), но раундовый фокус включает interface impacts across workflow/skills/docs/tests. Для такого фокуса не хватает обязательного inventory:
- какие repo-local skills читают или реплицируют contract semantics;
- какие parser/runtime entrypoints потребляют markdown contracts;
- где `elixir/WORKFLOW.md` и LET workflow расходятся по ownership surface.

Это поправимо без смены маршрута, но без такого inventory первая фаза будет стартовать с неполным dependency map.

### 6. Interface impacts `app_server` и `status_dashboard` пока заданы слишком локально

**Тип:** `working criticism`

Phase 3 и Phase 5 описывают `app_server`, `dashboard` и `tool protocol helpers` как почти локальные слои [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:327), [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:365). Для initial plan это приемлемо, но документ пока не закрепляет, какие из этих интерфейсов являются merely presentation, а какие отражают runtime contract state. При текущем round focus это выглядит как недописанный prerequisite, а не как явная ошибка.

## Recommendations

1. Переписать source-of-truth boundaries в плане с file-level формулировок на semantic-level matrix:
   - `project-contract` -> delivery/proof/handoff semantics;
   - repo-local skills -> second-order executable policy layer;
   - LET workflow -> routing/state transitions;
   - `elixir/WORKFLOW.md` -> runtime prompt/config contract, кроме полей, уже канонизированных contract-файлом.
2. Сделать Phase 1 не “contract consolidation” вообще, а “canonical boundary extraction + skills/workflow/runtime consumer alignment”.
3. Поднять зависимость `dynamic_tool` <-> `handoff_check` в явный blocking prerequisite перед Phase 2/3 parallelism.
4. Добавить в validation matrix отдельный acceptance item на skill alignment и отдельный acceptance item на preserved cross-surface contract consumers.
5. Расширить Phase 0 обязательным inventory workflows/skills/parsers/tests, а не только Elixir hotspot call maps.

## Compact Fix List For Repair Round

1. Уточнить иерархию SSOT так, чтобы repo-local skills были явно выделены как второй слой канона, а не только consumers.
2. Разбить ownership boundaries по semantic surfaces внутри `elixir/WORKFLOW.md`, а не по файлам целиком.
3. Добавить в prerequisites явный cross-surface inventory для workflow, skills, parser entrypoints и contract-sensitive tests.
4. Исправить зависимости между `Phase 2` и `Phase 3`: запретить параллелизм до доказанной развязки `dynamic_tool` и `handoff_check`.
5. Расширить validation matrix отдельными proof items для skill alignment и cross-surface contract consumer compatibility.

## Ledger

- **Target document:** `docs/plans/symphony-refactor-plan.md`
- **Focus used:** completeness and correctness of dependencies, prerequisites, interface impacts, and source-of-truth boundaries across runtime/orchestrator, workflow/skills, `docs/policy/project-contract.md`, and tests
- **Main findings:** skills layer understated in SSOT hierarchy; semantic ownership inside `elixir/WORKFLOW.md` underspecified; `handoff_check` / `dynamic_tool` dependency understated; validation matrix missing explicit skill/workflow alignment proof
- **Exact ordered fix list for repair round:** `1) SSOT hierarchy`, `2) semantic ownership split`, `3) cross-surface inventory prerequisites`, `4) Phase 2/3 dependency correction`, `5) validation matrix expansion`
