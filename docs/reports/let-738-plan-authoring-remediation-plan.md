# LET-738: Plan Authoring Remediation Plan (mode:plan first-pass correctness)

## 1) Спецификация целевого документа

### 1.1 Цель

Пересобрать `Task-spec contract` так, чтобы `mode:plan` task-spec description
формировался корректно с первого прохода и не ломал переход
`Spec Prep -> Spec Review -> In Progress`.

### 1.2 Ограничения

- Не добавлять новые сущности, скрипты, policy-файлы или новые runtime-механизмы.
- Менять только существующие файлы контракта/инструкций/контрактных тестов.
- Приоритет источников: `project-contract` -> skills -> workflow prose.

### 1.2.1 Нормализация терминов

- `Task-spec contract`:
  контракт структуры и содержимого issue description на этапе authoring.
- `Runtime consume contract`:
  контракт того, как runtime/parser/validator потребляют и проверяют этот description.
- В документе использовать только эти термины для соответствующих слоев, чтобы
  не смешивать `authoring-контракт`/`description contract`/`generator contract`.

### 1.3 Входные конфликты, которые нужно закрыть

1. Двусмысленность: `checklists explicit` vs запрет чекбоксов в description.
2. Дрейф между workflow и `project-contract` по структуре short plan.
3. Конфликт правила `## Symphony` last section с требованием не перемещать inline media/uploads.
4. Смешение issue description (`Task-spec contract`) и рабочего журнала (workpad).

### 1.4 Критерии готовности remediation-плана

- Для каждого конфликта задано одно однозначное правило без противоречий.
- Для каждого правила указан конкретный файл/раздел, где фиксируется изменение.
- Для каждого изменения указан named regression-proof.
- План закрывает зависимости и интерфейсные последствия по цепочке
  `workflow -> skill -> runtime parser/consumer tests`.

## 2) Решение конфликтов (однозначные правила)

### Конфликт A: checklist wording vs no checkboxes

Решение:
- В issue description разрешены только обычные маркеры списка (`- пункт`).
- Markdown-чекбоксы (`- [ ]`, `- [x]`) разрешены только в workpad.
- Формулировка `checklists are explicit` заменяется на
  `acceptance/verification items are explicit and reviewable as plain list items`.

Почему это снимает конфликт:
- Сохраняется требование явности/обозримости пунктов.
- Устраняется интерпретация, которая провоцирует чекбоксы в description.

### Конфликт B: workflow template vs project-contract canonical short plan

Источник контракта:
- `project-contract` требует canonical short-plan поля:
  `Document Spec`, `Verification Plan`, `Residual Risks`,
  и для `mode:plan` также `Acceptance Matrix` + `Proof Mapping`.

Решение:
- В workflow фиксируется явный mapping (без нового policy):
  - `Document Spec` := `Проблема` + `Цель` + `Скоуп` (+ `Вне скоупа`/`Зависимости` при необходимости);
  - `Verification Plan` := `Критерии приемки` + обязательные `Acceptance Matrix` и `Proof Mapping`;
  - `Residual Risks` := обязательный раздел `Остаточные риски` для `mode:plan`
    (а `Заметки` остаются только для контекста rollout/constraints).
- Для `mode:plan` обязательность `Acceptance Matrix`, `Proof Mapping` и `Остаточные риски`
  фиксируется явно в `Task-spec contract`.

Почему это снимает конфликт:
- Совместимость с `project-contract` становится явной и проверяемой.
- `Residual Risks` больше не зависят от опционального раздела.

### Конфликт C: `## Symphony` last section vs preserve uploads/media

Выбранный путь: parser hardening (а не запрет trailing media).

Решение:
- `## Symphony` остается последним **H2** разделом.
- Нехедерные inline media/uploads после `## Symphony` сохраняются и не перемещаются.
- Машиночитаемые строки в `## Symphony` задаются как contiguous marker-block сразу под заголовком.
- `extract_symphony_marker` в workflow (bootstrap + retry hook) ужесточается:
  - читает только contiguous marker-block;
  - прекращает парсинг marker-строк при первой непустой non-marker строке
    (даже если дальше встречается `Base branch:`/`Working branch:` как обычный текст).

Почему это снимает конфликт:
- Сохраняется требование “не перемещать uploads/media”.
- Убирается parser ambiguity и ложные marker collisions.

