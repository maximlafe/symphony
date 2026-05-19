# LET-741 Plan First-Pass Correctness Remediation Red Team R2

## Phase 1: Problem Definition

- Core problem: critique whether the remediation plan can be implemented slice-by-slice without hidden carry-over, whether rollback/defer boundaries match the real dependency graph, whether tests prove first-pass authoring correctness rather than only post-hoc rejection, and whether the live smoke is sufficient and bounded.
- Scope: target plan only, with local code/doc evidence where it clarifies execution order, guard order, or test adequacy.
- Out of scope: editing the target document, implementing the plan, re-opening R1 parser/interface findings except where they affect sequencing or proof adequacy.
- Success criteria: identify blocking sequencing and validation gaps, separate critical findings from lower-priority concerns, and provide an exact ordered fix list.
- Uncertainties: the future implementation may choose either a new helper or an optioned helper; critique below treats the helper boundary as planned but not yet implemented.

## Phase 2: Expert Assembly

- Leslie Lamport (Critic, process/state invariants): checks temporal ordering, state gates, and whether a later slice can safely depend on earlier slices.
- Barbara Liskov (Critic, interface substitutability): checks rollback/defer boundaries around helper APIs and existing callers.
- Kent Beck (Balanced, test design): checks whether tests prove the intended behavior path rather than only isolated fixtures.
- Gene Kim (Evangelist, delivery flow): checks whether the plan can be shipped incrementally without hidden work-in-progress or broad rollback.
- Michael Nygard (Critic, production readiness/failure modes): checks the live smoke scope, external dependency boundaries, and failure attribution.

Evidence boundary: local files and the target document only; future behavior is called out as inference when not directly present in current code.

## Iteration 1: Execution-Order Audit

Moderator reasoning: the target now has good interface invariants, so the best first discriminator is whether the slice order can actually preserve the promise of first-pass correctness. I checked whether each slice has a self-contained verification boundary and whether later slices depend on earlier ones in ways that make rollback unsafe.

Executor findings:

- Verified fact: the plan orders docs authoring changes first, parser/helper second, SpecCheck enforcement fourth, DynamicTool guard fifth, and all regression tests last. See target lines 126-316.
- Verified fact: current SpecCheck only collects contract requirement findings for matrix presence and `required_before`; it does not call description proof mapping diagnostics today. See `elixir/lib/symphony_elixir/spec_check.ex:88-116` and `elixir/lib/symphony_elixir/spec_check.ex:517-540`.
- Verified fact: current DynamicTool checks `guard_proof_contract_description/2` before it fetches issue context, and that guard currently calls `HandoffCheck.proof_contract_errors/1` for any description containing `## Acceptance Matrix`. See `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1787-1794` and `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1889-1915`.
- Verified fact: the target says Slice E should align `issueUpdate(description)` with the new mode-scoped diagnostic, but also says the Slice E rollback boundary is only `dynamic_tool.ex`, if the change is required after Slice C/D. See target lines 252-275.

Mechanism audit:

1. Target promise: first completed `mode:plan` planning pass writes canonical `Proof Mapping`, invalid mappings are not accepted as passed, and malformed plan descriptions are blocked before write where scoped.
2. Actual planned mechanism: change authoring docs, add parser/helper, wire SpecCheck, then align DynamicTool, then add tests and smoke.
3. Stronger reading fails because SpecCheck and DynamicTool are not independent enforcement layers for the first write. SpecCheck can fail after the description exists; DynamicTool is the before-write guard. If DynamicTool alignment is deferred or implemented after SpecCheck without a temporary fail-closed plan, the plan may still permit bad first writes and only reject them later.
4. Minimal fix set: treat the description helper, SpecCheck call-site, and DynamicTool call-site as one ordered enforcement chain for mode-plan write correctness, or explicitly split the promise into “post-write spec gate” and “pre-write guard” phases with separate acceptance criteria.

## Iteration 2: Rollback/Defer Boundary Audit

Moderator reasoning: after the ordering pass, the largest remaining risk is whether the stated rollback boundaries are operationally real. I focused on cases where rolling back one file while keeping dependent slices would leave compile failures, behavior holes, or widened enforcement.

Executor findings:

