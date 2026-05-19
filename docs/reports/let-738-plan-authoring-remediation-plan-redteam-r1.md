# Red Team Round 1 — LET-738 Plan Authoring Remediation

## Phase 1: Problem Definition

- Core problem: проверить, закрывает ли remediation-план все зависимости/пререквизиты/интерфейсные последствия для цепочки `workflow -> skill -> tests` без новых сущностей.
- Scope: только документ `/docs/reports/let-738-plan-authoring-remediation-plan.md` и его заявленные изменения в существующих файлах.
- Out of scope: внедрение самих правок и оценка UX/стиля.
- Success criteria: найти несоответствия, которые оставят конфликты после выполнения плана, и дать упорядоченный fix-list для repair-round.
- Evidence boundary: только repo-grounded факты из текущих файлов/строк.

## Phase 2: Expert Assembly

- Team size: 4.
- Role mix:
  - Critic · Contract Consistency (приоритет `project-contract` и обязательные поля).
  - Critic · Parser/Interface Impact (влияние на текущие парсеры/гейты).
  - Balanced · Test Strategy (достаточность regression-proof по месту изменения).
  - Evangelist · Minimal-change Integrator (минимальные правки без новых сущностей).
- Evidence boundary: локальные файлы, без предположений о внешнем поведении.

## Iteration (Executor-grounded critique)

### Mechanism Audit (required)

Target makes a strong guarantee claim: “остаточные конфликтные требования отсутствуют”
([let-738-plan-authoring-remediation-plan.md:166](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:166)).

1. Explicit promise:
- После выполнения плана конфликтов/рисков не останется.

2. What mechanism actually guarantees now:
- План ограничен prose+skill+contract-test текстом ([...remediation-plan.md:89-131](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:89), [...:125-131](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:125)).
- В runtime уже есть потребители, чувствительные к формату description/markers:
  - `extract_symphony_marker` читает `## Symphony` до следующего H2
    ([let.WORKFLOW.md:277-299](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:277)).
  - machine-readable поля для two-layer контракта извлекаются regex’ом по всему markdown
    ([handoff_check.ex:1309-1315](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/handoff_check.ex:1309)).

3. Where stronger reading fails:
- Ниже перечислены P0 gaps: обещание “конфликтов не останется” не следует из предложенного механизма.

4. Minimal fix set:
- см. Ordered fix list в конце (P0/P1 разделение).

## Findings

## Critical findings (P0)

1. **`Residual Risks` остаётся недоопределённым относительно `project-contract`** (`verified issue`).
- План маппит `Residual Risks` на `Заметки`
  ([...remediation-plan.md:55](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:55)).
- Но в workflow `Заметки` сейчас опциональны (“добавляй только если нужны”)
  ([let.WORKFLOW.md:1089-1091](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:1089)).
- В `project-contract` short plan должен сохранять canonical fields,
  включая `Residual Risks` ([project-contract.md:44-45](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md:44)).
- Следствие: даже после правок можно получить валидный по workflow description без явного residual-risks эквивалента.

2. **Правило “`## Symphony` = last H2 + trailing uploads allowed” не закрывает интерфейсный риск текущего парсера** (`verified issue`).
- План допускает trailing non-heading media после `## Symphony`
  ([...remediation-plan.md:66-69](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:66)).
- Текущий parser `extract_symphony_marker` продолжает читать секцию до следующего H2
  ([let.WORKFLOW.md:281-286](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:281)).
- Marker-matching делается по строкам внутри этой области ([...:287-298](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:287)); значит trailing контент может расширять parse-surface и вызывать ложные marker collisions.
- Следствие: заявленное снятие конфликта C неполное без parse-safe ограничения или parser hardening.

3. **Proof strategy недостаточна для заявленной “first-pass correctness” гарантии** (`verified issue`).
- План ограничивает proof в основном текстовыми assert’ами workflow/skill
  ([...remediation-plan.md:125-131](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:125), [...:146-155](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:146)).
- Но критичные интерфейсы проверки/потребления description живут в runtime code-path:
  - `dynamic_tool.ex` (mode:plan description write guard по AM)
    ([dynamic_tool.ex:1890](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1890));
  - `handoff_check.ex` two-layer extraction/validation
    ([handoff_check.ex:1289-1315](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/handoff_check.ex:1289));
  - `spec_check.ex` spec gate semantics
    ([spec_check.ex:522](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/spec_check.ex:522)).
- Следствие: текстовый drift можно поймать, но interface regression (parse/consume path) остаётся непокрытым.

## Lower-priority findings (P1)

1. **Не описана совместимость для legacy `plan-mode` без `mode:plan` label** (`bounded concern`).
- В workflow есть legacy path и mode-routing нюансы
  ([let.WORKFLOW.md:792-794](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:792)).
- План концентрируется на `mode:plan`, но не фиксирует, какие из authoring-правил должны наследоваться legacy-spec-prep path.

2. **Не зафиксирован критерий “done” для claims об отсутствии residual conflicts** (`working criticism`).
- В документе есть абсолютное утверждение `none`
  ([...remediation-plan.md:184](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:184)),
  но нет explicit acceptance-критерия, проверяющего runtime parse safety и end-to-end consume safety.

## Recommendations

1. Внести P0-правку на уровень workflow/skill: сделать residual-risks эквивалент обязательным для `mode:plan` (не опциональным).
2. Для конфликта C выбрать один из двух минимальных путей и зафиксировать явно:
- либо строго запретить любой trailing text/media после `## Symphony`;
- либо harden существующий parser `extract_symphony_marker` так, чтобы он парсил только contiguous marker-block и игнорировал trailing non-marker lines.
3. Расширить proof-план минимум одним interface-level regression check для parse/consume path (`dynamic_tool`/`handoff_check`/`spec_check`), а не только текстовыми assert’ами.

## Compact ledger

- Target document:
  - `/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md`
- Focus used:
  - completeness/correctness of dependencies, prerequisites, and interface impacts across workflow/skill/test changes.
- Main findings:
  - 3 critical (P0): unresolved `Residual Risks` contract mapping; unresolved parser/interface risk for `## Symphony` trailing content; insufficient interface-level proof strategy.
  - 2 lower-priority (P1): legacy-path inheritance ambiguity; unsupported absolute “no residual issues” claim.
- Exact ordered fix list for repair round:
  1. **P0**: Rewrite mapping so `Residual Risks` equivalent is mandatory in `mode:plan` description contract (workflow + plan-mode wording + tests).
  2. **P0**: Resolve `## Symphony` trailing-content interface risk by choosing and documenting one parse-safe contract (strict no-trailing or parser hardening), then align tests.
  3. **P0**: Add interface-level regression coverage for description parse/consume path (`dynamic_tool` and/or `handoff_check`/`spec_check`) tied to the updated authoring contract.
  4. **P1**: Explicitly state inheritance of updated authoring rules for legacy spec-prep path.
  5. **P1**: Replace absolute “none” residual claim with bounded claim contingent on passing the new interface-level proof.
