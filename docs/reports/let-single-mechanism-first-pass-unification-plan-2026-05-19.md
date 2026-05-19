# LET Single Mechanism First-Pass Unification Plan (2026-05-19)

## Document Specification

Core problem: the LET stack is expressed across contract, workflow, skills, and runtime surfaces that sometimes use the same words for different ownership boundaries. That creates drift, fallback ambiguity, and repair-after-the-fact behavior instead of first-pass correctness.

Scope: align the existing mechanism so that `project-contract`, `let.WORKFLOW.md`, the LET skills, and the runtime service path all describe and enforce the same flow without contradiction.

Out of scope:

- new policy entities;
- new scripts;
- new blocking gates;
- new standalone service layers;
- product feature expansion;
- redesigning the LET lifecycle.

Success criteria:

- one canonical vocabulary for the control stages `Spec Prep`, `Spec Review`, `In Progress`, `In Review`, `Blocked`, and `Merging`; supporting routing states `Todo`, `Rework`, `Done`, and `Backlog` remain named elsewhere but are not part of that canonical stage set;
- one ownership boundary per surface, with no duplicated authority;
- `Acceptance Matrix`, `Proof Mapping`, and `Checkpoint` semantics line up across contract, workflow, skills, and runtime;
- the first persisted task-spec is already valid;
- the later handoff outcomes (`In Review` / `Blocked`) are already valid when execution reaches handoff;
- compatibility behavior is explicit when it exists and never silently overrides canonical behavior.

Canonical success phrase for this document: `first-pass correctness`.
The phrase names the claim; the Validation Bar defines the testable property.

Resolved evidence notes:

- the legacy `Spec Prep` wording audit outside the named LET surfaces has been grounded in repo docs and is now treated as a closed compatibility finding;
- the runtime call-site inventory has been grounded within an explicit production-code boundary and is now treated as a closed inventory finding;
- the swarm-assisted plan path contract has explicit subordinate-short-plan evidence and is now treated as a closed branch-contract finding;
- the helper-copy test alignment issue has been grounded as a canonical-proof-vs-helper-smoke distinction and is now treated as a closed validation finding.

## Single Mechanism

The target mechanism is a single flow, not a collection of adjacent flows:

`Todo` intake -> `Spec Prep` -> `Spec Review` -> `In Progress` -> `In Review` or `Blocked` -> `Merging`

Artifact alias rule for this document:

- `task-spec`, `issue-description`, and `short plan` refer to the persisted plan body for the current `mode:plan` or `Spec Prep` stage;
- `canonical task-spec template` is the workflow-rendered form of that same persisted plan body;
- `handoff state` is the later execution handoff state and is not the same artifact as the persisted plan body.

The purpose of the documentation pass is to make each surface point at the same control points:

- contract defines the rules;
- workflow mirrors the rules for operators;
- skills operationalize the rules at authoring and execution time;
- runtime enforces the rules;
- tests prove the rules;
- review and merge skills preserve the same rules after implementation.

If a surface cannot be made to agree, the document should treat that as a compatibility gap to be named explicitly, not as a new mechanism.

## Ownership Map

