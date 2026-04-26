# PARITY-05 Plan (Spec Prep)

## 1) Подтверждено по текущему коду и артефактам

- Основная логика review/finalizer decision уже реализована в `ControllerFinalizer.run/3`:
  - wait checks -> snapshot -> pre-handoff proof gate -> handoff check -> state transition.
- В коде есть явные decision-ветки:
  - `pull request checks failed` -> `{:fallback, status=action_required}`
  - `pull request checks are still pending` -> `{:retry, status=waiting}`
  - `pull request has actionable feedback` -> `{:fallback, status=action_required}`
  - `symphony_handoff_check failed` -> `{:fallback, status=action_required}`
  - успешный путь -> `{:ok, status=succeeded}` + переход issue в `In Review`.
- Покрытие unit-тестами широкое (`controller_finalizer_test.exs`), но отсутствует отдельный canonical parity contract для `PARITY-05`:
  - нет единой deterministic/live matrix фиксации old finalizer решений;
  - нет выделенного parity-suite уровня тикета с явным Acceptance Matrix mapping.
- `github_pr_snapshot` normalizer уже покрывает actionable feedback semantics в `dynamic_tool_test.exs`, но это tool-level доказательство, не ticket-level parity contract.

## 2) Выбранный MVP и почему

### MVP

Зафиксировать `PARITY-05` как отдельный executable contract поверх существующей реализации:

1. Ввести canonical finalizer semantics contract (decision table).
2. Добавить deterministic matrix fixture по ключевым веткам finalizer (`ok/retry/fallback/not_applicable` + blocked replay guard).
3. Добавить live-sanitized fixture на исторических LET traces с финализаторными сигналами.
4. Добавить parity suite, который прогоняет одну и ту же decision-модель на deterministic и live cases.
5. При обнаружении semantic drift исправить минимально локально в runtime.

### Почему это минимально достаточный путь

- Закрывает именно `PARITY-05` (review/finalizer semantics), не заходя в полный merge-gating (`PARITY-06`).
- Использует уже существующий runtime и тестовые паттерны, добавляя только отсутствующий parity contract слой.
- Даёт executable proof вместо «рассыпанных» unit-тестов без единой acceptance-модели тикета.

## 3) Готовый engineering spec

## Проблема

Review/finalizer поведение в Next реализовано и частично покрыто тестами, но не зафиксировано как единый replacement-scope parity contract. Без этого subtle regressions в review/handoff/merge-подготовке могут пройти незамеченными.

## Цель

Сделать old finalizer decisions explicit и executable: decision-семантика должна быть формализована, fixture-backed и проверяться единым parity runner.

## Скоуп

1. Канонический контракт finalizer semantics:
   - входные сигналы (`wait_result`, `snapshot`, `handoff_manifest`, proof gate, state transition),
   - ожидаемые outcome-классы (`ok`, `retry`, `fallback`, `not_applicable`),
   - обязательные checkpoint-поля (`controller_finalizer.status/reason/blocked_*`).
2. Deterministic matrix fixture по replacement-критичным решениям.
3. Live-sanitized fixture из реальных LET traces с finalizer/review сигналами.
4. Отдельный `PARITY-05` parity suite + evidence doc.
5. Минимальные runtime-корректировки только при обнаруженном drift.

## Вне скоупа

- Полный merge gating and stale-proof policy (`PARITY-06`).
- Расширение actionable feedback classifier beyond текущего contract scope (`PARITY-14`).
- Изменение cutover/runtime orchestration вне finalizer decision surface.

## Ограничения и инварианты

- Тикет не закрывается без executable evidence.
- `PARITY-05` фиксирует decision semantics, а не только tool output.
- Для live fixture использовать только sanitized traces (без сырого операторского текста).
- Fail-closed поведение должно сохраняться для error/ambiguous paths.

## Риски

- Исторические traces могут быть неполными по отдельным веткам outcome.
- Возможна разница между tool-level snapshot данными и checkpoint-level finalizer state.
- Drift может быть «тихим» в полях `blocked_head/blocked_pr_number`.

## Зависимости

- `LINEAR_API_KEY` (live traces).
- `make symphony-preflight`.
- `make symphony-acceptance-preflight`.
- `mix test`.

## План валидации

- Baseline:
  - есть множество unit tests в `controller_finalizer_test.exs`, но нет ticket-level matrix contract.