- Verified fact: Slice D explicitly depends on the new description-only diagnostic from Slice C. See target lines 230-241.
- Verified fact: Slice E also depends on the new description-only diagnostic and mode-scoped behavior. See target lines 256-272.
- Verified fact: the target says each slice gets at most two fix attempts and then that slice is rolled back, with no partial parser or spec-gate changes carried into the next slice after rollback. See target lines 345-348.
- Verified fact: Slice A and Slice B broaden authoring instructions to legacy spec-prep, while later enforcement says legacy must be precisely detected or deferred. See target lines 73-74, 245-248, and current `.agents/skills/plan-mode/SKILL.md:107-108` / `workflows/letterl/maxime/let.WORKFLOW.md:817-821`.

Route update:

- ACTIVE: dependency rollback boundaries for C/D/E.
- SUPPORTING: authoring-doc legacy broadening before enforcement predicate exists.
- CLOSED: no need to revisit R1's split-validator finding except as a dependency precondition.

## Iteration 3: Test and Smoke Adequacy Audit

Moderator reasoning: the user specifically asked whether tests prove first-pass authoring correctness rather than merely blocking bad writes. I inspected the named regressions and compared them to the end-to-end promise.

Executor findings:

- Verified fact: the proposed tests include negative SpecCheck, positive SpecCheck, parser tests, DynamicTool blocking, DynamicTool non-plan non-regression, description/workpad separation, and workflow/skill template string checks. See target lines 286-314.
- Verified fact: the current workflow contract tests mostly assert presence of phrases in skill/workflow/policy text, not execution of an authoring run. See existing `elixir/test/symphony_elixir/let_workflow_contract_test.exs` references surfaced by search and target line 312.
- Verified fact: the live smoke asks to create a new simple `mode:plan` Linear issue, run local Symphony, confirm canonical mapping, confirm `symphony_spec_check`, confirm no manual repair, and later confirm handoff separation. See target lines 331-340.
- Working inference: the proposed local tests prove that canonical fixture descriptions pass and noncanonical fixture descriptions fail. They do not by themselves prove that the planning prompt/workflow causes the first generated description to contain the canonical block, because no deterministic authoring path is exercised locally.

## Critical Findings

### C1. Slice E is too deferable for a first-pass write guarantee

Result type: verified issue.

Target references: target lines 5-7, 252-275, 331-338.

Evidence:

- The target promise is first-pass task-spec description correctness, not only eventual rejection by `symphony_spec_check`.
- The only before-write layer in the named implementation surfaces is DynamicTool `issueUpdate(description)`. Current guard order runs a generic proof-contract check before mode context is available. See `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1787-1794` and `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1889-1915`.
- Slice E is phrased as alignment that may be needed “after Slice C/D,” with a rollback boundary limited to `dynamic_tool.ex`.

Impact:

- If Slice D lands without Slice E, a bad mode-plan description can still be written and only later fail SpecCheck. That improves gate correctness but does not satisfy first-pass authoring/write correctness.
- If Slice E is deferred after DynamicTool complexity, acceptance criteria that require `issueUpdate(description)` to block malformed mode-plan mapping become unsatisfied.

Required repair:

- Promote Slice E from conditional/deferable alignment to a required enforcement slice for the first-pass write guarantee.
- Order the enforcement chain as C then E then D, or C then D+E as a single atomic enforcement group, so the before-write guard and post-write spec gate cannot drift.
- If E must be deferred, explicitly narrow the shipped claim to “SpecCheck rejects bad mappings after write,” and remove first-pass/before-write acceptance criteria from that milestone.

### C2. Rollback boundaries for C/D/E are not dependency-safe as written

Result type: verified issue.

Target references: target lines 224, 250, 274-275, 345-348.

Evidence:

- Slice D calls the helper introduced in Slice C by design. Slice E also depends on the same helper and mode-scoped semantics.
- The rollback rule says rollback “that slice” after two attempts and do not carry partial parser or spec-gate changes into the next slice.

Impact:

- Rolling back Slice C while keeping Slice D or E would either fail compilation or silently remove the enforcement primitive those slices need.
- Rolling back Slice D while keeping Slice E creates a before-write-only system where SpecCheck may still pass a bad existing description, weakening the stated “not accepted as passed” guarantee.
- Rolling back Slice E while keeping Slice D creates a post-write-only system, weakening first-pass write correctness.

Required repair:

- Define dependency-aware rollback groups: C is the interface foundation; D and E are dependent call-sites. If C rolls back, D/E must roll back or be behind a feature-free no-op shim.
- Define separate minimum shippable sets: authoring-only A+B; spec-gate-only C+D; first-pass write correctness C+D+E plus A+B.
- Make tests for each minimum set explicit before allowing partial shipment.

### C3. Tests are currently back-loaded, so slices are not actually verifiable slice-by-slice

Result type: bounded concern with verified plan evidence.

Target references: target lines 277-316, 320-329, 345-348.

Evidence:

- The plan lists all regressions in Slice F after A-E.
- Rollback rules require deciding whether each slice is green after at most two attempts, but no per-slice red/green tests are assigned to A, B, C, D, or E.

Impact:

- The implementation can accumulate hidden carry-over across A-E and only discover failures in Slice F, at which point the “rollback that slice” instruction is ambiguous because failures may originate in parser, SpecCheck wiring, DynamicTool guard order, or docs.
- Back-loaded tests make it harder to prove that C did not alter handoff semantics before D/E are added.

Required repair:

- Move tests into the slices they prove: C owns parser/helper and handoff separation tests; D owns SpecCheck positive/negative/mode-scope tests; E owns DynamicTool before-write and non-plan non-regression tests; A/B own workflow/skill template tests.
- Keep Slice F only for cross-surface regression sweep and broader validation.

### C4. The local test plan proves validator behavior more than first-pass authoring behavior

Result type: working criticism.

Target references: target lines 126-174, 286-314, 331-338.

Evidence:

- SpecCheck tests with fixture descriptions prove pass/fail semantics for supplied text.
- DynamicTool tests prove bad supplied text can be blocked before write.
- The workflow/skill regression only says to prove the canonical template and forbidden examples are documented.
- No named local test exercises the actual plan-mode prompt/rendering path that produces the first `issueUpdate(description)` payload.

Impact:

- The plan could pass all local tests while the authoring agent still omits the `## Proof Mapping` block, paraphrases it, places it after `## Symphony`, or uses `*` bullets in a real first pass.
- Live smoke may catch this, but it is late, external, and potentially flaky. That makes authoring correctness depend on a manual/end-to-end check rather than a deterministic regression.

Required repair:

- Add a deterministic authoring-contract test, even if it is doc-level: assert the exact copyable template includes `## Acceptance Matrix`, a `required_before` column, `## Proof Mapping`, `- AM-1 -> validation:am-1`, `- AM-2 -> runtime:runtime smoke`, and that this block appears before final `## Symphony` guidance.
- Prefer a stronger test if an existing prompt rendering surface exists: render the mode-plan instruction/prompt and assert the same canonical block and forbidden prefixes are present in the actual prompt delivered to the agent.
- Keep live smoke as confirmation, not the first proof of authoring-path correctness.

### C5. The live smoke is directionally right but not sufficiently scoped for failure attribution

Result type: bounded concern.

Target references: target lines 331-340, 365-368.

Evidence:

- The smoke includes creating a Linear issue and running local Symphony, then later checking execution handoff independence.
- The plan acknowledges Linear/auth/runtime flakiness, but it does not define the exact minimal issue content, labels, expected state transition, capture artifacts, timeout/retry policy, or what evidence distinguishes authoring failure from guard failure from SpecCheck failure.

Impact:

- A failed smoke may be hard to interpret: bad generated text, blocked write, missing local branch wiring, Linear state mismatch, or SpecCheck invocation failure can all look like “the smoke failed.”
- The “during later execution handoff” check expands the smoke beyond first-pass planning and may require unrelated execution work, making the smoke heavier than necessary for this remediation.

Required repair:

- Scope the live smoke to one minimal mode-plan planning issue and capture three artifacts: attempted `issueUpdate(description)` payload or resulting description, `symphony_spec_check` output, and confirmation that no manual edit occurred between first write and SpecCheck.
- Split the later execution-handoff independence check into a separate optional compatibility smoke or rely on deterministic local handoff tests for this plan.
- Define stop conditions: one fresh issue, one local run, bounded retry only for external Linear/auth failures, and no product-code execution required.

## Lower-Priority Findings

### L1. Legacy spec-prep is still broadened in authoring docs before a precise enforcement predicate exists

Result type: bounded concern.

Target references: target lines 73-74, 245-248; current `.agents/skills/plan-mode/SKILL.md:107-108`; current `workflows/letterl/maxime/let.WORKFLOW.md:817-821`.

