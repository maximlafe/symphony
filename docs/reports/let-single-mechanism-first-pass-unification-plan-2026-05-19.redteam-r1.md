# Red Team Critique: LET Single Mechanism First-Pass Unification Plan (2026-05-19)

Target document:
- `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`

Round:
- 1 of 3

Focus:
- completeness and correctness of dependencies, prerequisites, producer/consumer ownership, and interface impacts across service/contracts/flows/scripts/skills

## Phase 1: Problem Definition

- Core problem: the target document claims a single aligned LET mechanism, but its dependency map does not fully or correctly identify the actual owners, prerequisite conditions, and interface consumers that make first-pass correctness possible.
- Scope: critique only the document's mapping of dependencies, prerequisites, ownership, and interface impacts.
- Out of scope: proposing new gates, new entities, new scripts, or a rework of the LET lifecycle.
- Success criteria: identify where the document misstates ownership, omits a prerequisite or consumer, or leaves an interface boundary ambiguous enough to break the claimed unification.
- Missing information: whether the author intended this document to be a full interface map or only a high-level plan; the text currently reads like the former.

## Phase 2: Expert Assembly

- Team size: 4
- Role mix: 2 critics, 1 balanced synthesizer, 1 implementation-focused critic
- Evidence boundary: local files only, with claims grounded in the target document and the referenced contract/workflow/skill files

## Audit Result

### Critical Findings

1. `verified issue` - wrong runtime owner path for `dynamic_tool`
   - The ownership map and runtime alignment section point to `elixir/lib/symphony_elixir/dynamic_tool.ex` as the pre-write enforcement owner.
   - The real module path in this repo is `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`.
   - Why this matters: the document is explicitly about ownership boundaries. A wrong file path is not a cosmetic typo here; it breaks the dependency map and any downstream implementation checklist that tries to locate the owning interface.
   - Affected lines: target document lines 59-60 and 162-165.
   - Impact: any repair round based on this map will start from a false owner reference, which undermines first-pass correctness before any code is touched.

2. `working criticism` - producer/consumer chain is incomplete for the actual LET entrypoints and validators
   - The target claims a single mechanism across contract, workflow, skills, runtime, and tests, but the ownership map omits the actual top-level producers that initiate the flow, such as the CLI and workflow loader, and it also omits the validation consumers that prove the canonical shape.
   - Specifically missing from the map and alignment story:
     - `cli.ex` / workflow entrypoint as the route producer;
     - `workflow.ex` as the canonical workflow-path resolver;
     - `spec_check` and workflow contract tests as consumers of the authored issue-description shape;
     - the precise test surfaces that consume the contract before runtime enforcement.
   - Why this matters: the document talks about "one validation story" and "first-pass correctness", but it never closes the loop from producer to consumer. Without that, the claimed unification is still abstract rather than interface-complete.
   - Affected lines: target document lines 7, 49-63, 178-186, and 199-207.

### Lower-Priority Findings

1. `bounded concern` - runtime responsibilities are collapsed too early
   - The runtime section names `handoff_check.ex`, `dynamic_tool.ex`, `controller_finalizer.ex`, and `orchestrator.ex`, but it does not distinguish the boundary between pre-write issue-update enforcement and post-write handoff validation strongly enough.
   - Why this matters: the document wants to align existing mechanisms, not create new ones. If the consumer boundary is not explicit, the next repair round can accidentally assign enforcement to the wrong layer.
   - Affected lines: target document lines 156-165.

2. `bounded concern` - swarm-assisted planning prerequisites are underspecified relative to the contract
   - The plan describes swarm support as subordinate to the short plan, but it does not restate the key prerequisite chain from the contract and workflow with enough precision to make the dependency map complete.
   - Missing in the target's own ownership/prerequisite language:
     - gate enabled vs legacy compatibility path;
     - artifact attachment before `Spec Review`;
     - revision pairing as a prerequisite for review-ready handoff;
     - the fact that the artifact is supporting-only and not a second authority.
   - Why this matters: the doc correctly wants a single mechanism, but its support-path description still reads like a general principle instead of an enforceable interface contract.
   - Affected lines: target document lines 113-122 and 145-154.

### Recommendations

1. Replace the incorrect `dynamic_tool` file path with the actual owner path.
2. Expand the ownership map to include the real producer/consumer chain: route entrypoint, workflow resolver, authoring skill, contract/workflow consumers, runtime enforcers, and validation tests.
3. Split runtime ownership into "pre-write issue-update enforcement" and "post-write handoff validation" so the interface boundary is explicit.
4. Restate swarm-assisted prerequisites as a dependency chain, not just as a subordinate principle.

## Mechanism Audit

### What the target explicitly promises

- one canonical LET vocabulary;
- one ownership boundary per surface;
- aligned `Acceptance Matrix`, `Proof Mapping`, and `Checkpoint` semantics;
- first persisted state already valid;
- explicit compatibility behavior when it exists.

### What the mechanism actually guarantees in the document

- the document gives a plausible high-level alignment intent;
- it partially names the main contract, workflow, skill, and runtime surfaces;
- it does not yet fully enumerate the producer/consumer chain that would make the promise mechanically checkable.

### Where the stronger reading fails

- the wrong `dynamic_tool` path breaks the owner map;
- missing entrypoint and validator consumers leave the unification chain incomplete;
- runtime ownership is not yet split with enough precision to prevent layer drift;
- swarm-support prereqs are described, but not as a fully closed dependency chain.

### Minimal Fix Set

- `P0`: correct the runtime owner path and expand the owner map to include the actual producer/consumer chain.
- `P1`: sharpen the runtime boundary and the swarm-assisted prerequisite chain so the document can support a true first-pass correctness claim.

## Route Ledger

- `ACTIVE`: ownership-path correctness
- `ACTIVE`: producer/consumer completeness
- `SUPPORTING`: runtime boundary sharpness
- `SUPPORTING`: swarm-assisted prerequisite chain

## Ordered Fix List for Repair Round

1. Fix the incorrect `dynamic_tool` path everywhere it appears in the target document.
2. Add the missing producer/consumer interfaces to the ownership map and surface-alignment sections.
3. Explicitly separate pre-write enforcement from post-write handoff validation in the runtime section.
4. Restate the swarm-assisted plan prerequisites as a closed dependency chain tied to the contract/workflow.
5. Re-run the validation bar wording after the ownership map is complete, so the first-pass correctness claim is actually grounded in the interface map.

## Compact Ledger

- Target document: `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`
- Focus used: completeness and correctness of dependencies, prerequisites, producer/consumer ownership, and interface impacts across service/contracts/flows/scripts/skills
- Main findings:
  - critical: wrong `dynamic_tool` owner path
  - critical: producer/consumer chain incomplete
  - lower priority: runtime boundary too compressed
  - lower priority: swarm prerequisites under-specified
- Exact ordered fix list:
  1. Fix the incorrect `dynamic_tool` path everywhere it appears in the target document.
  2. Add the missing producer/consumer interfaces to the ownership map and surface-alignment sections.
  3. Explicitly separate pre-write enforcement from post-write handoff validation in the runtime section.
  4. Restate the swarm-assisted plan prerequisites as a closed dependency chain tied to the contract/workflow.
  5. Re-run the validation bar wording after the ownership map is complete, so the first-pass correctness claim is actually grounded in the interface map.
