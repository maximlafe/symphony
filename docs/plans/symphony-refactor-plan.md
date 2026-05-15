# План рефакторинга Symphony

## Document Spec

- **Цель документа:** зафиксировать исполнимый, поэтапный план рефакторинга `Symphony` без поставки продуктового кода в рамках этого документа.
- **Формат результата:** канонический короткий план на русском языке, пригодный для последующего `swarm-iterate` / `swarm-red-team` цикла.
- **Область:** Elixir runtime, workflow/contract слой, repo-local worker skills и тестовая защита вокруг самых перегруженных модулей.
- **Вне области:** big-bang rewrite, смена продуктовой архитектуры, редизайн UX, миграция на другой orchestration stack, массовая замена LET-процесса.
- **Критерии успеха:**
  - выбран один основной маршрут рефакторинга;
  - порядок фаз и зависимости между ними однозначны;
  - границы владения, правила отката и матрица валидации заданы явно;
  - риск drift между `docs/policy/project-contract.md`, workflow, skills и runtime учтен как первичный.
- **Рабочие допущения:**
  - `docs/policy/project-contract.md` остается семантическим SSOT для delivery/proof/handoff;
  - repo-local stage и ops skills под `.agents/skills/` остаются вторым по приоритету executable policy layer после `project-contract` и должны синхронизироваться с ним при любом contract change;
  - `workflows/letterl/maxime/let.WORKFLOW.md` остается SSOT для LET routing/state machine;
  - `elixir/WORKFLOW.md` остается runtime prompt/config contract только для runtime-owned полей и не переопределяет semantics, уже канонизированные `project-contract`;
  - рефакторинг идет через behavior-preserving extraction под существующей и расширяемой тестовой защитой.

## Подтвержденный контекст

- `README.md` описывает репозиторий как production-oriented fork `openai/symphony` с Linear-driven workers, repo-local workflow в `elixir/WORKFLOW.md`, worker skills в `.agents/skills/` и каноническим delivery/proof/handoff контрактом в `docs/policy/project-contract.md`.
- **Измеренные size hotspots по фактическому `wc -l`:**
  - `elixir/lib/symphony_elixir/orchestrator.ex` — `8086`
  - `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` — `3877`
  - `elixir/lib/symphony_elixir/handoff_check.ex` — `3108`
  - `elixir/lib/symphony_elixir/codex/app_server.ex` — `2408`
  - `elixir/lib/symphony_elixir/status_dashboard.ex` — `2299`
  - `elixir/lib/symphony_elixir/linear/client.ex` — `1427`
- **Семантически критичные execution hotspots независимо от line count:**
  - `elixir/lib/symphony_elixir/agent_runner.ex` — execution-control hotspot on the orchestrator path
  - `elixir/lib/symphony_elixir/codex/app_server.ex` — session/runtime lifecycle hotspot
  - `elixir/lib/symphony_elixir/handoff_check.ex` — fail-closed proof/handoff hotspot
- Основная защитная тестовая поверхность:
  - `elixir/test/symphony_elixir/core_test.exs`
  - `elixir/test/symphony_elixir/orchestrator_status_test.exs`
  - `elixir/test/symphony_elixir/json_formatter_test.exs`
  - `elixir/test/symphony_elixir/dynamic_tool_test.exs`
  - `elixir/test/symphony_elixir/handoff_check_test.exs`
  - `elixir/test/symphony_elixir/runtime_smoke_test.exs`
  - `elixir/test/symphony_elixir/let_workflow_contract_test.exs`
- Подтвержденный системный риск: семантика размазана между контрактом, workflow, repo-local skills, runtime-парсерами и substring-heavy тестами.

## Semantic Source-Of-Truth Matrix

| Semantic surface | Primary canon | Secondary / executable canon | Consumers / projections | Notes |
| --- | --- | --- | --- | --- |
| Delivery / proof / handoff semantics | `docs/policy/project-contract.md` | repo-local stage/ops skills under `.agents/skills/` | `elixir/WORKFLOW.md`, `workflows/letterl/maxime/let.WORKFLOW.md`, runtime parsers, handoff/runtime tests | При расхождении контракт выше skills, skills выше workflow prose. |
| LET routing / state transitions | `workflows/letterl/maxime/let.WORKFLOW.md` | repo-local planning/ops skills that implement LET path | LET workflow tests, runtime orchestration consumers | `project-contract` не владеет routing logic. |
| Runtime prompt/config contract | `elixir/WORKFLOW.md` | runtime config readers / prompt consumers | `orchestrator.ex`, `agent_runner.ex`, `app_server.ex`, runtime smoke/tests | Только runtime-owned fields; imported semantics не считаются локальным каноном этого файла. |
| Planning artifact / execution-evidence semantics | `docs/policy/project-contract.md` | repo-local skills + runtime validators | `elixir/WORKFLOW.md`, `dynamic_tool.ex`, `handoff_check.ex`, related tests | Здесь особенно высок drift risk между markdown, skill prose и runtime parsers. |
| Verification / proof enforcement | `docs/policy/project-contract.md` for semantics; concrete tests for implementation proof | repo-local validation helpers/skills | `agent_runner.ex`, `handoff_check.ex`, `dynamic_tool.ex`, runtime smoke, final gate | Нельзя считать tests только consumers: они закрепляют implementation-facing proof surface. |

## Phase 1: Problem Definition

