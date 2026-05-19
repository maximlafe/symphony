# LET-738 `mode:plan` RCA Red-Team Round 3

## Scope For This Round
- Focus: wording precision, consistency, and internal coherence.
- Constraint: proposed fixes must stay within existing mechanisms only; no new entities, no new scripts, no new policy layer.

## Problem Frame
The target RCA now has a workable structure, but it still leaks precision at the language boundary. The remaining issues are not about missing mechanism coverage; they are about whether the document names the existing mechanisms consistently enough for a reader to execute the repair without guessing.

## Critical Findings

### 1) `plan-skill` is a terminology error that breaks coherence with the rest of the document
The Execution Order section says to rerun the existing `SpecCheck` and `plan-skill` contract coverage before touching tracker behavior ([let-738-mode-plan-rca.md:55](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L55)). That wording is not coherent with the rest of the RCA or the repo terminology:
- the repo-local planning mechanism is `plan-mode`, not `plan-skill` ([let-738-mode-plan-rca.md:10](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L10), [let_workflow_contract_test.ex:146](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L146));
- the actual test artifact cited later is `let_workflow_contract_test.exs:152-163`, not a `plan-skill` suite ([let-738-mode-plan-rca.md:64](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L64)).

Why this matters:
- The reader cannot tell whether `plan-skill` is supposed to mean a skill file, a test suite, or a shorthand for `let_workflow_contract_test`.
- The document’s own repair order becomes ambiguous because the first step names a non-existent or at least undocumented verification surface.
- This is a wording precision failure, but it is severe enough to affect internal coherence.

Status: `verified issue`

### 2) The repeated `SpecCheck` references blur shared baseline coverage versus step-specific coverage
The Execution Order section uses `SpecCheck` in both the writer and guard steps ([let-738-mode-plan-rca.md:55-56](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L55), [let-738-mode-plan-rca.md:56](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-rca.md#L56)). That is technically plausible, but the current wording makes it look as if `SpecCheck` is a distinct proof target for two different layers instead of a shared baseline suite.

Why this matters:
- The document already has a separate row for writer repair and guard preservation in the Test Coverage Map ([let-738-mode-plan-rca.md:64-65](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-rca.md#L64), [let-738-mode-plan-rca.md:65](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-rca.md#L65)).
- Without a clear statement that `SpecCheck` is shared baseline coverage, the step numbering implies a stronger separation than the tests actually express.
- That makes the execution sequence harder to read and easier to misapply.

Status: `working criticism`

## Lower-Priority Findings

### 1) The bounded-retry preservation sentence is grammatically detached from step 3
The sentence "The current bounded retry / continuation behavior is preserved here and is not being redesigned" sits under step 3 as a standalone line ([let-738-mode-plan-rca.md:48](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L48)). It is understandable, but it reads like an aside rather than part of the validation rule for the tracker step.

Status: `bounded concern`

### 2) The residual buckets use overlapping terms for different kinds of incompleteness
The residual section now splits into `Unfixed`, `Untested`, and `Still Inferred`, which is better than before, but the `Untested` bucket currently includes a statement about implementation order being described but not proven ([let-738-mode-plan-rca.md:60-61](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L60)). That is a process claim, not a test claim, so the bucket labels still blur execution uncertainty with evidence uncertainty.

Status: `bounded concern`

## Recommendations
1. Replace `plan-skill` with the actual existing verification surface name and align the step text with the test map.
2. Mark `SpecCheck` as shared baseline coverage where it is repeated, rather than implying it is step-specific twice.
3. Attach the bounded-retry preservation sentence directly to the tracker step as a validation rule.
4. Reword the residual buckets so `Untested` refers only to missing proof and not to unexecuted sequencing.

## Exact Ordered Fix List For The Repair Round
1. Replace `plan-skill` in the Execution Order section with the actual existing suite or contract surface name used elsewhere in the RCA.
2. Add one short clause stating that `SpecCheck` is shared baseline coverage, not a distinct writer-only or guard-only proof source.
3. Fold the bounded-retry preservation sentence into the tracker step as part of the validation expectation.
4. Tighten the residual bucket labels so `Untested` is reserved for missing proof and the sequencing note moves to `Unfixed` or a separate process note.

## Compact Ledger
- Target document: `/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md`
- Focus used: wording precision, consistency, and internal coherence
- Main findings:
  - `plan-skill` is an incoherent term in the repair sequence
  - repeated `SpecCheck` references blur shared baseline coverage versus step-specific coverage
  - residual bucket labels still overlap process uncertainty and evidence uncertainty
- Exact ordered fix list for the repair round:
  1. replace `plan-skill` with the actual suite / contract surface name
  2. mark `SpecCheck` as shared baseline coverage
  3. attach bounded-retry preservation to the tracker step
  4. tighten residual bucket labels
