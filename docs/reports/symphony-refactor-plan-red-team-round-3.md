# Red Team Critique: symphony-refactor-plan Round 3

## Scope

- Цель раунда: проверить wording precision, internal coherence, contradiction/conflict scan, residual risk closure и то, действительно ли документ implementation-ready без скрытых допущений.
- Этот раунд отличается от round 1 и round 2: здесь нет повторной проверки SSOT hierarchy или execution-order architecture как таковых; проверяется только согласованность текущего текста и его готовность к исполнению.

## Critical Findings

### 1. Документ одновременно заявляет implementation-ready и оставляет скрытый execution gate

**Тип:** `verified issue`

План несколько раз позиционируется как implementation-ready, включая итоговый ledger [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:611). Но в residual/open issues still says:
- нужен call-graph hotspot-модулей,
- нужна карта test runtime cost,
- нужна отдельная red-team проверка sequencing перед кодовой реализацией
  [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:613).

Это не просто “future refinement”. Последний пункт по смыслу выглядит как обязательный pre-execution gate, а не как optional hardening. В текущем виде план не до конца честен о своей готовности: либо он implementation-ready уже сейчас, либо execution still depends on another critique gate.

### 2. Validation matrix и proof mapping местами используют placeholder-level proof targets вместо concrete proof contract

**Тип:** `verified issue`

После round 2 matrix стала богаче, но часть элементов все еще сформулирована как placeholders:
- `skill-alignment checks`
- `targeted AgentRunner proofs`
- `targeted mapping checks`
- `runtime/contract targeted proofs`
  [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:524), [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:528), [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:529), [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:533).

Для implementation-ready плана это слабое место: matrix уже перешла от концепции к execution contract, а proof targets still contain unnamed future test bundles. Пока эти bundles не привязаны хотя бы к конкретным test files / named slices / command forms, документ все еще требует implicit interpretation by executor.

### 3. Phase scoping around workflow/skills late-phase safety trigger is internally muddy

**Тип:** `verified issue`

`Phase 5` formally covers dashboard and Linear client isolation [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:464), but its late-phase safety trigger reaches out to “workflow или repo-local skills” changes [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:482).

That is directionally reasonable as a safety rule, but textually incoherent in the current plan shape:
- workflow/skills work is otherwise centered in Phase 1;
- Phase 5 scope is dashboard/Linear;
- the trigger sounds like a global policy, not a Phase-5-local rule.

Result: the reader cannot tell whether this is:
1. a universal dependency rule that should live in `Dependency And Order Constraints`, or
2. a local Phase 5 blocker only when dashboard/Linear work touches those surfaces.

### 4. The plan mixes measured facts and unmeasured labels in hotspot inventory

**Тип:** `verified issue`

The hotspot list starts as a line-count inventory, but `agent_runner.ex` is inserted as “execution-control hotspot on the orchestrator path” without the same measured basis [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:24). This is a small wording issue with larger coherence impact: the section now looks like a single evidence class, but it actually mixes measured size hotspots with semantic criticality hotspots without saying so.

That makes the inventory slightly misleading and introduces avoidable ambiguity into prioritization logic.

## Lower-Priority Findings

### 5. “Only this phase / strictly after this phase” wording is uneven across the document

**Тип:** `bounded concern`

Some sections use hard gating language precisely (`не стартует`, `запрещен`, `strictly after`), while others use softer phrasing like `желательно после` or `возможно, потребуется уточнить` around still-important execution choices [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:453), [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:606). The inconsistency does not break the plan, but it makes the enforcement strength of some rules less obvious than others.

### 6. Residual risks section is accurate, but not yet classified into “must resolve before execution” vs “can resolve during Phase 0”

**Тип:** `working criticism`

The residual risks are reasonable, but they are all listed together [symphony-refactor-plan.md](/Users/lafe/.codex/worktrees/3410/Symphony/docs/plans/symphony-refactor-plan.md:602). For a reader deciding whether execution may start, this leaves one last hidden assumption: are these blockers, or simply tracked preflight tasks? The current document implies the latter, but does not say it explicitly.

## Recommendations

1. Resolve the implementation-ready contradiction by clearly labeling residual items as either:
   - mandatory pre-execution gates, or
   - Phase 0 execution inputs that do not block plan readiness.
2. Replace placeholder proof targets with concrete test-file or command-level references wherever the matrix already expects execution.
3. Move or reword the workflow/skills late-phase safety trigger so it reads as either a global dependency rule or a narrowly scoped Phase 5 condition, not both.
4. Split hotspot inventory into two labels:
   - measured size hotspots;
   - semantically critical execution hotspots.
5. Normalize enforcement language so “required”, “strictly after”, “optional”, and “to be уточнен during Phase 0” are used consistently.

## Compact Fix List For Repair Round

1. Resolve implementation-ready vs residual-gate contradiction.
2. Replace placeholder proof targets with concrete proof references.
3. Clarify the scope of the workflow/skills late-phase safety trigger.
4. Separate measured hotspots from semantically critical hotspots in wording.
5. Classify residual risks and normalize enforcement language.

## Ledger

- **Target document:** `docs/plans/symphony-refactor-plan.md`
- **Focus used:** wording precision, internal coherence, contradiction/conflict scan, residual risk closure, and implementation-readiness without hidden assumptions
- **Main findings:** implementation-ready claim conflicts with residual gating language; some proof targets remain placeholders; Phase 5 contains a global-looking workflow/skills trigger inside a local phase; hotspot inventory mixes measurement types without saying so
- **Exact ordered fix list for repair round:** `1) implementation-ready contradiction`, `2) concrete proof targets`, `3) trigger scope clarification`, `4) hotspot wording split`, `5) residual-risk classification and enforcement wording`