- **Core problem:** кодовая база накопила крупные модули и дублирующие semantic seams; изменения в контрактах и runtime теперь дорого и рискованно вносить, потому что знания о поведении распределены между кодом, markdown workflow/contract файлами, skills и тестами.
- **Scope:** декомпозиция hotspot-модулей, вынос общих policy/contract/parser abstraction, стабилизация тестовой защиты и явных ownership boundaries.
- **Out of scope:** переписывание orchestration logic с нуля, одновременная смена workflow contract и runtime protocol, отказ от текущего двухслойного planning contract, массовый перенос на новые библиотеки без локальной необходимости.
- **Success criteria:** после завершения плана каждый крупный модуль можно дробить по швам, не теряя поведение; contract drift отслеживается тестами и ownership rules; каждая фаза откатываема без каскадного отката всей программы.
- **Uncertainties / missing information:**
  - пока нет полного call-graph для `orchestrator.ex` и `dynamic_tool.ex`;
  - не измерена фактическая скорость/стоимость тестовых пакетов по каждому workstream;
  - не собран churn-map по файлам, поэтому приоритеты фаз основаны на размере и контрактном риске, а не на git-истории.

### Swarm Configuration Snapshot

- **preset:** Diagnosis / Engineering
- **rigor / stakes:** high
- **grounding need:** high
- **creativity need:** medium
- **problem ambiguity:** medium
- **route branching budget:** narrow (`<= 3`)
- **closure strictness:** high

## Phase 2: Expert Assembly

- **Размер команды:** 5 экспертов.
- **Evidence boundary:** только подтвержденный repo context, локальные файлы, tool-grounded выводы и явно маркированные допущения.
- **Состав:**
  - **Barbara Liskov** (Critic) — модульные контракты, границы ответственности, invariants.
  - **Michael Feathers** (Critic · Implementer) — безопасный рефакторинг legacy-кода через characterization tests и seam extraction.
  - **Joe Armstrong** (Balanced) — декомпозиция long-running/runtime-heavy Elixir систем.
  - **Martin Fowler** (Evangelist) — поэтапная эволюция архитектуры без rewrite.
  - **Kent Beck** (Critic · Completer-Finisher) — минимальные шаги, тестовая дисциплина, контроль blast radius.

## Phase 3: Dynamic Iteration

### Open Items

| id | state | item |
| --- | --- | --- |
| `OI-1` | `resolved` | Нужно ли планировать big-bang rewrite? |
| `OI-2` | `resolved` | С чего начинать: с runtime-модулей или с контрактного слоя? |
| `OI-3` | `resolved` | Нужны ли отдельные ownership boundaries и rollback rules на фазу? |
| `OI-4` | `deferred-in-scope` | Нужен точный call-graph `orchestrator.ex` перед стартом реализации. |
| `OI-5` | `deferred-in-scope` | Нужна фактическая карта длительности тестовых пакетов до исполнения Phase 0. |

### Iteration 1 — Option A: Round-Robin

**Moderator reasoning:** главный неразрешенный вопрос в начале — где проходит первый безопасный шов. Без этого нельзя выбрать порядок фаз: ранний заход в `orchestrator.ex` может дать ложный старт, если contract drift останется незафиксированным.

**Экспертные позиции:**

- **Liskov:** первая проблема не размер модулей сам по себе, а неявные semantic contracts. Пока `project-contract`, workflow и runtime-парсеры не связаны явной ownership-моделью, любая декомпозиция будет размножать drift.
- **Feathers:** большой файл сам по себе не приговор; опасен большой файл без characterization tests вокруг observable behavior. Нужен baseline и extraction seams, а не rewrite.
- **Armstrong:** `orchestrator.ex` и `dynamic_tool.ex` выглядят как разные причины сложности: orchestration graph против protocol/tool dispatch. Их нельзя дробить одной техникой.
- **Fowler:** маршрут должен быть vertical-by-risk: сначала слой, который разблокирует безопасные изменения в остальных слоях, затем крупнейшие runtime-модули по очереди.
- **Beck:** фазы должны заканчиваться локальным publishable state. Если для фазы нельзя назвать cheap gate, final gate и rollback, фаза слишком крупная.

**Route update:**

- `Route A` big-bang rewrite -> `CLOSED`: отвергнут как несовместимый с текущей контрактной и тестовой поверхностью.
- `Route B` incremental extraction starting from runtime hotspots -> `DORMANT`: возможен, но пока не доказано, что порядок безопасен.
- `Route C` contract-first incremental extraction -> `ACTIVE`: имеет лучший шанс уменьшить drift до декомпозиции runtime.

**Next Decision:** Option E

### Iteration 2 — Option E: Executor

**Moderator reasoning:** нужно заземлить, действительно ли contract-layer является первой точкой риска, а не просто красивой идеей. Это дискриминируется проверкой фактических SSOT-утверждений и hotspot/test inventory.

**Executor preflight**

- **Questions:** где в репозитории реально закреплены SSOT и какие модули/тесты уже образуют минимальный защитный периметр?
- **Scope:** `README.md`, `docs/policy/project-contract.md`, `elixir/WORKFLOW.md`, `workflows/letterl/maxime/let.WORKFLOW.md`, hotspot-файлы и named tests.
- **Plan:** прочитать contract/workflow sources, проверить line-count hotspots, подтвердить тесты и зафиксировать зависимость между contract drift и runtime behavior.

**Tool-backed findings:**

- **Verified fact:** `docs/policy/project-contract.md` прямо называет себя canonical repository contract для delivery/proof/handoff semantics.
- **Verified fact:** `elixir/WORKFLOW.md` закрепляет `planning.swarm_assist_enabled: true`, runtime/config contract и прямую зависимость от project contract.
- **Verified fact:** `README.md` и workflow подтверждают, что repo-local skills под `.agents/skills/` являются частью рабочего контракта target repo.
- **Verified fact:** крупнейшие модули и named tests совпадают с исходным описанием; риск сосредоточен не в одном файле, а в нескольких сцепленных поверхностях.
- **Working hypothesis:** первым priority seam должен стать слой contract normalization + parser helpers, потому что он лежит на пути handoff/workflow/tests и снижает стоимость следующих extraction phases.

**Route update:**

