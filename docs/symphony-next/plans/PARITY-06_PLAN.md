# PARITY-06 Plan (Spec Prep)

## 1) Подтверждено по текущему коду и артефактам

- Merge-gating в `Symphony-next` фактически реализуется в `HandoffCheck`:
  - `pr_snapshot_missing_items/1` проверяет:
    - `all_checks_green == true`
    - `has_pending_checks == false`
    - `has_actionable_feedback == false`
    - merge-ready через `merge_state_status`.
- Текущее merge-state правило permissive:
  - сейчас блокируются только `DIRTY`, `BLOCKED`, `UNKNOWN`;
  - остальные значения (включая `nil`/пустые/неизвестные outside denylist) считаются merge-ready.
- Stale-proof transition guard уже есть в
  `review_ready_transition_allowed?/5`:
  - stale workpad hash -> `:handoff_manifest_stale`;
  - stale validation gate final proof/git mismatch -> `:handoff_manifest_stale`.
- Покрытие по `HandoffCheck` широкое, но отсутствует отдельный ticket-level
  executable parity contract для `PARITY-06`:
  - нет единой deterministic matrix для merge-ready/not-ready/stale-proof;
  - нет live-sanitized parity fixture по real LET traces для merge-gating signals;
  - нет отдельного canonical `PARITY-06` suite c явной Acceptance Matrix mapping.

## 2) Выбранный MVP и почему

### MVP

Закрыть `PARITY-06` через минимальный безопасный delta:

1. Зафиксировать canonical merge-gating contract (merge-ready/not-ready/stale-proof).
2. Ужесточить merge-state gate до fail-closed allowlist:
   - merge-ready только для явно разрешённых состояний.
3. Добавить deterministic matrix fixture:
   - merge-ready positive,
   - not-ready причины,
   - stale-proof transition denial.
4. Добавить live-sanitized fixture из реальных LET комментариев с
   `merge_state_status`/check signals.
5. Добавить отдельный parity suite `PARITY-06` и evidence doc.

### Почему это минимально достаточный путь

- Закрывает именно merge gating parity (`PARITY-06`), не заходя в расширение
  review feedback классификатора (`PARITY-14`).
- Не расширяет runtime surface за пределы текущего `HandoffCheck`/finalizer
  контрактного контура.
- Даёт executable proof вместо «распылённых» тестов без тикетного контракта.

## 3) Готовый engineering spec

## Проблема

Replacement-scope merge-ready решение критично для production parity, но сейчас
оно не заморожено как отдельный контракт `PARITY-06`, а merge-state проверка в
`HandoffCheck` допускает fail-open поведение для части ambiguous/non-allowlist
состояний.

## Цель

Сделать merge gating behavior explicit и executable:

- merge-ready/not-ready decision table;
- stale-proof transition semantics;
- deterministic + live parity proof.

## Скоуп

1. Canonical contract для merge gating (`PARITY-06`).
2. Tighten merge-state readiness rule (fail-closed allowlist).
3. Deterministic matrix fixture (ready/not-ready/stale).
4. Live-sanitized fixture generator и fixture на реальных LET traces.
5. Отдельный parity suite и evidence doc.
6. Обновление backlog/progress статусов по результату ticket cycle.

## Вне скоупа

- Полная классификация actionable review feedback beyond текущего контура
  (`PARITY-14`).
- Cutover/shadow/rollback production rollout proofs (`PARITY-11..13`).
- Runtime/Codex-depth расширения (`PARITY-07..09`, `PARITY-20`).

## Ограничения и инварианты

- Тикет не закрывается без executable evidence.
- `unknown`/ambiguous merge-state в replacement-scope -> `not_ready`.
- Stale-proof guard must remain fail-closed.
- Live fixture только sanitized и только на реальных LET traces.

## Риски

- Исторические комментарии могут содержать неполные snapshot-поля.
- Возможна разница между old operator wording и typed snapshot полями.
- Слишком жёсткий allowlist может временно увеличить false negatives (осознанно,
  fail-closed безопаснее для replacement gate).

## Зависимости

- `LINEAR_API_KEY`
- `make symphony-preflight`
- `make symphony-acceptance-preflight`
- `mix test` / `make all`

## План валидации

- Baseline:
  - `HandoffCheck`/`DynamicTool` тесты есть, но нет ticket-level contract.
- Delta:
  - появляется canonical merge-gating contract + deterministic/live fixtures +
    dedicated parity suite.
