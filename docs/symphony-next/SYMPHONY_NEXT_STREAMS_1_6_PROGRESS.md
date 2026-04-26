# Symphony Next Streams 1-6 Progress

## Baseline (2026-04-26)

- Target repo (user path): `/Users/lafe/Dev/LL/Symphony`
- Execution worktree (clean `main` synced with `origin/main`): `/tmp/symphony-parity-main`
- Baseline source branch in user repo with local changes preserved:
  - `codex/hegemonikon-symphony-integration`
  - local modified/untracked files were **not** overwritten
- `main` sync status in execution worktree:
  - `main` fast-forwarded to `origin/main` (`b6a7344`)
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
| `PARITY-01` | Stream 1 | `in_review_prep` | `parity/parity-01-freeze-linear-routing-contract` | `-` | `-` | `docs/symphony-next/evidence/PARITY-01/PARITY-01_EVIDENCE_2026-04-26.md` | `pending PR/CI/merge` |
| `PARITY-02` | Stream 1 | `todo` | `-` | `-` | `-` | `-` | `-` |
| `PARITY-03` | Stream 1 | `todo` | `-` | `-` | `-` | `-` | `-` |
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
  - блокеров на уровне implementation/evidence нет; остались шаги PR/CI/merge.
