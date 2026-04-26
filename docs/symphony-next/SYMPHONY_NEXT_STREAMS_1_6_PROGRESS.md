# Symphony Next Streams 1-6 Progress

## Baseline (2026-04-26)

- Target repo (user path): `/Users/lafe/Dev/LL/Symphony`
- Execution worktree (clean `main` synced with `origin/main`): `/tmp/symphony-parity-main`
- Baseline source branch in user repo with local changes preserved:
  - `codex/hegemonikon-symphony-integration`
  - local modified/untracked files were **not** overwritten
- `main` sync status in execution worktree:
  - `main` fast-forwarded to `origin/main` (`1b10198`)
  - `git status`: clean

## Streams In Scope

- Stream 1: `PARITY-01`, `PARITY-02`, `PARITY-03`
- Stream 2: `PARITY-04`, `PARITY-05`, `PARITY-06`, `PARITY-14`
- Stream 3: `PARITY-07`, `PARITY-08`, `PARITY-09`, `PARITY-19`, `PARITY-20`
- Stream 4: `PARITY-10`, `PARITY-23`
- Stream 5: `PARITY-11`, `PARITY-12`, `PARITY-13`
- Stream 6: `PARITY-15`, `PARITY-16`, `PARITY-17`, `PARITY-18`

## Ticket Tracker

| ticket | stream | status | branch | PR | merge commit | evidence | blockers |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `PARITY-01` | Stream 1 | `done` | `parity/parity-01-freeze-linear-routing-contract` | `https://github.com/maximlafe/symphony/pull/143` | `094cbd9105e607aa7b303fe8b0b8655a5c92afaf` | `docs/symphony-next/evidence/PARITY-01/PARITY-01_EVIDENCE_2026-04-26.md` | `-` |
| `PARITY-02` | Stream 1 | `done` | `parity/parity-02-freeze-issue-trace-contract` | `https://github.com/maximlafe/symphony/pull/144` | `1b101982afca8c4253925dd321501d3d7560ec89` | `docs/symphony-next/evidence/PARITY-02/PARITY-02_EVIDENCE_2026-04-26.md` | `-` |
| `PARITY-03` | Stream 1 | `in_review_prep` | `parity/parity-03-prove-old-trace-resume-compatibility` | `-` | `-` | `docs/symphony-next/evidence/PARITY-03/PARITY-03_EVIDENCE_2026-04-26.md` | `-` |
| `PARITY-04` | Stream 2 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-05` | Stream 2 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-06` | Stream 2 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-14` | Stream 2 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-07` | Stream 3 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-08` | Stream 3 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-09` | Stream 3 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-19` | Stream 3 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-20` | Stream 3 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-10` | Stream 4 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-23` | Stream 4 | `todo` | `-` | `-` | `-` | `-` | `after replacement class; only pre-work allowed before full replacement` |
| `PARITY-11` | Stream 5 | `todo` | `-` | `-` | `-` | `-` | `requires real shadow scope and live allowlist` |
| `PARITY-12` | Stream 5 | `todo` | `-` | `-` | `-` | `-` | `requires limited cutover capability and scheduler safety gate` |
| `PARITY-13` | Stream 5 | `todo` | `-` | `-` | `-` | `-` | `requires rollback drills in real runtime conditions` |
| `PARITY-15` | Stream 6 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-16` | Stream 6 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-17` | Stream 6 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-18` | Stream 6 | `todo` | `-` | `-` | `-` | `-` | `depends on PARITY-17 classification` |

## Preflight Reading Completed

- `SYMPHONY_NEXT_PARITY_TICKET_MAP.md`
- `SYMPHONY_NEXT_FEATURE_PARITY.md`
- `SYMPHONY_NEXT_FEATURE_PARITY_CHECKLIST.md`
- `SYMPHONY_NEXT_PARITY_EXECUTION_PLAN.md`
- `SYMPHONY_NEXT_PARITY_INVENTORY.md`

## Notes

- Ticket closure rule: no closure without executable evidence.
- For live/cutover/runtime parity tasks, synthetic/fake proof is rejected by policy.
- If class/precondition conflicts appear, ticket is tracked as `blocked` or `partial` with explicit unblock action.

## PARITY-01 Update (2026-04-26)

- Что сделано:
  - создан RU plan-spec (`docs/symphony-next/plans/PARITY-01_PLAN.md`) с Acceptance Matrix и 2 critique pass;
  - создан canonical contract (`docs/symphony-next/contracts/PARITY-01_LINEAR_ROUTING_CONTRACT.md`);
  - добавлены fixture-backed matrix cases + live-sanitized fixture generator;
  - добавлен executable parity test suite `linear_routing_parity_test.exs`.
- Что проверено:
  - `make symphony-preflight`
  - `make symphony-acceptance-preflight`
  - `mix format --check-formatted`
  - `mix test test/symphony_elixir/linear_routing_parity_test.exs`
- Что пошло не по плану:
  - нестабильный TLS transport к Linear API (`curl: (35)`), обойдено через `--http1.1` и повторные прогоны.
- Текущие блокеры/риски:
  - блокеров на уровне implementation/evidence нет.

## PARITY-01 Post-merge (2026-04-26)

- PR/merge:
  - PR: `https://github.com/maximlafe/symphony/pull/143`
  - merge commit: `094cbd9105e607aa7b303fe8b0b8655a5c92afaf`
