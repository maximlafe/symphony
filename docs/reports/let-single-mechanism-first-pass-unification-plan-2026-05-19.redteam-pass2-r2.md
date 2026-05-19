# Red Team Critique, Pass 2 Round 2

Target: `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`

Focus: execution order, rollback/failure modes, and test/verification adequacy for first-pass correctness.

Result type: critique-first review, not a repair spec.

## Active Critique Routes

- `ACTIVE`: rollback/failure-mode claims are not tied to the stated proof sequence.
- `ACTIVE`: execution order is described, but the repair-to-test dependency chain is still underspecified.
- `SUPPORTING`: the proof bar is broader than the current test coverage signal.

## Critical Findings

1. The rollback/failure-mode promise is not actually proven by the validation bar.
   - Evidence: the plan says that if a later step invalidates an earlier ownership, proof, or precedence assumption, the process should stop at the first inconsistent step and preserve the last consistent state (`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:207-211`).
   - The validation bar that claims to establish `first-pass correctness` does not include any rollback-specific slice or test source; it only enumerates ownership-map completeness, canonical text shape, runtime enforcement shape, and end-to-end consistency (`docs/reports/...:213-233`).
   - The repo already has rollback-oriented coverage that would be the natural proof anchor for this promise, including `execution_rollout_test.exs` rollback cases and rollback/Spec Review bounce behavior in `dynamic_tool_test.exs` (`elixir/test/symphony_elixir/execution_rollout_test.exs:76, 207-236`; `elixir/test/symphony_elixir/dynamic_tool_test.exs:2084-2246`).
   - Why this matters: the document treats rollback as part of the mechanism, but the proof sequence never names a concrete rollback check. That leaves the strongest failure-mode claim unsupported, which is a direct gap in first-pass correctness.

2. The execution-order story is not enforced as a dependency chain between repair steps and verification steps.
   - Evidence: the recommended repair order is linearized into six steps (`docs/reports/...:188-195`), and the rollback text says later steps must not proceed until earlier dependencies are revalidated (`docs/reports/...:199-203`).
   - But the validation bar is still organized as four aggregate proof slices, not as step-by-step checkpoints for the ordered repair path (`docs/reports/...:213-233`). There is no explicit statement that step 1, step 2, step 3, etc. each have a concrete revalidation artifact before the next step can begin.
   - Why this matters: the plan can be followed in sequence while still letting an early step silently regress, because the document does not bind each repair step to a specific proof source or stop condition. In practice, that makes the order advisory rather than mechanically enforced.

## Lower-Priority Findings

1. The proof bar underuses the existing rollback evidence already present in the repo.
   - Evidence: the repo’s rollback-focused tests are visible and named, but the document’s validation bar never cites them by source (`elixir/test/symphony_elixir/execution_rollout_test.exs:76, 207-236`; `elixir/test/symphony_elixir/dynamic_tool_test.exs:2084-2246`).
   - Why this matters: the plan currently asks reviewers to trust an abstract failure-mode statement instead of pointing at the tests that already demonstrate rollback behavior. That weakens the verification story without adding any new mechanism.

2. The end-to-end consistency slice is too coarse to diagnose order-versus-rollback failures.
   - Evidence: slice 4 groups `execute-mode`, merge/watcher behavior, and consumer/producer name alignment into one final gate (`docs/reports/...:226-228`).
   - Why this matters: when that aggregate slice fails, the repair round cannot tell whether the problem is ordering, rollback preservation, or test coverage. The result is a diagnostic bottleneck, not a proof of first-pass correctness.

## Recommendations

1. Add the existing rollback-oriented tests to the validation bar so the stop-and-preserve-last-consistent-state claim is proved, not just stated.
2. Bind each repair-order step to an explicit revalidation checkpoint so a later step cannot silently invalidate an earlier one.
3. Split the end-to-end consistency slice into separately named proof responsibilities, or explicitly label it as aggregate-only and list its concrete proof sources.

## Compact Ledger

- Target document: `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`
- Focus used: execution order, rollback/failure modes, and test/verification adequacy for first-pass correctness
- Main findings: rollback is asserted but not proven; repair order is linear but not checkpointed; verification is too coarse to diagnose failure-mode regressions
- Exact ordered fix list for repair round:
  1. Add the existing rollback-oriented tests to the validation bar.
  2. Tie each repair-order step to a concrete revalidation checkpoint.
  3. Split or explicitly qualify the coarse end-to-end consistency slice.
