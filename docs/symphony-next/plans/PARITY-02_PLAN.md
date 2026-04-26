# PARITY-02 Plan (Spec Prep)

## 1) Подтверждено по текущему коду и артефактам

- Трассы в Linear уже пишутся через явные инструменты и runtime-пайплайн:
  - `sync_workpad` (создание/обновление комментария) — `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
  - `linear_upload_issue_attachment` (загрузка + `attachmentCreate`) — `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
  - `symphony_handoff_check` (манифест handoff + fail-closed semantics) — `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`, `elixir/lib/symphony_elixir/controller_finalizer.ex`
- Есть unit/regression покрытие tool-level поведения (`dynamic_tool_test.exs`), но нет отдельного replacement-scope parity-контракта, который фиксирует **формат и минимальные инварианты реальных issue traces** для:
  - workpad comments,
  - attachments/artifacts,
  - handoff decision traces,
  - handoff/milestone evidence.
- По live LET данным подтверждена реальная trace-поверхность:
  - Workpad traces (`Codex Workpad` / `Рабочий журнал Codex`) встречаются в старых реальных issues (например `LET-482`, `LET-483`, `LET-530`).
  - Handoff decision traces (`selected_action`, `checkpoint_type`, `stop_with_classified_handoff`) встречаются в production-like issues (например `LET-518`, `LET-577`, `LET-598`, `LET-617`, `LET-633`).
  - Attachments с evidence/proof и PR-контекстом присутствуют в тех же issue traces.
- Code-grounding риск подтверждён: часть комментариев Linear содержит raw control-bytes; без sanitize-пайплайна JSON-парсинг live-среза падает (`jq parse error`).

## 2) Выбранный MVP и почему

### MVP

Зафиксировать canonical issue trace contract как "контракт + deterministic fixture + live-sanitized fixture + parity tests":

1. Документ-контракт с обязательными trace-каналами и их инвариантами.
2. Deterministic fixture с атомарными сценариями каналов:
   - workpad comment trace,
   - artifact attachment trace,
   - handoff decision trace,
   - handoff milestone trace.
3. Live-sanitized fixture из реальных LET issues (allowlist filters: `Codex Workpad` и `selected_action`).
4. Исполняемый parity-suite, который валидирует единые инварианты для deterministic и live fixture.
5. Evidence-пакет (commands, hashes, sampled scope, blocker notes).

### Почему это минимально достаточный путь

- Закрывает именно `PARITY-02` (trace contract freeze), не влезая в `PARITY-04+` (PR semantics/finalizer parity).
- Даёт executable evidence против реальных старых traces, а не только synthetic assertions.
- Сохраняет малый blast radius: новая контрактная документация + fixtures + parity tests + генератор.

## 3) Готовый engineering spec

## Проблема

В `Symphony-next` есть рабочие механизмы записи комментариев/вложений/handoff-сигналов, но нет единого replacement-scope контракта issue traces. Из-за этого можно получить функционально "зелёный" flow, который оставляет в Linear трассы, неэквивалентные операторским ожиданиям старого Symphony.

## Цель

Сделать issue trace contract явным и исполняемым, чтобы comment/workpad/artifact/handoff trace semantics были формально зафиксированы и проверены на реальных старых LET issues.

## Скоуп

1. Зафиксировать canonical issue trace contract:
   - workpad comment trace,
   - artifact attachment trace,
   - handoff decision trace,
   - handoff milestone/evidence trace,
   - минимальные timing/order инварианты для trace-событий.
2. Добавить deterministic fixture с атомарными trace-сценариями.
3. Добавить live-sanitized fixture из реальных LET issues:
   - срез workpad traces (`comments contains "Codex Workpad"`),
   - срез handoff traces (`comments contains "selected_action"`).
4. Добавить parity test suite, который валидирует contract-инварианты для обоих fixture-наборов.
5. Добавить evidence doc с path/hash/commands/run results.

## Вне скоупа

- Изменение PR discovery/merge/finalizer decision policy (`PARITY-04`, `PARITY-05`, `PARITY-06`).
- Изменение runtime continuation/recovery semantics (`PARITY-07+`).
- Редизайн текстов комментариев в проде сверх фиксируемого replacement-scope сигнала.

## Ограничения и инварианты

- Ticket не закрывается без executable evidence.
- Live proof должен опираться на реальные LET issues; synthetic-only недостаточно.
- Sanitization обязателен: нельзя публиковать чувствительные данные из live traces.
- `surface exists` и `run executed` в acceptance mapping не смешивать.
- Если live Linear недоступен/нестабилен, статус только `Blocked` с точным unblock action.

## Риски

- Нестабильный транспорт к Linear API (TLS/connection reset) может сорвать reproducible live fixture generation.
- Raw control bytes в comment body могут ломать JSON-парсинг без sanitize шага.
- Недостаточный live sample может создать ложное ощущение parity coverage.

## Зависимости