- Delta:
  - появляется canonical decision matrix + live fixture + отдельный parity suite.
- Dataset:
  - deterministic matrix веток finalizer;
  - live LET traces с сигналами review/finalizer.
- False-positive ceiling:
  - 0 ambiguous classification в parity matrix runner.

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-05-AM-01` | Checks failed | `fallback` + `controller_finalizer.status=action_required` + reason=`pull request checks failed` | test | deterministic parity suite | surface_exists | review |
| `PARITY-05-AM-02` | Checks pending in snapshot | `retry` + status=`waiting` + reason=`pull request checks are still pending` | test | deterministic parity suite | surface_exists | review |
| `PARITY-05-AM-03` | Actionable feedback | `fallback` + status=`action_required` + reason=`pull request has actionable feedback` | test | deterministic parity suite | surface_exists | review |
| `PARITY-05-AM-04` | Handoff manifest failed | `fallback` + reason=`symphony_handoff_check failed` | test | deterministic parity suite | surface_exists | review |
| `PARITY-05-AM-05` | Success path | `ok` + status=`succeeded` + issue transition to review-ready state | test | deterministic parity suite | surface_exists | review |
| `PARITY-05-AM-06` | State transition failure | `retry` + status=`waiting` + reason=`failed to transition issue state` | test | deterministic parity suite | surface_exists | review |
| `PARITY-05-AM-07` | Proof gate missing | fail-fast `fallback` before handoff with proof diagnostic | test | deterministic parity suite | surface_exists | review |
| `PARITY-05-AM-08` | Blocked replay guard | `eligible?/2=false` for same blocked head/fingerprint | test | deterministic parity suite | surface_exists | review |
| `PARITY-05-AM-09` | Live historical finalizer traces | реальные sanitized traces проходят тот же decision contract runner | artifact | live fixture + parity suite run | run_executed | review |
| `PARITY-05-AM-10` | Contract-doc consistency | doc decision table и assertions совпадают | test | contract parity assertions | surface_exists | review |

## Proof Mapping (требование к execute handoff)

- Каждый `PARITY-05-AM-*` маппится на один или более deterministic/live case IDs.
- Для `AM-09` обязательно:
  - команда генерации live fixture,
  - sampled identifiers/outcomes,
  - SHA256 fixture.
- Для outcome-case фиксировать и expected outcome type, и checkpoint fields (`status`, `reason`, `blocked_*` где применимо).

## Alternatives considered

1. Ограничиться существующими `controller_finalizer_test.exs`.
   - Отклонено: нет явного ticket-level parity contract.
2. Сразу объединить `PARITY-05` и `PARITY-06`.
   - Отклонено: увеличивает scope и затягивает replacement-critical контроль.
3. Делать только deterministic coverage без live traces.
   - Отклонено: слабее replacement-proof для historical behavior.

## Заметки

- Execute-фаза должна идти в стиле minimal safe delta: сначала fixtures/parity suite, затем локальные runtime-правки только если выявлен drift.
- При недостатке live coverage по отдельным веткам фиксировать это явно в evidence и не помечать тикет `done` без закрытия replacement-critical веток.

## Symphony

- Ticket: `PARITY-05`
- Stream: `Stream 2`
- Mode: `Spec Prep -> In Progress`
- Required capabilities: `LINEAR_API_KEY`, `make symphony-preflight`, `make symphony-acceptance-preflight`, `mix test`

## Critique Pass 1

### Замечания к черновику

1. Не был явно отделён decision-level contract от tool-level snapshot assertions.
2. Не хватало blocked replay guard как отдельного acceptance-item.
3. Не было явного требования по checkpoint field parity.

### Применённые правки

- Добавлен focus на decision-level semantics (`ok/retry/fallback/not_applicable`).
- Добавлен `PARITY-05-AM-08` для replay guard.
- В `Proof Mapping` добавлено требование фиксировать `status/reason/blocked_*`.

## Critique Pass 2

### Замечания после pass 1

1. Нужно явно зафиксировать live contour отдельно от deterministic.
2. Требовалось ограничить scope от `PARITY-06` и `PARITY-14`.
3. Нужна явная consistency проверка doc vs suite.

### Применённые правки

- `AM-01..08` оставлены deterministic, `AM-09` выделен как live artifact contour.
- Явно добавлены `Вне скоупа` для `PARITY-06`/`PARITY-14`.
- Добавлен `AM-10` (contract-doc consistency).