- `Route C` contract-first incremental extraction: `ACTIVE -> SUPPORTING evidence confirmed`.
- `Route B` runtime-first: `DORMANT`, reopen condition — если contract inventory покажет, что drift не влияет на runtime/tests.

**Next Decision:** Option D

### Iteration 3 — Option D: Adjudication

**Moderator reasoning:** после подтверждения SSOT нужен явный выбор между двумя реальными маршрутами: начать с контрактного слоя или сразу дробить `orchestrator.ex`. Без adjudication план останется двусмысленным.

**Competing routes:**

1. **Route C1: Contract-first**
   - сначала зафиксировать канонические semantics и ownership;
   - затем вынести shared helpers/parsers;
   - потом дробить runtime hotspots под уже стабилизированным контрактом.
2. **Route C2: Runtime-first**
   - сначала дробить `orchestrator.ex` и `dynamic_tool.ex`;
   - затем подтягивать contract/workflow alignment по мере необходимости.

**Strongest case for C1:** уменьшает drift до начала механической декомпозиции, дает стабильную proof surface для handoff/runtime/workflow tests, снижает вероятность повторной правки уже выделенных модулей.

**Strongest case for C2:** сразу атакует крупнейшую техническую боль и может быстрее уменьшить размер самых дорогих файлов.

**Challenge pass:**

- против **C1**: есть риск увязнуть в документах и не дойти до runtime extraction.
- против **C2**: можно зафиксировать неверные seams, если semantic duplication между workflow/skills/runtime останется невыясненной.

**Adjudication:** победитель — **C1**. Риск “увязнуть в документах” контролируется тем, что contract-first фаза ограничена не редактированием prose ради prose, а выделением ownership boundaries, parser/helpers и drift-detection tests. Риск C2 выше: он может размножить неправильные интерфейсы и ухудшить merge/conflict pressure.

**Route update:**

- `Route C1` -> `ACTIVE`
- `Route C2` -> `CLOSED`

**Next Decision:** Option G

### Iteration 4 — Option G: Checkpoint

- **Progress:** выбран единый маршрут: contract-first, затем behavior-preserving extraction hotspot-модулей.
- **Unresolved questions:** точный call-graph `orchestrator.ex`, фактическая стоимость тестовых пакетов, точное разбиение ownership внутри dashboard/app-server слоя.
- **Quality assessment:** информации достаточно для implementation-ready плана уровня `start Phase 0`; оставшиеся unknowns влияют на детализацию задач внутри фаз, но не создают скрытого внешнего gate перед стартом исполнения.
- **Active route status:** `Route C1` остается `ACTIVE`; falsifier — если на Phase 0 выяснится, что contract semantics уже изолированы и основной риск полностью runtime-local. Reopen condition для закрытого runtime-first пути — только при таком опровержении.
- **Strategic choice:** финализировать initial plan в одном маршруте и явно отметить deferred unknowns как preflight задачи Phase 0, а не раздувать документ спекуляцией.

**Next Decision:** Option H

### Iteration 5 — Option H: Finalization

**Readiness check:**

- достаточно данных для полезного плана: **да**;
- ключевые неопределенности либо сняты, либо ограничены preflight-фазой: **да**;
- дополнительная итерация в этом сообщении с высокой вероятностью меняла бы степень детализации, но не сам маршрут: **да**.

**Pre-mortem pass:**

- **Liskov:** план может ошибиться, если ownership boundaries окажутся слишком абстрактными для реального runtime API.
- **Feathers:** план может ошибиться, если characterization tests окажутся substring-heavy и не будут реально защищать behavior.
- **Armstrong:** план может ошибиться, если `orchestrator.ex` содержит циклические зависимости, требующие иной очередности extraction.
- **Fowler:** план может ошибиться, если фазы окажутся слишком горизонтальными и не дадут shipping checkpoints.
- **Beck:** план может ошибиться, если validation matrix не будет привязана к конкретным proof slices.

Ни один из пунктов не открывает новый обязательный маршрут для этого initial draft; все они адресуются внутри Phase 0, validation matrix и rollback rules.

## Выбранный маршрут

Основной маршрут: **не переписывать Symphony, а последовательно выносить behavior-preserving seams под тестами, начиная с contract/semantic слоя, затем переходя к крупнейшим runtime hotspot-модулям по одному bounded workstream за раз**.

Это значит:

1. Сначала стабилизировать канонику и точки ее чтения.
2. Затем выделять shared helpers и parser/normalizer слои.
3. Потом дробить крупные runtime-модули, каждый раз оставляя рабочее состояние с локальной валидацией и явным rollback.

## Non-Goals

- Не делать одномоментный rewrite `orchestrator.ex`, `dynamic_tool.ex` или всей Elixir runtime.
- Не менять semantic SSOT местами: `project-contract`, LET workflow и runtime workflow не должны потерять свои роли.
- Не объединять в один PR сразу contract, workflow, runtime, dashboard и Linear client refactor.
- Не заменять существующую proof vocabulary новой терминологией.
- Не считать уменьшение line count самоцелью без упрощения ownership и testability.

## Ownership Boundaries

### 1. Contract / semantics

- **SSOT:** `docs/policy/project-contract.md`
- **Owns exactly:** `delivery:tdd`, `Acceptance Matrix`, `Proof Mapping`, `Checkpoint`, `cheap gate` / `final gate`, `In Review` / `Blocked`, workpad/attachment evidence rules, planning artifact semantics, `Execution Evidence` semantics.
- **Secondary/executable canon:** repo-local stage и ops skills под `.agents/skills/`.
- **Consumers / projections:** `elixir/WORKFLOW.md`, LET workflow prose/examples, runtime validation/handoff parsers, contract-sensitive tests.
- **Owner workstream:** Contract Agent
- **Skills:** `zoom-out`, `diagnose`, `tdd`

