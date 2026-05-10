---
plan_revision: plan-rev-LET-717-20260510-2228
artifact_revision: plan-rev-LET-717-20260510-2228
target_issue: LET-717
artifact_type: supporting_swarm_artifact
scope: plan_stage_support
canonical_plan_relation: supports_only
---

# LET-717: поддерживающий артефакт для strict runtime-token proof

## Назначение

Этот документ поддерживает канонический краткий план LET-717 и не переопределяет его. Он фиксирует вспомогательную plan-stage рамку для strict runtime-token handoff path: зависимости, prerequisites, interface impacts, порядок исполнения, failure modes, rollback, диагностику и validation mapping.

Каноническое требование остается главным: strict runtime-token handoff path обязан fail closed при missing token, stale token и argument-only token; успешный handoff допустим только после runtime-source validation свежего `runtime_execution_attempt_token`, связанного с текущей runtime execution attempt.

Этот артефакт не добавляет самостоятельные canonical acceptance criteria. Он описывает supporting evidence, которое execution task может использовать для реализации и проверки canonical short plan.

## Термины и нормативные слова

- `strict runtime-token handoff path`: защищаемый handoff flow LET-717, где доказательство принимается только из runtime context.
- `handoff boundary`: конкретная enforcement point внутри strict runtime-token handoff path.
- `runtime_execution_attempt_token`: token value, используемый как часть runtime-token proof.
- `runtime context`: авторитетный execution context, из которого token source может быть подтвержден.
- `argument-only token`: token value, пришедший только через argument, payload, CLI/API parameter, mock input или legacy field.
- `runtime-token proof`: результат успешной runtime-source validation; сам token value proof не является.
- `fresh`: token source подтвержден runtime context и связан с текущей runtime execution attempt.
- `stale`: token не связан с текущей runtime execution attempt или не совпадает с authoritative runtime state.
- `fail closed`: отсутствие, mismatch, неоднозначность или exception приводят к отказу, а не к permissive fallback.

Нормативные слова:
- `обязан` / `MUST`: обязательное требование для supporting plan evidence.
- `не должен` / `MUST NOT`: запрещенное поведение.
- `следует` / `SHOULD`: рекомендуемое поведение, допустимое к уточнению в реализации.
- `допустимо` / `MAY`: разрешенный вариант, если он не нарушает canonical short plan.

## Инварианты поведения

1. Missing token: strict runtime-token handoff path обязан отказать, если runtime token отсутствует.
2. Stale token: strict runtime-token handoff path обязан отказать, если token value не связан с текущей runtime execution attempt через authoritative runtime state.
3. Argument-only token: strict runtime-token handoff path обязан отказать, если token value передан только через argument-like surface и не подтвержден runtime context.
4. Fresh runtime token: handoff может пройти только если runtime-source validation подтверждает `runtime_execution_attempt_token` из runtime context.
5. Fail closed: отсутствие, неоднозначность, mismatch или validation exception не должны приводить к fallback на argument-only token.

## Зависимости и prerequisites

Перед strict enforcement реализация обязана подтвердить:

1. Authoritative runtime execution attempt:
   - где хранится или вычисляется текущая execution attempt;
   - какое состояние считается authoritative для token binding;
   - как downstream handoff получает runtime context.

2. Freshness rule:
   - token value должен быть связан с текущей execution attempt;
   - stale определяется через mismatch с authoritative runtime state;
   - точное comparison rule остается implementation detail, но обязано быть тестируемым.

3. Caller inventory:
   - все legitimate in-scope handoff callers должны иметь runtime-context path;
   - legacy callers, передающие только token argument, не должны становиться bypass.

4. Execution sequencing:
   - найти impacted handoff callers;
   - обеспечить runtime context propagation;
   - проверить dry-run diagnostics;
   - включить strict validation на handoff boundary;
   - удалить, игнорировать или явно запретить argument-only token как proof source.

