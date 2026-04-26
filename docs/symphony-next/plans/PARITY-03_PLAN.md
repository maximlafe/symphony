# PARITY-03 Plan (Spec Prep)

## 1) Подтверждено по текущему коду и артефактам

- Канонический checkpoint-контракт уже централизован в `ResumeCheckpoint`:
  - capture/load/normalize/readiness: `elixir/lib/symphony_elixir/resume_checkpoint.ex`
  - telemetry-derive для `resume_mode` / `resume_fallback_reason`: `elixir/lib/symphony_elixir/telemetry_schema.ex`
  - merge логика provided+loaded checkpoint в retry path: `elixir/lib/symphony_elixir/orchestrator.ex` (`resolve_resume_checkpoint/2`, `merge_loaded_resume_checkpoint/2`).
- Есть покрытие unit/regression по checkpoint-нормализации и retry semantics:
  - `elixir/test/symphony_elixir/resume_checkpoint_test.exs`
  - `elixir/test/symphony_elixir/core_test.exs`
  - `elixir/test/symphony_elixir/telemetry_schema_test.exs`
- В replacement backlog отсутствует отдельный executable parity-контракт, который валидирует совместимость **legacy resume traces** на реальных старых Linear следах (`PARITY-03` пока `todo`).
- По live LET traces подтверждены реальные historical сигналы resume/fallback:
  - `LET-559`: явный `resume_mode=fallback_reread` + причина через отсутствие `workpad_ref`/`workpad_digest`;
  - `LET-537`: явный контракт `resume_mode`/`resume_fallback_reason` как production evidence;
  - `LET-474`: мониторинговые комментарии с `resume_mode=resume_checkpoint|fallback_reread`.
- Риск подтверждён: без отдельной parity-проверки legacy traces можно формально иметь checkpoint API, но оставить "ambiguous recovery" в replacement-scope runtime доказательствах.

## 2) Выбранный MVP и почему

### MVP

Зафиксировать `PARITY-03` как контракт + fixtures + executable parity suite:

1. Документ-контракт совместимости legacy resume traces.
2. Deterministic matrix fixture с legacy-shape checkpoint сценариями (ready/fallback/mismatch/unavailable).
3. Live-sanitized fixture из реальных LET comments с `resume_mode` сигналами.
4. Parity suite, который на обоих fixture-наборах прогоняет `ResumeCheckpoint.for_prompt/1` и проверяет отсутствие ambiguous recovery:
   - `resume_mode` всегда явный (`resume_checkpoint` или `fallback_reread`);
   - для fallback всегда машинно-читаемый `resume_fallback_reason`.
5. Evidence doc с командами, артефактами и hash.

### Почему это минимально достаточный путь

- Закрывает ровно `PARITY-03` (legacy resume compatibility), не захватывая `PARITY-07+` (широкий runtime recovery).
- Использует существующий runtime-контракт (`ResumeCheckpoint` + `TelemetrySchema`) без расширения orchestration surface.
- Даёт executable proof на реальных historical traces, а не только synthetic тесты.

## 3) Готовый engineering spec

## Проблема

`Symphony-next` умеет читать/нормализовать resume checkpoint, но для replacement-критичного требования `PARITY-03` нет отдельного доказательства, что legacy resume traces из реальной истории Linear всегда приводят к однозначному recover decision без неоднозначности.

## Цель

Доказать совместимость `Symphony-next` с legacy resume traces так, чтобы resume/fallback decision был детерминирован и machine-readable для реальных старых issue traces.

## Скоуп

1. Зафиксировать canonical legacy resume compatibility contract:
   - входные legacy checkpoint/traces формы;
   - правила нормализации;
   - правила derive `resume_mode` и `resume_fallback_reason`;
   - критерий "no ambiguous recovery".
2. Добавить deterministic fixture по legacy checkpoint формам.
3. Добавить live-sanitized fixture из real LET comments с `resume_mode` сигналами.
4. Добавить parity test suite для matrix + live fixture.
5. Добавить evidence doc (`commands`, `hash`, sampled scope).

## Вне скоупа

- Изменение scheduler/recovery engine (Stream 3: `PARITY-07`, `PARITY-09`).
- Изменение GitHub/finalizer semantics (`PARITY-04..06`, `PARITY-14`).
- Cutover/rollback proof (`PARITY-11..13`).

## Ограничения и инварианты

- Ticket не закрывается без executable evidence.
- Live fixture обязан быть из реальных LET traces, с sanitize.
- `resume_mode` должен быть только `resume_checkpoint` или `fallback_reread`.
- Для `fallback_reread` `resume_fallback_reason` обязателен и machine-readable.
- `surface exists` и `run executed` не смешивать в acceptance mapping.

## Риски

- Нестабильный Linear transport (`SSL_ERROR_SYSCALL`) при live fixture generation.
- Historical comments могут иметь неструктурированные формулировки fallback причины.
- Риск ложной уверенности при слишком узком live sample.