### 2. Repo-local stage and ops skills

- **Canonical role:** second-order executable policy layer; при расхождении идут после `project-contract`, но до workflow prose examples.
- **Owns exactly:** executable interpretation и stage-specific operationalization канонических semantics без самостоятельного изменения vocabulary или precedence.
- **Consumes from:** `docs/policy/project-contract.md`, `workflows/letterl/maxime/let.WORKFLOW.md`, `elixir/WORKFLOW.md`.
- **Must stay aligned with:** contract change-control path, planning/repair flow, runtime validation expectations.
- **Owner workstream:** Skills Alignment Agent
- **Skills:** `zoom-out`, `diagnose`, `debug`

### 3. LET routing / state machine

- **SSOT:** `workflows/letterl/maxime/let.WORKFLOW.md`
- **Owns exactly:** tracker states, routing/state-machine decisions, stage transitions, workflow-level branch/recovery rules.
- **Consumers:** planning/spec-prep routing, LET workflow tests, repo-local planning skills, orchestration consumers.
- **Owner workstream:** Workflow Agent
- **Skills:** `zoom-out`, `diagnose`, `debug`

### 4. Runtime prompt/config contract (`elixir/WORKFLOW.md`)

- **SSOT:** `elixir/WORKFLOW.md`
- **Owns exactly:** runtime-owned config fields, prompt/runtime behavior, repository-specific runtime contract, execution-stage operational rules.
- **Imports but does not own:** `delivery:tdd`, `Acceptance Matrix`, `Proof Mapping`, `Checkpoint`, handoff gate semantics, planning artifact semantics, `Execution Evidence` semantics from `project-contract`.
- **Consumers:** runtime bootstrap/config parsing, handoff/runtime smoke, planning gate behavior, `orchestrator.ex`, `app_server.ex`.
- **Owner workstream:** Runtime Contract Agent
- **Skills:** `zoom-out`, `diagnose`, `tdd`

### 5. Runtime implementation hotspots

- **Primary files:** `orchestrator.ex`, `agent_runner.ex`, `dynamic_tool.ex`, `handoff_check.ex`, `app_server.ex`, `status_dashboard.ex`, `linear/client.ex`
- **Must preserve interfaces for:** workflow/skill consumers, markdown-contract parsers, handoff manifest generation, runtime smoke and final-gate proof.
- **Control-loop surfaces that cannot drift during migration:** issue hydration, classified run failure semantics, pre-run and after-run hook sequencing, acceptance capability preflight, acceptance contract lock, app-session lifecycle, continuation/max-turn behavior, execution-attempt token propagation.
- **Owner workstream:** Runtime Refactor Agent
- **Skills:** `zoom-out`, `diagnose`, `tdd`, `debug`

### 6. Verification surface

- **Primary files:** `core_test.exs`, `orchestrator_status_test.exs`, `json_formatter_test.exs`, `dynamic_tool_test.exs`, `handoff_check_test.exs`, `runtime_smoke_test.exs`, `let_workflow_contract_test.exs`
- **Owns exactly:** implementation-facing regression surface proving that contract/workflow/skill/runtime consumers still agree after extraction.
- **Owner workstream:** Validation Agent
- **Skills:** `tdd`, `debug`

## Phased Refactor Plan

### Phase 0. Baseline, inventory, freeze

**Цель:** получить стартовую карту seams и validation baseline до реальных extraction changes.

**Шаги:**

1. Собрать dependency/call map для:
   - `orchestrator.ex`
   - `agent_runner.ex`
   - `dynamic_tool.ex`
   - `handoff_check.ex`
2. Собрать cross-surface inventory prerequisites:
   - какие repo-local skills читают, повторяют или operationalize contract semantics;
   - какие parser/runtime entrypoints потребляют markdown contracts и workflow fields;
   - где `project-contract`, repo-local skills, `elixir/WORKFLOW.md` и LET workflow пересекаются по одним и тем же semantic fields;
   - какие test files закрепляют эти пересечения как proof surface.
3. Зафиксировать current proof slices:
   - contract/workflow tests
   - targeted hotspot tests, with separate note for `AgentRunner` control-loop behavior
   - `make symphony-runtime-smoke SCENARIO=all`
   - `make symphony-validate`
4. Выделить tests, которые проверяют semantics через substring/text coupling, и пометить их на последующую нормализацию.
5. Классифицировать внешние интерфейсы `app_server.ex` и `status_dashboard.ex`:
   - purely presentation / projection;
   - runtime-contract-reflecting;
   - mixed surfaces, требующие разреза до extraction.
6. Определить candidate seams:
   - contract normalization/parsing
   - skills/workflow alignment
   - orchestration state transitions
   - agent-run control loop / session lifecycle
   - tool schema/rendering
   - handoff manifest/evidence validation
   - dashboard projection/presentation
   - Linear API transport/mapping

**Exit criteria:**

- карта seams задокументирована;
- cross-surface inventory по contract/workflow/skills/parsers/tests собран;
- `AgentRunner` control-loop surfaces и их proofs перечислены отдельно;
- baseline green или список существующих красных тестов зафиксирован;
- каждый hotspot получил первичный extraction plan.

**Rollback:** если inventory automation или baseline нестабилен, не начинать extraction; ограничиться фиксацией baseline и repair validation first.

### Phase 1. Canonical boundary extraction and drift guards

**Цель:** уменьшить semantic drift между `project-contract`, repo-local skills, workflow и runtime consumers до дробления runtime.

**Шаги:**

1. Исправить и закрепить SSOT hierarchy:
   - `project-contract` как primary canon для delivery/proof/handoff semantics;
   - repo-local skills как secondary executable canon;
   - LET workflow как routing/state-machine canon;
   - `elixir/WORKFLOW.md` как runtime prompt/config canon только для runtime-owned surfaces.