5. Diagnostic readiness:
   - validation path обязан различать missing, stale, argument-only и validation error;
   - diagnostics не должны раскрывать raw token.

## Порядок исполнения и gates

| Фаза | Цель | Exit criteria |
|---|---|---|
| 1. Caller inventory | найти все in-scope handoff callers | список callers зафиксирован; legacy/argument-only surfaces помечены |
| 2. Runtime context propagation | довести runtime context до legitimate callers | каждый in-scope caller имеет runtime-context path или явно исключен из strict runtime-token handoff path |
| 3. Dry-run diagnostics | проверить observability до strict enforcement | reason classes и redaction проверены без принятия argument-only token как proof |
| 4. Strict enforcement | включить fail-closed validation на handoff boundary | negative tests fail closed; positive tests pass для всех in-scope callers |
| 5. Legacy proof cleanup | убрать или обезвредить argument-only token source | argument-only token не может стать runtime-token proof |
| 6. Evidence mapping | связать evidence с canonical plan | layered validation evidence mapped to concrete tests |

Pre-enforcement gate checks:
- all in-scope callers identified;
- runtime context propagation proven for each legitimate caller;
- missing/stale/argument-only negative tests fail closed;
- fresh runtime-context positive tests pass;
- diagnostics redaction verified;
- unexpected validation exceptions fail closed;
- feature flag stance, if any, documented and tested.

Plan-stage support считается неполным для execution handoff evidence, пока gates и layered validation evidence не сопоставлены с concrete tests.

## Interface impacts

| Surface | Impact |
|---|---|
| Handoff boundary | принимает proof только после runtime-source validation |
| Runtime context object/envelope | несет `runtime_execution_attempt_token` и связь с текущей attempt |
| CLI/API/function arguments | token argument не считается proof без runtime context |
| Worker/subprocess boundary | runtime context сериализуется/гидратируется без превращения token в обычный argument |
| Tests and mocks | mock token в argument-like input не проходит strict runtime-token handoff path |
| Legacy callers | мигрируются, блокируются или явно исключаются из strict runtime-token handoff path |
| Diagnostics/logging | показывают source class и mismatch class без raw token |

## Границы

В scope:
- runtime-token proof на handoff boundary;
- negative paths: missing, stale, argument-only, validation error;
- positive path: fresh runtime-context `runtime_execution_attempt_token`;
- dependency/interface planning;
- execution gates, failure modes, diagnostics, rollback и validation mapping.

Out of scope:
- изменение canonical short plan;
- новая auth model за пределами runtime-token proof;
- признание argument-only token compatibility proof;
- UX изменения, не нужные для LET-717.

## Failure mode matrix

| Failure mode | Expected behavior | Required evidence |
|---|---|---|
| Mixed old/new callers | old argument-only caller does not satisfy runtime-token proof | caller/legacy coverage |
| Context hydration failure | fail closed, diagnostic reason emitted | worker/subprocess propagation test |
| Missing attempt metadata | fail closed as missing binding or validation error | unit + boundary test |
| Malformed token/context | fail closed, no fallback to argument-only token | malformed-context regression |
| Validation exception | fail closed, no permissive fallback | fail-open regression test |
| Diagnostics failure | no raw token exposure; failure does not grant proof | diagnostics/redaction test |
| Enforcement misconfiguration | strict runtime-token handoff path remains strict or blocked | flag/config behavior test |
| Rollback/disabled enforcement | not represented as satisfying strict runtime-token guarantee | rollback validation test |

## Риски