| Surface | Owns | Must Not Own |
| --- | --- | --- |
| `elixir/lib/symphony_elixir/cli.ex` | route entrypoint and mode dispatch into LET flows | redefining task-spec semantics or proof ownership |
| `elixir/lib/symphony_elixir/workflow.ex` | canonical workflow-path resolution and default workflow loading | competing route canon or hidden fallback policy |
| `docs/policy/project-contract.md` | canonical task-spec, proof, checkpoint, and handoff invariants | operator prose, implementation details, or duplicated runtime policy text |
| `workflows/letterl/maxime/let.WORKFLOW.md` | routing prose, stage transitions, and the user-facing canonical task-spec template | alternate contract semantics or competing field definitions |
| `.agents/skills/plan-mode/SKILL.md` | `Spec Prep` shaping, canonical `Acceptance Matrix` / `Proof Mapping` authoring, and optional swarm-assisted planning discipline | product code edits, merge behavior, or execution handoff semantics |
| `.agents/skills/execute-mode/SKILL.md` | execution preflight, proof alignment, and review-ready or blocked handoff discipline | redefining `Spec Prep` semantics or inventing new proof classes |
| `.agents/skills/research-mode/SKILL.md` | `Spec Prep` research and task-spec normalization for `mode:research` | product code edits, execution handoff semantics, or merge behavior |
| `.agents/skills/diagnose/SKILL.md` | analysis-only diagnosis during `Spec Prep` | shipped fixes, handoff enforcement, or routing ownership |
| `.agents/skills/zoom-out/SKILL.md` | bounded codebase mapping during `Spec Prep` | product code edits or contract ownership |
| `.agents/skills/tdd/SKILL.md` | deterministic red/green proof shaping for `delivery:tdd` work | changing task-spec semantics or handoff ownership |
| `.agents/skills/symphony-setup/SKILL.md` and `docs/onboarding/symphony-setup.md` | setup/bootstrap guidance for the LET workflow surface | redefining task-spec or handoff semantics |
| `.agents/skills/land/SKILL.md` | merge/watch discipline after the PR is review-ready | changing task-spec contract shape or bypassing review semantics |
| `.agents/skills/swarm-mode/SKILL.md` and swarm-iterate support | critique/repair of the plan artifact only | becoming a parallel source of truth for runtime behavior |
| `elixir/lib/symphony_elixir/spec_check.ex` | `Spec Prep` parser/validator for canonical issue-description shape | replacing workflow prose or handoff enforcement |
| `elixir/lib/symphony_elixir/handoff_check.ex` | parsing and enforcement of the handoff contract | silently tolerating contract drift or replacing the contract with ad hoc runtime logic |
| `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` | pre-write enforcement for issue updates | broadening scope beyond the current issue contract |
| `elixir/lib/symphony_elixir/controller_finalizer.ex` | finalization path alignment | changing the meaning of `Spec Prep` or `In Review` |
| `elixir/lib/symphony_elixir/orchestrator.ex` | orchestration and continuation routing | duplicating contract language or inventing new lifecycle states |
| `elixir/test/symphony_elixir/let_workflow_contract_test.exs` | workflow prose/template consumer for the canonical task-spec shape | treating helper copies as canonical text |
| `elixir/test/symphony_elixir/spec_check_test.exs` | spec-description consumer and validator for canonical plan text | validating only helper-local shortcuts |
| `elixir/test/symphony_elixir/handoff_check_test.exs` | handoff consumer for runtime contract shape and proof mapping | collapsing description, workpad, and runtime proof surfaces |
| `elixir/test/symphony_elixir/let_workflow_contract_test.exs` and its live skill-file assertions | consumer for the live LET skill surfaces and onboarding path | treating imported skill copies as canonical text |
| contract and workflow tests | proving the same behavior the docs claim | codifying helper-specific shortcuts as if they were canonical |

## First-Pass Correctness Rules

The first pass is correct only if the mechanism is aligned before any correction loop has to rescue it.

Rules:

- each surface must use the same canonical names for the same lifecycle states;
- `Acceptance Matrix` is mandatory where the contract says it is mandatory, and `Required capabilities` cannot replace it;
- `Proof Mapping` must mean the same thing in issue description, workpad, and runtime checks;
- issue-description proof labels reserve future proof targets, while checked workpad evidence remains execution proof;
- `Checkpoint` is classified only where the contract says execution handoff exists;
- `Spec Review` remains a `Spec Prep` review gate, not an execution handoff;
- `In Review` is reserved for `human-verify`;
- `Blocked` is reserved for unresolved `decision` or `human-action` blockers;
- if a compatibility path exists, it must be described as compatibility, not as a second canonical route;
- if a surface cannot enforce something on first pass, the document should say where enforcement actually belongs instead of introducing a new gate.

