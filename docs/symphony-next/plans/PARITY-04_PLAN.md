# PARITY-04 Plan (Spec Prep)

## 1) Подтверждено по текущему коду и артефактам

- В runtime есть `github_pr_snapshot` и `github_wait_for_checks`, и есть покрытие их output-семантики:
  - `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
  - `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- В `controller_finalizer` PR-контекст используется через checkpoint (`open_pr`), но отдельного явного контракта восстановления PR evidence из legacy источников нет:
  - `elixir/lib/symphony_elixir/controller_finalizer.ex`
  - `elixir/lib/symphony_elixir/resume_checkpoint.ex`
- В parity inventory зафиксирован риск `pr_from_linear_comment_workpad` и `Real PR discovery parity from all legacy evidence sources`.
- В workflow-политике формально перечислены сигналы переиспользования PR (branch, comments/attachments/workpad), но это зафиксировано как процессная инструкция, а не как единый executable contract.
- По live LET истории доступны реальные PR evidence traces в комментариях/attachments и `branchName` issue-поля; `workpad`-канал с PR URL в исторических комментариях встречается редко/нулевой в sampled выборке.

## 2) Выбранный MVP и почему

### MVP

Зафиксировать canonical PR evidence contract как explicit resolver + fixtures + parity suite:

1. Ввести typed resolver для PR evidence источников:
   - branch lookup,
   - issue comment,
   - workpad body,
   - workspace checkpoint.
2. Зафиксировать deterministic precedence и parse rules.
3. Добавить deterministic fixture с атомарными source-сценариями.
4. Добавить live-sanitized fixture из реальных LET traces (branch/comment/attachment evidence).
5. Добавить parity suite, который валидирует единый контракт восстановления `repo/pr_number/url/source`.

### Почему это минимально достаточный путь

- Закрывает именно `PARITY-04` (freeze contract), не расширяя review/finalizer semantics (`PARITY-05`, `PARITY-06`).
- Делает PR evidence recovery неявным и проверяемым через executable assertions.
- Позволяет покрыть workpad/workspace источники детерминированно даже при ограниченной live представленности.

## 3) Готовый engineering spec

## Проблема

PR discovery в replacement-контуре частично опирается на runtime/tool usage и process-инструкции, но не зафиксирован как единый явный executable контракт по источникам branch/comment/workpad/workspace. Это создаёт риск тихого drift при handoff/merge решениях.

## Цель

Сделать PR evidence recovery explicit и executable, чтобы извлечение `repo/pr_number/url/source` из replacement-критичных источников было детерминированным и проверяемым.

## Скоуп

1. Ввести canonical PR evidence resolver contract:
   - source types: `workspace_checkpoint`, `workpad`, `issue_comment`, `issue_attachment`, `branch_lookup`;
   - parse rules для PR URL и `PR #<n>` marker;
   - source precedence и fail-closed поведение.
2. Добавить deterministic matrix fixture по source-сценариям и edge cases.
3. Добавить live-sanitized fixture из LET traces (branch/comment/attachment).
4. Добавить parity suite, валидирующий contract output.
5. Собрать evidence doc с командами/hash/sample scope.

## Вне скоупа

- Изменение merge/readiness/finalizer decision policy (`PARITY-05`, `PARITY-06`).
- Изменение runtime continuation/recovery (`PARITY-07+`).
- Расширение GitHub adapter beyond PR evidence recovery.

## Ограничения и инварианты

- Ticket не закрывается без executable evidence.
- Контракт должен явно покрывать branch/comment/workpad/workspace источники.
- Live traces обязательно sanitized.
- Если evidence не извлекается, resolver должен fail closed (`source=none`, без guessed PR).
- `surface exists` и `run executed` фиксируются отдельно.

## Риски

- Live traces могут быть неравномерно распределены по источникам (особенно workpad).
- Нестабильный доступ к Linear API для генерации live fixture.
- Неполный parser может дать ложные positive на noisy text.

## Зависимости

- `LINEAR_API_KEY`.
- `make symphony-preflight`.
- `mix test`.
- `jq/curl` для live-sanitized fixture generation.

