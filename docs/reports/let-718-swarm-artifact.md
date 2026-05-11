# LET-718 Swarm Artifact

plan_revision: let-718-plan-r1
artifact_revision: let-718-plan-r1

## Спецификация документа

Цель документа: поддержать `mode:plan` Spec Prep для LET-718 при подготовке E2E-валидации Symphony skills по цепочке `research -> plan -> execute`.

Статус документа: supporting-only. Канонический короткий план, область работ, acceptance, state routing, proof semantics и checkpoint rules остаются в описании Linear issue и в `docs/policy/project-contract.md`. Этот артефакт не заменяет и не расширяет SSOT, а только собирает контекст, зависимости, предпосылки, интерфейсные воздействия, риски, контуры реализации, проверки и диагностики.

Ожидаемое использование: артефакт должен быть связан с коротким планом через одинаковые `plan_revision` и `artifact_revision`, а при включенном `planning.swarm_assist_enabled=true` должен оставаться subordinate artifact under `docs/reports/`.

## Контекст

LET-718 проверяет сквозную пригодность Symphony workflow для задач, проходящих через исследование, планирование и исполнение. Фокус не в новой бизнес-логике, а в доказуемости переходов между стадиями и в том, что stage skills соблюдают общий контракт.

Каноническая рамка берется из `docs/policy/project-contract.md`:

- `mode:plan` при включенном swarm assist использует две прослойки: короткий канонический план и linked swarm artifact.
- Короткий план остается SSOT для scope, acceptance и proof semantics.
- Linked artifact является только supporting analysis.
- `artifact_revision` должен совпадать с `plan_revision`.
- Для execution-фазы требуется preflight с секцией `Execution Evidence`.
- `symphony_handoff_check` должен fail-closed при divergence между issue contract, artifact, attachment и runtime evidence.

Релевантная реализация находится в `elixir/lib/symphony_elixir/handoff_check.ex`, а регрессионные сигналы - в `elixir/test/symphony_elixir/handoff_check_test.exs`.

## Dependencies And Prerequisites

Эта секция фиксирует только то, что должно быть проверено вокруг артефакта. Значения и итоговые обязательства принадлежат каноническому короткому плану в Linear issue.

Для planning-layer prerequisites короткий план должен содержать:

- label/context: `mode:plan`;
- gate: `planning.swarm_assist_enabled=true`;
- `plan_revision`: `let-718-plan-r1`;
- `artifact_path`: `docs/reports/let-718-swarm-artifact.md`;
- `artifact_revision`: `let-718-plan-r1`;
- состояние plan lifecycle, совместимое с review-ready handoff после прохождения проверок;
- канонические поля task-spec, acceptance и proof mapping, если они требуются коротким планом.

Для artifact prerequisites должны быть выполнены:

- файл artifact существует по `artifact_path`;
- файл readable в workspace;
- machine-readable строки `plan_revision` и `artifact_revision` в файле совпадают с issue metadata;
- artifact не содержит самостоятельных acceptance criteria, routing rules, proof semantics или checkpoint rules.

Для Linear attachment prerequisites:

- artifact должен быть загружен в Linear attachments до Spec Review handoff;
- допустимый title attachment: полный `artifact_path` (`docs/reports/let-718-swarm-artifact.md`) или filename (`let-718-swarm-artifact.md`);
- выбранная форма title должна совпадать с тем, что проверяет runtime/оператор в Linear.

Для stage prerequisites:

- `research -> plan -> execute` является наблюдаемым E2E coverage route для LET-718;
- workflow и stage skills владеют routing semantics;
- этот artifact только указывает, какие зависимости должны быть видимы при проверке маршрута.

## Interface Impacts

Эта секция описывает интерфейсные поверхности, которые E2E validation должна задействовать. Она не вводит новые интерфейсные правила.

Входы для `symphony_handoff_check` / runtime handoff:

- issue description с `plan_revision`, `artifact_path`, `artifact_revision`;
- labels, включая `mode:plan`;
- workspace path, из которого читается `artifact_path`;
- Linear attachments list с title по full path или filename;
- workpad с секцией `Execution Evidence`;
- current preflight attempt run token;
- expected run token source: `runtime_execution_attempt_token` для strict mode или `argument_fallback` только для compatibility mode;
- strict runtime token flag, если включена проверка `verification.execution_evidence.strict_runtime_token_required`;
- PR/runtime snapshot и validation inputs, требуемые каноническим handoff path.

Ожидаемый output interface:

- handoff manifest содержит mirrored `execution_evidence`;
- `execution_evidence.manifest_mirror_allowed=true` только при валидном `status=passed` и отсутствии blocking divergence;
- `missing_items` и `handoff_failure` отражают fail-closed причины при mismatch, missing artifact, missing attachment, stale token или invalid evidence;
- artifact остается secondary, а short plan остается canonical во всех manifest-adjacent интерпретациях.

Рекомендуемые supporting-only значения для `Execution Evidence.consumed_sections`:

- `Risk / Signal`;
- `Implementation Contour`;
- `Validation Contour`;
- `Rollback / Diagnostics`;
- `Residual Risks`.

Эти значения помогают показать, какие части artifact были прочитаны execution-stage agent. Они не являются acceptance criteria и не заменяют канонический proof mapping.

## Risk / Signal

Главный риск LET-718: E2E-проверка может выглядеть успешной на уровне текста плана, но не доказать runtime handoff contract. Поэтому сигнал должен включать не только наличие артефакта, но и поведение fail-closed в `symphony_handoff_check`.

Уже известные runtime-сигналы:

- blocked `Execution Evidence.status` блокирует review-ready handoff.
- partial status блокирует manifest mirror.
- unsupported status блокирует handoff.
- stale `run_token` блокирует handoff.
- missing current run token блокирует handoff.
- artifact/revision mismatch блокирует handoff.
- missing artifact file или missing Linear attachment блокируют handoff.
- strict runtime token mode требует источник `runtime_execution_attempt_token`, а не argument fallback.

Критический сигнал для E2E: успешный путь должен показать, что execute-stage agent перед реализацией потребляет только supporting sections artifact, сохраняет короткий план каноническим и записывает валидный `Execution Evidence`.

## Implementation Contour

Контур реализации для будущей execution-задачи должен оставаться минимальным и проверяемым:

1. Stage routing:
   - подтвердить наблюдаемое прохождение `research -> plan -> execute`;
   - не переносить routing rules в этот artifact;
   - фиксировать только точки, нужные для E2E validation.

2. Swarm-assisted two-layer planning:
   - подготовить короткий план в Linear как SSOT;
   - связать его с `docs/reports/let-718-swarm-artifact.md`;
   - держать `plan_revision` и `artifact_revision` равными `let-718-plan-r1`;
   - использовать artifact только для дополнительного анализа рисков, диагностики и реализации.

3. Execution preflight:
   - прочитать из Linear issue `plan_revision`, `artifact_path`, `artifact_revision`;
   - подтвердить совпадение revision pair;
   - подтвердить наличие artifact file и Linear attachment;
   - записать workpad-секцию `Execution Evidence`;
   - указать `status`, свежий `run_token`, `artifact_file`, `revision_pair`, `consumed_sections` и note о precedence;
   - для strict runtime token mode подтвердить источник `runtime_execution_attempt_token`.

4. Runtime handoff:
   - запускать `symphony_handoff_check` так, чтобы manifest отражал `execution_evidence`;
   - при strict runtime token mode принимать только `runtime_execution_attempt_token`;
   - считать любые divergence blocking до перехода в review-ready handoff.

## Validation Contour

Валидация LET-718 должна разделять prerequisites, positive proof path и fail-closed proof path. Эта секция не вводит acceptance semantics поверх канонического плана.

Prerequisite checks:

- short plan содержит machine-readable plan metadata;
- linked artifact существует в `docs/reports/`;
- Linear attachment title соответствует full `artifact_path` или filename;
- artifact revision lines совпадают с issue metadata;
- `research -> plan -> execute` подтвержден как наблюдаемая stage coverage chain.

Положительный путь:

- workpad содержит валидный `Execution Evidence`;
- `Execution Evidence.status=passed`;
- `Execution Evidence.run_token` совпадает с текущей попыткой;
- `Execution Evidence.artifact_file` совпадает с issue `artifact_path`;
- `revision_pair.plan_revision` и `revision_pair.artifact_revision` совпадают с issue metadata;
- `consumed_sections` содержит только supporting sections artifact;
- note явно фиксирует: artifact is secondary, short plan is canonical;
- handoff manifest содержит mirrored `execution_evidence`.

Негативные пути:

- missing или placeholder `plan_revision`;
- missing `artifact_path`;
- missing `artifact_revision`;
- `artifact_revision != plan_revision`;
- missing artifact file;
- unreadable artifact file;
- missing matching Linear attachment;
- `Execution Evidence.status=blocked`;
- `Execution Evidence.status=partial`;
- unsupported status;
- stale или missing current run token;
- mismatch `Execution Evidence.artifact_file`;
- mismatch revision pair;
- strict runtime token mode с fallback source вместо `runtime_execution_attempt_token`.

Локальный ориентир проверки: существующие тесты вокруг `HandoffCheck.evaluate/2` уже выражают основные fail-closed свойства. Для LET-718 новая проверка должна склеить их в E2E-сценарий маршрута, а не дублировать контракт вручную в artifact.

## Rollback / Diagnostics

Если E2E validation ломается, диагностику нужно вести по первому fail-closed divergence:

- issue metadata: проверить `plan_revision`, `artifact_path`, `artifact_revision`;
- artifact file: проверить наличие, readable path и revision lines;
- Linear attachment: проверить title match по full path или filename;
- workpad: проверить наличие `Execution Evidence` и все runtime-owned fields;
- run token: проверить свежесть current attempt token и источник token в strict mode;
- manifest: проверить `execution_evidence`, `missing_items`, `handoff_failure.kind`, hard/recoverable item split.

Rollback для планового слоя: вернуть короткий план в `provisional`/not review-ready состояние и регенерировать linked artifact с тем же revision pair. Artifact сам по себе не должен чинить scope, acceptance или checkpoint rules.

Rollback для execution слоя: остановить handoff, оставить задачу вне review-ready, обновить workpad с конкретным blocker и повторить preflight с новым runtime token.

## Residual Risks

- Linear attachment state может расходиться с локальным artifact file; это должно оставаться blocking divergence до ручного или runtime-подтвержденного исправления.
- E2E-сценарий может подтвердить handoff contract, но не доказать корректность всех возможных stage routing веток.
- Strict runtime token behavior зависит от корректной передачи `runtime_execution_attempt_token`; fallback допустим только как compatibility mode, не как целевой strict путь.
- Supporting artifact может устареть относительно короткого плана; при любом содержательном расхождении короткий план остается authoritative, а artifact должен быть regenerated или reset.
- Рекомендуемые `consumed_sections` помогают диагностике, но не должны превращаться в скрытые acceptance criteria.
