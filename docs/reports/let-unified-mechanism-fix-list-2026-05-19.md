# LET Unified Mechanism Fix List (2026-05-19)

## Goal

One non-contradictory mechanism across `plan -> execute -> review`, with a single
workflow canon and aligned runtime guards.

## Ownership Boundary

Use this document as a dependency map, not as a contract replacement.

- Contract source-of-truth:
  - `docs/policy/project-contract.md` owns the task-spec requirements, handoff
    invariants, and checkpoint semantics.
- Workflow prose mirror:
  - `workflows/letterl/maxime/let.WORKFLOW.md` mirrors the contract for operator
    instructions and phase-specific routing.
- Parser/runtime owner:
  - `elixir/lib/symphony_elixir/handoff_check.ex` owns runtime parsing and
    enforcement.
- Interface/call-site owners:
  - `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
  - `elixir/lib/symphony_elixir/controller_finalizer.ex`
- Compatibility rule:
  - when the contract and runtime disagree, the repair must say explicitly
    whether the change is a contract amendment, a runtime migration, or both.
- Checkpoint data-flow prerequisite:
  - the `In Review` guard can only enforce `checkpoint_type=human-verify` when
    the checkpoint record has already been propagated into the handoff payload;
    otherwise the enforcement belongs earlier in the transition path.

## Completed In This Branch

1. Single canonical workflow file enabled in runtime:
   - default path now resolves to `workflows/letterl/maxime/let.WORKFLOW.md`:
     - `elixir/lib/symphony_elixir/workflow.ex:8-19`
     - `elixir/lib/symphony_elixir/cli.ex:40`
2. Parallel workflow surface removed:
   - deleted `elixir/WORKFLOW.md`
   - guard test asserts absence of legacy file:
     - `elixir/test/symphony_elixir/let_workflow_contract_test.exs:124-128`
3. Deploy/runtime defaults aligned to canonical path:
   - `elixir/deploy/docker/docker-compose.yml:22`
   - `elixir/deploy/docker/compose.env.example:10`
4. Onboarding/docs aligned to canonical path:
   - `README.md:17`
   - `docs/onboarding/symphony-setup.md:44-60`
   - `elixir/README.md:35-123`
5. Core path behavior tests updated:
   - `elixir/test/symphony_elixir/cli_test.exs:46-53`
   - `elixir/test/symphony_elixir/core_test.exs:296-306`

## Remaining Drift (Must Fix For Full Consistency)

1. `In Review` transition does not enforce `checkpoint_type=human-verify` at
   runtime transition guard, and the guard path must be fed checkpoint data
   before the enforcement can be considered real.
   - Contract/prose require this:
     - `docs/policy/project-contract.md:215-239`
     - `workflows/letterl/maxime/let.WORKFLOW.md:713-716, 975`
   - Execution order:
     1. propagate the checkpoint record through the handoff assembly path and
        call sites;
     2. enforce `checkpoint_type=human-verify` in the runtime guard only after
        that checkpoint record is present in the handoff payload.
   - Runtime currently validates only allowed enum values:
     - `elixir/lib/symphony_elixir/handoff_check.ex:2834-2860`
   - Review-ready transition checks manifest pass but not checkpoint semantics:
     - `elixir/lib/symphony_elixir/handoff_check.ex:649-657`
     - `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:2085-2130`
     - `elixir/lib/symphony_elixir/controller_finalizer.ex:522-537`
2. Acceptance Matrix `required_before` is contract-required, but parser silently
   defaults missing value to `review`.
   - Contract requires explicit field:
     - `docs/policy/project-contract.md:178, 182-183`
   - Runtime defaulting behavior:
     - `elixir/lib/symphony_elixir/handoff_check.ex:2124-2128`
     - `elixir/lib/symphony_elixir/handoff_check.ex:2208-2218`
   - Migration prerequisite:
     - decide whether legacy rows are mass-updated, rejected, or normalized in a
       compatibility pass before changing the parser default, because silent
       fallback removal is a breaking acceptance-matrix change.

3. Proof Mapping bullet grammar drift in plan-mode issue-description mapping:
   - Workflow/skill require hyphen bullets for issue description:
     - `workflows/letterl/maxime/let.WORKFLOW.md:816-818, 1137`
   - Parser currently accepts both `-` and `*`:
     - `elixir/lib/symphony_elixir/handoff_check.ex:2078`
   - Diagnostics/tests still codify `*` acceptance:
     - `elixir/lib/symphony_elixir/spec_check.ex:591`
     - `elixir/test/symphony_elixir/spec_check_test.exs:120-133`
     - `elixir/test/symphony_elixir/handoff_check_test.exs:423-439`
   - Ownership note:
     - this report keeps the contract/workflow policy aligned on hyphen-only in
       plan-mode issue-description mapping, while the runtime parser and tests
       must be updated together if the implementation continues to accept more
       than the contract allows.

4. Hidden fallback for `test` proof selectors can satisfy mapping through
   `targeted tests`/`repo validation`, but this is stricter/less explicit in
   prose.
   - Runtime fallback:
     - `elixir/lib/symphony_elixir/handoff_check.ex:35`
     - `elixir/lib/symphony_elixir/handoff_check.ex:2521-2529`
   - Covered by tests:
     - `elixir/test/symphony_elixir/handoff_check_test.exs:3529-3560`
   - Ownership decision:
     - treat the fallback as a supported contract feature and document it
       explicitly, or remove it from the parser and update the tests in the same
       change; do not leave it as an undocumented runtime leak.

5. PR merge-ready `UNKNOWN` is a named regression gate in this report, not a
   separate contract invariant.
   - Runtime blocks only `DIRTY`/`BLOCKED`:
     - `elixir/lib/symphony_elixir/handoff_check.ex:2926`
   - Test confirms `UNKNOWN` currently passes:
     - `elixir/test/symphony_elixir/handoff_check_test.exs:4299-4315`
   - Regression gate:
     - `elixir/test/symphony_elixir/handoff_check_test.exs:4299-4315`
   - Classification:
     - this is runtime hardening, not a stated contract invariant, unless the
       contract is amended to require fail-closed `UNKNOWN` handling.

## Rollback And Stop Rules

Compatibility-sensitive parser changes use fail-fast rollback if the first red
or green slice regresses current behavior.

If these sections differ, `Recommended Fix Order` is authoritative; the rollback
rules and validation slice only constrain how that order is executed.

- `required_before`:
  - if legacy rows are not migrated cleanly, stop after the red test and restore
    the current parser default until the compatibility pass is complete.
- Proof Mapping grammar:
  - if plan-mode or review-mode parsing regresses, stop before touching selector
    fallback or `UNKNOWN` hardening, and keep the old grammar accepted until the
    contract/workflow and both test modules are aligned.
- Selector fallback:
  - if removing the fallback breaks the selector-path regression tests, keep the
    fallback in place or document it as contract behavior before proceeding.
- Merge-ready `UNKNOWN`:
  - if the named regression gate fails, treat the item as deferred runtime
    hardening and do not let it block earlier parser or checkpoint fixes.

## Recommended Fix Order

1. Confirm and document the source-of-truth / ownership boundary for
   checkpoint semantics, acceptance-matrix parsing, proof-mapping grammar, and
   selector fallback.
2. Enforce `checkpoint_type` by handoff phase:
   - `review` -> only `human-verify`
   - `done`/blocked paths -> `decision` or `human-action` when applicable
3. Make `required_before` explicit in parser, but only after choosing the
   migration policy for legacy rows.
4. Make Proof Mapping grammar consistent with the chosen contract/runtime
   boundary for plan-mode vs execution/review parsing.
5. Either document selector fallback as first-class contract or remove it.
6. Keep merge-ready `UNKNOWN` only as a named regression gate
   (`handoff_check_test.exs:4299-4315`) unless the contract is updated to
   require fail-closed handling.

## Validation Slice For Each Fix

1. Checkpoint propagation + guard enforcement:
   - red: `elixir/test/symphony_elixir/dynamic_tool_test.exs`
   - red: `elixir/test/symphony_elixir/controller_finalizer_test.exs`
   - red: `elixir/test/symphony_elixir/handoff_check_test.exs`
   - green: the same three modules after payload propagation and guard
     enforcement both exist.
2. `required_before` migration:
   - red: `elixir/test/symphony_elixir/handoff_check_test.exs`
   - fixtures: update legacy acceptance-matrix rows in the same slice before
     removing the parser default.
3. Proof Mapping grammar:
   - red: `elixir/test/symphony_elixir/spec_check_test.exs`
   - red: `elixir/test/symphony_elixir/handoff_check_test.exs`
   - green: both modules after the grammar and parser policy match.
4. Selector fallback:
   - red: `elixir/test/symphony_elixir/handoff_check_test.exs`
   - green: `elixir/test/symphony_elixir/handoff_check_test.exs:3529-3560`
     only after the contract decision is explicit.
5. Merge-ready `UNKNOWN`:
   - red: `elixir/test/symphony_elixir/handoff_check_test.exs:4299-4315`
   - green: that same regression gate if the item remains in the active repair
     sequence.
6. Run `mix format --check-formatted` after each green slice.
7. After every second green slice: run `make symphony-runtime-smoke SCENARIO=all`
   and `make symphony-validate`.