The operational meaning of first-pass correctness is simple:

- no hidden manual fix is needed to make the first persisted description valid;
- no skill instruction contradicts the contract it points to;
- no workflow step asks for a field or state that the runtime does not recognize;
- no runtime check accepts a shape that the workflow or contract forbids;
- no validation file only proves a helper copy instead of the canonical mechanism.

## Surface Alignment

### Contract

`docs/policy/project-contract.md` is the canonical source of truth for task-spec structure, proof mapping, checkpoints, and handoff rules.

Alignment requirement:

- keep `Acceptance Matrix`, `Proof Mapping`, `Checkpoint`, and `In Review` / `Blocked` semantics stable and explicit;
- do not let workflow prose or skills redefine these terms;
- if a legacy fallback remains, make the fallback condition explicit in the contract rather than burying it in runtime prose.

### Workflow

`workflows/letterl/maxime/let.WORKFLOW.md` must behave like the operator mirror of the contract, not like a second contract.

Alignment requirement:

- the task-spec section should match the contract vocabulary exactly;
- the issue-description template and the workpad template should not disagree on ownership of proof labels versus checked evidence;
- the workflow also owns the producer-side actions that make the mirror executable: stage-start comments, workpad bootstrap, `.workpad-id` persistence, and `sync_workpad` handoff sequencing;
- `Spec Prep`, `Spec Review`, `In Review`, `Blocked`, and `Merging` should each map to a single interpretation;
- any mention of legacy `plan-mode` should be framed as compatibility only, not as a competing path with different semantics.
- the workflow is a consumer of the canonical contract text, while `cli.ex` and `workflow.ex` are the producers that route users into that workflow canon.

### Plan Skill

`.agents/skills/plan-mode/SKILL.md` must make `Spec Prep` deterministic enough that the first persisted issue description already satisfies the contract.

Alignment requirement:

- the authoring template should be copyable and canonical;
- the `Acceptance Matrix` and `Proof Mapping` rules should not require hidden interpretation;
- the swarm-assisted path, when enabled, should remain subordinate to the short plan and never become an alternate authority;
- any artifact path or revision pairing should be treated as supporting context only, not as a replacement for canonical planning text.
- `plan-mode` owns proof authoring and `Spec Prep` wording, while `execute-mode` owns checkpoint semantics and execution handoff wording.

### Execute Skill

`.agents/skills/execute-mode/SKILL.md` must consume the same contract that plan mode authors.

Alignment requirement:

- execution preflight should read the canonical plan metadata and supporting artifact without elevating the artifact to authority;
- `Execution Evidence` should record runtime facts only;
- proof targets in the issue description and proof rows in the workpad should stay internally consistent;
- execution must not widen scope beyond the issue contract.
- `spec_check.ex` and the contract tests are the primary consumers that verify authored text before runtime enforcement takes over.

### Land Skill

`.agents/skills/land/SKILL.md` should preserve the already-approved handoff shape while merge work is happening.

Alignment requirement:

- treat review and merge as post-handoff concerns;
- do not let merge automation introduce new task-spec semantics;
- keep the watcher loop and PR checks aligned with the same review-ready state defined by the contract.

### Swarm Support

`swarm-mode` and `swarm-iterate` are planning support, not a parallel mechanism.

Alignment requirement:

- critique and repair the plan artifact only;
- keep the short plan as SSOT when the swarm-assisted path is enabled;
- do not allow the linked artifact to redefine scope, proof, or checkpoint semantics;
- if the artifact and short plan diverge, the divergence is a failure condition, not a second opinion.
- the enabled-path dependency chain is explicit and linear: `mode:plan` + `planning.swarm_assist_enabled=true` -> `swarm-iterate` critique/repair -> artifact under `docs/reports/` -> artifact uploaded to Linear before `Spec Review` -> `plan_revision == artifact_revision` -> short plan remains canonical -> artifact stays supporting-only;
- if the gate is disabled, the legacy `plan-mode` path stays unchanged as compatibility fallback, but it is not a second canonical route.

