# Red Team Critique: ticket-movement-rewrite-plan Round 2

## Scope

- Focus for this round: execution order, rollback or failure modes, and test coverage adequacy.
- Non-goal: re-evaluating the baseline non-legacy framing or redoing the dependency-map critique from round 1.
- Evidence boundary: the target plan at [docs/plans/ticket-movement-rewrite-plan.md](../plans/ticket-movement-rewrite-plan.md) plus local code/tests that expose the real validation surfaces.

## Critical Findings

### 1. The plan names stage contracts that are not anchored to concrete implementation surfaces

**Type:** `verified issue`

The plan’s ownership map and dependency order are built around `PlanContract`, `ExecutionContract`, and `ReviewContract` ([docs/plans/ticket-movement-rewrite-plan.md](../plans/ticket-movement-rewrite-plan.md)). In the repository, `ExecutionContract` is real and test-backed, but there is no matching `PlanContract` or `ReviewContract` module in the current code search; the implementation surface instead remains split across existing runtime modules and validation helpers, with `ExecutionContract` already used from `orchestrator.ex` and `dynamic_tool.ex`.

That makes the execution order look cleaner than the actual codebase. The plan says “split the contracts by stage” before the concrete implementation boundaries have been named. In practice, that means step ordering depends on abstractions that are currently aspirational, not executable. This is not a style concern; it is a sequencing gap that will surface as soon as the team tries to write or run tests against those contracts.

### 2. Rollback/failure handling is still too coarse for the number of moving parts the plan introduces

**Type:** `verified issue`

The plan has a prerequisite list, a work order, and a validation matrix, but it does not define a rollback boundary for each major change. The only explicit failure rule is inside the `changed_paths` section, which says the behavior should fail closed if fallback still yields an empty list. Everything else is left as “don’t do the step until the prior one is done.”

That is not enough for the surfaces the plan touches:

- `changed_paths` is read by `controller_finalizer.ex` and `dynamic_tool.ex`.
- retry/dedupe mechanics already exist in `orchestrator.ex` and have dedicated tests around dedupe windows and retry budgets.
- Linear side effects already have behavior-sensitive tests in the app-server surface.

Because the plan introduces a canonical pipeline, a retry simplification, and an idempotent Linear wrapper, the failure story needs to say what gets reverted if a late step fails after earlier steps land. Right now there is no explicit rule for partial application across these layers, so “ordered work” can still leave the repo in a mixed state with no declared retreat point.

### 3. The validation matrix is too abstract to prove the new failure modes the plan actually introduces

**Type:** `verified issue`

The matrix uses broad buckets like “contract tests,” “execution tests,” and “Linear-layer tests” ([docs/plans/ticket-movement-rewrite-plan.md](../plans/ticket-movement-rewrite-plan.md)). That is insufficient for the changes this plan claims to make, because the new risk is not just whether the happy path still works. The risk is whether each interface boundary behaves correctly under fallback, dedupe, and partial rollout conditions.

Concrete gaps:

- The matrix does not name a test target for `changed_paths` source precedence, even though the real behavior sits in `controller_finalizer.ex` and `dynamic_tool.ex`, not only in `validation_gate.ex`.
- The matrix does not name a test target for the idempotent Linear wrapper, even though the current plan makes that wrapper a new boundary.
- The matrix does not specify which tests should prove the new stage boundary between `Plan`, `Execute`, and `Review`, so “contract tests” can be satisfied by unrelated contract assertions.
- Existing tests do cover some relevant primitives, such as `validation_gate_test.exs`, `execution_contract_test.exs`, and `core_test.exs`, but the plan does not bind its new claims to those concrete files or to new tests that would actually fail when the wrong layer changes.

This means the matrix is a checklist, not a proof map. For a plan that introduces new ownership and rollback expectations, that is not strong enough.

## Lower-Priority Findings

### 4. The execution order is linear, but the stop rules between the middle steps are underspecified

**Type:** `bounded concern`

The plan says inventory comes before ownership, ownership before canonical state machine, canonical state machine before guard cleanup, and so on. That ordering is sensible, but it still leaves a key question open: what happens if the inventory shows that the supposed `Plan` / `Execute` / `Review` split does not map cleanly onto the current code?

There is no explicit “retire this route” or “keep this route dormant” rule for the possibility that one of the middle steps proves the abstraction too coarse. Without that, the plan can keep marching down a clean-looking path even when the real code wants a different seam.

### 5. The rollback language for `changed_paths` is good, but the rest of the plan does not reach the same standard

**Type:** `working criticism`

The `changed_paths` section is the only place where the document says what to do when a fallback path still fails: fail closed. The other major steps do not match that precision.

That imbalance matters because the plan treats `changed_paths`, retry/failover simplification, and the Linear wrapper as neighboring changes in one execution sequence. If only one of those surfaces has explicit failure semantics, the rest remain vulnerable to partial adoption and unclear reversal.

## Recommendations

1. Anchor `PlanContract` and `ReviewContract` to concrete modules or explicit existing files, or rename them to the actual implementation surfaces before execution.
2. Add rollback rules per major step, not just one fail-closed note for `changed_paths`.
3. Replace generic test buckets with concrete proof targets and command/file-level gates.
4. Add explicit stop rules for the case where inventory or ownership mapping shows the canonical pipeline does not fit the code cleanly.
5. Tie Linear-wrapper and retry/failover changes to named tests that fail on partial rollout, not just on generic happy-path regressions.

## Compact Fix List For Repair Round

1. Anchor the stage-contract abstractions to real implementation surfaces.
2. Define per-step rollback or failure-mode rules for the whole sequence.
3. Replace abstract validation buckets with concrete proof targets.
4. Add stop rules for a failed canonicalization or ownership split.
5. Bind Linear-wrapper and retry/failover changes to named regression tests.

## Ledger

- **Target document:** [docs/plans/ticket-movement-rewrite-plan.md](../plans/ticket-movement-rewrite-plan.md)
- **Focus used:** execution order, rollback or failure modes, and test coverage adequacy
- **Main findings:** the plan’s stage-contract model is not anchored to real modules, rollback boundaries are too coarse for the number of moving parts, and the validation matrix is too abstract to prove the new failure modes
- **Exact ordered fix list for the repair round:** `1) anchor stage-contract abstractions to real implementation surfaces; 2) define per-step rollback/failure rules; 3) replace abstract validation buckets with concrete proof targets; 4) add stop rules for failed canonicalization/ownership split; 5) bind Linear-wrapper and retry/failover changes to named regression tests`