Impact:

- The plan says legacy enforcement must be precise or deferred, but authoring prose already applies the same invariants to legacy spec-prep. That is probably safe as guidance, but it can create a behavior mismatch: agents may rewrite legacy tickets more aggressively than validators enforce.

Suggested repair:

- In A/B, phrase legacy spec-prep guidance as “when the workflow can precisely identify this as legacy spec-prep; otherwise prefer mode:plan-scoped enforcement first.”
- Or defer legacy authoring changes along with legacy enforcement.

### L2. Rollback rules do not say what to do with documentation-only slices if enforcement slices fail

Result type: bounded concern.

Target references: target lines 160, 176, 349-350.

Impact:

- If A/B land but C/D/E fail and are deferred, the docs will instruct agents to produce canonical mapping but no validator will enforce it. That may be acceptable, but the plan should name it as an authoring-only partial state rather than implying full remediation.

Suggested repair:

- Add a partial-shipment ledger state: A+B only is allowed as guidance hardening, but it must not close LET-741 or claim first-pass correctness until C+D+E and tests are green.

### L3. Test expectations should assert diagnostics are specific enough for repair, not just pass/fail

Result type: bounded concern.

Target references: target lines 288-293, 304-308.

Impact:

- If diagnostics only say “proof contract error,” authors may not know to replace `test:` with `validation:` or `runtime_smoke:` with `runtime:`. The plan asks for one diagnostic mentioning canonical prefixes, but does not require pair-specific diagnostics for all bad pairings through SpecCheck and DynamicTool.

Suggested repair:

- For D/E tests, assert reason codes or message fragments distinguish malformed prefix, missing mapping, duplicate AM id, unknown AM id, and proof_type/reference mismatch.

## Recommendations

- Reorder implementation to A/B docs plus their contract tests, then C helper plus parser/separation tests, then E before-write guard tests, then D SpecCheck tests, then final sweep. If keeping D before E, explicitly state the temporary guarantee is post-write only.
- Replace file-only rollback boundaries with dependency rollback groups: `C-foundation`, `D-spec-gate-callsite`, `E-before-write-callsite`, and `A/B-authoring-guidance`.
- Add a per-slice “green proof” line under each slice so the two-attempt rollback rule has an objective signal.
- Add a deterministic authoring-path test or prompt-rendering test; do not rely only on live Linear smoke to prove first-pass generation.
- Split live smoke into a minimal planning smoke and an optional handoff-compatibility smoke.

## Compact Ledger

- Target document: `docs/reports/let-741-plan-first-pass-correctness-remediation.md`.
- Focus used: execution order, rollback/defer boundaries, test coverage adequacy, first-pass authoring proof versus bad-write blocking, and live smoke scoping.
- Main findings: Slice E is too deferable for a first-pass write guarantee; C/D/E rollback boundaries are dependency-unsafe; tests are back-loaded instead of slice-local; local tests prove validator fixtures more than actual first-pass authoring; live smoke needs tighter failure attribution and should not bundle later execution handoff.
- Exact ordered fix list: 1. Define minimum shippable sets: A+B guidance only, C+D spec-gate only, and A+B+C+D+E full first-pass write correctness. 2. Promote DynamicTool Slice E to required for the full first-pass guarantee, or explicitly narrow any partial shipment to post-write SpecCheck enforcement. 3. Make C the foundation slice and declare D/E dependent rollback with C; do not allow C rollback while D/E remain active. 4. Move tests into their owning slices: A/B template tests, C parser/separation tests, D SpecCheck scope tests, E DynamicTool before-write/non-plan tests. 5. Add a deterministic authoring-path or prompt-rendering test proving the actual plan-mode instruction contains the canonical copyable `Proof Mapping` block. 6. Require diagnostics-specific assertions for bad prefix, missing mapping, duplicate/unknown AM id, and proof_type/reference mismatch across D/E where applicable. 7. Clarify legacy spec-prep as deferred unless a precise predicate exists before both authoring and enforcement changes. 8. Scope live smoke to one fresh mode-plan issue, one local run, captured first description/update payload, captured SpecCheck output, no manual edit, and bounded external-retry rules. 9. Move the later execution-handoff independence check to deterministic local tests or a separate optional compatibility smoke.