### Runtime Service

The service layer must mirror the same mechanism rather than interpreting it again.

Alignment requirement:

- `codex/dynamic_tool.ex` is the pre-write owner: it blocks invalid issue updates before persistence;
- `handoff_check.ex` is the post-write owner: it parses and enforces the canonical handoff shape after the issue/workpad state exists;
- `controller_finalizer.ex` consumes the same handoff vocabulary during finalization, and `orchestrator.ex` consumes it during continuation routing;
- the concrete tool interfaces that carry the side effects are owned by those modules in sequence: `sync_workpad`, `github_wait_for_checks`, `github_pr_snapshot`, and `linear_upload_issue_attachment` move workpad state, PR evidence, and attachment evidence through the handoff path;
- runtime should enforce contract shape, not invent alternate logic to compensate for text drift.
- runtime consumes the output of the authoring and workflow layers; it does not redefine what those layers are allowed to produce.

## Recommended Repair Order

1. Lock the canonical vocabulary in the contract and workflow prose first.
   - Checkpoint: re-run ownership-map completeness and canonical text shape after this step before moving to step 2.
2. Make `plan-mode` reference proof-authoring semantics and `execute-mode` reference checkpoint semantics.
   - Checkpoint: re-run canonical text shape and confirm it still matches the contract before moving to step 3.
3. Keep swarm-assisted planning subordinate to the short plan and explicit about artifact support only.
   - Checkpoint: re-run canonical text shape plus the plan-skill and workflow assertions before moving to step 4.
4. Align runtime enforcement so it validates the same shape the docs and skills already require.
   - Checkpoint: re-run runtime enforcement shape and rollback / failure-mode shape before moving to step 5.
5. Align tests to the canonical surfaces instead of helper copies or shortcut terminology.
   - Checkpoint: re-run ownership-map completeness, runtime enforcement shape, and rollback / failure-mode shape on the same revision before moving to step 6.
6. Remove or rename leftover compatibility wording only after the canonical path is already stable.
   - Checkpoint: re-run all prior slices together and confirm no regression before treating the cleanup as complete.

This order preserves first-pass correctness because it fixes the definitions before asking the runtime to enforce them.

Rollback / failure mode:

- if any later step invalidates an earlier ownership, proof, or precedence assumption, stop at the first inconsistent step and preserve the last consistent state;
- do not advance to the next repair step until the earlier step's dependency is revalidated against the current document text;
- if a compatibility phrasing change breaks canonical alignment, keep the canonical wording and defer the compatibility cleanup rather than widening scope.

## Validation Bar

The `first-pass correctness` claim is only complete if the following proof sequence passes on the same document revision:

1. Ownership-map completeness:
   - `cli.ex`, `workflow.ex`, `spec_check.ex`, `handoff_check.ex`, `codex/dynamic_tool.ex`, `controller_finalizer.ex`, `orchestrator.ex`, the live LET skill surfaces (`research-mode`, `diagnose`, `zoom-out`, `tdd`, `symphony-setup`), `docs/onboarding/symphony-setup.md`, and the named test consumers must line up with the actual route and enforcement surfaces.
   - This slice only proves the map is complete; it does not yet prove canonical text or runtime behavior.
2. Canonical text shape:
   - `let_workflow_contract_test.exs` and `spec_check_test.exs` must assert the issue-description and workflow-template fields, proof labels, and transition meanings that the contract claims.
   - This slice proves authored text shape only; it does not yet prove runtime enforcement.
3. Runtime enforcement shape:
   - `handoff_check_test.exs` must prove the runtime rejects the same invalid shapes that the canonical text forbids, and that pre-write and post-write owners stay split.
   - This slice proves runtime behavior only; it does not substitute for authored-text proof.