2. Разбить ownership по semantic surfaces, а не по файлам целиком:
   - какие поля в `elixir/WORKFLOW.md` являются local runtime canon;
   - какие поля в нем только импортируют contract semantics;
   - где skills operationalize contract, а где merely consume workflow/runtime context.
3. Вынести или подготовить shared parsing/normalization layer для canonical fields:
   - `Acceptance Matrix`
   - `Proof Mapping`
   - `Checkpoint`
   - `Execution Evidence`
   - planning artifact fields (`plan_revision`, `artifact_path`, `artifact_revision`)
4. Выделить отдельный alignment pass для repo-local skills:
   - убрать ложную автономию skills относительно contract semantics;
   - зафиксировать skills как обязательный change-control layer первой фазы;
   - обновлять skill semantics одновременно с contract-boundary changes.
5. Заменить дублирующие inline semantic checks в runtime и tests на общие helpers там, где это снижает drift без расширения surface area.
6. Ужесточить drift-detection tests между markdown contract/workflow, repo-local skills и runtime consumers.

**Зависимости:** после Phase 0 и до любой крупной декомпозиции runtime modules.

**Validation sequencing:**

1. Сначала targeted characterization proof для semantic boundary change.
2. Затем phase cheap gate на том же рабочем дереве.
3. Только после зеленого cheap gate и только для publishable integration state — clean-HEAD final gate (`make symphony-validate`).

**Rollback:** если общие helpers ломают workflow/handoff semantics, откатить helper introduction целиком и оставить только тесты, обнаруживающие drift; если contract boundary обновлен не полностью across skills/workflow/runtime consumers, откатить semantic migration целиком до последнего состояния, где все три поверхности согласованы.

### Phase 2. Handoff and proof engine extraction

**Цель:** выделить из `handoff_check.ex` самостоятельные компоненты, потому что handoff/proof semantics критичны и высоко связаны с contract-first маршрутом.

**Шаги:**

1. Разделить:
   - parsing workpad/manifest evidence;
   - rule evaluation;
   - reporting/rendering diagnostics.
2. Отдельно зафиксировать и измерить текущие cross-surface зависимости с `dynamic_tool.ex`:
   - contract enforcement touchpoints;
   - shared proof targets;
   - общие parser/normalizer paths.
3. Свести contract-sensitive vocabulary к одному import path.
4. Добавить blocking decoupling gate: `Phase 3` не стартует, пока не доказано, какие зависимости `handoff_check` <-> `dynamic_tool` реально можно развязать без смены semantics.
5. Закрыть фазу targeted tests и runtime smoke на handoff-поверхности.

**Зависимости:** после Phase 1, до крупной перестройки `orchestrator.ex` и до любого параллельного split `dynamic_tool`.

**Validation sequencing:**

1. Targeted characterization proof for handoff/proof behavior.
2. Phase cheap gate for handoff/runtime-contract change class.
3. Clean-HEAD final gate only after handoff extraction is ready to remain as the new baseline.

**Rollback:** если после extraction не сохраняется идентичный handoff manifest/proof behavior, откатить до последнего green checkpoint фазы; если acceptance lock, execution evidence, attachment/proof mapping или handoff manifest оказались в stale/partial state, считать фазу failed closed и откатить partial migration вместе с proof artifacts.

### Phase 3. Dynamic tool, agent runner, and app server decomposition

**Цель:** разделить tool protocol, agent-run control loop и app-server orchestration, чтобы сократить blast radius последующих runtime changes без потери execution safety.

**Шаги:**

1. Проверить blocking decoupling gate из `Phase 2`:
   - shared proof targets между `dynamic_tool` и `handoff_check` перечислены;
   - cross-surface dependencies признаны либо уменьшены;
   - обновлен ownership map для contract-sensitive paths.
2. В `dynamic_tool.ex` отделить:
   - schema/model shaping;
   - request/response normalization;
   - transport/execution glue;
   - error rendering.
3. В `agent_runner.ex` выделить и зафиксировать как отдельные migration surfaces:
   - issue hydration;
   - classified run failure semantics;
   - pre-run / after-run hook sequencing;
   - acceptance capability preflight;
   - acceptance contract lock;
   - continuation/max-turn logic;
   - execution-attempt token propagation;
   - session teardown guarantees.
4. В `app_server.ex` перед extraction разделить интерфейсы на:
   - runtime-contract-reflecting;
   - session/process lifecycle;
   - Codex app-server integration;
   - request dispatch.
5. В `app_server.ex` отделить implementation по этим границам, не смешивая runtime-contract-reflecting surfaces с transport/lifecycle кодом.
6. Перенести shared tool protocol helpers в отдельный слой, не зависящий от UI/dashboard.

**Зависимости:** строго после Phase 2 decoupling gate; параллельный запуск с поздней `Phase 2` запрещен, пока не доказана реальная развязка через tests и ownership map.

**Migration safety invariants:**

- цепочка `Orchestrator -> AgentRunner -> Workspace hooks / acceptance preflight / acceptance lock -> AppServer session lifecycle` должна оставаться behavior-preserving на каждом промежуточном шаге;
- любая правка `orchestrator`, `agent_runner` или `app_server` обязана сохранять issue hydration, classified failure semantics, hook sequencing, session teardown и continuation/max-turn behavior;
- runtime smoke не заменяет targeted control-loop proofs для этих изменений, а идет после них.

**Validation sequencing:**

1. Targeted characterization proof for `dynamic_tool`.
2. Targeted control-loop proof for `agent_runner` / `app_server`.
3. Phase cheap gate for runtime/handoff/control-loop change class.
4. Clean-HEAD final gate only after phase-local migration state is publishable and all control-loop invariants green.

