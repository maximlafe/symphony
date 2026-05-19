# Red Team Critique: LET Single Mechanism First-Pass Unification Plan (2026-05-19)

Target document:
- `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`

Round:
- 3 of 3

Focus:
- wording precision, consistency of vocabulary across stages, and internal coherence

## Phase 1: Problem Definition

- Core problem: the target document still uses overlapping lifecycle nouns and success phrases without fully pinning down which term owns which stage, which makes hidden term drift possible even when the broader mechanism looks aligned.
- Scope: critique only wording precision, stage vocabulary consistency, and internal coherence.
- Out of scope: new gates, new entities, new scripts, or a lifecycle redesign.
- Success criteria: identify where the document reuses a term across stages without an explicit equivalence rule, or where it assigns one stage's semantics to another stage.
- Missing information: whether the author intended `task-spec`, `issue-description`, and `short plan` to be aliases; the document does not state that directly.

## Phase 2: Expert Assembly

- Team size: 4
- Role mix: 2 critics, 1 balanced synthesizer, 1 implementation-focused critic
- Evidence boundary: local files only, with claims grounded in the target document and the referenced contract/workflow/skill files

## Audit Result

### Critical Findings

1. `verified issue` - the success criterion conflates two different lifecycle products
   - The document says: "the first persisted task-spec / handoff state is already valid".
   - That phrase collapses the persisted task-spec and the later handoff state into a single success object, but the workflow and contract elsewhere treat spec prep and execution handoff as different stages with different owners.
   - Why this matters: first-pass correctness can be claimed only if the reader knows whether success applies to the initial persisted task-spec, the later handoff state, or both. The current wording leaves that ambiguous, so the success criterion can be read as already satisfied by the wrong stage.
   - Affected lines: target document lines 20-24, 34-47, 122-141, and 195-217.
   - Impact: the document can appear internally consistent while still allowing a false "done" reading that actually proves only one side of the lifecycle.

2. `working criticism` - step 2 in the repair order blurs stage ownership by assigning checkpoint semantics to plan-mode
   - The repair order says: "Make `plan-mode` and `execute-mode` reference the same proof and checkpoint semantics."
   - `plan-mode` owns spec-prep shaping and proof authoring, while checkpoint semantics belong to execution handoff and `In Review` / `Blocked` routing.
   - Why this matters: the sentence suggests that `plan-mode` should reference checkpoint semantics in the same way as `execute-mode`, but the rest of the document says checkpoints are classified only where execution handoff exists.
   - Affected lines: target document lines 80-86, 122-141, and 178-193.
   - Impact: this is hidden term drift across stages. The wording suggests a shared semantic surface where the contract actually has a stage-specific boundary.

### Lower-Priority Findings

1. `bounded concern` - the document uses multiple nouns for the plan artifact without an explicit alias rule
   - The text alternates between `task-spec`, `issue-description`, `short plan`, `canonical task-spec template`, and `first persisted` state.
   - The document implies these are related, but it never states a simple equivalence such as "in this plan, `task-spec` means the persisted issue description" or "the short plan is the canonical task-spec body for `mode:plan`".
   - Why this matters: without a glossary-like bridge, readers can drift between thinking about the authored text, the persisted issue body, the plan-mode contract, and the execution handoff as separate or interchangeable objects.
   - Affected lines: target document lines 18-30, 53-69, 122-141, and 197-217.

2. `bounded concern` - the end-state vocabulary repeats the same idea with slightly different success phrases
   - The document uses `first-pass correctness`, `first valid path`, `canonical path`, and `already canonical path` as if they were one invariant.
   - Those phrases are close, but they are not identical: one is a claim about the repair pass, one is about runtime traversal, and one is about the canonicality of the path.
   - Why this matters: the document reads cleaner than it is. The reader has to infer that all four phrases mean the same success condition, but the text never nails that down.
   - Affected lines: target document lines 20-24, 187, 200, and 217-240.

### Recommendations

1. Add an explicit alias rule for `task-spec`, `issue-description`, and `short plan` if they are intended to describe the same persisted body in different stages.
2. Rewrite the repair-order checkpoint sentence so `plan-mode` is tied to proof authoring only, while checkpoint semantics remain exclusive to execution handoff.
3. Choose one success phrase for the document and reuse it consistently instead of rotating among `first-pass correctness`, `first valid path`, and `canonical path`.
4. If the document intends `task-spec / handoff state` to be one concept, state the equivalence explicitly rather than leaving it to inference.

## Mechanism Audit

### What the target explicitly promises

- one canonical vocabulary across LET stages;
- one ownership boundary per surface;
- first-pass correctness rather than repair-after-the-fact consistency;
- a single canonical path through the system.

### What the mechanism actually guarantees in the document

- the document has a coherent high-level intent;
- the ownership map and proof sequence are better aligned than before;
- the wording still leaves some stage nouns and success phrases underspecified.

### Where the stronger reading fails

- `task-spec / handoff state` is not pinned to one lifecycle product;
- checkpoint semantics are phrased as if plan-mode owns them;
- multiple synonyms are used for the same success condition without an explicit alias rule;
- the reader must infer which term names the canonical persisted artifact.

### Minimal Fix Set

- `P0`: separate the persisted task-spec from the later handoff state in the success criterion.
- `P0`: remove checkpoint semantics from the `plan-mode` repair-order wording.
- `P1`: add an explicit alias rule for the artifact nouns used across stages.
- `P1`: normalize the success phrases to one canonical wording.

## Route Ledger

- `ACTIVE`: stage-product distinction
- `ACTIVE`: checkpoint semantics wording
- `SUPPORTING`: artifact noun aliasing
- `SUPPORTING`: success phrase normalization

## Ordered Fix List for Repair Round

1. Split the success criterion so it distinguishes the initial persisted task-spec from the later handoff state.
2. Rewrite the `plan-mode` / `execute-mode` repair-order sentence so only `execute-mode` carries checkpoint semantics.
3. Add an explicit alias rule for `task-spec`, `issue-description`, `short plan`, and `canonical task-spec template` if they are meant to refer to the same persisted artifact.
4. Normalize the success vocabulary to one canonical phrase and use it consistently in the repair order, validation bar, and end state.
5. Re-read the document end to end after those wording fixes and verify that no stage now implies ownership of another stage's semantics.

## Compact Ledger

- Target document: `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`
- Focus used: wording precision, consistency of vocabulary across stages, and internal coherence
- Main findings:
  - critical: success criterion conflates the persisted task-spec with the later handoff state
  - critical: repair-order wording gives `plan-mode` checkpoint semantics it should not own
  - lower priority: artifact nouns drift without an explicit alias rule
  - lower priority: success phrases drift without one canonical wording
- Exact ordered fix list:
  1. Split the success criterion so it distinguishes the initial persisted task-spec from the later handoff state.
  2. Rewrite the `plan-mode` / `execute-mode` repair-order sentence so only `execute-mode` carries checkpoint semantics.
  3. Add an explicit alias rule for `task-spec`, `issue-description`, `short plan`, and `canonical task-spec template` if they are meant to refer to the same persisted artifact.
  4. Normalize the success vocabulary to one canonical phrase and use it consistently in the repair order, validation bar, and end state.
  5. Re-read the document end to end after those wording fixes and verify that no stage now implies ownership of another stage's semantics.