### Конфликт D: смешение description и рабочего журнала

Решение:
- Ownership фиксируется явно в workflow и plan-mode:
  - issue description: только `Task-spec contract`;
  - workpad: чекбоксы, прогресс, checkpoint, execution evidence, операционный журнал.
- В description запрещаются workpad-маркеры/секции
  (`Рабочий журнал Codex`, `Execution Evidence`, progress logs, managed markers).

Почему это снимает конфликт:
- Устраняется причина “план похож на журнал” и handoff-blockers на `Task-spec contract`.

## 3) Минимальный пофайловый план правок (без новых сущностей)

## 3.1 `workflows/letterl/maxime/let.WORKFLOW.md`

Изменить только существующие prose/шаблон/embedded-hook блоки:

1. В `Task-spec issue description` добавить mode:plan addendum:
- обязательные `Acceptance Matrix` + `Proof Mapping`;
- обязательный `Остаточные риски` (эквивалент canonical `Residual Risks`);
- при `planning.swarm_assist_enabled=true` обязательные
  `plan_revision`, `artifact_path`, `artifact_revision` (`artifact_revision == plan_revision`).

2. В completion bar (`Spec Review`) заменить двусмысленное `checklists` wording
   на формулировку plain-list-only для description.

3. В правилах `## Symphony`:
- явно зафиксировать “last H2 section”;
- явно разрешить trailing non-heading uploads/media;
- явно потребовать contiguous marker-block для `Repo/Base branch/Working branch/Required capabilities`.

4. В guardrails добавить явную строку:
- `workpad-only content (progress checklist, checkpoint, execution evidence) is not allowed in issue description`.

5. Добавить mapping-абзац:
- русские секции task-spec эквивалентны canonical short-plan полям из `project-contract`.

6. В обоих embedded shell hooks (`after_create`/bootstrap и `before_run`/retry)
   обновить `extract_symphony_marker` до parse-safe поведения
   (contiguous marker-block, stop on first non-marker content line).

7. Явно указать наследование этих правил `Task-spec contract` для legacy spec-prep path
   (без `mode:*` labels), чтобы не было расхождения между `mode:plan` и legacy.

## 3.2 `.agents/skills/plan-mode/SKILL.md`

Добавить компактный preflight `Task-spec contract` перед `issueUpdate(description)`:

1. Проверка структуры: для `mode:plan` есть обязательные task-spec секции,
   включая `Acceptance Matrix`, `Proof Mapping`, `Остаточные риски`.
2. Нормализация списков: в description только plain bullets, без markdown-чекбоксов.
3. Проверка ownership: workpad-секции не попали в description.
4. Проверка `## Symphony`: последняя H2; машиночитаемые строки — contiguous marker-block.
5. При gate=true: `plan_revision`, `artifact_path`, `artifact_revision` присутствуют и согласованы.
6. Для legacy spec-prep path использовать те же инварианты `Task-spec contract`.

Важно: это write-first-time инструкция генерации, не новый runtime-блокер.

## 3.3 `elixir/test/symphony_elixir/let_workflow_contract_test.exs`

Расширить текстовые contract-assertions:

1. Явная формулировка plain-list-only для issue description.
2. Явная формулировка: `## Symphony` — last H2 section.
3. Явная формулировка mode:plan mandatory: `Acceptance Matrix`, `Proof Mapping`, `Residual Risks` equivalent.
4. Явная формулировка gate=true trio: `plan_revision`, `artifact_path`, `artifact_revision`.
5. Явная формулировка запрета workpad/progress markers в description.
6. Явная формулировка наследования правил `Task-spec contract` для legacy spec-prep path.

## 3.4 `elixir/test/symphony_elixir/workspace_and_config_test.exs`

Parser-hardening tests делать с обязательной привязкой к каноническому workflow hook.

1. Parity gate (обязательный):
- в `workspace_and_config_test.exs` явно объявляется anchor:
  `@let_workflow_path Path.expand("../../../workflows/letterl/maxime/let.WORKFLOW.md", __DIR__)`;
- hook-скрипты всегда извлекаются из канонического файла через
  `{:ok, %{config: config}} = Workflow.load(@let_workflow_path)` и
  `config["workspace"]["hook"]["after_create"]` / `config["workspace"]["hook"]["before_run"]`;