## Зависимости

- `LINEAR_API_KEY`, доступ к LET historical traces.
- `make symphony-preflight`.
- Elixir test runtime (`mix test`) и tooling (`jq`, `curl`, sanitize step).

## План валидации

- Baseline:
  - существуют unit/regression тесты checkpoint/telemetry, но нет отдельного PARITY-03 suite по live legacy traces.
- Delta:
  - появляется `PARITY-03` контракт + deterministic/live fixtures + parity suite.
  - live historical traces проходят те же no-ambiguity checks, что deterministic cases.
- Dataset:
  - deterministic legacy matrix fixture;
  - live LET comments с `resume_mode` сигналом (`resume_checkpoint`/`fallback_reread`), sanitized.
- False-positive ceiling:
  - 0 кейсов с ambiguous recovery (`resume_mode` nil/unknown, fallback без причины) в sampled replacement-scope traces.

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-03-AM-01` | Legacy ready checkpoint shape | нормализация даёт `resume_mode=resume_checkpoint`, `resume_fallback_reason=nil` | test | PARITY-03 deterministic suite | surface_exists | review |
| `PARITY-03-AM-02` | Legacy sparse checkpoint (missing required fields) | явный `fallback_reread` + `checkpoint_missing_required_field` | test | PARITY-03 deterministic suite | surface_exists | review |
| `PARITY-03-AM-03` | Legacy mismatch reason string | явный `fallback_reread` + `checkpoint_mismatch` | test | PARITY-03 deterministic suite | surface_exists | review |
| `PARITY-03-AM-04` | Legacy unavailable checkpoint signal | явный `fallback_reread` + `resume_checkpoint_unavailable` | test | PARITY-03 deterministic suite | surface_exists | review |
| `PARITY-03-AM-05` | Live-sanitized traces with `resume_mode=resume_checkpoint` | no ambiguity: explicit mode + no fallback reason | artifact | PARITY-03 live fixture + suite run | run_executed | review |
| `PARITY-03-AM-06` | Live-sanitized traces with `resume_mode=fallback_reread` | no ambiguity: explicit mode + machine-readable fallback reason | artifact | PARITY-03 live fixture + suite run | run_executed | review |
| `PARITY-03-AM-07` | Retry metadata handoff from normalized checkpoint | runtime payload сохраняет explicit `resume_mode`/`resume_fallback_reason` | test | deterministic suite assertions on for_prompt payload | surface_exists | review |
| `PARITY-03-AM-08` | Contract doc vs executable suite consistency | документ и assert-набор не противоречат | test | explicit contract assertions | surface_exists | review |

## Proof Mapping (требование к execute handoff)

- Каждый `PARITY-03-AM-*` должен маппиться на конкретный assert или artifact case.
- Для live доказательства (`AM-05`, `AM-06`) обязательно приложить:
  - команду генерации live fixture;
  - sampled issue identifiers (sanitized references);
  - SHA256 fixture;
  - дату/время генерации.
- No-ambiguity проверка должна быть отдельной явной проверкой (не "по умолчанию зелёно").

## Alternatives considered

1. Ограничиться существующими `core_test`/`resume_checkpoint_test`.
   - Отклонено: нет replacement-scope parity-proof на real legacy traces.
2. Делать `PARITY-03` только через ручной лог-аудит без fixtures.
   - Отклонено: не воспроизводимо, не executable.
3. Одновременно расширять runtime continuation/recovery логику.
   - Отклонено: это уже scope `PARITY-07/09`, не минимальный change set для `PARITY-03`.

## Заметки

- Для `PARITY-03` выбираем opt-in TDD: сначала contract fixtures + parity assertions, потом минимальные кодовые правки только если выявится drift.
- При сетевой нестабильности Linear фиксировать capability-риск и retry path в evidence.

## Symphony

- Ticket: `PARITY-03`
- Stream: `Stream 1`
- Mode: `Spec Prep -> In Progress`
- Required capabilities: `LINEAR_API_KEY`, `make symphony-preflight`, `mix test`, live Linear read access

## Critique Pass 1

### Замечания к черновику

1. No-ambiguity criterion был описан слишком общо.
2. Не был выделен отдельный сценарий для machine-readable fallback reason.
3. Не было явной привязки live evidence к historical `resume_mode` traces.

### Применённые правки

- Добавлен явный инвариант `fallback_reread` => обязательный `resume_fallback_reason`.
- В Acceptance Matrix добавлены отдельные `AM-05` и `AM-06`.
- В validation dataset явно зафиксированы historical LET comments с `resume_mode`.

## Critique Pass 2

### Замечания после pass 1

1. Нужно отделить "контракт существует" от "run реально выполнен".
2. Требовалась явная проверка consistency doc vs suite.

### Применённые правки

- Уточнены `proof_semantic` (`surface_exists` vs `run_executed`).
- Добавлен `PARITY-03-AM-08` с обязательной consistency-проверкой.
