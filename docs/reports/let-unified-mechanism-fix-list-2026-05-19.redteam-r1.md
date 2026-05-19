# Red-Team Critique: LET Unified Mechanism Fix List (Round 1 of 3)

Focus: completeness and correctness of dependencies, prerequisites, interface impacts, and contract/runtime ownership boundaries.

## Critical Findings

1. The fix list treats `In Review` checkpoint enforcement as a local runtime guard change, but the current guard interface does not carry the data needed to enforce `checkpoint_type=human-verify`.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:31-41`, `:78-80`.
   - Supporting code anchors: `elixir/lib/symphony_elixir/handoff_check.ex:649-657`, `:2834-2860`, `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:2085-2130`, `elixir/lib/symphony_elixir/controller_finalizer.ex:522-537`.
   - Why this is a gap: `review_ready_transition_allowed?/5` validates manifest data, but the call path shown in the document only proves the handoff phase and transition state. The document does not state where checkpoint data is sourced from, how it reaches the guard, or whether enforcement must move to a different layer. As written, the repair round can be implemented in the wrong place and still leave the transition semantically unenforced.

2. The document does not establish the ownership boundary between contract, workflow prose, parser, and runtime for items 2-4, so the fix order is incomplete as a dependency graph.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:43-68`, `:76-85`.
   - Supporting anchors: `docs/policy/project-contract.md:178-186`, `:190-215`, `workflows/letterl/maxime/let.WORKFLOW.md:713-716`, `:816-818`, `:1137-1138`.
   - Why this is a gap: the document lists drift symptoms, but it never states which layer is source-of-truth and which layers are mirrors. That matters because `required_before`, proof-bullet grammar, and selector fallback can be resolved either by tightening runtime parsing or by updating the contract semantics. Without a declared ownership boundary, the repair round cannot tell whether a change is a contract amendment, a runtime migration, or both.

## Lower-Priority Findings

1. `required_before` is correctly flagged as contract-required, but the document omits the migration/backward-compatibility prerequisite.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:43-49`, `:81-82`.
   - Supporting anchors: `docs/policy/project-contract.md:178-183`, `elixir/lib/symphony_elixir/handoff_check.ex:2124-2128`, `:2208-2218`.
   - Risk: removing the silent default changes acceptance-matrix behavior for any legacy rows that rely on omission. The fix list should explicitly say whether legacy rows are being mass-updated, rejected, or normalized in a compatibility pass.

2. The Proof Mapping grammar item is directionally correct, but the fix list does not separate plan-mode authoring rules from execution/review runtime parsing.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:51-59`, `:82-83`.
   - Supporting anchors: `workflows/letterl/maxime/let.WORKFLOW.md:1137-1138`, `:1179-1206`, `elixir/lib/symphony_elixir/handoff_check.ex:2078`, `elixir/lib/symphony_elixir/spec_check.ex:591`.
   - Risk: the document says the contract is hyphen-only, but the cited workflow sections include a plan-mode-specific proof-mapping grammar. The repair round needs to say whether the change is to accept less in all contexts, or to keep different grammars by context.

3. The hidden selector fallback is noted, but the document does not assign ownership for whether that fallback is a supported contract feature or an implementation leak.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:61-68`, `:84`.
   - Supporting anchors: `elixir/lib/symphony_elixir/handoff_check.ex:35`, `:2521-2529`, `elixir/test/symphony_elixir/handoff_check_test.exs:3529-3560`.
   - Risk: the fix order says “document selector fallback as first-class contract or remove it,” but that is not the same as deciding which layer owns the behavior today. If the runtime owns it, the contract should describe it. If the contract does not want it, the parser needs to reject it and the tests must be updated together.

4. The merge-ready/unknown-state item is plausible, but the document does not show a contract anchor that requires fail-closed handling for `UNKNOWN`.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:70-85`.
   - Supporting anchors: `elixir/lib/symphony_elixir/handoff_check.ex:2926`, `elixir/test/symphony_elixir/handoff_check_test.exs:4299-4315`.
   - Risk: this may be a runtime-hardening recommendation rather than a contract drift. If so, it should be labeled as such instead of being presented at the same certainty level as the other contract/runtime mismatches.

## Recommendations

1. Add an explicit dependency chain before the fix list:
   - contract source-of-truth,
   - workflow prose mirror,
   - parser/runtime owner,
   - call-site/interface updates,
   - tests and fixtures.

2. Split item 1 into two statements:
   - where checkpoint data is authored or extracted,
   - where the runtime guard consumes it.

3. For items 2-4, state whether the repair is a contract change, a runtime enforcement change, or a compatibility migration.

4. Reclassify item 5 unless the contract is updated to define unknown merge-state handling as a required invariant.

## Repair Round Order

1. Define the source-of-truth and ownership boundary for checkpoint semantics, acceptance-matrix parsing, and proof-mapping grammar.
2. Update the `In Review` checkpoint path with the data-flow prerequisite needed to actually enforce `human-verify`.
3. Decide and document the `required_before` migration policy before changing parser defaults.
4. Choose one proof-mapping grammar policy by context and align contract, workflow, parser, and tests.
5. Decide whether selector fallback is supported contractually or must be rejected by runtime parsing.
6. Reassess merge-state `UNKNOWN` after the prior contract/runtime ownership decisions are in place.

## Ledger

- Target document: `/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-unified-mechanism-fix-list-2026-05-19.md`
- Focus used: completeness and correctness of dependencies, prerequisites, interface impacts, and contract/runtime ownership boundaries
- Main findings: missing checkpoint data-flow prerequisite for `In Review`; missing ownership boundary for items 2-4; missing migration/compatibility and context-ownership details for lower-priority items
- Exact ordered fix list for repair round:
  1. Define the source-of-truth and ownership boundary for checkpoint semantics, acceptance-matrix parsing, and proof-mapping grammar.
  2. Update the `In Review` checkpoint path with the data-flow prerequisite needed to actually enforce `human-verify`.
  3. Decide and document the `required_before` migration policy before changing parser defaults.
  4. Choose one proof-mapping grammar policy by context and align contract, workflow, parser, and tests.
  5. Decide whether selector fallback is supported contractually or must be rejected by runtime parsing.
  6. Reassess merge-state `UNKNOWN` after the prior contract/runtime ownership decisions are in place.