- Post-merge sanity:
  - `make symphony-preflight` — pass
  - `mix test test/symphony_elixir/linear_routing_parity_test.exs` — pass

## PARITY-02 Update (2026-04-26)

- Что сделано:
  - создан RU plan-spec (`docs/symphony-next/plans/PARITY-02_PLAN.md`) с Acceptance Matrix и 2 critique pass;
  - создан canonical contract (`docs/symphony-next/contracts/PARITY-02_ISSUE_TRACE_CONTRACT.md`);
  - добавлен deterministic fixture `parity_02_issue_trace_matrix.json`;
  - добавлен live generator `scripts/generate_parity_02_live_sanitized_fixture.sh` (retry + control-byte sanitize);
  - сгенерирован live-sanitized fixture `parity_02_issue_trace_live_sanitized.json`;
  - добавлен executable parity suite `issue_trace_parity_test.exs`;
  - собран evidence doc `docs/symphony-next/evidence/PARITY-02/PARITY-02_EVIDENCE_2026-04-26.md`.
- Что проверено:
  - `make symphony-preflight`
  - `make symphony-acceptance-preflight`
  - `mix format --check-formatted`
  - `mix test test/symphony_elixir/issue_trace_parity_test.exs test/symphony_elixir/linear_routing_parity_test.exs`
- Что пошло не по плану:
  - intermittent TLS/reset к Linear API во время live queries; обойдены retry-пайплайном генератора;
  - raw control-bytes в части live comment body ломали JSON parse; добавлен sanitize step в generator contract.
- Текущие блокеры/риски:
  - implementation/evidence blockers отсутствуют.

## PARITY-02 Post-merge (2026-04-26)

- PR/merge:
  - PR: `https://github.com/maximlafe/symphony/pull/144`
  - merge commit: `1b101982afca8c4253925dd321501d3d7560ec89`
- Post-merge sanity:
  - `make symphony-preflight` — pass
  - `mix test test/symphony_elixir/issue_trace_parity_test.exs` — pass

## PARITY-03 Update (2026-04-26)

- Что сделано:
  - создан RU plan-spec (`docs/symphony-next/plans/PARITY-03_PLAN.md`) с Acceptance Matrix и 2 critique pass;
  - создан canonical contract (`docs/symphony-next/contracts/PARITY-03_LEGACY_RESUME_COMPATIBILITY_CONTRACT.md`);
  - добавлен deterministic fixture `parity_03_resume_legacy_matrix.json`;
  - добавлен live generator `scripts/generate_parity_03_live_sanitized_fixture.sh` (retry + control-byte sanitize);
  - сгенерирован live-sanitized fixture `parity_03_resume_legacy_live_sanitized.json` на historical LET traces;
  - добавлен executable parity suite `resume_legacy_parity_test.exs`;
  - устранён fail-closed drift в `TelemetrySchema` для legacy inconsistent `resume_mode` payload;
  - собран evidence doc `docs/symphony-next/evidence/PARITY-03/PARITY-03_EVIDENCE_2026-04-26.md`.
- Что проверено:
  - `make symphony-preflight`
  - `make symphony-acceptance-preflight`
  - `mix format --check-formatted`
  - `mix test test/symphony_elixir/resume_legacy_parity_test.exs test/symphony_elixir/telemetry_schema_test.exs test/symphony_elixir/resume_checkpoint_test.exs test/symphony_elixir/core_test.exs`
  - `mix test test/symphony_elixir/linear_routing_parity_test.exs test/symphony_elixir/issue_trace_parity_test.exs test/symphony_elixir/resume_legacy_parity_test.exs`
- Что пошло не по плану:
  - первоначальная версия live-case ожидала `resume_checkpoint` по явному trace marker, но normalized checkpoint shape был not-ready; зафиксирован и устранён ambiguity drift fail-closed нормализацией.
- Текущие блокеры/риски:
  - implementation/evidence blockers отсутствуют; осталось PR/CI/merge прохождение.