- для локального исполнения разрешены только env-замены repo URL в тестовом окружении;
  parser-логика hook текста не переписывается;
- helper-функции (`repository_routing_hook`/`repository_retry_hook`) остаются только как
  адаптеры выполнения и всегда проходят обязательную byte/parsing parity-проверку
  против канонически извлеченного hook-текста.

2. Interface-level parser regression (bootstrap + retry hook paths):
- trailing non-marker content внутри `## Symphony` не должен порождать
  дополнительные `Base branch:`/`Working branch:` matches;
- marker parsing прекращается на первой непустой non-marker строке;
- `Base branch` fallback/default поведение не меняется, когда marker отсутствует;
- marker multiplicity/invalid marker сценарии сохраняют существующие blocker/error semantics;
- trailing uploads/media не ломают корректные marker значения.
- parser-кейсы этого блока помечаются тегом `@tag :parser_contract` для узкого Tier-1 gate.

Это закрепляет parse-safe поведение `Task-spec contract` на реальном hook-пути, без новых сущностей.

## 3.5 Runtime consumer regression surface (existing suites)

Для consume-side подтверждения без новых сущностей использовать/расширить
существующие suite-пути:

1. `elixir/test/symphony_elixir/handoff_check_test.exs`
   (two-layer metadata extraction/validation invariants).
2. `elixir/test/symphony_elixir/dynamic_tool_test.exs`
   (mode:plan `Task-spec contract` gate around Acceptance Matrix/Proof Mapping path).
3. `elixir/test/symphony_elixir/spec_check_test.exs`
   (mode:plan spec-gate expectations).

## 4) Порядок внедрения (bounded slices + slice gates)

### 4.1 Cross-slice failure policy

- Для каждого distinct failing signal внутри одного slice: максимум 2 fix attempts.
- Если 2-я попытка не дала green:
  - rollback всего slice к pre-slice состоянию или `defer` с явной причиной;
  - зафиксировать blocker/reason и почему продолжение unsafe;
  - не переносить partial изменения в следующий slice (no hidden carry-over).

### 4.2 Slice order and mandatory gates

1. Slice A (contract prose in `let.WORKFLOW.md`)
- Scope: секции task-spec/guardrails/completion-bar/mapping/legacy inheritance.
- Must-pass before next slice:
  - `mix test test/symphony_elixir/let_workflow_contract_test.exs`.
- Rollback boundary: только правки workflow prose.

2. Slice B (`Task-spec contract` generation in `plan-mode/SKILL.md`)
- Scope: pre-write проверки `Task-spec contract` и wording 1:1 с workflow.
- Must-pass before next slice:
  - `mix test test/symphony_elixir/let_workflow_contract_test.exs`.
- Rollback boundary: только правки `plan-mode` skill.

3. Slice C (workflow/skill contract assertions)
- Scope: обновление `let_workflow_contract_test.exs`.
- Must-pass before next slice:
  - `mix test test/symphony_elixir/let_workflow_contract_test.exs`.
- Rollback boundary: только contract-test assertions.

4. Slice D (parser interface tests)
- Scope: `workspace_and_config_test.exs` parity gate + parser failure modes.
- Must-pass before next slice:
  - `mix test test/symphony_elixir/workspace_and_config_test.exs --only parser_contract`.
- Rollback boundary: parser test-only changes.

5. Slice E (consumer regression alignment)
- Scope: targeted updates/verification in `handoff_check_test` / `dynamic_tool_test` / `spec_check_test` (only where required by changed contract).
- Must-pass before completion:
  - targeted tests (section 5.1), then full confirmations (section 5.2).
- Rollback boundary: consumer tests and minimal coupled adjustments only.

## 5) Проверка и доказательство внедрения (targeted -> full)

Правило таксономии:
- `Tier-1 targeted` = минимальный набор команд для текущего slice/failing signal
  (предпочтительно line/tag scoped; file-scoped допустим только для узкой
  специализированной suite).
- `Tier-2 full` = полное подтверждение по затронутым core-suite перед финализацией.

### 5.1 Tier-1 targeted gates (per-slice and fast triage)

1. Workflow/skill contract:
- `mix test test/symphony_elixir/let_workflow_contract_test.exs`.

2. Parser contract path:
- `mix test test/symphony_elixir/workspace_and_config_test.exs --only parser_contract`.