**Rollback:** если extraction требует одновременного изменения dashboard, handoff surfaces или contract-sensitive runtime validators, split признается слишком широким и разбивается на меньшие sub-phases; если ломается любой control-loop invariant, откатывать всю частичную миграцию `agent_runner`/`app_server` вместе, а не только последний helper.

### Phase 4. Orchestrator decomposition

**Цель:** сократить `orchestrator.ex` через вынос bounded subdomains, не меняя state machine behavior.

**Предпочтительный разрез:**

1. issue routing / attempt lifecycle
2. workspace/bootstrap lifecycle
3. validation/handoff transitions
4. retry/reconcile logic
5. observability/status emission

**Правила:**

- извлекать по одному subdomain за раз;
- не смешивать extraction с semantic changes workflow contract;
- каждый шаг закрывать characterization tests, затем phase cheap gate, и только потом runtime smoke / final gate по change class.
- не выделять orchestration slices, пока связанный `AgentRunner` control-loop segment не имеет отдельного green proof.

**Зависимости:** после Phase 1 и желательно после Phase 2-3, когда contract/tool seams уже выделены.

**Validation sequencing:**

1. Targeted orchestration proof on the touched subdomain.
2. Targeted `AgentRunner` control-loop proof, если шаг затрагивает execution path.
3. Phase cheap gate for runtime/orchestration change class.
4. Clean-HEAD final gate only when subdomain extraction is stable enough to become the new integration baseline.

**Rollback:** если очередной subdomain extraction требует переписать несколько соседних подсистем сразу, шаг отклоняется и режется на меньшие vertical slices; если orchestration change проходит локально, но ломает runner continuation, hook sequencing или classified failure path, откатывать весь subdomain slice.

### Phase 5. Dashboard and Linear client isolation

**Цель:** изолировать presentation/projection logic и transport/client logic от core orchestration.

**Шаги:**

1. Вынести из `status_dashboard.ex`:
   - projection builders;
   - formatting/presentation helpers;
   - runtime-state mapping с отдельной пометкой, какие проекции merely presentation, а какие отражают contract/runtime state.
2. Вынести из `linear/client.ex`:
   - transport layer;
   - query/mutation builders;
   - response decoding/mapping;
   - retry/backoff policy hooks.

**Зависимости:** после стабилизации orchestration seams, чтобы не зацементировать временные API.

**Validation sequencing:**

1. Targeted projection/transport proof.
2. Phase cheap gate on the affected change class.
3. Final gate only when no upstream runtime-control instability remains open.

**Rollback:** при обнаружении, что dashboard/Linear changes зависят от незавершенной orchestration decomposition, фаза возвращается в backlog и не проталкивается поверх незрелых интерфейсов.

### Phase 6. Test cleanup, dead-path removal, final simplification

**Цель:** снять технический долг, возникший после extraction, только после того как новые seams доказали свою устойчивость.

**Шаги:**

1. Удалить dead wrappers и временные adapters, оставшиеся после миграций.
2. Упростить substring-heavy tests там, где уже есть более точные semantic assertions.
3. Зафиксировать новую module map и ownership notes рядом с кодом и/или в repo docs.

**Зависимости:** только после зеленого прохождения предыдущих фаз.

**Rollback:** если cleanup меняет proof surface без пользы для читаемости/ownership, cleanup отменяется.

## Dependency And Order Constraints