## План валидации

- Baseline:
  - `github_pr_snapshot`/finalizer тесты есть, но source-contract PR evidence recovery не выделен.
- Delta:
  - появляется explicit PR evidence resolver contract + matrix/live fixtures + parity suite.
- Dataset:
  - deterministic source matrix;
  - live LET issues с PR URL traces (comments/attachments) и `branchName`.
- False-positive ceiling:
  - 0 ambiguous source resolutions в matrix/live cases (нет guessed PR без валидного evidence).

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-04-AM-01` | Workspace checkpoint source | извлекаются repo/pr/url/source=`workspace_checkpoint` | test | deterministic parity suite | surface_exists | review |
| `PARITY-04-AM-02` | Workpad source | PR evidence извлекается из workpad body по contract parser | test | deterministic parity suite | surface_exists | review |
| `PARITY-04-AM-03` | Issue comment source | PR URL/marker извлекается из issue comments | test | deterministic parity suite | surface_exists | review |
| `PARITY-04-AM-04` | Issue attachment source | PR URL извлекается из issue attachments | test | deterministic parity suite | surface_exists | review |
| `PARITY-04-AM-05` | Branch lookup source | branch lookup возвращает deterministic PR evidence | test | deterministic parity suite | surface_exists | review |
| `PARITY-04-AM-06` | Source precedence case | при нескольких источниках используется зафиксированный precedence | test | deterministic parity suite | surface_exists | review |
| `PARITY-04-AM-07` | No-evidence fail-closed case | resolver не придумывает PR и возвращает explicit none | test | deterministic parity suite | surface_exists | review |
| `PARITY-04-AM-08` | Live-sanitized PR evidence traces | реальные LET traces проходят тот же contract runner | artifact | live fixture + parity suite run | run_executed | review |
| `PARITY-04-AM-09` | Contract doc vs executable suite consistency | контракт и assertions согласованы | test | explicit contract assertions | surface_exists | review |

## Proof Mapping (требование к execute handoff)

- Каждый `PARITY-04-AM-*` маппится на конкретный deterministic/live case.
- Для `AM-08` обязательно:
  - команда генерации live fixture,
  - sampled identifiers,
  - SHA256 fixture,
  - дата генерации.
- Для branch source фиксировать lookup input/output явно в case metadata.

## Alternatives considered

1. Ограничиться существующими `dynamic_tool_test`/`controller_finalizer_test`.
   - Отклонено: не фиксируют source-level PR evidence contract.
2. Сделать только doc без executable fixtures.
   - Отклонено: не устраняет drift risk.
3. Сразу объединить с `PARITY-05/06`.
   - Отклонено: расширение scope beyond minimal freeze task.

## Заметки

- Для `PARITY-04` используем opt-in TDD: сначала matrix/live assertions, потом минимальные корректировки реализации по результатам тестов.
- Если workpad source не представлен в live history, закрываем его deterministic contract coverage и фиксируем ограничение в evidence.

## Symphony

- Ticket: `PARITY-04`
- Stream: `Stream 2`
- Mode: `Spec Prep -> In Progress`
- Required capabilities: `LINEAR_API_KEY`, `make symphony-preflight`, `mix test`, live Linear read access

## Critique Pass 1

### Замечания к черновику

1. Не был явно зафиксирован fail-closed сценарий `no evidence`.
2. Недоставало отдельного precedence-case.
3. Не было явного покрытия attachment source.

### Применённые правки

- Добавлен `PARITY-04-AM-07` (fail-closed none).
- Добавлен `PARITY-04-AM-06` (source precedence).
- Добавлен `PARITY-04-AM-04` (attachment source).

## Critique Pass 2

### Замечания после pass 1

1. Нужно явно отделить deterministic source coverage от live evidence coverage.
2. Требовалась явная consistency проверка doc vs suite.

### Применённые правки

- `AM-01..07` оставлены в deterministic proof contour, `AM-08` вынесен в live artifact contour.
- Добавлен `PARITY-04-AM-09`.
