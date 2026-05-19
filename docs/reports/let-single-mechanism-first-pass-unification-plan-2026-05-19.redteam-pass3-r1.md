# Red-Team Critique: LET Single Mechanism First-Pass Unification Plan

Round 1 of 3

Focus: closeability and correctness of the four explicitly open points, with concrete repo evidence.

## Phase Snapshot

- Target: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md)
- Evidence boundary: local repo files and tests only
- Result typing: verified issue, bounded concern, working criticism

## Critical Findings

### 1) Legacy compatibility wording is still present outside the named LET surfaces

**Status:** `verified issue`

The open point cannot be closed now. The repo still carries legacy `plan-mode` / `Spec Prep` compatibility language outside the named LET contract surfaces the target wants audited.

- [`workflows/letterl/maxime/README.md:50`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/README.md#L50) says `Spec Prep` / `Spec Review` remain the opt-in analysis-only path and that `plan-mode` is the only planning entrypoint, then routes `swarm-iterate` directly under the same legacy framing.
- [`workflows/letterl/maxime/README.md:62`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/README.md#L62) still uses `In Review` / `Blocked` wording in the older compatibility style.
- [`elixir/AGENTS.md:64`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/AGENTS.md#L64) centralizes the mode chain, but it also explicitly says not to duplicate routing semantics elsewhere, which makes the remaining legacy wording in other repo docs harder to dismiss as harmless noise.

The target doc’s uncertainty here is real: the compatibility vocabulary has not been fully audited out of repo-local supporting surfaces, so “explicitly compatibility-only or removed” is not yet true everywhere it needs to be.

### 2) Full runtime call-site inventory is not durably established

**Status:** `verified issue`

The repo shows the runtime call chain, but not a complete inventory artifact that proves the full set of consumers of the canonical handoff vocabulary. The visible runtime call sites are scattered, and the target’s “exact set” condition is not satisfied by scattered code references alone.

- [`elixir/lib/symphony_elixir/controller_finalizer.ex:96`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L96) calls `sync_workpad` and `github_wait_for_checks`.
- [`elixir/lib/symphony_elixir/controller_finalizer.ex:135`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L135) calls `github_pr_snapshot`.
- [`elixir/lib/symphony_elixir/controller_finalizer.ex:304`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L304) calls `symphony_handoff_check`.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:397`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L397) dispatches the supported runtime tools, including `sync_workpad`, `linear_upload_issue_attachment`, `github_pr_snapshot`, `github_wait_for_checks`, `symphony_handoff_check`, and `symphony_spec_check`.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:484`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L484) contains the actual tool executors for those surfaces.

That is enough to prove the runtime path exists. It is not enough to prove the inventory is exhaustive, nor that every call site has been aligned against the same canonical handoff vocabulary. The target should not close this point yet.

## Lower-Priority Findings

### 3) The swarm-assisted branch contract is documented, but environment-wide closure is still too soft

**Status:** `bounded concern`

The repo does contain strong evidence that the swarm-assisted path is subordinate to the short plan:

- [`docs/policy/project-contract.md:34`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L34)
- [`docs/plans/swarm-two-layer-plan-contract.md:5`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/plans/swarm-two-layer-plan-contract.md#L5)
- [`.agents/skills/plan-mode/SKILL.md:33`](/Users/lafe/.codex/worktrees/a262/Symphony/.agents/skills/plan-mode/SKILL.md#L33)
- [`workflows/letterl/maxime/let.WORKFLOW.md:794`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md#L794)

But the target’s open point is narrower than “the docs say so.” It asks whether the current branch confirms the swarm-assisted path stays subordinate in every environment. The repo does not yet give a single authoritative runtime-facing proof of that precedence across environments; it gives aligned prose, not a closed branch contract proof.

### 4) Helper-copy tests still mix canonical-surface checks with copy-surface checks

**Status:** `bounded concern`

The test suite is not yet cleanly aligned to canonical surfaces only. `let_workflow_contract_test.exs` still asserts both canonical contract files and helper/copy surfaces:

- [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:6`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L6) loads the live workflow plus the default workflow and several skill-file paths.
- [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:125`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L125) asserts the default workflow carries the same stage/cost contract.
- [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:159`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L159) reads the repo-local skill files, project contract, and onboarding doc directly, then uses their content as proof of the mechanism.

That is useful coverage, but it still proves a mixture of canonical surfaces and helper/copy surfaces. The open point is therefore not yet closeable as stated.

## Recommendations

1. Treat the legacy wording audit as incomplete until the compatibility language outside the named LET surfaces is either removed or explicitly reclassified as compatibility-only text.
2. Produce a durable runtime call-site inventory before claiming closure, and tie each call site to the exact canonical vocabulary it consumes.
3. Keep the swarm-assisted path subordinate in the docs, but add one branch-facing proof that shows the short plan wins even when the gate is enabled.
4. Retarget the tests so canonical surfaces are the proof target; leave helper-copy coverage only as compatibility smoke, not as primary evidence of the mechanism.

## Ledger

- Target document: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md)
- Focus: closeability and correctness of the four open points
- Main findings:
  - legacy compatibility wording outside named LET surfaces is still present;
  - runtime call-site coverage is visible but not durably inventoried;
  - swarm-assisted subordinate-branch evidence is strong but not fully environment-closed;
  - helper-copy tests still mix canonical and non-canonical proof surfaces
- Exact ordered fix list for the repair round:
  1. Remove or reclassify legacy compatibility wording outside the named LET surfaces.
  2. Write the runtime call-site inventory and reconcile it against the canonical handoff vocabulary.
  3. Add one branch-facing proof that the short plan remains authoritative when the swarm gate is enabled.
  4. Rework the tests so canonical surfaces are the primary proof target and helper copies remain secondary.