| Риск | Последствие | Сдерживание |
|---|---|---|
| Argument-only token ошибочно принимается как proof | обход strict runtime-token handoff path | source classification и rejection |
| Freshness rule не привязан к authoritative state | stale token проходит повторно | binding to current execution attempt |
| Strict enforcement включен до caller migration | legitimate handoff ломается | execution gates и dry-run diagnostics |
| Mixed callers остаются после rollout | частичные отказы или bypass | caller inventory + legacy coverage |
| Worker/subprocess теряет context | handoff ломается | process-boundary validation |
| Mock token проходит как proof | тесты скрывают bypass | test harness bypass tests |
| Validation exception fail-open | security regression | fail-open regression tests |
| Diagnostics раскрывают token | secret leak | log class/reason only |
| Rollback звучит как success state | гарантия LET-717 размывается | rollback table + post-rollback validation |

## Диагностика

Reason classes:
- `runtime_token_missing`
- `runtime_token_stale`
- `runtime_token_argument_only`
- `runtime_token_valid`
- `runtime_token_validation_error`

Safe breadcrumbs:
- token source class: `runtime_context`, `argument`, `payload`, `mock`, `unknown`;
- caller or boundary class, если это уже есть в системе;
- current attempt id presence: present/absent, without secret value;
- mismatch class: missing binding, stale attempt, source rejected, validation exception;
- validation phase: before handoff, at handoff boundary, after context hydration.

Diagnostics timing checks:
- dry-run/pre-enforcement: reason classes and redaction observable before strict rollout;
- strict enforcement: rejection reason emitted for missing/stale/argument-only/error paths;
- rollback/disabled mode, if used: diagnostics distinguish emergency exception from valid runtime-token proof.

Raw token или значения, достаточные для его восстановления, логировать нельзя.

## Feature flag stance

Feature flag не является обязательной частью плана. Если реализация вводит flag или config switch для rollout/rollback, она обязана тестировать состояния явно.

| State | Required behavior |
|---|---|
| Default state | strict runtime-token handoff path enabled or blocked until enabled |
| Strict enabled | missing/stale/argument-only fail closed; fresh runtime context passes |
| Disabled/rollback | emergency/scoped exception only; does not satisfy strict runtime-token guarantee |
| Misconfigured/unknown | fail closed or block strict runtime-token handoff path |

Disabled/rollback state может быть operational mitigation, но не должен описываться как successful LET-717 proof state.

## Rollback

Rollback должен быть контролируемым emergency/scoped action и не должен переопределять canonical guarantee.

| Symptom | Immediate action | Allowed rollback mode | Prohibited fallback | Post-rollback validation |
|---|---|---|---|---|
| Valid runtime context массово отклоняется | stop strict rollout, preserve diagnostics | temporarily disable enforcement or revert boundary change | accepting argument-only token as proof | argument-only rejection/blocked-path check |
| Runtime context propagation недоступен upstream | pause enforcement for affected path | keep path blocked or scoped-disabled | silent fallback to token argument | missing-context test remains fail-closed or blocked |
| Critical execution flow заблокирован | apply emergency mitigation | scoped rollback with owner/timebox | deleting negative tests silently | smoke + fail-open regression |
| Diagnostics leak risk | disable unsafe logging, keep enforcement if possible | redact or suppress diagnostic fields | logging raw token | redaction assertion |
| Flag/config misconfiguration | force known strict or blocked state | config rollback to last known safe state | permissive unknown state | flag-state behavior tests |

Допустимо:
- временно отключить strict enforcement для аварийного восстановления;
- откатить enforcement change на handoff boundary;
- оставить diagnostic/test evidence видимым для повторного включения.

Не допускается:
- объявить argument-only token валидным runtime-token proof;
- ввести silent fallback от runtime context к argument token;
- удалить negative tests без явной фиксации временного исключения.

## Validation mapping

Эта таблица является supporting evidence map для canonical short plan. Она не добавляет standalone acceptance criteria, пока такие критерии не приняты canonical task spec.

