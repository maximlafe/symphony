# PARITY-07 Plan (Spec Prep)

## 1) Подтверждено по текущему коду и артефактам

- В `Orchestrator` уже реализованы ключевые recovery-механизмы:
  - детекция stalled-run и fail-safe restart через `schedule_issue_retry`;
  - continuation/failure retry ветки с backoff и typed metadata;
  - восстановление `resume_checkpoint` через `resolve_resume_checkpoint/2`;
  - reconcile-path для orphaned claim (`reconcile_missing_retry_outcome`).
- Существующее покрытие (`orchestrator_status_test.exs`, `runtime_smoke_test.exs`)
  подтверждает отдельные части поведения (stall restart, retry lifecycle,
  pre-run hook stall guard, snapshot visibility), но не фиксирует единый
  replacement-контракт `PARITY-07` с atomic acceptance mapping.
- Для `PARITY-07` в backlog явный exit criterion:
  - long-running restart/recovery scenarios pass;
  - event-log replay yields stable state.
- В текущем наборе parity-артефактов отсутствуют:
  - dedicated contract-doc для runtime recovery parity;
  - deterministic matrix, явно покрывающая long-lived recovery/replay contour;
  - live-sanitized fixture + parity suite, маппящие contract AM items на proof.

## 2) Выбранный MVP и почему

### MVP

Закрыть `PARITY-07` минимальным безопасным контуром доказательства и точечным
runtime hardening только при реальном провале сценариев:

1. Зафиксировать canonical runtime recovery contract:
   - restart after stall;
   - retry reconcile after partial progress;
   - resume checkpoint reload priority;
   - replay stability (один и тот же event sequence даёт стабильный snapshot).
2. Добавить deterministic parity matrix + dedicated parity suite
   (`runtime_recovery_parity_test.exs`) с AM-id mapping.
3. Добавить live-sanitized runtime fixture generator на реальных LET traces
   (sanitized markers: `resume_mode`, `continuation_reason`, retry/backoff
   evidence) и проверить contract mapping against fixture.
4. Если parity suite выявит drift — внести минимальный runtime fix в
   `Orchestrator`/adjacent modules, без расширения в `PARITY-08/09/20`.
5. Выпустить evidence pack и обновить backlog/progress docs.

### Почему это минимально достаточный путь

- Закрывает ровно риск `PARITY-07` (runtime recovery/replay parity), не
  перетягивая реализацию richer runner depth (`PARITY-08`) и continuation-turn
  richness (`PARITY-09`) в этот тикет.
- Сохраняет hard-gate "no green on paper": closure только через executable
  matrix + live artifact.
- Укладывается в существующую архитектуру (runner-agnostic core, capability
  gates, typed snapshot contracts).

## 3) Готовый engineering spec

## Проблема

`Symphony-next` уже имеет runtime retry/recovery primitives, но для replacement
scope нет единого executable proof, что long-lived recovery/replay-paths ведут к
стабильному состоянию при restart/retry/partial-progress сценариях. Без этого
замена может быть формально "зелёной" на коротких кейсах и деградировать в
долгоживущих production-петлях.

## Цель

Сделать runtime recovery parity для replacement-scope явной, контрактной и
исполняемой: long-lived restart/recovery + replay stability должны быть
доказаны deterministic и live-sanitized evidence.

## Скоуп

1. Новый canonical contract:
   - `docs/symphony-next/contracts/PARITY-07_RUNTIME_RECOVERY_CONTRACT.md`.
2. Deterministic parity dataset:
   - `elixir/test/fixtures/parity/parity_07_runtime_recovery_matrix.json`.
3. Live fixture generator + sanitized artifact:
   - `scripts/generate_parity_07_live_sanitized_fixture.sh`;
   - `elixir/test/fixtures/parity/parity_07_runtime_recovery_live_sanitized.json`.
4. Dedicated executable suite:
   - `elixir/test/symphony_elixir/runtime_recovery_parity_test.exs`.
5. Точечный runtime fix только если deterministic/live сценарии падают.
6. Evidence + docs update после merge.

## Вне скоупа

- Runner architecture decision/implementation depth (`PARITY-08`).
- Rich continuation-turn semantics (`PARITY-09`) сверх recovery parity.
- Final ops/resilience subset implementation (`PARITY-20`).
- Cutover/shadow/rollback ticket scope (`PARITY-11..13`).

## Ограничения и инварианты

- Ticket не закрывается без executable evidence (deterministic + live).
- Replay stability трактуется fail-closed:
  - если повторный replay того же sequence меняет итоговый runtime snapshot,
    это blocker.
- Runtime parity proof не может подменяться только CI-pass или unit-only
  happy-path assertions.
- Не допускается скрытое смещение orchestration logic в skills/prompts.

## Риски

- Live traces могут быть шумными/неполными для recovery markers.
- Возможны intermittent Linear API/TLS ошибки при fixture generation.
- Replay scenarios могут требовать точечного изменения idempotency/normalization
  logic в `Orchestrator`.

## Зависимости

