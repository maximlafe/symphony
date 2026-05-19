# Red Team Critique, Pass 2 Round 1

Target: `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`

Focus: completeness and correctness of dependencies, prerequisites, producer/consumer ownership, and interface impacts across service/contracts/flows/scripts/skills.

Result type: critique-first review, not a repair spec.

## Active Critique Routes

- `ACTIVE`: ownership-map completeness across skills and runtime consumers/producers.
- `ACTIVE`: workflow side-effect and tool-interface boundaries that the current plan under-describes.
- `SUPPORTING`: validation-bar coverage versus the surfaces the plan says it is proving.

## Critical Findings

1. The ownership map is not complete enough to support the document's own claim of `one ownership boundary per surface`.
   - Evidence: the target plan's ownership map covers `cli.ex`, `workflow.ex`, `project-contract.md`, `let.WORKFLOW.md`, `plan-mode`, `execute-mode`, `land`, `swarm-mode`, `swarm-iterate`, `spec_check.ex`, `handoff_check.ex`, `dynamic_tool.ex`, `controller_finalizer.ex`, `orchestrator.ex`, and three test consumers (`docs/reports/...:58-78`).
   - Missing from that map are the actual LET skill surfaces already asserted elsewhere in the repo: `research-mode`, `diagnose`, `zoom-out`, `tdd`, and the setup/onboarding path. The workflow contract test explicitly treats those as live entrypoints and dependencies (`elixir/test/symphony_elixir/let_workflow_contract_test.exs:9-16`, `159-220`).
   - Why this matters: the plan says the LET stack spans `contract, workflow, skills, and runtime` and that `skills operationalize the rules at authoring and execution time` (`docs/reports/...:5-7`, `47-54`), but the ownership map only accounts for a subset of the skills surface. That leaves the dependency boundary incomplete, so the resulting repair round can still miss a live consumer/producer pair while believing the map is closed.

2. The validation bar cannot prove the ownership claim as written because it omits the same skill surfaces that the plan says are part of the mechanism.
   - Evidence: validation slice 1 only requires `cli.ex`, `workflow.ex`, `spec_check.ex`, `handoff_check.ex`, `dynamic_tool.ex`, `controller_finalizer.ex`, `orchestrator.ex`, and named test consumers to line up (`docs/reports/...:205-220`).
   - The repo's workflow contract test explicitly checks the `research-mode`, `plan-mode`, `execute-mode`, `zoom-out`, `diagnose`, and `tdd` skill files as first-class surfaces (`elixir/test/symphony_elixir/let_workflow_contract_test.exs:9-16`, `159-220`).
   - Why this matters: slice 1 is supposed to prove map completeness before text shape or runtime behavior (`docs/reports/...:209-217`), but the slice itself does not cover the full surface set the document claims is in scope. That makes the proof sequence weaker than the claim it is meant to justify.

## Lower-Priority Findings

1. The workflow section understates the workflow's producer/consumer responsibilities.
   - Evidence: the plan describes `let.WORKFLOW.md` as owning routing prose, stage transitions, and the canonical task-spec template (`docs/reports/...:58-65`, `117-128`).
   - The actual workflow is also the producer of stage-start comments, `.workpad-id`, workpad bootstrap, and the `sync_workpad` handoff path (`workflows/letterl/maxime/let.WORKFLOW.md:773-809`).
   - Why this matters: if the repair round only treats the workflow as a prose mirror, it can miss interface drift in comment creation, workpad synchronization, and stage-entry side effects even while the vocabulary appears aligned.

2. The runtime section names the main modules but not the concrete tool interfaces that carry the side effects.
   - Evidence: the plan says `dynamic_tool.ex` is the pre-write owner and `handoff_check.ex` is the post-write owner, with `controller_finalizer.ex` and `orchestrator.ex` consuming the same handoff vocabulary (`docs/reports/...:176-186`).
   - The actual runtime path includes tool-level interfaces such as `sync_workpad`, `github_wait_for_checks`, `github_pr_snapshot`, and the attachment upload path in `DynamicTool` (`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1-40`, `1-120`, plus the broader module layout).
   - Why this matters: the current plan is still one abstraction level too high for interface-impact auditing. It identifies the owning modules but not the call boundaries that determine whether workpad content, PR evidence, and uploaded artifacts are actually produced and consumed in the intended order.

## Recommendations

1. Add the omitted existing skill surfaces to the ownership map and the validation slice that proves map completeness.
2. Spell out the workflow side effects that make `let.WORKFLOW.md` a producer, not just a prose mirror.
3. Pin the runtime tool interfaces to the owning modules so the repair round can reason about evidence production and consumption without rediscovering the call chain.

## Compact Ledger

- Target document: `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`
- Focus used: completeness and correctness of dependencies, prerequisites, producer/consumer ownership, and interface impacts across service/contracts/flows/scripts/skills
- Main findings: incomplete ownership map for live skill surfaces; validation bar omits the same surfaces; workflow and runtime side effects are under-specified at the interface boundary
- Exact ordered fix list for repair round:
  1. Extend the ownership map to include the omitted live skill surfaces already in the workflow contract.
  2. Extend validation slice 1 so map completeness is proven against those same surfaces.
  3. Add the workflow's producer side effects (`stage-start`, `.workpad-id`, workpad bootstrap/sync) to the workflow ownership boundary.
  4. Bind the runtime tool interfaces to the owning modules so the evidence and handoff flow is explicit.
