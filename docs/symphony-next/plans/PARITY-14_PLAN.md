# PARITY-14 Plan (Spec Prep)

## 1) Подтверждено по текущему коду и артефактам

- `github_pr_snapshot` уже вычисляет `has_actionable_feedback`, но как итоговый
  булев флаг без явной классификации decision-state для workflow.
- В `DynamicTool`:
  - review feedback учитывается только как `CHANGES_REQUESTED` (`review` канал);
  - top-level и inline комментарии проходят через эвристику
    `potentially_actionable_feedback?/1`;
  - итоговый snapshot не содержит явного поля класса
    (`changes_requested`/`actionable_comments`/`none`).
- В `ControllerFinalizer` и `HandoffCheck` workflow-решение сейчас завязано на
  `has_actionable_feedback == true/false`, а не на явную typed классификацию.
- Это оставляет риск semantic drift:
  - одна и та же review-ситуация может трактоваться по-разному при изменении
    эвристик;
  - оператор видит только булев результат без прозрачного state-контракта.

## 2) Выбранный MVP и почему

### MVP

Закрыть `PARITY-14` минимальным безопасным изменением:

1. Ввести явную классификацию review feedback state в snapshot:
   - `changes_requested`
   - `actionable_comments`
   - `none`
2. Добавить explicit summary по review states (`changes_requested`, `approved`,
   `commented`, `dismissed`, `pending`, `unknown`).
3. Привязать workflow-решения (`ControllerFinalizer`, `HandoffCheck`) к новому
   `actionable_feedback_state` (с fail-safe fallback на legacy bool при
   отсутствии поля).
4. Добавить deterministic matrix + live-sanitized fixture + dedicated parity
   suite.
5. Зафиксировать canonical contract и evidence.

### Почему это минимально достаточный путь

- Решает именно `PARITY-14`: явная классификация + привязка к workflow
  decisions.
- Не расширяет скоуп до `PARITY-06` merge semantics или runtime/cutover.
- Сохраняет обратную совместимость: legacy payload без нового поля остаётся
  поддержан через fallback.

## 3) Готовый engineering spec

## Проблема

Текущий replacement-контур GitHub review feedback опирается на булев
`has_actionable_feedback` без явного decision-state контракта. Это делает
review/handoff финализацию менее прозрачной и создаёт риск дрейфа semantics.

## Цель

Сделать review feedback classification явной, тестируемой и напрямую связанной с
workflow-решениями review/handoff.

## Скоуп

1. `DynamicTool.github_pr_snapshot`:
   - добавить `review_state_summary`;
   - добавить `actionable_feedback_state`;
   - добавить item-level classification в `actionable_feedback`.
2. `ControllerFinalizer`:
   - decision на fallback по review feedback переводится на
     `actionable_feedback_state` (с fallback на legacy bool).
3. `HandoffCheck`:
   - gating по feedback переводится на `actionable_feedback_state`
     (с fallback на legacy bool);
   - manifest содержит `actionable_feedback_state`.
4. Новый parity contract, deterministic fixture, live fixture generator, parity
   test suite, evidence doc.
5. Обновление backlog/progress-доков после merge.

## Вне скоупа

- Изменение merge-state allowlist/merge gating (`PARITY-06`).
- Runtime/cutover/shadow/rollback (`PARITY-07..13`, `PARITY-20`).
- Расширение tool surface beyond текущего snapshot/finalizer контура.

## Ограничения и инварианты

- Тикет не закрывается без executable evidence.
- При наличии `actionable_feedback_state` workflow использует его как source of
  truth.
- Legacy snapshot без `actionable_feedback_state` остаётся валидным через
  fallback на `has_actionable_feedback`.
- `unknown`-состояние классификации не может silently давать green decision.

## Риски

- Реальные PR review payload отличаются по форме/author metadata.
- Возможна неполная выборка live-сценариев (например, мало свежих
  `CHANGES_REQUESTED`).
- При некорректной миграции есть риск рассинхронизации между snapshot и
  workflow guard.

## Зависимости

- `GH_TOKEN` / `gh auth status`
- `LINEAR_API_KEY` (для issue/worklog обновлений)
- `make symphony-preflight`
- `make symphony-acceptance-preflight`
- `mix test` / `make all`

## План валидации

- Baseline:
  - есть bool-решение по feedback без typed decision-state.
- Delta:
  - явный `actionable_feedback_state`, `review_state_summary`,
    item-level classification;
  - workflow guards используют explicit state.