- `LINEAR_API_KEY` + доступ к LET team scope.
- `make symphony-preflight`.
- Тестовый runtime Elixir (`mix test`) и JSON tooling (`jq`, `perl`/эквивалент sanitize).

## План валидации

- Baseline:
  - существуют tool-level тесты для `sync_workpad`, `linear_upload_issue_attachment`, `symphony_handoff_check`, но нет отдельного PARITY-02 trace parity suite.
- Delta:
  - появляется отдельный PARITY-02 contract + deterministic/live fixtures + parity tests.
  - live-sanitized traces проходят те же инварианты, что deterministic cases.
- Dataset:
  - deterministic matrix fixture;
  - live LET workpad-filter fixture (`Codex Workpad`);
  - live LET handoff-filter fixture (`selected_action`).
- False-positive ceiling:
  - 0 допустимых ambiguous/missing contract signals в replacement-scope cases, вошедших в fixture.

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-02-AM-01` | Workpad comment trace case | фиксируются минимальные поля trace (`channel`, `created_at`, `author`, `workpad_signal`) | test | PARITY-02 deterministic parity suite | surface_exists | review |
| `PARITY-02-AM-02` | Artifact attachment trace case | attachment trace содержит обязательные contract-поля (`title`, `url`/ref, `created_at`) | test | PARITY-02 deterministic parity suite | surface_exists | review |
| `PARITY-02-AM-03` | Handoff decision trace case | `selected_action` + `checkpoint_type` извлекаются и валидируются как handoff signal | test | PARITY-02 deterministic parity suite | surface_exists | review |
| `PARITY-02-AM-04` | Handoff milestone/evidence trace case | milestone/handoff evidence trace соответствует зафиксированному каналу контракта | test | PARITY-02 deterministic parity suite | surface_exists | review |
| `PARITY-02-AM-05` | Timing/order invariant case | все trace events имеют parseable `created_at`, достаточный для детерминированной реконструкции хронологии | test | PARITY-02 deterministic parity suite | surface_exists | review |
| `PARITY-02-AM-06` | Live-sanitized workpad-trace issues | реальные старые LET traces проходят те же workpad/artifact contract checks | artifact | live-sanitized fixture + parity suite run | run_executed | review |
| `PARITY-02-AM-07` | Live-sanitized handoff-trace issues | реальные старые LET traces проходят handoff decision/milestone contract checks | artifact | live-sanitized fixture + parity suite run | run_executed | review |
| `PARITY-02-AM-08` | Contract-doc vs suite consistency | документ контракта и executable assertions не противоречат | test | explicit contract assertions in suite | surface_exists | review |

## Proof Mapping (требование к execute handoff)

- Каждый `PARITY-02-AM-*` маппится на конкретный test/assertion или live artifact.
- Для `AM-06/AM-07` обязательно приложить:
  - команду генерации live fixture,
  - sampled identifiers (sanitized reference),
  - SHA256 fixture,
  - дату генерации.
- Для live доказательства обязателен явный sanitize pipeline (включая обработку control chars).

## Alternatives considered

1. Ограничиться только doc-контрактом без live fixtures.
   - Отклонено: нет executable parity against real issues.
2. Сразу менять runtime comment formatting для "идеального" единого шаблона.
   - Отклонено: расширение скоупа и риск регрессий, не нужен для freeze-контракта.
3. Проверять только handoff traces без workpad/attachments.
   - Отклонено: тикет требует полный trace contract (comment/workpad/artifact/handoff).

## Заметки

- Для `PARITY-02` выбираем opt-in TDD: сначала fixtures + parity tests, затем минимальные правки только при обнаружении contract drift.
- Если live query нестабилен, в evidence фиксировать точные transport errors и применённый retry/sanitize path.

## Symphony

- Ticket: `PARITY-02`
- Stream: `Stream 1`
- Mode: `Spec Prep -> In Progress`
- Required capabilities: `LINEAR_API_KEY`, `make symphony-preflight`, `mix test`, live Linear read access

## Critique Pass 1

### Замечания к черновику

1. Недостаточно явно разделены workpad traces и handoff traces в live dataset.
2. Не был закреплён технический инвариант sanitize для control-bytes.
3. Не хватало явного timing/order сценария в Acceptance Matrix.

### Применённые правки

- Добавлены два раздельных live-среза (`Codex Workpad`, `selected_action`) в scope/validation.
- Sanitize pipeline вынесен в инварианты и proof mapping как обязательный.
- Добавлен `PARITY-02-AM-05` (timing/order invariant).

## Critique Pass 2

### Замечания после pass 1

1. Нужно жёстче зафиксировать, что live proof обязателен до `In Review`.
2. Не хватало отдельного пункта на consistency doc vs executable suite.

### Применённые правки

- Для `AM-06` и `AM-07` закреплён `required_before=review`.
- Добавлен `PARITY-02-AM-08` и explicit consistency check в proof mapping.