1. **Phase 0 обязательна первой.** Без baseline нельзя отличить рефакторинг от скрытого behavioral change.
2. **Phase 1 идет до крупных runtime extraction.** Это главный anti-drift барьер.
3. **Phase 2 идет раньше полной декомпозиции orchestrator.** Иначе handoff/proof rules продолжат протекать через большой общий модуль.
4. **Phase 3 не идет параллельно с Phase 2, пока decoupling gate между `handoff_check` и `dynamic_tool` не закрыт явным proof.**
5. **Phase 3 не стартует, пока `AgentRunner` control-loop invariants и их targeted proofs не перечислены как migration surface.**
6. **Phase 4 не должна включать одновременно `orchestrator.ex` и workflow semantic rewrites.**
7. **Phase 5 идет после стабилизации core seams и после зеленого safety trigger на `orchestrator` / `agent_runner` / `app_server`.**
8. **Phase 6 всегда последняя.**
9. **Изменения `status_dashboard`, workflow или repo-local skills`, которые отражают runtime-control behavior, трактуются как global late-phase safety rule, а не как Phase-5-local convenience step: они запрещены, пока execution-control surfaces `orchestrator` / `agent_runner` / `app_server` не стабилизированы зеленым cheap gate и clean-HEAD final gate на текущем baseline.**

## Validation Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `R1` | Baseline перед первым extraction | текущий runtime и contract behavior зафиксирован | `runtime_smoke` | `make symphony-runtime-smoke SCENARIO=all` | `runtime_smoke` | `review` |
| `R2` | SSOT hierarchy и canonical boundary split | primary/secondary canon и imported semantics не перепутаны между contract, skills, workflows и runtime | `test` | `elixir/test/symphony_elixir/let_workflow_contract_test.exs` + `elixir/test/symphony_elixir/dynamic_tool_test.exs` + `elixir/test/symphony_elixir/handoff_check_test.exs` | `run_executed` | `review` |
| `R3` | Repo-local skills alignment после Phase 1 | skills остаются синхронизированы с contract boundary и change-control expectations | `test` | `elixir/test/symphony_elixir/let_workflow_contract_test.exs` + `elixir/test/symphony_elixir/dynamic_tool_test.exs` + `elixir/test/symphony_elixir/handoff_check_test.exs` | `run_executed` | `review` |
| `R4` | Cross-surface consumer compatibility | workflow, skills, runtime parsers и tests одинаково читают canonical fields | `test` | `elixir/test/symphony_elixir/dynamic_tool_test.exs` + `elixir/test/symphony_elixir/handoff_check_test.exs` + `elixir/test/symphony_elixir/let_workflow_contract_test.exs` | `run_executed` | `review` |
| `R5` | Handoff/proof engine refactor | handoff manifest и fail-closed semantics сохраняются | `test` | `elixir/test/symphony_elixir/handoff_check_test.exs` | `run_executed` | `review` |
| `R6` | `handoff_check` / `dynamic_tool` decoupling gate | cross-surface dependencies перечислены и reduction claims доказаны до split `Phase 3` | `test` | `elixir/test/symphony_elixir/dynamic_tool_test.exs` + `elixir/test/symphony_elixir/handoff_check_test.exs` | `run_executed` | `review` |
| `R7` | `AgentRunner` control-loop invariants | issue hydration, classified failure, hooks, acceptance lock, session teardown и continuation behavior сохраняются | `test` | `elixir/test/symphony_elixir/core_test.exs` + `elixir/test/symphony_elixir/runtime_smoke_test.exs` + `elixir/test/symphony_elixir/json_formatter_test.exs` | `run_executed` | `review` |
| `R8` | Dynamic tool decomposition | tool behavior и error shaping сохраняются | `test` | `elixir/test/symphony_elixir/dynamic_tool_test.exs` | `run_executed` | `review` |
| `R9` | Workflow/skills migration safety | workflow and repo-local skills changes retain executable semantics and do not drift from runtime validators | `test` | `elixir/test/symphony_elixir/let_workflow_contract_test.exs` + `elixir/test/symphony_elixir/dynamic_tool_test.exs` + `elixir/test/symphony_elixir/handoff_check_test.exs` | `run_executed` | `review` |
| `R10` | Orchestrator decomposition | orchestration state/status behavior сохраняется | `test` | `elixir/test/symphony_elixir/core_test.exs` + `elixir/test/symphony_elixir/orchestrator_status_test.exs` | `run_executed` | `review` |
| `R11` | Proof-state validity during migration | stale acceptance lock, stale execution evidence, broken proof mapping, mismatched clean-HEAD assumptions fail closed | `test` | `elixir/test/symphony_elixir/handoff_check_test.exs` + `elixir/test/symphony_elixir/dynamic_tool_test.exs` | `run_executed` | `review` |
| `R12` | Repo-wide integration после каждой завершенной фазы | рефакторинг не ломает общий validation gate | `test` | `make symphony-validate` | `run_executed` | `review` |
| `R13` | Финальный runtime contract regression | workflow/runtime/handoff/skill surfaces совместимы после серии extraction | `runtime_smoke` | `elixir/test/symphony_elixir/runtime_smoke_test.exs` + `make symphony-runtime-smoke SCENARIO=all` | `runtime_smoke` | `review` |

## Proof Mapping

- `R1` -> baseline runtime smoke log и зафиксированный стартовый validation status.
- `R2` -> proof через `elixir/test/symphony_elixir/let_workflow_contract_test.exs`, `elixir/test/symphony_elixir/dynamic_tool_test.exs` и `elixir/test/symphony_elixir/handoff_check_test.exs`, подтверждающий правильный precedence order и semantic boundary split.
- `R3` -> proof через `elixir/test/symphony_elixir/let_workflow_contract_test.exs`, `elixir/test/symphony_elixir/dynamic_tool_test.exs` и `elixir/test/symphony_elixir/handoff_check_test.exs`, подтверждающий, что repo-local skills синхронизированы с contract-boundary changes.
- `R4` -> cross-surface proof через `elixir/test/symphony_elixir/dynamic_tool_test.exs`, `elixir/test/symphony_elixir/handoff_check_test.exs` и `elixir/test/symphony_elixir/let_workflow_contract_test.exs` на одинаковое чтение canonical fields skills/workflow/runtime consumers.
- `R5` -> targeted proof через `elixir/test/symphony_elixir/handoff_check_test.exs` на тех же сценариях, что защищают fail-closed behavior.
- `R6` -> proof через `elixir/test/symphony_elixir/dynamic_tool_test.exs` и `elixir/test/symphony_elixir/handoff_check_test.exs`, что claims о развязке `handoff_check` / `dynamic_tool` подтверждены, а не предполагаются.
- `R7` -> proof через `elixir/test/symphony_elixir/core_test.exs`, `elixir/test/symphony_elixir/runtime_smoke_test.exs` и `elixir/test/symphony_elixir/json_formatter_test.exs` на hydration, failure classification, hooks, acceptance lock, session teardown и continuation behavior.
- `R8` -> targeted proof через `elixir/test/symphony_elixir/dynamic_tool_test.exs` на сохранение schema/rendering/execution semantics.
- `R9` -> proof через `elixir/test/symphony_elixir/let_workflow_contract_test.exs`, `elixir/test/symphony_elixir/dynamic_tool_test.exs` и `elixir/test/symphony_elixir/handoff_check_test.exs` на сохранение executable semantics и alignment с runtime validators.
- `R10` -> targeted orchestration proof через `elixir/test/symphony_elixir/core_test.exs` и `elixir/test/symphony_elixir/orchestrator_status_test.exs` на state/status/attempt behavior.
- `R11` -> fail-closed proof через `elixir/test/symphony_elixir/handoff_check_test.exs` и `elixir/test/symphony_elixir/dynamic_tool_test.exs` для invalid proof-state cases: stale acceptance lock, stale execution evidence, broken proof mapping, clean-HEAD mismatch.
- `R12` -> обязательный repo-wide final gate `make symphony-validate` на завершении каждой крупной фазы.
- `R13` -> runtime smoke proof для cross-surface contract compatibility, включая skill/runtime handoff surfaces.

## Rollback Rules

### Общие

1. Любая фаза откатывается локально, если меняет поведение до прохождения ее targeted proof.
2. Нельзя накапливать два незавершенных extraction fronts одновременно.
3. Если изменение требует правки contract semantics и runtime behavior в одном шаге без промежуточного green state, шаг считается слишком широким и режется.
4. Если после extraction растет число временных adapters без явной даты удаления, шаг замораживается до упрощения.
5. Любая partial semantic migration across contract/workflow/skills/runtime validators считается failed closed, даже если основной runtime path выглядит зеленым.
6. Любой invalid proof-state (`stale acceptance lock`, `stale execution evidence`, broken proof mapping, dirty-worktree reuse of final proof) считается rollback trigger.

### По фазам

- **Phase 1:** при semantic drift откатить shared helper/extractor, сохранить только тестовое обнаружение drift; если contract text, workflow prose, repo-local skills и runtime validators не обновились согласованно, откатывать весь semantic migration batch.
- **Phase 2:** при расхождении handoff manifest вернуть прежний evaluation path; stale acceptance lock, stale execution evidence или broken proof mapping трактовать как fail-closed rollback event.
- **Phase 3:** при слипании tool protocol, `AgentRunner` control-loop и app-server lifecycle вернуть split к меньшему scope; если нарушен session teardown или hook sequencing, откатить весь partial control-loop migration.
- **Phase 4:** если очередной subdomain extraction требует touching нескольких ownership zones, откатить и переопределить seam; если проход `orchestrator` ломает `AgentRunner`-backed execution path, откатывать весь subdomain slice вместе с orchestration glue.
- **Phase 5:** при нестабильности dashboard/Linear projections отложить их до завершения orchestrator cleanup; late-phase changes, отражающие runtime-control behavior, откатывать при любом upstream control-loop regression.
- **Phase 6:** dead-path removal откатывается первым, если ломает final gate или инвалидирует ранее green proof-state.

## Risks And Conflicts

### Основные риски

1. **Semantic drift:** одинаковые термины трактуются по-разному в contract, workflow, skills и runtime.
2. **False-green tests:** substring-heavy assertions могут пропускать неверный structural behavior.
3. **Merge pressure:** крупные hotspot-файлы с высокой вероятностью будут параллельно меняться другими агентами.
4. **Over-extraction:** слишком ранний вынос abstraction layers увеличит косвенность без реального упрощения.
5. **Phase coupling:** попытка рефакторить `orchestrator`, `handoff_check` и `dynamic_tool` в одной волне создаст неоткатываемый клубок.

### Конфликты и способы снятия

1. **Contract-first vs runtime-first:** конфликт снят в пользу contract-first, потому что он уменьшает цену последующих изменений.
2. **Дробить по слоям или по вертикальным маршрутам:** выбран вертикальный маршрут по bounded subdomain, а не горизонтальная “общая cleanup phase”.
3. **Улучшать тесты до extraction или после:** сначала только те улучшения, которые нужны как characterization shield; косметическая переработка тестов — в последней фазе.

## Execution Preparation Notes

- Перед стартом кодовых изменений внутри `Phase 0` нужно:
  - собрать `zoom-out` карту по `orchestrator.ex`, `dynamic_tool.ex`, `handoff_check.ex`;
  - проверить `diagnose`-уровнем самые слабые текущие tests;
  - определить, где будущие extraction seams требуют `tdd`-стиля characterization proof.
- Эти шаги являются частью исполнения `Phase 0`, а не отдельным внешним approval или critique gate.

## Residual Risks

### Phase 0 Inputs (не блокируют старт `Phase 0`)

- До Phase 0 остается неразрешенным точный модульный разрез `orchestrator.ex`.
- Не измерена стоимость частых `make symphony-validate` прогонов по фазам; это Phase 0 input для уточнения cheap/final proof cadence, а не скрытый gate на старт плана.

### Must Resolve Before Leaving Phase 0

- Нужно подтвердить, что baseline tests покрывают extraction seams достаточно семантически для первой волны изменений.
- Нужно зафиксировать фактический call-graph execution-control surfaces настолько, чтобы следующий phase-local split не опирался на скрытые допущения.

### Open Risks To Monitor During Execution

- Не доказано, что все текущие tests достаточно семантические для безопасного extraction.
- Возможна переоценка надежности отдельных regression slices, если фактический call-graph выявит более плотную связанность control-loop surfaces, чем ожидается на старте.

### Readiness Status

- План считается implementation-ready для старта `Phase 0`.
- Остаточные пункты выше не являются обязательным внешним gate до начала исполнения; они должны быть закрыты или уточнены внутри `Phase 0` и по ходу phase-local validation sequencing.
- Нормативная сила формулировок в этом документе едина: `обязательна`, `запрещено`, `rollback trigger`, `required_before` означают hard gate; `monitor`, `input`, `deferred-in-scope` означают управляемый риск без запрета на старт `Phase 0`.

## End-of-Run Ledger

- **Target document:** `docs/plans/symphony-refactor-plan.md`
- **Specification chosen:** короткий implementation-ready refactor plan на русском языке с явным Swarm Mode протоколом, фазами, зависимостями, ownership, rollback, validation и non-goals; готов к старту с `Phase 0` без скрытого внешнего critique gate.
- **Main sections created:** `Document Spec`, `Подтвержденный контекст`, `Phase 1`, `Phase 2`, `Phase 3`, `Выбранный маршрут`, `Non-Goals`, `Ownership Boundaries`, `Phased Refactor Plan`, `Dependency And Order Constraints`, `Validation Matrix`, `Proof Mapping`, `Rollback Rules`, `Risks And Conflicts`, `Residual Risks`, `End-of-Run Ledger`.
- **Residual open issues:** нужен call-graph hotspot-модулей; нужна карта test runtime cost; обе задачи входят в `Phase 0` и не блокируют старт исполнения по этому плану.