3. Consumer smoke checks (single-signal targeted):
- `mix test test/symphony_elixir/spec_check_test.exs:81`
- `mix test test/symphony_elixir/handoff_check_test.exs:1651`
- `mix test test/symphony_elixir/dynamic_tool_test.exs:2473`

### 5.2 Tier-2 full confirmations (boundary/final)

1. `mix test test/symphony_elixir/handoff_check_test.exs`
2. `mix test test/symphony_elixir/dynamic_tool_test.exs`
3. `mix test test/symphony_elixir/spec_check_test.exs`
4. `mix test test/symphony_elixir/workspace_and_config_test.exs`

### 5.3 Manual authoring smoke

- description без чекбоксов;
- содержит `Acceptance Matrix`, `Proof Mapping`, `Остаточные риски`;
- при gate=true содержит `plan_revision`, `artifact_path`, `artifact_revision`;
- не содержит workpad-секций;
- `## Symphony` последняя H2 и marker-block parse-safe.

## 6) Что сознательно НЕ делаем

- Не добавляем новые policy-файлы.
- Не добавляем новые скрипты/генераторы/линтеры.
- Не добавляем новые runtime подсистемы.
- Не меняем execution semantics вне scope `Task-spec contract` для mode:plan/legacy spec-prep.

## 7) Остаточные риски (bounded)

- До прохождения proof-set из раздела 5 статус remediation остается `provisional`.
- После прохождения tier-1 + tier-2 proof-set остаточные конфликты
  в рамках `Task-spec contract` ожидаются закрытыми.
- Вне рамки этого плана остается только будущий drift при несинхронных
  правках workflow/skill/tests.

## Repair Round 1 Ledger

- Target document:
  - `docs/reports/let-738-plan-authoring-remediation-plan.md`

- Items fixed in order:
  1. P0: `Residual Risks` mapping сделан обязательным (`Остаточные риски`), а не опциональным через `Заметки`.
  2. P0: выбран и зафиксирован parse-safe путь для `## Symphony` (parser hardening + tests), без запрета trailing uploads.
  3. P0: proof strategy усилена до interface-level через parser/consumer test surface, не только текстовые asserts.
  4. P1: добавлено явное наследование правил `Task-spec contract` для legacy spec-prep path.
  5. P1: абсолютный claim `none` заменен на bounded residual-risk statement с условием green proof-set.

- Items retired with justification:
  - none.

- Residual open issues still open:
  - design-level conflicts resolved; execution-level proof pending (section 5 test set).

## Repair Round 2 Ledger

- Target document:
  - `docs/reports/let-738-plan-authoring-remediation-plan.md`

- Items fixed in order:
  1. P0: добавлен canonical-hook parity gate, чтобы parser tests валидировали поведение, связанное с каноническим `let.WORKFLOW.md`, а не только helper-копиями.
  2. P0: добавлены slice-level execution gates с обязательным `must-pass-before-next-slice` для каждого slice.
  3. P0: добавлена явная per-slice failure policy: максимум 2 attempts, затем rollback/defer с причиной и без hidden carry-over.
  4. P0: расширено parser failure-mode покрытие для init+retry hook paths (non-marker interruption, fallback/default, marker-collision).
  5. P1: proof-команды разделены на Tier-1 targeted gates и Tier-2 full confirmations для лучшего triage/rollback.

- Items retired with justification:
  - none.

- Residual open issues still open:
  - design-level conflicts resolved; execution-level proof pending until section 5 commands are green.

## Repair Round 3 Ledger

- Target document:
  - `docs/reports/let-738-plan-authoring-remediation-plan.md`

- Items fixed in order:
  1. P0: section 3.4 parity-gate переписан в однозначный strict-path без условной ветки.
  2. P0: anchor-стратегия для канонического hook extraction уточнена до явного и декларируемого пути (`@let_workflow_path` + `Workflow.load` + config path).
  3. P0: taxonomy `Tier-1 targeted` vs `Tier-2 full` зафиксирована строгими правилами и командами.
  4. P1: терминология нормализована вокруг `Task-spec contract` и `Runtime consume contract`.
  5. P1: residual-status фразы в ledger переформулированы в bounded, неконфликтный вид.

- Items retired with justification:
  - none.

- Residual open issues still open:
  - none at wording/coherence level; execution proof remains pending until section 5 commands are green.
