# PARITY-01 Plan (Spec Prep)

## 1) Подтверждено по текущему коду и артефактам

- Текущее routing-поведение разбросано по нескольким слоям:
  - polling scope и state-настройки: `elixir/lib/symphony_elixir/config.ex`, `elixir/lib/symphony_elixir/config/schema.ex`
  - нормализация Linear issue + assignee filter + team/project query: `elixir/lib/symphony_elixir/linear/client.ex`
  - финальное решение "брать в dispatch / не брать": `elixir/lib/symphony_elixir/orchestrator.ex`
- В `let.WORKFLOW.md` для LET зафиксированы replacement-scope состояния:
  - `Todo`, `Spec Prep`, `In Progress`, `Merging`, `Rework`
  - manual intervention: `Blocked`
  - terminal: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`
- Уже есть точечные тесты на team-scope и assignee matching, но нет единого fixture-backed routing matrix, который однозначно закрывает replacement-scope комбинации.

## 2) Выбранный MVP и почему

### MVP

Зафиксировать canonical Linear routing contract как "контракт + исполняемая матрица + live-sanitized fixture":

1. Документ-контракт с deterministic routing rules.
2. Fixture-набор replacement-scope кейсов (включая sanitized live issues).
3. Тестовый раннер матрицы, который валидирует route-intent и dispatch eligibility.
4. Evidence-пакет с путями/хешами для live-sanitized среза.

### Почему это минимально достаточный путь

- Закрывает главный риск `PARITY-01`: исчезновение `unknown` из routing semantics.
- Не требует переписывать runtime.
- Даёт воспроизводимый baseline для следующих тикетов Stream 1 и Stream 2.

## 3) Готовый engineering spec

## Проблема

Routing-контракт между Linear polling и фактическим dispatch в оркестраторе не зафиксирован как единый executable источник правды. Из-за этого возможна "бумажная" паритетность без доказательства на replacement-scope комбинациях (team/project/assignee/state/blockers/labels).

## Цель

Сделать routing-контракт явным и исполняемым так, чтобы для replacement-scope нельзя было оставить неучтённые ветки (`unknown`) в route-intent.

## Скоуп

1. Ввести canonical routing contract для LET scope:
   - polling scope (project/team),
   - assignee matching,
   - active/manual/terminal state semantics,
   - todo+blockers gate,
   - label behavior (что влияет и что не влияет на dispatch).
2. Добавить fixture-backed routing matrix.
3. Добавить live-sanitized fixture из реальных Linear issues (allowlisted scope, без чувствительных данных).
4. Добавить автоматическую проверку matrix + fixture.
5. Добавить evidence summary для `PARITY-01`.

## Вне скоупа

- Изменение runtime scheduler logic сверх нужного для явной фиксации текущего контракта.
- Изменение GitHub/handoff/finalizer semantics (`PARITY-04+`).
- Изменение continuation/recovery semantics (`PARITY-07+`).

## Ограничения и инварианты

- Нельзя ослаблять существующие capability/safety boundaries.
- Нельзя закрывать тикет без executable evidence.
- Live-sanitized fixture должен происходить из реального Linear scope и быть воспроизводимым.
- Нельзя заменять live доказательство synthetic-only тестом.

## Риски

- Drift между WORKFLOW/config и matrix.
- Неполные live-sanitized кейсы (coverage illusion).
- Неверная интерпретация blockers для `Todo`.

## Зависимости

- Рабочий `LINEAR_API_KEY`.
- `make symphony-preflight` зелёный.
- Доступ к LET team scope для live-sanitized выборки.

## План валидации

- Baseline:
  - текущие routing-тесты проходят.
- Delta:
  - появляется единый routing matrix test suite.
  - replacement-scope cases покрыты явными матричными кейсами.
  - live-sanitized fixture верифицируется тем же раннером.
- False-positive ceiling:
  - 0 допускаемых "unknown/ambiguous" для replacement-scope matrix-кейсов.

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-01-AM-01` | Team scope + active state + routable assignee | issue попадает в candidate set и eligible к dispatch | test | routing matrix suite | route_intent | review |
| `PARITY-01-AM-02` | Active state + non-routable assignee | issue исключается из dispatch | test | routing matrix suite | route_intent | review |
| `PARITY-01-AM-03` | `Todo` с non-terminal blocker | issue не dispatch-ится | test | routing matrix suite | route_intent | review |
| `PARITY-01-AM-04` | Terminal state | running issue снимается/не dispatch-ится | test | routing matrix suite | route_intent | review |
| `PARITY-01-AM-05` | Manual intervention state (`Blocked`) | issue не dispatch-ится как active work | test | routing matrix suite | route_intent | review |
| `PARITY-01-AM-06` | Replacement-scope state matrix (`Todo`, `Spec Prep`, `In Progress`, `Merging`, `Rework`) | deterministic eligibility по контракту | test | routing matrix suite | route_intent | review |
| `PARITY-01-AM-07` | Sanitized live issues from LET scope | все кейсы проходят через ту же матрицу без ambiguity | artifact | live-sanitized fixture + evidence summary | run_executed | review |
| `PARITY-01-AM-08` | Contract doc vs executable matrix consistency | контракт и тестовые ожидания не противоречат | test | contract consistency assertions | surface_exists | review |

## Proof Mapping (требование к execute handoff)

- Каждый `PARITY-01-AM-*` должен быть связан минимум с одним конкретным тестом/артефактом.
- Для `PARITY-01-AM-07` обязательно приложить:
  - путь до live-sanitized fixture,
  - команду формирования,
  - hash/дата.
- `surface exists` и `run executed` не смешивать в один пункт.

## Alternatives considered

1. Только документ без тестовой матрицы.
   - Отклонено: не даёт executable proof.
2. Только тесты без явного контракта.
   - Отклонено: не устраняет ambiguity для операторов и review.
3. Генерировать matrix исключительно из runtime логов.
   - Отклонено: сложно стабилизировать как deterministic regression suite.

## Заметки

- Для `PARITY-01` выбираем opt-in TDD: сначала matrix tests/fixtures, потом минимальные правки, если найдётся drift.
- Если live Linear недоступен, тикет не закрывается: статус только `Blocked` с точным unblock action.

## Symphony

- Ticket: `PARITY-01`
- Stream: `Stream 1`
- Mode: `Spec Prep -> In Progress`
- Required capabilities: `LINEAR_API_KEY`, `make symphony-preflight`, test runtime

## Critique Pass 1

### Замечания к черновику

1. Недостаточно явно разделены rules уровня polling и rules уровня dispatch.
2. Не задана явная проверка на drift между doc-контрактом и test matrix.
3. Не зафиксирован false-positive ceiling.

### Применённые правки

- Добавлено явное разделение в scope и acceptance matrix.
- Добавлен `PARITY-01-AM-08` (consistency check doc vs executable matrix).
- Явно указан false-positive ceiling = 0.

## Critique Pass 2

### Замечания после pass 1

1. Недостаточно чётко закреплён live-sanitized evidence как обязательный для review.
2. Не указано, что manual intervention state не должен считаться active dispatch.

### Применённые правки

- Добавлены `PARITY-01-AM-05` и усиленная формулировка `PARITY-01-AM-07`.
- В инвариантах и заметках закреплено отсутствие закрытия без live-sanitized evidence.