- `GH_TOKEN`, `LINEAR_API_KEY`.
- `make symphony-preflight`.
- `make symphony-acceptance-preflight`.
- `mix test` + repo validation (`make all`/эквивалент по текущему контракту).
- Доступ к real LET issues для live-sanitized evidence.

## План валидации

- Baseline:
  - есть разрозненные runtime tests без `PARITY-07` contract matrix.
- Delta:
  - введён canonical contract + AM mapping;
  - deterministic + live parity suites исполняются и подтверждают recovery/replay
    stability.
- Dataset:
  - deterministic matrix cases (`PARITY-07-AM-*`);
  - live-sanitized LET trace samples с runtime recovery markers.
- False-positive ceiling:
  - 0 кейсов, где replay одного и того же события приводит к разному snapshot;
  - 0 кейсов "stalled->retry", где retry metadata теряет обязательные поля
    (`attempt`, `error_class`, `continuation/recovery signal`) при recovery.

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-07-AM-01` | Running issue stalls beyond timeout | worker terminates, retry scheduled with transient class and attempt increment | test | deterministic parity suite | surface_exists | review |
| `PARITY-07-AM-02` | Active pre-run hook window under hook timeout | no false stalled retry during guarded pre-run hook | test | deterministic parity suite | surface_exists | review |
| `PARITY-07-AM-03` | Retry lookup sees issue moved terminal | claim released and cleanup path triggered deterministically | test | deterministic parity suite | surface_exists | review |
| `PARITY-07-AM-04` | Resume checkpoint provided + loadable checkpoint exists | loaded ready checkpoint dominates stale fallback checkpoint | test | deterministic parity suite | surface_exists | review |
| `PARITY-07-AM-05` | Retry token missing but claim orphaned | reconcile path clears orphaned claim (no stuck claimed issue) | test | deterministic parity suite | surface_exists | review |
| `PARITY-07-AM-06` | Replay identical codex event sequence over same baseline | resulting runtime snapshot fields are stable (idempotent replay) | test | deterministic parity suite | surface_exists | review |
| `PARITY-07-AM-07` | Live sanitized LET traces with recovery markers | mapping to canonical recovery classes is deterministic and no `unknown` in replacement scope | artifact | live fixture + parity assertions | run_executed | review |
| `PARITY-07-AM-08` | End-to-end validation matrix | preflight + acceptance + targeted parity tests + repo validation pass | test | validation command log | run_executed | review |
| `PARITY-07-AM-09` | Contract consistency | all AM ids and runtime-recovery markers present in contract doc and suite | test | contract parity assertions | surface_exists | review |
| `PARITY-07-AM-10` | Post-merge sanity | relevant runtime recovery checks pass on synced `main` | test | post-merge sanity log | run_executed | done |

## Proof Mapping (требование к execute handoff)

- Каждый `PARITY-07-AM-*` должен быть привязан к:
  - deterministic case id (или live case id),
  - конкретной test assertion/command,
  - артефакту (fixture/evidence/log) при `proof_type=artifact`.
- Для `AM-07` обязательно:
  - путь live fixture;
  - sampled issue identifiers;
  - fixture SHA256.
- Для `AM-10` обязательно:
  - команды post-merge sanity;
  - явный pass/fail status.

## Alternatives considered

1. Закрыть тикет только расширением существующих runtime smoke tests.
   - Отклонено: не даёт contract-level acceptance mapping и live fixture contour.
2. Сразу внедрить richer runner behavior (app-server depth) в рамках `PARITY-07`.
   - Отклонено: это scope `PARITY-08/09`, нарушает минимальный change set.
3. Ограничиться doc-only фиксацией recovery semantics.
   - Отклонено: против hard-gate "no executable evidence".

## Заметки

- `PARITY-07` трактуется как parity-proof + точечный fix-only-if-needed.
- Если live fixture generation блокируется внешне (auth/network), ticket уходит в
  `Blocked` только после capability-gate прогона и с точным unblock action.

## Symphony

- Ticket: `PARITY-07`
- Stream: `Stream 3`
- Mode: `Spec Prep -> In Progress`
- Required capabilities: `LINEAR_API_KEY`, `GH_TOKEN`,
  `make symphony-preflight`, `make symphony-acceptance-preflight`, `mix test`

## Critique Pass 1

### Замечания к черновику

1. Недостаточно явно был зафиксирован replay stability как отдельный
   acceptance item.
2. Не был прописан false-positive ceiling для live contour.
3. Граница с `PARITY-08/09` требовала более жёсткой фиксации.

### Применённые правки

- Добавлен отдельный `AM-06` про idempotent replay.
- Добавлен explicit false-positive ceiling в план валидации.
- Уточнены `Out of scope` и MVP-границы с `PARITY-08/09/20`.

## Critique Pass 2

### Замечания после pass 1

1. Нужна явная привязка post-merge sanity к acceptance.
2. Нужно формализовать required-before (`review` vs `done`) на runtime proof.
3. Нужно зафиксировать fail-closed интерпретацию нестабильного replay.

### Применённые правки

- Добавлен `AM-10` (post-merge sanity, required_before=`done`).
- Матрица нормализована по `required_before`.
- Инварианты дополнены fail-closed правилом для replay stability.
