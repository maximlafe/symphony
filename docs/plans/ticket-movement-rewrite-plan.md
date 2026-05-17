# План переписывания логики движения тикета (inline)

## Цель

Переписать логику движения тикета как один прямой, проверяемый поток. В этом контексте нет пользователей и нет legacy-value, поэтому миграционная безопасность не является отдельной продуктовой целью. Приоритеты плана: явные зависимости, явные интерфейсы, явные инварианты и проверяемые точки останова.

## Термины

- Не вводить новые терминологические сущности без опоры на текущие идентификаторы кода.
- `legacy adapter path` не фиксируется как целевая продуктовая сущность. Если в коде нужен переходный маршрут, он должен быть описан как временный технический путь, а не как отдельная пользовательская ветка.
- `checkpointed rule-table version` использовать только если в коде уже есть точное имя соответствующего поля или записи; иначе оставить термином только для пояснения в этом документе и заменить его на реальный кодовый идентификатор при реализации.

## Базовые числа

Зафиксировать как baseline из текущего кода и не вводить поверх них произвольные значения:

- continuation attempts default = `3`
- verification recoverable drift max attempts = `1`
- failure retry base = `10_000ms`
- linear poll backoff = `60_000ms`
- tracker escalation dedupe ttl = `300_000ms`
- retry budget ttl = `300_000ms`
- max retry backoff default = `300_000ms`

Эти числа считаются плановым baseline. Изменять их можно только отдельным последующим решением, если кодовая причина будет явно зафиксирована.

## Предусловия

Перед любым поведением-изменяющим шагом должны быть выполнены все пункты ниже:

1. `characterization gate` на текущем поведении логики движения тикета.
2. Инвентаризация текущих lifecycle-paths, guard-paths и Linear side effects.
3. Таблица `current state -> target state`.
4. Явная карта зависимостей между `Plan -> Execute -> Review -> Done/Blocked`.
5. Явная ownership-карта для plan / execution / review boundaries и Linear side effects.
6. Зафиксированный fallback для `changed_paths` и его инварианты.
7. Зафиксированный runtime baseline из текущих чисел кода.

Пока эти условия не выполнены, никакие изменения поведения не считаются безопасно запущенными.

## Ownership map

These boundary labels are planning labels, not new Elixir modules. The concrete implementation surfaces today are:

- plan boundary: `ValidationGate` plus `controller_finalizer` pre-handoff path;
- execution boundary: `ExecutionContract` plus `Orchestrator`;
- review boundary: `HandoffCheck` plus `controller_finalizer` final handoff path;
- Linear side effects: the existing app-server / Linear call path, to be consolidated into one wrapper.

### Plan boundary

Owns:

- форму планового состояния;
- переход из `Plan` в `Execute`;
- обязательные поля плана;
- preflight-валидацию перед началом движения;
- источник `changed_paths` на уровне плановой стадии.
- политика fallback для `changed_paths`.

May not own:

- прямые Linear side effects;
- retry policy;
- execution-time failover.

### Execution boundary

Owns:

- выполнение переходов в `Execute`;
- retry/failover;
- continuation limits;
- recoverable drift handling;
- backoff и retry budget mechanics;
- idempotency requirements для повторных запусков.

May not own:

- review-only decisions;
- finalization semantics;
- презентационные Linear side effects, если они не связаны с самим execution flow.

### Review boundary

Owns:

- review gate;
- переход в `Done` или `Blocked`;
- final handoff checks;
- blocked-state reasoning;
- final acceptance of the ticket movement result.

May not own:

- retry scheduling;
- execution-side backoff;
- hidden fallback paths.

### Linear side effects

Все Linear side effects должны быть изолированы в одном idempotent wrapper в Linear-layer. Этот wrapper owns:

- создание и обновление Linear state;
- комментарии и статусные изменения;
- dedupe/identity key handling;
- повторные вызовы без дублирования side effects.

