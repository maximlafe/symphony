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
| `PARITY-03` | Stream 1 | `done` | `parity/parity-03-prove-old-trace-resume-compatibility` | `https://github.com/maximlafe/symphony/pull/145` | `a2d7c5630637f7330f0be6e59a7344f30b64f2c6` | `docs/symphony-next/evidence/PARITY-03/PARITY-03_EVIDENCE_2026-04-26.md` | `-` |
| `PARITY-04` | Stream 2 | `done` | `parity/parity-04-freeze-pr-evidence-contract` | `https://github.com/maximlafe/symphony/pull/146` | `a013737db4d78693f7f97550a9a9159998edb572` | `docs/symphony-next/evidence/PARITY-04/PARITY-04_EVIDENCE_2026-04-26.md` | `-` |
| `PARITY-05` | Stream 2 | `done` | `parity/parity-05-encode-review-finalizer-semantics` | `https://github.com/maximlafe/symphony/pull/147` | `45c97dce969cd57ec5bf02469250dded2510c729` | `docs/symphony-next/evidence/PARITY-05/PARITY-05_EVIDENCE_2026-04-26.md` | `-` |
| `PARITY-06` | Stream 2 | `done` | `parity/parity-06-prove-merge-gating-parity` | `https://github.com/maximlafe/symphony/pull/148` | `16a0dbbf163b9ed79b87596abb5549c82cd22e26` | `docs/symphony-next/evidence/PARITY-06/PARITY-06_EVIDENCE_2026-04-26.md` | `-` |
| `PARITY-14` | Stream 2 | `in_progress` | `parity/parity-14-actionable-feedback-classification` | `-` | `-` | `docs/symphony-next/evidence/PARITY-14/PARITY-14_EVIDENCE_2026-04-26.md` | `-` |
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

## PARITY-03 Post-merge (2026-04-26)

- PR/merge:
  - PR: `https://github.com/maximlafe/symphony/pull/145`
  - merge commit: `a2d7c5630637f7330f0be6e59a7344f30b64f2c6`
- Post-merge sanity:
  - `make symphony-preflight` — pass
  - `mix test test/symphony_elixir/resume_legacy_parity_test.exs` — pass

## PARITY-04 Update (2026-04-26)

- Что сделано:
  - создан RU plan-spec (`docs/symphony-next/plans/PARITY-04_PLAN.md`) с Acceptance Matrix и 2 critique pass;
  - создан canonical contract (`docs/symphony-next/contracts/PARITY-04_PR_EVIDENCE_CONTRACT.md`);
  - добавлен fail-closed resolver `PrEvidence` с explicit `source=none`;
  - добавлен deterministic fixture `parity_04_pr_evidence_matrix.json`;
  - добавлен live generator `scripts/generate_parity_04_live_sanitized_fixture.sh` (retry + control-byte sanitize);
  - сгенерирован live-sanitized fixture `parity_04_pr_evidence_live_sanitized.json`;
  - добавлен executable parity suite `pr_evidence_parity_test.exs`;
  - собран evidence doc `docs/symphony-next/evidence/PARITY-04/PARITY-04_EVIDENCE_2026-04-26.md`.
- Что проверено:
  - `make symphony-preflight`
  - `make symphony-acceptance-preflight`
  - `mix format --check-formatted`
  - `mix test test/symphony_elixir/pr_evidence_parity_test.exs test/symphony_elixir/linear_routing_parity_test.exs test/symphony_elixir/issue_trace_parity_test.exs test/symphony_elixir/resume_legacy_parity_test.exs`
  - `mix test test/symphony_elixir/telemetry_schema_test.exs test/symphony_elixir/resume_checkpoint_test.exs test/symphony_elixir/core_test.exs`
- Что пошло не по плану:
  - `gh pr list --head` не дал стабильных соответствий для исторических head-веток в sampled dataset;
  - branch lookup live-cases зафиксированы через `issue_trace_url_fallback` (реальные issue branch + PR URL traces).
  - первичный CI прогон (`make-all/infra-pass`) упал на `@spec`/coverage gate для нового модуля;
  - добавлен отдельный exhaustive unit suite `pr_evidence_test.exs`, чтобы вернуть `make all` и global coverage к `100%`.
- Текущие блокеры/риски:
  - блокеров по `PARITY-04` нет.

## PARITY-04 Post-merge (2026-04-26)

- PR/merge:
  - PR: `https://github.com/maximlafe/symphony/pull/146`
  - merge commit: `a013737db4d78693f7f97550a9a9159998edb572`
- Post-merge sanity:
  - `make symphony-preflight` — pass
  - `mix test test/symphony_elixir/pr_evidence_parity_test.exs test/symphony_elixir/pr_evidence_test.exs` — pass
- Linear:
  - `LET-639` обновлён русским execution-worklog и переведён в `Done`.

## PARITY-05 Update (2026-04-26)

- Что сделано:
  - создан RU plan-spec (`docs/symphony-next/plans/PARITY-05_PLAN.md`) с Acceptance Matrix и 2 critique pass;
  - создан canonical contract (`docs/symphony-next/contracts/PARITY-05_FINALIZER_SEMANTICS_CONTRACT.md`);
  - добавлен deterministic fixture `parity_05_finalizer_semantics_matrix.json`;
  - добавлен live generator `scripts/generate_parity_05_live_sanitized_fixture.sh` (retry + control-byte sanitize + real LET sampling);
  - сгенерирован live-sanitized fixture `parity_05_finalizer_semantics_live_sanitized.json`;
  - добавлен executable parity suite `finalizer_semantics_parity_test.exs`;
  - собран evidence doc `docs/symphony-next/evidence/PARITY-05/PARITY-05_EVIDENCE_2026-04-26.md`.