- Dataset:
  - deterministic matrix сценарии merge-ready/not-ready/stale-proof;
  - live LET traces с `merge_state_status` и related check signals.
- False-positive ceiling:
  - 0 `unknown` outcomes в replacement-scope merge gating.

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-06-AM-01` | Green checks + no pending + no actionable + allowlisted merge state | `merge_ready=true` | test | deterministic parity suite | surface_exists | review |
| `PARITY-06-AM-02` | `all_checks_green=false` | `merge_ready=false` + reason `pull request checks are not fully green` | test | deterministic parity suite | surface_exists | review |
| `PARITY-06-AM-03` | `has_pending_checks=true` | `merge_ready=false` + reason `pull request still has pending checks` | test | deterministic parity suite | surface_exists | review |
| `PARITY-06-AM-04` | `has_actionable_feedback=true` | `merge_ready=false` + reason `pull request still has actionable feedback` | test | deterministic parity suite | surface_exists | review |
| `PARITY-06-AM-05` | merge state non-allowlist (`DIRTY`/`BLOCKED`/`UNKNOWN`/ambiguous) | `merge_ready=false` + reason `pull request is not merge-ready` | test | deterministic parity suite | surface_exists | review |
| `PARITY-06-AM-06` | Stale validation-gate proof/head mismatch at transition | `review_ready_transition_allowed?` -> `:handoff_manifest_stale` | test | deterministic parity suite | surface_exists | review |
| `PARITY-06-AM-07` | Workpad hash drift after successful handoff check | `review_ready_transition_allowed?` -> `:handoff_manifest_stale` | test | deterministic parity suite | surface_exists | review |
| `PARITY-06-AM-08` | Fresh manifest + fresh git + unchanged workpad | `review_ready_transition_allowed?` -> `:ok` | test | deterministic parity suite | surface_exists | review |
| `PARITY-06-AM-09` | Live LET traces with merge/check signals | same canonical merge-gating decision mapping passes | artifact | live fixture + parity suite run | run_executed | review |
| `PARITY-06-AM-10` | Contract-doc consistency | contract markers and AM ids синхронизированы с suite | test | contract parity assertions | surface_exists | review |

## Proof Mapping (требование к execute handoff)

- Каждый `PARITY-06-AM-*` должен маппиться на deterministic/live case IDs.
- Для `AM-09` обязательно:
  - команда генерации live fixture;
  - sampled identifiers/signals summary;
  - SHA256 fixture.
- Для merge-gating cases фиксировать:
  - observed snapshot fields (`all_checks_green`, `has_pending_checks`,
    `has_actionable_feedback`, `merge_state_status`);
  - expected readiness class и reason(s).

## Alternatives considered

1. Оставить текущее denylist merge-state без tightening.
   - Отклонено: сохраняет `unknown`-class fail-open риск.
2. Закрыть тикет только документацией без dedicated suite.
   - Отклонено: не даёт executable replacement proof.
3. Сразу объединить `PARITY-06` и `PARITY-14`.
   - Отклонено: расширяет scope и усложняет risk isolation.

## Заметки

- Execute-фаза идёт в режиме minimal safe delta:
  contract/fixtures/suite -> runtime tweak только если drift подтверждён.
- Для replacement-class ticket `unknown` merge-state parity трактуется как
  `not_ready` (hard gate).

## Symphony

- Ticket: `PARITY-06`
- Stream: `Stream 2`
- Mode: `Spec Prep -> In Progress`
- Required capabilities: `LINEAR_API_KEY`, `make symphony-preflight`,
  `make symphony-acceptance-preflight`, `mix test`

## Critique Pass 1

### Замечания к черновику

1. Не был явно выделен fail-open риск текущего merge-state denylist.
2. Не хватало явной stale-proof transition части в Acceptance Matrix.
3. Не был зафиксирован hard-gate `unknown => not_ready`.

### Применённые правки

- Явно добавлен root cause по permissive merge-state gate.
- Добавлены `AM-06..08` на stale-proof transition.
- Добавлен explicit invariant и AM-05 про ambiguous merge-state.

## Critique Pass 2

### Замечания после pass 1

1. Нужна явная граница с `PARITY-14`.
2. Не хватало live contour с полями snapshot signals.
3. Требовалась явная Proof Mapping структура.

### Применённые правки

- Добавлен `Вне скоупа` с явным отсечением `PARITY-14`.
- `AM-09` выделен как live-sanitized contour на real LET traces.
- Добавлен подробный `Proof Mapping` блок для execute handoff.