Ни один другой слой не должен вызывать Linear напрямую, если действие уже проходит через этот wrapper.

## Dependency and prerequisite map

Порядок работ должен быть таким:

1. Сначала characterization gate.
2. Затем inventory и `current state -> target state`.
3. Затем ownership map для boundary responsibilities и Linear side effects.
4. Затем canonical state machine.
5. Затем разделение по boundary labels.
6. Затем удаление дублирующей guard-логики.
7. Затем `changed_paths` fallback semantics.
8. Затем retry/failover simplification.
9. Затем idempotent Linear wrapper.
10. Затем test matrix как gate map.

Любой шаг ниже по списку зависит от завершения всех более ранних шагов. Если шаг нуждается в данных из более раннего шага, он не может начинаться по предположению.

## Rollback and stop rules

Каждый шаг останавливается и откатывается по своему правилу.

1. **Переопределение границ**
   - Если план не удаётся привязать к конкретным surfaces, не оставлять абстрактные boundary-module имена как целевую архитектуру.
   - В таком случае оставить только concrete surfaces и не продолжать абстрактное именование.

2. **Characterization gate**
   - Если baseline поведения не фиксируется, не начинать никаких behavior-changing edits.
   - Откат на этом шаге означает, что никакие последующие шаги не считаются применёнными.

3. **Inventory and mapping**
   - Если inventory показывает, что `Plan -> Execute -> Review` не маппится на реальный code path, остановиться на inventory и не force-fit canonicalization.
   - В этом срезе canonical split не вводить, пока не найден реальный seam.

4. **Boundary contracts and interface ownership**
   - Если ownership пересекает несколько concrete surfaces без одного clear boundary, оставить boundary composite и не объявлять его split-ready.
   - Откат на этом шаге означает возврат только explanatory labeling без изменения runtime behavior.

5. **Canonical pipeline and guard cleanup**
   - Если удаление дублирующей guard-логики меняет current behavior, откатить только guard cleanup, а mapping и inventory сохранить.
   - Если canonical pipeline не сохраняет current entry/exit semantics, guards не удалять.

6. **`changed_paths` fallback semantics**
   - Владелец политики fallback: plan boundary.
   - Если fallback возвращает пустой или synthetic `changed_paths`, поведение fail closed и текущий primary source path не менять.
   - Fallback changes считать незавершёнными, пока существующий regression case вокруг `changed_paths is empty` не fail closed.

7. **Retry/failover simplification**
   - Если simplification меняет current baseline numbers or retry semantics, откатить только simplification и сохранить preexisting retry path.
   - Новые defaults не вводить, пока этот шаг не завершён.

8. **Idempotent Linear wrapper**
   - Если wrapper не может доказать idempotency на реальном operation key, direct Linear writes оставить на месте и call sites не переключать.
   - Откат на этом шаге означает удаление только wrapper call-site migration без изменения существующей Linear implementation.

9. **Validation gate map**
   - Если change cannot point to a named regression test, не считать change завершённым.
   - Если coverage только generic happy-path, шаг оставлять open.

## Canonical state machine

Канонический поток:

- `Plan`
- `Execute`
- `Review`
- `Done`
- `Blocked`

Правила переходов:

- `Plan -> Execute` только после прохождения plan-side preflight;
- `Execute -> Review` только после завершения execution evidence;
- `Review -> Done` только если review gate зеленый;
- любой этап -> `Blocked`, если нарушен обязательный инвариант или не выполняется обязательная проверка.

Промежуточные локальные состояния допускаются только внутри соответствующего контракта и не должны становиться новым публичным маршрутом.

## Plan of work

1. **Re-scope**
   - Убрать из плана предположение, что здесь нужен migration-safety-first режим.
   - Не проектировать отдельную legacy-compatible ветку как продуктовую цель.
   - Все дальнейшие шаги считать прямым переписыванием логики, а не сохранением старой пользовательской траектории.

