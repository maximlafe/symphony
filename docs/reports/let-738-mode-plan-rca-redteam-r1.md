# LET-738 `mode:plan` RCA Red-Team Round 1

## Scope For This Round
- Focus: completeness and correctness of dependencies, prerequisites, and interface impacts.
- Constraint: proposed fixes must stay within existing mechanisms only; no new entities, no new scripts, no new policy layer.

## Problem Frame
The target RCA correctly identifies a real contract issue around `mode:plan`, but it does not yet prove that the proposed fixes are complete with respect to the mechanisms that actually own the behavior. The document mixes three interfaces:
- planning-description generation,
- `issueUpdate(description)` enforcement,
- Linear retry / milestone publication.

The current draft does not separate those interfaces sharply enough, so its fix plan can be read as if a description-writer change alone would address blocker behavior that is actually owned by other layers.

## Critical Findings

### 1) Missing prerequisite map for the enabled planning path
The document states that `mode:plan` is a canonical short-plan flow with `Acceptance Matrix` semantics, but it never enumerates the prerequisites that make that path valid in this repo: `planning.swarm_assist_enabled=true`, `plan-mode` as the only planning entrypoint in enabled mode, and the `artifact_path` / `artifact_revision` / attachment contract that must already hold before planning handoff is complete.

Why this matters:
- The target fix plan says the generated description must include `Document Spec`, `Verification Plan`, `Residual Risks`, `Acceptance Matrix`, and `Proof Mapping` ([let-738-mode-plan-rca.md:33](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L33), [let-738-mode-plan-rca.md:34](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L34), [let-738-mode-plan-rca.md:35](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L35), [let-738-mode-plan-rca.md:36](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L36), [let-738-mode-plan-rca.md:37](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L37), [let-738-mode-plan-rca.md:38](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L38), [let-738-mode-plan-rca.md:39](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L39)).
- But the actual enabled-mode contract also requires `plan_revision`, `artifact_path`, `artifact_revision`, and Linear attachment upload before handoff ([project-contract.md:43](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L43), [project-contract.md:49](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L49), [project-contract.md:50](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L50), [project-contract.md:51](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L51), [project-contract.md:52](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L52), [project-contract.md:57](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L57), [project-contract.md:59](/Users/lafe/.codex/worktrees/a262/Symphony/docs/policy/project-contract.md#L59), [elixir/WORKFLOW.md:212](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/WORKFLOW.md#L212), [elixir/WORKFLOW.md:215](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/WORKFLOW.md#L215), [elixir/WORKFLOW.md:218](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/WORKFLOW.md#L218), [elixir/WORKFLOW.md:219](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/WORKFLOW.md#L219), [elixir/WORKFLOW.md:220](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/WORKFLOW.md#L220)).
- Without that prerequisite map, the fix plan is incomplete: it covers only the short-plan content schema, not the handoff prerequisites that gate review-ready acceptance.

Status: `verified issue`

### 2) Interface ownership is blurred between writer, guard, and tracker
The RCA implies that the non-canonical description problem is primarily a planning-content issue, but the evidence shows the hard enforcement lives in the description-update guard, while the blocker storm came from tracker-side Linear retries and milestone publishing.

Why this matters:
- `issueUpdate(description)` is blocked by the `Acceptance Matrix` guard in `dynamic_tool.ex` ([dynamic_tool.ex:1940](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L1940), [dynamic_tool.ex:1955](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/codex/dynamic_tool.ex#L1955)).
- The target correctly notes the 429 retry storm in live logs ([let-738-mode-plan-rca.md:20](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L20), [let-738-mode-plan-rca.md:29](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L29), [let-738-mode-plan-rca.md:30](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L30)).
- But the fix plan collapses those into one remediation story and does not say which layer owns which failure mode. That makes the proposal hard to implement cleanly inside existing mechanisms, because a generator fix and a retry-throttle fix are different interfaces with different regressions.

Status: `verified issue`

### 3) The fix plan omits the dependency that actually preserves bounded convergence
The document says the later patch made the path "bounded and fail-closed", but the repair plan itself does not restate the existing bounded-convergence prerequisites that make this true: retry-poll continuation ceiling logic and the continuation-specific retry metadata path.

Why this matters:
- The bounded behavior is implemented by the orchestrator continuation path, not by the description writer ([orchestrator.ex:1943](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L1943), [orchestrator.ex:1958](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L1958), [orchestrator.ex:4515](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L4515), [orchestrator.ex:4533](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L4533), [let-738-mode-plan-rca.md:21](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L21)).
- The target fix plan only says to keep Linear 429 handling bounded ([let-738-mode-plan-rca.md:35](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L35), [let-738-mode-plan-rca.md:36](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L36), [let-738-mode-plan-rca.md:37](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L37), [let-738-mode-plan-rca.md:38](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md#L38)) but does not specify the existing control points that must remain untouched.
- That omission makes the fix list underspecified for a reader trying to patch within the current system without accidentally weakening the continuation ceiling.

Status: `working criticism`

## Lower-Priority Findings

### 1) The residual-risk section is too weak for dependency-heavy behavior
The residual issues mention that the exact pre-fix description text was not preserved and that triggers can vary by run, but they do not explicitly call out the missing interface map as a residual risk. For a document whose own fix plan depends on existing mechanisms, that is a material omission.

Status: `bounded concern`

### 2) The target should name the interface impact of each proposed fix
The repair list talks about "the generated description", "the exact generator", and "downstream tracker plumbing", but it does not assign each fix to a concrete existing interface:
- planning-description generator,
- issue-description update guard,
- Linear milestone publishing / retry loop,
- workpad execution evidence.

That makes the document harder to operationalize and easier to misread as proposing a single-layer change.

Status: `bounded concern`

## Recommendations
1. Add a dependency / prerequisite matrix to the RCA before the fix plan.
2. Split the fix plan by owning interface: description generation, description-update guard, tracker retry / milestone publication, and workpad evidence.
3. Preserve the existing bounded-convergence mechanisms exactly as-is; do not introduce new entities, scripts, or policy layers.
4. Reword the residual-risk section so it explicitly states which prerequisite is still unverified versus which interface is merely inferred.

## Exact Ordered Fix List For The Repair Round
1. Add a compact `Dependencies / Prerequisites` subsection that lists the enabled planning gate, the `plan-mode` entrypoint, `artifact_path` / `artifact_revision`, and Linear attachment requirements.
2. Add an `Interface Impacts` subsection that maps each proposed change to one existing owner only.
3. Recast the fix plan so the description-schema fix and the Linear retry fix are separate bullets with separate validation expectations.
4. Add one sentence stating that the current bounded retry / continuation behavior is preserved and is not being redesigned.
5. Update residual issues to include the missing prerequisite map as an explicit open issue until it is verified.

## Compact Ledger
- Target document: `/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-mode-plan-rca.md`
- Focus used: completeness and correctness of dependencies, prerequisites, and interface impacts
- Main findings:
  - missing prerequisite map for enabled `mode:plan`
  - blurred ownership between writer, guard, and tracker
  - underspecified bounded-convergence dependency
- Exact ordered fix list for the repair round:
  1. add dependencies / prerequisites subsection
  2. add interface impacts subsection
  3. separate description-schema and retry fixes
  4. state bounded retry behavior is preserved
  5. make missing prerequisite map a residual issue