- Dataset:
  - deterministic parity matrix (state combinations);
  - live-sanitized PR samples из реальных GitHub review/comment traces.
- False-positive ceiling:
  - 0 случаев, где `actionable_feedback_state=none`, а workflow блокируется
    только из-за classification drift;
  - 0 случаев, где `changes_requested` трактуется как non-blocking.

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-14-AM-01` | Review содержит `CHANGES_REQUESTED` от actionable source | `actionable_feedback_state=changes_requested`, `has_actionable_feedback=true` | test | deterministic parity suite | surface_exists | review |
| `PARITY-14-AM-02` | Нет `CHANGES_REQUESTED`, но есть actionable root comments | `actionable_feedback_state=actionable_comments`, `has_actionable_feedback=true` | test | deterministic parity suite | surface_exists | review |
| `PARITY-14-AM-03` | Только non-actionable acknowledgements/bot noise/replies | `actionable_feedback_state=none`, `has_actionable_feedback=false` | test | deterministic parity suite | surface_exists | review |
| `PARITY-14-AM-04` | Mixed review states (approved/commented/dismissed/pending) | `review_state_summary` заполняется explicit counts | test | deterministic parity suite | surface_exists | review |
| `PARITY-14-AM-05` | `actionable_feedback_state=changes_requested` | `ControllerFinalizer` возвращает fallback `pull request has actionable feedback` | test | controller parity assertions | surface_exists | review |
| `PARITY-14-AM-06` | `actionable_feedback_state=none` | `HandoffCheck` не добавляет missing item по actionable feedback | test | handoff parity assertions | surface_exists | review |
| `PARITY-14-AM-07` | Legacy snapshot без нового поля state | workflow guard корректно работает через bool fallback | test | backward-compat parity assertions | surface_exists | review |
| `PARITY-14-AM-08` | Live PR samples с разными review/comment профилями | canonical classification mapping исполняется без `unknown` | artifact | live fixture + parity suite run | run_executed | review |
| `PARITY-14-AM-09` | Contract-doc consistency | все AM ids и decision markers синхронизированы с suite | test | contract parity assertions | surface_exists | review |
| `PARITY-14-AM-10` | End-to-end validation matrix | preflight + acceptance + targeted tests + repo validation green | test | validation commands log | run_executed | review |

## Proof Mapping (требование к execute handoff)

- Каждый `PARITY-14-AM-*` маппится на deterministic/live case IDs.
- Для `AM-08` обязательно:
  - команда генерации live fixture;
  - sampled repositories/PR summary;
  - SHA256 live fixture.
- Для workflow mapping (`AM-05..07`) фиксируются:
  - observed snapshot fields;
  - expected workflow decision;
  - assertion target (`ControllerFinalizer` / `HandoffCheck`).

## Alternatives considered

1. Оставить bool-only модель и добавить только документацию.
   - Отклонено: не закрывает explicit classification gap.
2. Перенести всё в `HandoffCheck`, не трогая `github_pr_snapshot`.
   - Отклонено: state остаётся неявным в источнике данных.
3. Полный refactor review parser в отдельный модуль.
   - Отклонено: избыточно для тикета, нарушает minimal delta.

## Заметки

- План intentionally fail-closed на уровне workflow interpretation.
- Message contract для fallback остается стабильным (`pull request has
  actionable feedback`) для совместимости с текущими сценариями/evidence.

## Symphony

- Ticket: `PARITY-14`
- Stream: `Stream 2`
- Mode: `Spec Prep -> In Progress`
- Required capabilities: `gh auth`, `LINEAR_API_KEY`,
  `make symphony-preflight`, `make symphony-acceptance-preflight`, `mix test`

## Critique Pass 1

### Замечания к черновику

1. Недостаточно явно был зафиксирован backward compatibility путь.
2. Не хватало проверки привязки к обоим workflow guard (`ControllerFinalizer` и
   `HandoffCheck`).
3. Не был явно описан live contour.

### Применённые правки

- Добавлен explicit invariant по legacy bool fallback.
- Добавлены `AM-05..07` для workflow-level tie-in.
- Добавлен `AM-08` с live-sanitized GitHub samples.

## Critique Pass 2

### Замечания после pass 1

1. Нужна stricter формулировка `unknown` policy.
2. Нужен явный false-positive ceiling.
3. Нужно зафиксировать, что fallback reason message не меняется.

### Применённые правки

- Добавлен инвариант про fail-closed обработку `unknown`.
- Добавлен false-positive ceiling в `План валидации`.
- Явно зафиксирована совместимость fallback reason в `Заметки`.