2. **Characterization gate**
   - Зафиксировать текущее поведение движения тикета.
   - Покрыть входы, переходы и блокировки, которые уже есть в коде.
   - Использовать этот gate как baseline, а не как общий safety ritual.

3. **Inventory and mapping**
   - Собрать текущие lifecycle-paths.
   - Собрать guard-paths.
   - Собрать Linear side effects.
   - Построить таблицу `current state -> target state`.
   - Отдельно пометить, какие пути являются обязательными, а какие можно слить в canonical pipeline.

4. **Boundary contracts and interface ownership**
   - Зафиксировать, какие поля, переходы и side effects принадлежат plan boundary (`ValidationGate` + `controller_finalizer` pre-handoff path), execution boundary (`ExecutionContract` + `Orchestrator`), и review boundary (`HandoffCheck` + `controller_finalizer` final handoff path).
   - Зафиксировать, где заканчивается плановая стадия и начинается execution/review.
   - Зафиксировать все Linear side effects как единый interface boundary.

5. **Canonical pipeline and guard cleanup**
   - Построить один canonical pipeline поверх `Plan -> Execute -> Review -> Done/Blocked`.
   - Удалить дубли guard-логики только после того, как ownership map и state machine зафиксированы.
   - Не оставлять два конкурирующих пути принятия решения.

6. **`changed_paths` fallback semantics**
   - Основной источник `changed_paths` должен быть явным и детерминированным.
   - Fallback должен применяться только если основной источник пуст или недоступен.
   - Fallback не должен синтезировать пути, которых нет в реальном изменении.
   - Если после fallback список все еще пуст, поведение должно fail closed.
   - Список `changed_paths` должен быть нормализованным, списком строк и стабильным по порядку.

7. **Retry/failover simplification**
   - Использовать только текущие baseline-числа из кода.
   - `continuation attempts default = 3`.
   - `verification recoverable drift max attempts = 1`.
   - `failure retry base = 10_000ms`.
   - `linear poll backoff = 60_000ms`.
   - `tracker escalation dedupe ttl = 300_000ms`.
   - `retry budget ttl = 300_000ms`.
   - `max retry backoff default = 300_000ms`.
   - Не вводить новые retry бюджеты или новые backoff-значения без отдельного code-backed решения.

8. **Idempotent Linear wrapper**
   - Вынести все Linear writes в один wrapper.
   - Сделать wrapper idempotent по ключу операции и текущему состоянию тикета.
   - Повторные вызовы с тем же ключом не должны создавать новый side effect.
   - Dedupe и retry должны опираться на уже зафиксированные baseline ttl/backoff значения.

9. **Validation gate map**
   - Перевести тестовую матрицу из общего списка в карту gate-to-change.
   - Каждый тестовый bucket должен закрывать один или несколько конкретных interface changes.
   - Gate не считается зеленым, если он проверяет только общий happy path без привязки к измененному интерфейсу.

## Validation matrix

Названия named regression tests записываются как `file.exs: exact test title`.

