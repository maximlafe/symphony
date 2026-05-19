# Red-Team Critique: LET Unified Mechanism Fix List (Round 2 of 3)

Focus: execution order, rollback or failure modes, and test coverage adequacy of the proposed fix sequence.

## Critical Findings

1. The proposed order still collapses the checkpoint-data propagation work into a note instead of a discrete prerequisite, so item 2 can be attempted before the interface actually carries the data the guard needs.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:55-71`, `:124-129`.
   - Supporting anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:27-30`, `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:2085-2130`, `elixir/lib/symphony_elixir/controller_finalizer.ex:522-537`, `elixir/lib/symphony_elixir/handoff_check.ex:649-657`.
   - Why this is a problem: the document says the `In Review` guard can only enforce `checkpoint_type=human-verify` if the checkpoint record is already present in the handoff payload, but the repair order does not split that payload plumbing from the guard change. As written, a repair pass can land the local guard update first, observe no semantic effect, and mistakenly treat the step as complete.

## Lower-Priority Findings

1. Rollback and failure-mode handling is only explicit for `required_before`; the rest of the sequence has no stop/revert rule if a compatibility-sensitive parser change regresses current behavior.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:73-83`, `:100-111`, `:138-148`.
   - Supporting anchors: `elixir/test/symphony_elixir/handoff_check_test.exs:4288-4315`, `elixir/test/symphony_elixir/spec_check_test.exs:99-126`, `elixir/test/symphony_elixir/dynamic_tool_test.exs:2391-2509`, `:2857-2869`.
   - Why this matters: if the parser change for `required_before`, proof-mapping grammar, or selector fallback breaks a live contract path, the document does not say whether to revert the parser, preserve a compatibility shim, or halt later fixes. The result is a linear sequence with no explicit recovery path.

2. The validation slice is too generic to prove coverage adequacy for the actual surfaces changed by the plan.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:140-148`.
   - Supporting anchors: `elixir/test/symphony_elixir/dynamic_tool_test.exs:2391-2509`, `:2857-2869`, `elixir/test/symphony_elixir/spec_check_test.exs:99-126`, `elixir/test/symphony_elixir/handoff_check_test.exs:3944-4157`, `:4288-4315`.
   - Why this is a gap: the document names broad files and says "where applicable," but the repair sequence touches at least four distinct surfaces: the runtime handoff parser, the spec checker, the dynamic GraphQL/tool path, and the controller transition wrapper. The plan should say which test module must change for each item; otherwise a repair can pass the generic slice while leaving one of the coupled surfaces untested.

3. Merge-ready `UNKNOWN` is included in the sequence, but the document does not assign it a concrete regression gate, so its failure mode is under-specified.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:113-136`, `:140-148`.
   - Supporting anchors: `elixir/test/symphony_elixir/handoff_check_test.exs:4288-4315`.
   - Why this matters: the document now classifies this item as runtime hardening, but it still remains in the ordered repair list. Without an explicit test gate or a reason to defer it, the sequence leaves uncertainty about whether this is a required repair or an opportunistic hardening pass.

## Recommendations

1. Split the checkpoint change into two executable steps:
   - propagate checkpoint data through the transition path,
   - then enforce `checkpoint_type=human-verify` in the guard.

2. Add explicit rollback or stop rules for compatibility-sensitive parser changes:
   - if legacy matrix rows cannot be migrated cleanly,
   - if selector fallback behavior changes unexpectedly,
   - or if proof-mapping grammar updates break existing plan-mode parsing.

3. Replace the generic validation slice with a per-item test matrix:
   - `required_before` and parser defaulting should name `handoff_check_test.exs`;
   - proof-mapping grammar should name both `spec_check_test.exs` and `handoff_check_test.exs`;
   - selector fallback should name the existing selector-path tests explicitly;
   - merge-ready `UNKNOWN` should name the exact `merge_state_status` regression test.

4. Decide whether `UNKNOWN` is a required regression gate or a deferred hardening item, and then either promote it to a named test step or remove it from this repair sequence.

## Repair Round Order

1. Split the checkpoint work into payload propagation through the call sites, then guard enforcement.
2. Add explicit rollback/stop criteria for compatibility-sensitive parser changes before touching defaults or grammar.
3. Define the exact test module per fix, not just the broad file family.
4. Rework the validation slice so each step names the regression tests that must pass before the next step starts.
5. Either promote merge-ready `UNKNOWN` to a named regression gate or defer it out of this sequence with a stated justification.

## Ledger

- Target document: `/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-unified-mechanism-fix-list-2026-05-19.md`
- Focus used: execution order, rollback or failure modes, and test coverage adequacy of the proposed fix sequence
- Main findings: checkpoint enforcement is still sequenced before its data-flow prerequisite; rollback rules are missing for compatibility-sensitive parser changes; validation is too generic to prove coverage for the affected surfaces; merge-ready `UNKNOWN` lacks a concrete regression gate
- Exact ordered fix list for next repair round:
  1. Split the checkpoint work into payload propagation through the call sites, then guard enforcement.
  2. Add explicit rollback/stop criteria for compatibility-sensitive parser changes before touching defaults or grammar.
  3. Define the exact test module per fix, not just the broad file family.
  4. Rework the validation slice so each step names the regression tests that must pass before the next step starts.
  5. Either promote merge-ready `UNKNOWN` to a named regression gate or defer it out of this sequence with a stated justification.
