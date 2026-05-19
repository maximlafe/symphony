# Red-Team Critique: LET Single Mechanism First-Pass Unification Plan

Round 2 of 3

Focus: execution-order reliability and proof adequacy of the newly added closure evidence. Question: can each of the 4 closed points be independently verified and replayed?

## Phase Snapshot

- Target: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md)
- Repair source: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.redteam-pass3-r1.md`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.redteam-pass3-r1.md)
- Evidence boundary: local repo files only
- Result typing: verified issue, bounded concern, working criticism

## Critical Findings

### 1) The closure addendum is evidence-backed, but not replayable as an execution order

**Status:** `verified issue`

The new `Closed with evidence` subsections in the target doc are readable, but they are not independently replayable. They cite supporting files, yet they do not state a deterministic verification order, a search boundary, or a minimal replay procedure for each closure.

- The addendum begins at [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:248`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L248) and then lists four closure statements at [`...:250-283`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L250), but it never says how a reviewer should replay the closure checks in order.
- The closure language is therefore declarative, not procedural: it says the points are closed, but does not specify the exact evidence collection sequence that would reproduce that conclusion without re-reading the entire branch of surrounding prose.
- That is a proof adequacy problem, not just a style issue, because the user asked whether each point can be independently verified and replayed. The current addendum does not yet supply that independence.

### 2) The runtime call-site closure overstates completeness relative to the evidence shown

**Status:** `verified issue`

The target doc closes the runtime call-site inventory at [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:258-265`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L258) using a small set of anchors from `controller_finalizer.ex` and `dynamic_tool.ex`. Those anchors do show real consumers and dispatchers, but they do not by themselves establish an exhaustive inventory.

- [`elixir/lib/symphony_elixir/controller_finalizer.ex:96`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L96), [`...:106`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L106), [`...:135`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L135), and [`...:304`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L304) are all single-module call sites.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:397`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L397) and [`...:484`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L484) prove dispatch and executor existence, but not that no other runtime consumer exists elsewhere in the repo.
- Because the target doc does not record the search query or the completion criterion for the inventory, the claim cannot be independently replayed from the evidence set alone. A later reviewer would have to infer that completeness from prose rather than verify it from a bounded audit recipe.

### 3) The helper-copy alignment closure is internally mixed and therefore not independently verifiable

**Status:** `working criticism`

The target doc closes helper-copy alignment at [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:276-283`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L276), but the cited evidence itself mixes canonical-surface assertions with helper-file reads.

- [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:18`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L18) exercises the live workflow contract.
- [`...:48`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L48) and [`...:49`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L49) assert the canonical `Acceptance Matrix` and `Proof Mapping` sections.
- But [`...:159`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L159) explicitly reads skill surfaces and the contract file itself, and the later closure text at [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:282-283`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L282) reclassifies those reads as "compatibility evidence only" without proving that distinction from the test structure alone.
- The result is a closure statement that depends on interpretation: the target doc says helper-file reads are secondary, but the evidence bundle does not separate canonical proof from helper-copy smoke in a way that can be replayed mechanically.

## Lower-Priority Findings

### 4) The swarm-assisted branch-contract closure is supportable, but it is still prose-led rather than replay-led

**Status:** `bounded concern`

The branch-contract subsection at [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:267-274`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L267) is directionally correct: it points to the two-layer contract, the SSOT rule, and the compatibility-baseline wording in workflow. The problem is execution-order reliability.

- The cited anchors are all prose surfaces: [`docs/policy/project-contract.md:34`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L34), [`...:66`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L66), [`...:71`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L71), [`...:74`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L74), and workflow anchors at [`workflows/letterl/maxime/let.WORKFLOW.md:794-799`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md#L794).
- That is enough to justify the claim at the document level, but not enough to make it replayable as an independent branch-contract verification. There is still no explicit checklist of the environment condition being replayed, so the closure is weaker than the label suggests.

## Recommendations

1. Add a per-item replay recipe under each closure subsection: what exact file set or search scope a reviewer should inspect, and in what order.
2. Split the runtime inventory into "observed call sites" and "exhaustive inventory" or else provide a stated exhaustive-search boundary that proves completeness.
3. Separate canonical proof evidence from helper-copy smoke evidence so the test-alignment closure can be replayed without inference.
4. Make the swarm-assisted branch-contract closure name the exact environment condition or branch discriminator that was checked, not just the prose surfaces that describe it.

## Ledger

- Target document: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md)
- Focus: execution-order reliability and proof adequacy of the closure evidence
- Main findings:
  - closure evidence is declarative, not replayable as written;
  - runtime call-site closure overstates completeness relative to the anchors shown;
  - helper-copy alignment mixes canonical proof and helper-file smoke;
  - branch-contract closure is supportable but still prose-led
- Exact ordered fix list for the repair round:
  1. Add a deterministic replay order for each closure subsection.
  2. Tighten the runtime inventory to an explicitly exhaustive boundary or downgrade it to observed-call-site coverage.
  3. Separate canonical test proof from helper-copy compatibility smoke.
  4. Name the exact environment or branch discriminator for the swarm-assisted contract closure.