4. Rollback / failure-mode shape:
   - `execution_rollout_test.exs` must prove rollback target and promotion semantics for the ordered repair path, and `dynamic_tool_test.exs` must prove material spec changes bounce back to `Spec Review` instead of drifting forward.
   - This slice proves the stop-and-preserve-last-consistent-state claim that the rollback section makes.
5. End-to-end consistency:
   - execute-mode, merge/watcher behavior, and the consumer/producer names in the ownership map must stay aligned with the same canonical vocabulary after the earlier slices pass.
   - This is an aggregate-only convergence gate, not a substitute for the rollback or ordering proofs; its concrete sources are the execute-mode, land, and workflow surfaces already named in the document.

Progression rule:

- do not claim first-pass correctness unless slices 1-5 pass together on the same document revision;
- if any slice fails, fix that slice before reinterpreting the next one.

For this branch, the implementation goal is not merely "eventually consistent". The goal is `first-pass correctness` on the canonical path.

## Closure Addendum

### 1. Legacy compatibility wording audit outside named LET surfaces

Closure quality: complete as compatibility-scoped wording audit outside the named LET surface files.

What is proven closed: remaining legacy wording in non-canonical helper docs is explicitly compatibility-scoped and does not introduce a parallel route/mechanism.

Closed with evidence.

Replay order:

1. Open [`workflows/letterl/maxime/README.md:50`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/README.md#L50) and verify the remaining `Spec Prep` / `Spec Review` compatibility wording.
2. Open [`workflows/letterl/maxime/README.md:62`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/README.md#L62) and verify the remaining `In Review` / `Blocked` compatibility wording.
3. Open [`elixir/AGENTS.md:64`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/AGENTS.md#L64) and verify the repo-local canon instruction that supports the compatibility-scoping conclusion when read together with the README lines.
4. Conclude from the README plus AGENTS together that the remaining legacy wording is compatibility-scoped and outside the named LET surface files, without treating it as a new route or mechanism.

- [`workflows/letterl/maxime/README.md:50`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/README.md#L50) still contains `Spec Prep` / `Spec Review` compatibility wording and the legacy `plan-mode` framing, so the audit result is now grounded rather than speculative.
- [`workflows/letterl/maxime/README.md:62`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/README.md#L62) keeps `In Review` / `Blocked` compatibility wording in the workflow README, confirming the remaining legacy language lives outside the named LET surface files.
- [`elixir/AGENTS.md:64`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/AGENTS.md#L64) identifies the local policy canon and reinforces that routing semantics should not be duplicated elsewhere, which makes the remaining wording auditably compatibility-scoped rather than ambiguous.

### 2. Full runtime call-site inventory

Closure quality: complete within the declared production-code boundary `elixir/lib/**/*.ex` and `elixir/lib/mix/tasks/**/*.ex`.

What is proven closed: every production-code reference to the canonical runtime tool names `sync_workpad`, `linear_upload_issue_attachment`, `github_pr_snapshot`, `github_wait_for_checks`, `symphony_handoff_check`, and `symphony_spec_check` is inventoried within that boundary, and the inventory is not being presented as an observed subset.

Closed with evidence.

Replay order:

1. Run `rg -n "sync_workpad|github_wait_for_checks|github_pr_snapshot|linear_upload_issue_attachment|symphony_handoff_check|symphony_spec_check" elixir/lib elixir/lib/mix/tasks` to establish the production-code boundary and the complete set of matches inside it.
2. Inspect [`elixir/lib/mix/tasks/handoff.check.ex:45-59`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/mix/tasks/handoff.check.ex#L45) to confirm the task entrypoint invokes `symphony_handoff_check` through `DynamicTool.execute/4`.
3. Inspect [`elixir/lib/symphony_elixir/controller_finalizer.ex:96`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L96), [`...:106`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L106), [`...:135`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L135), and [`...:305`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L305) to confirm the finalizer call sites for `sync_workpad`, `github_wait_for_checks`, `github_pr_snapshot`, and `symphony_handoff_check`.
4. Inspect [`elixir/lib/symphony_elixir/run_phase.ex:391-445`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/run_phase.ex#L391), [`elixir/lib/symphony_elixir/orchestrator.ex:6766-6792`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L6766), [`...:6957`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L6957), [`...:6975`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L6975), and [`...:7520-7529`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L7520) to confirm continuation-routing and linear-mutation call sites for the same canonical tool names.
5. Inspect [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:39-463`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L39), [`...:484-767`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L484), [`...:966-1214`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L966), [`...:1613-1629`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L1613), [`...:1714-1757`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L1714), [`...:2081-2127`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L2081), [`...:2307`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L2307), and [`...:3655-3732`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L3655) to confirm declaration, dispatch, execution, normalization, cross-checking, and error payload coverage for the full tool set.
6. Inspect [`elixir/lib/symphony_elixir/codex/app_server.ex:2016`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/app_server.ex#L2016), [`elixir/lib/symphony_elixir/spec_check.ex:83-359`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/spec_check.ex#L83), and [`elixir/lib/symphony_elixir/handoff_check.ex:798-2903`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/handoff_check.ex#L798) to confirm the remaining production-code references that participate in the same runtime tool boundary.

- [`elixir/lib/mix/tasks/handoff.check.ex:47`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/mix/tasks/handoff.check.ex#L47) calls `symphony_handoff_check` from the CLI task entrypoint.
- [`elixir/lib/symphony_elixir/controller_finalizer.ex:96`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L96) calls `sync_workpad`.
- [`elixir/lib/symphony_elixir/controller_finalizer.ex:106`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L106) calls `github_wait_for_checks`.
- [`elixir/lib/symphony_elixir/controller_finalizer.ex:135`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L135) calls `github_pr_snapshot`.
- [`elixir/lib/symphony_elixir/controller_finalizer.ex:305`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/controller_finalizer.ex#L305) calls `symphony_handoff_check`.
- [`elixir/lib/symphony_elixir/run_phase.ex:391-445`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/run_phase.ex#L391) recognizes `github_wait_for_checks` and `symphony_handoff_check` in external-step routing.
- [`elixir/lib/symphony_elixir/orchestrator.ex:6766-6792`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L6766) consumes `symphony_handoff_check`, `github_pr_snapshot`, and `github_wait_for_checks` results.
- [`elixir/lib/symphony_elixir/orchestrator.ex:6957`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L6957) and [`...:6975`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L6975) add additional continuation consumers for `github_wait_for_checks` and `symphony_handoff_check`.
- [`elixir/lib/symphony_elixir/orchestrator.ex:7520-7529`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L7520) treats `sync_workpad` and `linear_upload_issue_attachment` as linear mutation tools.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:39-463`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L39) declares all six tools and their schemas.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:484-767`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L484) dispatches and executes all six tools.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:966-1214`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L966) normalizes all six tool argument sets.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1613-1629`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L1613) queries issue state for `symphony_handoff_check`.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1714-1757`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L1714) and [`...:2081-2127`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L2081) enforce tool gating for `symphony_spec_check` and `symphony_handoff_check`.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:2307`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L2307) queries state for `symphony_handoff_check`.
- [`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:3655-3732`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L3655) emits tool-specific error payloads and transition guards for the same runtime tool boundary.
- [`elixir/lib/symphony_elixir/codex/app_server.ex:2016`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/app_server.ex#L2016) updates wait-guard feedback digests for `github_pr_snapshot`.
- [`elixir/lib/symphony_elixir/spec_check.ex:83-359`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/spec_check.ex#L83) and [`elixir/lib/symphony_elixir/handoff_check.ex:798-2903`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/handoff_check.ex#L798) carry runtime-facing validation and error text for `symphony_spec_check`, `symphony_handoff_check`, and `github_pr_snapshot`.

### 3. Branch-contract confirmation for swarm-assisted path subordinate to short plan

Closure quality: complete on the branch-contract question.

What is proven closed: the short plan remains canonical, the artifact is subordinate, and the enabled swarm-assisted path is a compatibility-controlled critique/repair branch rather than a second authority.

Closed with evidence.

Replay order:

1. Inspect [`docs/policy/project-contract.md:34`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L34) and [`docs/policy/project-contract.md:66`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L66) to confirm the short-plan authority rule.
2. Inspect [`docs/policy/project-contract.md:71`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L71) and [`docs/policy/project-contract.md:74`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L74) to confirm `swarm-iterate` is a critique/repair step that compresses into the canonical short plan.
3. Inspect [`workflows/letterl/maxime/let.WORKFLOW.md:794`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md#L794), [`...:795`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md#L795), and [`...:799`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md#L799) to confirm the enabled-path gate, SSOT wording, and compatibility-baseline wording.
4. Pass only if the inspected anchors collectively show short-plan SSOT precedence and compatibility-only fallback; otherwise do not close the branch-contract replay.

- [`docs/policy/project-contract.md:34`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L34) defines the two-layer plan contract and makes the short plan the authoritative body.
- [`docs/policy/project-contract.md:66`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L66) states that if the short plan and artifact diverge, the short plan is authoritative.
- [`docs/policy/project-contract.md:71`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L71) names `swarm-iterate` as the planning critique/repair orchestrator, and [`docs/policy/project-contract.md:74`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L74) compresses the result into the canonical short plan.
- [`workflows/letterl/maxime/let.WORKFLOW.md:794`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md#L794) requires `swarm-iterate` only when `planning.swarm_assist_enabled` is `true`, while [`workflows/letterl/maxime/let.WORKFLOW.md:795`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md#L795) keeps the short plan as SSOT and [`workflows/letterl/maxime/let.WORKFLOW.md:799`](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md#L799) explicitly preserves the legacy path only as compatibility baseline.

### 4. Helper-copy smoke separated from canonical proof

Closure quality: complete as a proof-lane separation finding, not as a proof of the whole mechanism.

What is proven closed: the canonical proof lane is the one that proves the mechanism, and the helper-copy smoke lane remains secondary compatibility evidence only.

Closed with evidence.

Replay order:

1. Inspect [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:18`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L18), [`...:48`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L48), and [`...:49`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L49) to verify the canonical workflow and proof-section assertions.
2. Inspect [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:159`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L159) to identify the helper-copy smoke lane that still reads live skill surfaces and the contract directly.
3. Inspect [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:242`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L242) to confirm the contract remains the canonical source of truth.
4. Keep the canonical proof lane and the helper-copy smoke lane separate when replaying the closure; do not use the smoke lane as proof of the canonical mechanism.

Canonical proof lane:

- [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:18`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L18) exercises the live LET workflow contract directly, establishing the canonical workflow surface under test.
- [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:48`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L48) and [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:49`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L49) assert the canonical `Acceptance Matrix` and `Proof Mapping` sections, which are the proof surfaces named by the contract.

Helper-copy compatibility smoke:

- [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:159`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L159) reads the live skill surfaces and contract directly, but that coverage is explicitly secondary to the canonical contract assertions rather than a replacement for them.
- [`elixir/test/symphony_elixir/let_workflow_contract_test.exs:242`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/let_workflow_contract_test.exs#L242) confirms the project contract itself is the canonical source of truth, so helper-file reads remain compatibility evidence only.

## Compact Ledger

- Point 1: closed, compatibility-scoped; residual issues: none.
- Point 2: closed, inventory-complete within the declared production-code boundary; residual issues: none.
- Point 3: closed, branch-contract confirmed; residual issues: none.
- Point 4: closed, canonical proof-vs-helper-smoke separation confirmed; residual issues: none.

## End State

When the plan is implemented, the LET mechanism should read as one system from intake to merge:

- one contract;
- one workflow mirror;
- one planning skill contract;
- one execution contract;
- one merge contract;
- one runtime enforcement path;
- one validation story.

That is the `first-pass correctness` target.
