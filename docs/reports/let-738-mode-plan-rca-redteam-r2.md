# LET-738 `mode:plan` RCA Red-Team Round 2

## Scope For This Round
- Focus: execution order, rollback or failure modes, and test coverage adequacy.
- Constraint: proposed fixes must stay within existing mechanisms only; no new entities, no new scripts, no new policy layer.

## Problem Frame
The target RCA now separates prerequisites and interface ownership, which is a real improvement. The remaining gap is operational: it still does not say how to execute the repair safely when one layer can be fixed while another fails, and it does not map the repair plan to the test coverage that already exists in the repo.

The document therefore still reads like a conceptual correction plan, not an implementation-safe sequence.

## Critical Findings

### 1) The repair order has no explicit rollback boundary
The fix plan orders writer repair, guard preservation, tracker retry handling, test addition, and finally a fallback to the generator entrypoint ([let-738-mode-plan-rca.md:45](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L45), [let-738-mode-plan-rca.md:46](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L46), [let-738-mode-plan-rca.md:47](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L47), [let-738-mode-plan-rca.md:48](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L48), [let-738-mode-plan-rca.md:49](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L49), [let-738-mode-plan-rca.md:50](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L50), [let-738-mode-plan-rca.md:51](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L51), [let-738-mode-plan-rca.md:52](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L52)). But it does not say what happens if step 1 changes the plan shape without preserving the existing short-plan contract, or if step 3 stabilizes tracker retries while the writer output is still non-canonical.

Why this matters:
- The target already treats the writer, `issueUpdate(description)`, and Linear retries as distinct interfaces ([let-738-mode-plan-rca.md:29](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L29), [let-738-mode-plan-rca.md:30](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L30), [let-738-mode-plan-rca.md:31](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L31), [let-738-mode-plan-rca.md:32](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L32), [let-738-mode-plan-rca.md:33](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L33)).
- Without an explicit rollback or stop rule, the repair can land partial changes that are individually acceptable but collectively inconsistent with the RCA’s own causal chain.
- This is not a new mechanism request. It is a missing failure-mode definition for the existing sequence.

Status: `verified issue`

### 2) The document does not define the failure mode for partial application across layers
The RCA says the current bounded retry behavior is preserved, but it does not say whether a writer-only fix, a guard-only fix, or a tracker-only fix is considered acceptable if the other layers remain unchanged. That matters because the document’s own fix plan explicitly separates these layers.

Why this matters:
- The interface split is explicit in the RCA ([let-738-mode-plan-rca.md:29](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L29), [let-738-mode-plan-rca.md:30](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L30), [let-738-mode-plan-rca.md:31](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L31), [let-738-mode-plan-rca.md:32](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L32), [let-738-mode-plan-rca.md:33](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L33)).
- The repair plan still ends with a vague fallback sentence about moving the fix to the generator entrypoint ([let-738-mode-plan-rca.md:52](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L52)) instead of saying whether the earlier steps should be reverted, retained, or considered complete on their own.
- That leaves the reader with no explicit retreat point if one existing mechanism cannot be safely changed.

Status: `verified issue`

### 3) Test coverage is inadequate for the full repair sequence
The target only proposes two explicit regression tests: one for `Acceptance Matrix` blocking and one for 429 convergence ([let-738-mode-plan-rca.md:49](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L49), [let-738-mode-plan-rca.md:50](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L50), [let-738-mode-plan-rca.md:51](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L51)). That is too narrow for the sequence it now claims to repair.

Why this matters:
- The repo already has tests for the contract surfaces the RCA is talking about: `SpecCheck` coverage for `mode:plan` / `Required capabilities` behavior ([spec_check_test.ex:81-97](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/spec_check_test.exs#L81), [spec_check_test.ex:99-109](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/spec_check_test.exs#L99)), `HandoffCheck` coverage for `Execution Evidence` freshness and fail-closed validation ([handoff_check_test.ex:2388-2456](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/handoff_check_test.exs#L2388), [handoff_check_test.ex:2588-2603](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/handoff_check_test.exs#L2588)), `Linear` retry / cooldown coverage ([workspace_and_config_test.ex:2219-2263](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/workspace_and_config_test.exs#L2219), [workspace_and_config_test.ex:2440-2446](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/workspace_and_config_test.exs#L2440)), and continuation-handoff coverage for issue refresh 429s ([core_test.exs:7018-7077](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/core_test.exs#L7018)).
- The RCA does not map its repair steps to those existing suites, nor does it say which tests must rerun after each step.
- As written, the test plan proves only the narrowest slice of the repair, not the full dependency chain or the partial-failure behavior.

Status: `verified issue`

## Lower-Priority Findings

### 1) The fallback wording at the end of the fix plan is still underspecified
The final repair bullet says to move the fix to the generator entrypoint if the writer still emits non-canonical text ([let-738-mode-plan-rca.md:52](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L52)). That is directionally fine, but it does not say whether that fallback is a retry step, a stop condition, or a postmortem note.

Status: `bounded concern`

### 2) The residual issues do not separate "unfixed" from "untested"
The residual section still groups the remaining uncertainty around the exact pre-fix payload and the generator entrypoint mapping, but it does not distinguish those from the untested rollback behavior in the repair sequence ([let-738-mode-plan-rca.md:54](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L54), [let-738-mode-plan-rca.md:55](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L55), [let-738-mode-plan-rca.md:56](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L56), [let-738-mode-plan-rca.md:57](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L57), [let-738-mode-plan-rca.md:58](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L58)).

Status: `bounded concern`

## Recommendations
1. Add an explicit stop / rollback rule between the writer fix and the tracker fix so partial application is not treated as success by default.
2. Name the failure mode for each layer: writer-only, guard-only, tracker-only, and combined failure.
3. Map the repair steps to the existing test suites already in the repo instead of only adding two new narrow regression cases.
4. State which existing tests must rerun after each repair step and which failures would stop the sequence.

## Exact Ordered Fix List For The Repair Round
1. Add a rollback / stop-condition sentence to the fix plan that says what to do if the writer repair breaks the short-plan contract.
2. Add a separate partial-failure rule for each layer: writer, guard, and tracker.
3. Extend the test plan by referencing the existing `SpecCheck`, `HandoffCheck`, `workspace_and_config`, and `core` coverage that already exercises the relevant mechanisms.
4. State which test suite reruns correspond to which repair step, and what failure causes the repair round to stop.
5. Update residual issues so the remaining uncertainty is split into "unfixed", "untested", and "still inferred" buckets.

## Compact Ledger
- Target document: `/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md`
- Focus used: execution order, rollback or failure modes, and test coverage adequacy
- Main findings:
  - no rollback boundary between repair steps
  - no explicit partial-application failure mode
  - test coverage is too narrow for the full repair sequence
- Exact ordered fix list for the repair round:
  1. add rollback / stop-condition sentence
  2. add partial-failure rules per layer
  3. map repair steps to existing test suites
  4. state rerun/stop conditions for each suite
  5. split residual issues into unfixed / untested / inferred
