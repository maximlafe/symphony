# Red Team Critique: LET Single Mechanism First-Pass Unification Plan (2026-05-19)

Target document:
- `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`

Round:
- 2 of 3

Focus:
- execution order, rollback/failure modes, and adequacy of tests/verification proving first-pass correctness

## Phase 1: Problem Definition

- Core problem: the target document claims first-pass correctness, but it does not yet define a failure-aware execution sequence or a minimally sufficient verification sequence that would make that claim falsifiable.
- Scope: critique only the repair order, rollback/failure handling, and verification adequacy in the document.
- Out of scope: adding new gates, entities, scripts, or expanding the LET lifecycle.
- Success criteria: identify where the document lacks a safe repair boundary, where a failed step would leave the plan ambiguous, or where the verification story is too weak to prove first-pass correctness.
- Missing information: whether the author expects the document itself to be executable as a change plan or only to describe the change intent; the current text reads like an executable plan.

## Phase 2: Expert Assembly

- Team size: 4
- Role mix: 2 critics, 1 balanced synthesizer, 1 implementation-focused critic
- Evidence boundary: local files only, grounded in the target document and its referenced contract/workflow/skill files

## Audit Result

### Critical Findings

1. `verified issue` - no explicit rollback boundary for the ordered repair sequence
   - The document now has a six-step `Recommended Repair Order`, but it does not say what happens if step 2, 3, 4, or 5 invalidates the assumptions introduced by earlier steps.
   - There is no rollback/failure-mode section attached to the order, and no "stop here / revert to here" rule for the repair chain.
   - Why this matters: the document's central claim is first-pass correctness, which requires a safe failure boundary. Without one, a later step can quietly invalidate earlier steps, and the plan has no declared recovery rule.
   - Affected lines: target document lines 178-187 and 191-200.
   - Impact: the repair round itself becomes non-deterministic. If a later alignment change breaks a test or invalidates an ownership assumption, the document gives no explicit instruction for whether to pause, revert the last step, or accept partial alignment.

2. `working criticism` - verification is described, but not staged as a proof sequence that can actually establish first-pass correctness
   - The `Validation Bar` names `let_workflow_contract_test.exs`, `spec_check_test.exs`, and `handoff_check_test.exs`, but it does not define an ordered proof chain or indicate which assertions are the minimal red/green proof for each change slice.
   - The current wording says the tests should "assert the same field names" and "prove the exact issue-description template", but it does not say which test is the gate for which repair step, or what failure should block progression to the next step.
   - Why this matters: first-pass correctness is not proved by listing relevant tests. It is proved by showing the smallest sequence of checks that establishes the mechanism is already canonical before any later fix has to compensate.
   - Affected lines: target document lines 189-200.

### Lower-Priority Findings

1. `bounded concern` - rollback and compatibility modes are still not differentiated in the residual risk story
   - The residual open issues mention compatibility fallback, runtime call sites, swarm-assist assumptions, and helper-copy tests, but they are not tied back to a concrete rollback or stop condition.
   - Why this matters: an audit list is not the same thing as a failure mode. The document still lacks a rule for what to do when one of those open issues actually fails during repair or verification.
   - Affected lines: target document lines 202-207.

2. `bounded concern` - verification coverage mixes consumer alignment with proof adequacy, but does not separate them
   - The validation bar correctly mentions route entrypoints, validators, and runtime enforcers, but it does not distinguish between:
     - verifying the ownership map is complete;
     - verifying the canonical text shape is correct;
     - verifying runtime enforcement rejects the same invalid shapes.
   - Why this matters: when those concerns are collapsed, a passing test can be mistaken for proof of first-pass correctness even if it only proves one slice of the mechanism.
   - Affected lines: target document lines 193-198.

### Recommendations

1. Add an explicit rollback/failure-mode rule to the repair order so each step has a stop or revert boundary.
2. Turn the `Validation Bar` into an ordered proof sequence: what is checked first, what must fail/green at each slice, and what blocks progression.
3. Tie residual open issues to concrete stop conditions instead of leaving them as a loose audit list.
4. Separate ownership-map completeness checks from canonical-text checks and runtime-enforcement checks in the verification story.

## Mechanism Audit

### What the target explicitly promises

- a first-pass correct LET mechanism;
- a single canonical vocabulary and ownership boundary;
- tests that prove the same behavior the docs claim;
- a first valid path through the system that is already canonical.

### What the mechanism actually guarantees in the document

- the document has a linear repair order;
- it names the key consumer tests and runtime layers;
- it does not yet define a failure boundary or a proof sequence strong enough to make first-pass correctness falsifiable.

### Where the stronger reading fails

- a later repair step can invalidate an earlier assumption with no rollback rule;
- the tests are named, but the proof path is not staged;
- residual open issues are tracked, but not converted into stop/rollback conditions;
- "first valid path" remains an aspiration unless the verification order is tied to the repair order.

### Minimal Fix Set

- `P0`: define rollback/failure boundaries for the ordered repair sequence.
- `P0`: define the verification sequence as a minimal proof chain, not just a list of relevant tests.
- `P1`: bind residual issues to explicit stop conditions.
- `P1`: separate ownership-map validation from runtime-proof validation.

## Route Ledger

- `ACTIVE`: rollback/failure boundary
- `ACTIVE`: proof-sequence adequacy
- `SUPPORTING`: residual-issue stop conditions
- `SUPPORTING`: verification-slice separation

## Ordered Fix List for Repair Round

1. Add an explicit rollback/failure-mode rule to the repair order so each step has a stop or revert boundary.
2. Turn the `Validation Bar` into an ordered proof sequence: what is checked first, what must fail/green at each slice, and what blocks progression.
3. Tie residual open issues to concrete stop conditions instead of leaving them as a loose audit list.
4. Separate ownership-map completeness checks from canonical-text checks and runtime-enforcement checks in the verification story.
5. Re-run the document's own first-pass claim only after the repair order and proof sequence are both failure-aware.

## Compact Ledger

- Target document: `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`
- Focus used: execution order, rollback/failure modes, and adequacy of tests/verification proving first-pass correctness
- Main findings:
  - critical: no explicit rollback boundary for the ordered repair sequence
  - critical: verification is listed but not staged as a proof sequence
  - lower priority: residual issues are not tied to stop conditions
  - lower priority: verification mixes ownership completeness with proof adequacy
- Exact ordered fix list:
  1. Add an explicit rollback/failure-mode rule to the repair order so each step has a stop or revert boundary.
  2. Turn the `Validation Bar` into an ordered proof sequence: what is checked first, what must fail/green at each slice, and what blocks progression.
  3. Tie residual open issues to concrete stop conditions instead of leaving them as a loose audit list.
  4. Separate ownership-map completeness checks from canonical-text checks and runtime-enforcement checks in the verification story.
  5. Re-run the document's own first-pass claim only after the repair order and proof sequence are both failure-aware.