- Что проверено:
  - `make symphony-preflight`
  - `make symphony-acceptance-preflight`
  - `mix format --check-formatted`
  - `mix test test/symphony_elixir/finalizer_semantics_parity_test.exs`
  - `mix test test/symphony_elixir/finalizer_semantics_parity_test.exs test/symphony_elixir/controller_finalizer_test.exs test/symphony_elixir/pr_evidence_parity_test.exs`
  - `make all`
- Что пошло не по плану:
  - первичный `make all` упал на complexity-gate в `finalizer_semantics_parity_test.exs`; live mapper декомпозирован на helper-функции, после чего lint/coverage/dialyzer снова зелёные.
- Текущие блокеры/риски:
  - implementation/evidence blockers отсутствуют.

## PARITY-05 Post-merge (2026-04-26)

- PR/merge:
  - PR: `https://github.com/maximlafe/symphony/pull/147`
  - merge commit: `45c97dce969cd57ec5bf02469250dded2510c729`
- Post-merge sanity:
  - `make symphony-preflight` — pass
  - `mix test test/symphony_elixir/finalizer_semantics_parity_test.exs` — pass
- Linear:
  - `LET-640` обновлён русским execution-worklog и переведён в `Done`.

## PARITY-06 Update (2026-04-26)

- Что сделано:
  - создан RU plan-spec (`docs/symphony-next/plans/PARITY-06_PLAN.md`) с Acceptance Matrix и 2 critique pass;
  - создан canonical contract (`docs/symphony-next/contracts/PARITY-06_MERGE_GATING_CONTRACT.md`);
  - merge-state gating в `HandoffCheck` переведён на fail-closed allowlist (`CLEAN`, `HAS_HOOKS`);
  - добавлен deterministic fixture `parity_06_merge_gating_matrix.json`;
  - добавлен live generator `scripts/generate_parity_06_live_sanitized_fixture.sh` (retry + control-byte sanitize);
  - сгенерирован live-sanitized fixture `parity_06_merge_gating_live_sanitized.json`;
  - добавлен executable parity suite `merge_gating_parity_test.exs`;
  - собран evidence doc `docs/symphony-next/evidence/PARITY-06/PARITY-06_EVIDENCE_2026-04-26.md`.
- Что проверено:
  - `make symphony-preflight`
  - `make symphony-acceptance-preflight`
  - `mix format --check-formatted`
  - `mix test test/symphony_elixir/merge_gating_parity_test.exs`
  - `mix test test/symphony_elixir/merge_gating_parity_test.exs test/symphony_elixir/handoff_check_test.exs test/symphony_elixir/finalizer_semantics_parity_test.exs`
  - `make all`
- Что пошло не по плану:
  - в live-generator один из retry-attempts к Linear дал `curl: (35)`; final retry завершился успешно и fixture сгенерирован.
- Текущие блокеры/риски:
  - implementation/evidence blockers отсутствуют; осталось завершить PR/CI/merge цикл.

## PARITY-06 Post-merge (2026-04-26)

- PR/merge:
  - PR: `https://github.com/maximlafe/symphony/pull/148`
  - merge commit: `16a0dbbf163b9ed79b87596abb5549c82cd22e26`
- Post-merge sanity:
  - `make symphony-preflight` — pass
  - `mix test test/symphony_elixir/merge_gating_parity_test.exs` — pass
- Linear:
  - `LET-641` обновлён русским execution-worklog и переведён в `Done`.

## PARITY-14 Update (2026-04-26)

- Что сделано:
  - создан RU plan-spec (`docs/symphony-next/plans/PARITY-14_PLAN.md`) с Acceptance Matrix и 2 critique pass;
  - создан canonical contract (`docs/symphony-next/contracts/PARITY-14_ACTIONABLE_REVIEW_FEEDBACK_CONTRACT.md`);
  - в `github_pr_snapshot` добавлены explicit поля:
    - `review_state_summary`,
    - `actionable_feedback_state`,
    - item-level `classification` для actionable feedback;
  - workflow guards (`ControllerFinalizer`, `HandoffCheck`) привязаны к
    `actionable_feedback_state` с legacy bool fallback;
  - добавлен deterministic fixture
    `parity_14_actionable_feedback_matrix.json`;
  - добавлен live generator
    `scripts/generate_parity_14_live_sanitized_fixture.sh` с retry и
    GitHub sampling;
  - сгенерирован live-sanitized fixture
    `parity_14_actionable_feedback_live_sanitized.json`;
  - добавлен executable parity suite
    `actionable_feedback_parity_test.exs`;
  - собран evidence doc
    `docs/symphony-next/evidence/PARITY-14/PARITY-14_EVIDENCE_2026-04-26.md`.
- Что проверено:
  - `scripts/generate_parity_14_live_sanitized_fixture.sh`
  - `make symphony-preflight`
  - `make symphony-acceptance-preflight`
  - `mix format --check-formatted`
  - `mix test test/symphony_elixir/actionable_feedback_parity_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/handoff_check_test.exs test/symphony_elixir/controller_finalizer_test.exs`
  - `make all`
- Что пошло не по плану:
  - нестабильный GitHub API (`EOF`/TLS) при live sampling; добавлены retry в
    generator и seed PR IDs с подтверждённым `CHANGES_REQUESTED` для
    воспроизводимого live-dataset.
  - первичный прогон `make all` падал из-за coverage gate 100%; закрыто
    точечными test-cases и удалением недостижимых fallback clauses.
- Текущие блокеры/риски:
  - implementation/evidence blockers отсутствуют; осталось завершить PR/CI/merge цикл.