| Change | Named regression tests | Gate | What it proves |
| --- | --- | --- | --- |
| Characterization baseline | `validation_gate_test.exs: "classifies changed paths deterministically and fails closed for unknown paths"`; `execution_contract_test.exs: "retry budget status/open/outcome handles nil, cooldown, expiry and unknown outcomes"` | characterization tests | Текущее поведение движения тикета и retry baseline зафиксированы до изменений |
| Inventory / state mapping | `handoff_check_test.exs: "evaluate normalizes validation gate errors and git changed paths for invalid change classes"`; `core_test.exs: "failed symphony_handoff_check manifest fail-closes active run as human-action blocker"` | inventory tests | `current state -> target state` и dependency map совпадают с кодом |
| Boundary mapping | `execution_contract_test.exs: "classify_admission_failure normalizes payload and defaults with non-map input"`; `handoff_check_test.exs: "evaluate passes with matching attachment, checklist, and green PR"`; `app_server_test.exs: "app server dedupes repeated validation exec_background launches while the same surface is running"` | contract tests | Затронутые поверхности сохраняют поведение, соответствующее их границам, и остаются согласованными с ownership map |
| `changed_paths` fallback | `controller_finalizer_test.exs: "run/3 fail-closes changed_paths fallback when git diff is empty"`; `dynamic_tool_test.exs: "symphony_handoff_check fail-closes empty changed_paths fallback to runtime_contract"` | handoff / validation tests | Fallback детерминирован, fail closed, synthetic paths не возникают |
| Retry / failover | `execution_contract_test.exs: "retry budget status/open/outcome handles nil, cooldown, expiry and unknown outcomes"`; `core_test.exs: "recoverable symphony_handoff_check drift escalates after bounded retry budget is exhausted"` | execution tests | Baseline-числа и retry semantics сохраняются без произвольных default-значений |
| Linear wrapper | `app_server_test.exs: "app server dedupes repeated validation exec_background launches while the same surface is running"`; `app_server_test.exs: "app server allows validation rerun when workspace diff changes after green and never dedupes distinct bundles"`; `workspace_and_config_test.exs: "linear client applies assignee id filter directly in team-scope query"`; `workspace_and_config_test.exs: "linear client applies assignee id filter directly in project-scope query"` | Linear-layer tests | Idempotency и dedupe работают на повторных вызовах; assignee-filtered polling сохраняет schema-compatible GraphQL contract (`ID!` для assignee id) |
| End-to-end movement | `handoff_check_test.exs: "evaluate passes with matching attachment, checklist, and green PR"`; `core_test.exs: "recoverable symphony_handoff_check drift escalates after bounded retry budget is exhausted"` | e2e / runtime smoke | Полная цепочка `Plan -> Execute -> Review -> Done/Blocked` проходит как единый поток |
| Rollback / failure injection | `core_test.exs: "failed symphony_handoff_check manifest fail-closes active run as human-action blocker"`; `validation_gate_test.exs: "classifies changed paths deterministically and fails closed for unknown paths"` | failure-injection tests | Неуспешные ветки завершаются предсказуемо и не создают дубли |

## Retired items

- Отдельная legacy-compatible ветка как продуктовая цель retired: в этом контексте нет пользователей и legacy-value, поэтому отдельная миграционная страховка не нужна.
- Термин `legacy adapter path` retired как целевая сущность: он не должен определять архитектуру плана.
- Термин `checkpointed rule-table version` retired как новое имя: использовать только существующий кодовый идентификатор, если он уже есть.

## Residual issues

- Если в коде уже есть еще один скрытый consumer of `changed_paths`, его нужно включить в inventory до начала поведения-изменяющего шага.
- Если Linear wrapper already exists partially, нужно считать его не новым abstraction, а расширяемым boundary и не дублировать второй wrapper.
- Если boundary contracts already exist partially, план должен сверять именно текущие interfaces, а не переименовывать их задним числом.

## End-of-run ledger

- **Target document:** `docs/plans/ticket-movement-rewrite-plan.md`
- **Items fixed in order:** 1) re-scoped away from migration-safety-first assumptions; 2) added explicit dependency/prerequisite map; 3) defined interface ownership for boundary responsibilities and Linear side effects; 4) specified `changed_paths` fallback semantics and invariants; 5) locked baseline runtime numbers; 6) turned the test matrix into a gate map
- **Items retired with justification:** legacy-compatible product branch, `legacy adapter path` as a design target, and `checkpointed rule-table version` as a newly coined term, because there is no user-facing legacy value to preserve and the plan should follow existing code identifiers instead of inventing new ones
- **Residual issues still open:** any additional `changed_paths` consumers, any partially implemented Linear wrapper, and any already-existing boundary-contract interfaces that need to be matched exactly during implementation