| Layer | Проверка | Ожидаемый результат | Доказательство |
|---|---|---|---|
| Unit validation | missing token | отказ | missing-token fail-closed test |
| Unit validation | stale attempt-bound token | отказ | stale-token fail-closed test |
| Unit validation | malformed runtime context | отказ | malformed-context test |
| Unit validation | validation exception | отказ, no fallback | fail-open regression test |
| Handoff boundary integration | token only in function/CLI/API argument | отказ | argument-only rejection test |
| Handoff boundary integration | fresh `runtime_execution_attempt_token` from runtime context | успех | positive runtime-context test |
| Caller/legacy coverage | each in-scope legitimate caller after inventory | успех только с runtime context | per-caller positive tests |
| Caller/legacy coverage | legacy caller without runtime context | отказ или explicit out-of-scope handling | legacy caller strict-path test |
| Tests/mocks | mocked arg token without runtime context | отказ | test harness bypass test |
| Worker/subprocess propagation | context hydration across boundary | успех только при fresh runtime context | boundary propagation test |
| Diagnostics/redaction | rejection diagnostics | reason виден, raw token не раскрыт | log assertion / diagnostics assertion |
| Diagnostics timing | dry-run, strict, rollback/disabled where applicable | states distinguishable without raw token | timing-specific diagnostics assertions |
| Rollback/flag behavior | disabled/rollback state if used | not valid LET-717 proof state | rollback validation test |
| Config behavior | unknown/misconfigured enforcement state | fail closed or path blocked | config-state regression |
| Fail-open regression | unexpected exception or unexpected source class | отказ | fail-open sentinel test |

Positive coverage requirement:
- после caller inventory каждый legitimate in-scope handoff caller должен иметь positive test, который проходит только при fresh runtime-context token;
- один representative happy-path test недостаточен, если существует несколько in-scope caller classes.

## Acceptance support

Артефакт достаточен как plan-stage support, если implementation task может сопоставить canonical LET-717 acceptance criteria с Validation mapping, Interface impacts и Execution gates.

Минимальная supporting evidence matrix:
- execution gates имеют concrete test evidence;
- negative tests покрывают missing, stale, argument-only, mocked-arg, malformed-context, validation-exception и legacy-caller paths;
- positive tests покрывают fresh runtime-context `runtime_execution_attempt_token` для каждого legitimate in-scope caller;
- propagation test покрывает worker/subprocess boundary, если такой boundary участвует в handoff;
- diagnostics assertions подтверждают reason classes, timing states и отсутствие raw token;
- rollback/flag tests подтверждают, что disabled или rollback state не признает argument-only token валидным runtime-token proof;
- fail-open regression tests подтверждают отказ при unexpected validation exceptions.

## Открытые вопросы для реализации

1. Implementation boundary owner: точное имя handoff boundary и список affected callers.
2. Runtime state owner: authoritative source текущей runtime execution attempt.
3. Freshness owner: точное comparison rule для stale token.
4. Interface owner: какие CLI/API/function fields являются legacy argument-token surfaces.
5. Diagnostics owner: финальные event names и существующий logging vocabulary.
6. Test owner: какие mocks/fixtures должны быть обновлены, чтобы не обходить runtime context.
7. Release owner: кто утверждает gate completion перед strict enforcement.
8. Rollback owner: кто принимает scoped rollback decision и проверяет post-rollback validation.
9. Config owner: используется ли feature flag; если да, какие states/defaults допустимы.

## Swarm loop ledger

- Rounds completed: 3 red-team rounds and 3 repair passes.
- Round 1 focus: dependencies, prerequisites, and interface impacts.
- Round 2 focus: execution order, rollback/failure modes, and test coverage.
- Round 3 focus: wording precision, LET workflow vocabulary, and internal coherence.
- Key fixes: dependency/prerequisite section, interface impacts, freshness semantics, execution gates, failure-mode matrix, rollback decision table, layered validation, fail-open regressions, terminology/normative vocabulary, subordinate-authority wording.
- Residual implementation-owned issues: exact handoff boundary names, authoritative runtime state, stale comparison rule, diagnostic event names, concrete test names, feature-flag existence/defaults, and release/rollback/config owners.
