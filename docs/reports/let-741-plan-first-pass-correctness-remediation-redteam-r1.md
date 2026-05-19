# LET-741 Plan First-Pass Correctness Remediation Red Team R1

## Phase 1: Problem Definition

- Core problem: critique whether the remediation plan correctly handles dependencies, prerequisites, and interface impacts across issue-description plain bullets, workpad checkbox parsing, SpecCheck, HandoffCheck, DynamicTool `issueUpdate` guards, and the no-new-scripts/no-new-policy constraint.
- Scope: the target plan only; no edits to the target document. Evidence is local files in this workspace.
- Out of scope: repairing the plan, implementing code, changing policy, or broad critique unrelated to dependency/interface correctness.
- Success criteria: identify blocking interface mismatches, distinguish critical findings from lower-priority concerns, and provide an ordered repair list.
- Uncertainties: exact intended API shape for future description-only proof diagnostics is not present in code today; recommendations below infer the minimal safe interface from current callers.

## Phase 2: Expert Assembly

- Martin Fowler (Critic, software architecture boundaries): checks whether the proposed slices preserve separation between authoring contracts and execution evidence.
- Barbara Liskov (Critic, interface substitutability): checks whether reusing `HandoffCheck.proof_contract_errors/1` preserves caller expectations.
- Leslie Lamport (Critic, state/process invariants): checks whether guards and gates enforce the intended temporal states without over-constraining other paths.
- Kent Beck (Balanced, test contract design): checks whether regression tests prove the intended behavior rather than a misleading approximation.
- Gene Kim (Evangelist, delivery flow): checks whether the plan can be sequenced safely without new scripts or policy surfaces.

Evidence boundary: verified local file evidence only, with clearly marked inferences where implementation details are not yet defined.

## Iteration 1: Interface Mechanism Audit

Moderator reasoning: the target plan claims an end-to-end guarantee: first-pass `mode:plan` descriptions become canonical and invalid mappings are rejected before acceptance. The strongest discriminator is whether the named existing interfaces can safely carry both syntax-only description validation and execution-proof validation. I used local code evidence to test that mechanism.

Executor findings:

- Verified fact: `HandoffCheck.proof_contract_errors/1` currently parses workpad sections via `parse_workpad/1`, which splits only `###` sections and reads `### Proof Mapping` through checkbox rows. See `elixir/lib/symphony_elixir/handoff_check.ex:823` and `elixir/lib/symphony_elixir/handoff_check.ex:1689`.
- Verified fact: current workpad mapping parsing requires checkbox rows and extracts the AM id only from backticks. `parse_checkbox_items/1` matches `- [x] ...`, and `mapping_matrix_item_id/1` looks for `` `...` ``. See `elixir/lib/symphony_elixir/handoff_check.ex:1564`, `elixir/lib/symphony_elixir/handoff_check.ex:1689`, and `elixir/lib/symphony_elixir/handoff_check.ex:2025`.
- Verified fact: `SpecCheck.contract_requirement_findings/3` currently checks `Acceptance Matrix` presence and explicit `required_before` for `mode:plan`; it does not call proof-contract diagnostics. See `elixir/lib/symphony_elixir/spec_check.ex:517`.
- Verified fact: `DynamicTool.guard_proof_contract_description/2` calls `HandoffCheck.proof_contract_errors(description)` whenever the new description contains `## Acceptance Matrix`, before issue context is consulted for `mode:plan`. See `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1787` and `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1889`.
- Verified fact: project policy requires each required matrix item to map to exactly one concrete proof source and says execution-oriented specs use `Acceptance Matrix`; it also says artifact mappings require checked workpad artifact plus matching Linear attachment. See `docs/policy/project-contract.md:160` and `docs/policy/project-contract.md:182`.

Mechanism audit:

1. Target promise: `mode:plan` and legacy spec-prep descriptions get canonical plain-bullet `Proof Mapping` on first pass; SpecCheck and `issueUpdate(description)` reject noncanonical mapping; workpad checkbox handoff remains compatible; no new scripts or policies are introduced.
2. Actual planned mechanism: add authoring templates, add a plain-bullet parser inside `HandoffCheck`, reuse `HandoffCheck.proof_contract_errors/1` from SpecCheck and DynamicTool, then add tests.
3. Stronger reading fails because `proof_contract_errors/1` is not currently a description syntax contract. It validates checked execution evidence from a workpad and artifacts/attachments. Direct reuse for spec-prep descriptions conflates “canonical mapping syntax exists” with “mapped validation/artifact proof is checked,” which is not true before execution.
4. Minimal fix set: define a mode-aware description-only proof mapping diagnostic surface, or add an explicit option that disables workpad evidence requirements while preserving syntax/cardinality/type checks. Then wire SpecCheck and DynamicTool to that surface, leaving handoff execution checks unchanged.

## Critical Findings

### C1. Directly reusing `HandoffCheck.proof_contract_errors/1` for issue descriptions conflates syntax validation with execution proof validation

Result type: verified issue.

Target references: `docs/reports/let-741-plan-first-pass-correctness-remediation.md:151`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:167`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:194`.

Evidence:

- `proof_contract_errors/1` parses workpad sections and validates checked mappings against checked validation/artifact evidence. The validation path reaches `validate_matrix_mapping/7`, `find_checked_validation_item/4`, and artifact attachment checks. See `elixir/lib/symphony_elixir/handoff_check.ex:114`, `elixir/lib/symphony_elixir/handoff_check.ex:2185`, and `elixir/lib/symphony_elixir/handoff_check.ex:2279`.
- A valid issue-description bullet like `AM-1 -> validation:am-1` cannot by itself provide a checked `Validation` checkbox or checked artifact entry, because those are workpad/execution surfaces.

Impact:

- The proposed positive regression `spec_check accepts mode_plan_plain_bullet_canonical_proof_mapping` is likely incompatible with naive reuse of `proof_contract_errors/1`: SpecCheck would reject the canonical description because there is no checked workpad validation entry yet.
- If implementers weaken `proof_contract_errors/1` to allow description-only mappings, they risk weakening handoff/execution proof enforcement for existing callers.

Required repair:

- Split the interface explicitly: keep `proof_contract_errors/1` as execution/handoff proof validation, and add a description-only diagnostic such as `issue_description_proof_mapping_errors/1` or `proof_contract_errors(markdown, mode: :description_contract)`.
- The description-only path should validate section presence, bullet format, AM id coverage, duplicate AM ids/mappings, allowed prefixes, and proof_type-to-reference-type compatibility only. It must not require checked workpad validation, checked artifacts, or Linear attachments.

### C2. Slice C asks for `- AM-1 -> ...`, but the current workpad parser normalization extracts AM ids only from backticks

Result type: verified issue.

Target references: `docs/reports/let-741-plan-first-pass-correctness-remediation.md:91`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:131`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:133`.

Evidence:

- The target template uses plain bullets without backticks: `- AM-1 -> validation:am-1`.
- Current `mapping_matrix_item_id/1` returns an id only from a backticked token. See `elixir/lib/symphony_elixir/handoff_check.ex:2025`.
- Current format error text says the proof mapping entry is missing a matrix item id in backticks. See `elixir/lib/symphony_elixir/handoff_check.ex:2431`.

Impact:

- “Normalize mapping id and reference by the same rules as workpad mapping” conflicts with the proposed issue-description grammar. If the implementation literally reuses the workpad extraction rule, every target template row is malformed.
- This also affects tests: a positive plain-bullet test could fail because the parser expects `` `AM-1` `` rather than `AM-1`.

Required repair:

- Define separate issue-description grammar exactly, for example `^-\s+([^\s`]+)\s*->\s*(validation|artifact|runtime):(.+)$`, plus optional backtick tolerance if desired.
- Keep workpad checkbox grammar unchanged, including any existing backtick expectations.
- Update diagnostic copy so description mapping errors do not say “in backticks” unless backticks are actually required.

### C3. Adding missing Proof Mapping errors inside `HandoffCheck.proof_contract_errors/1` can over-block DynamicTool for non-plan descriptions

Result type: verified issue.

Target references: `docs/reports/let-741-plan-first-pass-correctness-remediation.md:154`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:158`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:167`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:171`.

Evidence:

- `DynamicTool.guard_proof_contract_description/2` calls `HandoffCheck.proof_contract_errors(description)` for any update containing `## Acceptance Matrix`, before it resolves issue context and before it knows whether the issue is `mode:plan`. See `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1787` and `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1889`.
- The separate `guard_plan_mode_acceptance_matrix_presence/3` is mode-aware, but it runs after the unconditional proof-contract guard. See `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1917`.

Impact:

- If `proof_contract_errors/1` starts returning “missing `## Proof Mapping`” for any non-empty Acceptance Matrix, then any non-plan description with an Acceptance Matrix but no Proof Mapping can be blocked by `issueUpdate(description)`, contradicting Slice D’s “non-plan behavior not tightened” constraint.
- This can also affect legacy execution/review-oriented tasks where the plan has not clearly specified whether plain-bullet issue-description Proof Mapping is mandatory or only `mode:plan` and legacy spec-prep.

Required repair:

- Make DynamicTool’s description proof-mapping guard mode-aware before invoking description-only proof mapping diagnostics, or pass issue labels/context into the diagnostic call.
- Preserve the current generic matrix parse guard only for truly malformed matrix rows if that behavior is already intentional; scope new missing/malformed Proof Mapping rejection to `mode:plan` and explicitly defined legacy spec-prep cases.

### C4. The plan does not specify how issue-description mappings and workpad mappings coexist during handoff, risking duplicate or contradictory mapping errors

Result type: working criticism grounded in current call graph.

Target references: `docs/reports/let-741-plan-first-pass-correctness-remediation.md:132`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:239`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:250`.

Evidence:

- The current handoff proof contract expects checked workpad mappings as execution evidence. See `elixir/lib/symphony_elixir/handoff_check.ex:2051` and `elixir/lib/symphony_elixir/handoff_check.ex:2172`.
- The target adds issue-description plain-bullet mappings but does not define whether those are syntax-only metadata, execution mappings, or a source merged into the existing workpad mapping list.

Impact:

- If plain-bullet description mappings are merged into the same mapping collection as checked workpad mappings, final handoff could see duplicates for the same AM id once execution adds checked workpad mappings.
- If description mappings are treated as checked mappings, handoff could falsely satisfy mapping coverage before execution evidence exists.
- If description mappings are ignored by handoff, that is probably correct, but the plan must say so explicitly because it also says to reuse `HandoffCheck` diagnostics.

Required repair:

- State an invariant: issue-description `## Proof Mapping` is a spec-gate syntax/cardinality contract, not execution proof evidence.
- State that handoff continues to require checked workpad `### Proof Mapping`, `### Validation`, `### Artifacts`, and attachments as applicable.
- Ensure tests include a combined description+workpad handoff case to prove plain description mappings neither duplicate nor satisfy checked workpad mappings.

### C5. Runtime mapping semantics are under-specified: current HandoffCheck allows `runtime` reference type for non-runtime proof types

Result type: verified issue.

Target references: `docs/reports/let-741-plan-first-pass-correctness-remediation.md:141`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:142`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:157`.

Evidence:

- Current `validate_validation_matrix_mapping/8` accepts both `validation` and `runtime` reference types for non-artifact mappings, then finds a checked validation item. See `elixir/lib/symphony_elixir/handoff_check.ex:2244`.
- Runtime-specific rejection is indirect: a `runtime` reference for a test may fail only because no checked validation matches, not because the reference type is semantically wrong.

Impact:

- The target’s desired rule “`proof_type=test` mapped to non-`validation` is an error” is stricter than current behavior and must be implemented in the description-only path and possibly in handoff path without breaking legacy workpad cases.
- The observed bad line `AM-3 -> runtime:GitHub PR snapshot` may pass prefix syntax and then fail only if tied to the wrong proof_type or missing runtime label. The plan should require a deterministic diagnostic for “runtime mapping must be used only with `runtime_smoke`.”

Required repair:

- Add explicit type-pair validation in the new description diagnostic: `test -> validation`, `runtime_smoke -> runtime`, `artifact -> artifact`.
- Decide separately whether the existing handoff workpad validator should be tightened to the same pairings, and if so add compatibility tests for existing accepted workpads.

## Lower-Priority Findings

### L1. The plan says legacy spec-prep path must behave like `mode:plan`, but enforcement mechanisms are label-centric

Result type: bounded concern.

Target references: `docs/reports/let-741-plan-first-pass-correctness-remediation.md:59`, `docs/reports/let-741-plan-first-pass-correctness-remediation.md:158`.

Evidence:

- `SpecCheck` identifies `mode:plan` via label membership only. See `elixir/lib/symphony_elixir/spec_check.ex:543`.
- DynamicTool’s acceptance matrix presence guard is mode-label aware through issue context. See `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:1936`.

Impact:

- “legacy spec-prep path” is not a first-class predicate in the proposed code slices. The plan does not define how SpecCheck or DynamicTool detects legacy spec-prep without tightening all non-plan issues.

Suggested repair:

- Define the legacy spec-prep predicate precisely, or narrow the acceptance criteria to `mode:plan` first and list legacy path as a later compatibility extension.

### L2. The regression list lacks negative tests for missing mapping, duplicate mapping, unknown AM id, and invalid proof_type pairings

Result type: bounded concern.

Target references: `docs/reports/let-741-plan-first-pass-correctness-remediation.md:189`.

Impact:

- The target lists these errors as required parser behavior but tests only one noncanonical prefix and one positive case. That leaves the parser contract under-proven.

Suggested repair:

- Add at least one table-driven `HandoffCheck` or description-diagnostic test covering missing `## Proof Mapping`, duplicate AM mapping, unknown AM id, `test -> runtime`, `runtime_smoke -> validation`, and `artifact -> validation`.

### L3. The authoring template may imply validation labels that do not yet exist at spec-prep time

Result type: bounded concern.

Target references: `docs/reports/let-741-plan-first-pass-correctness-remediation.md:99`.

Impact:

- `validation:am-1` is a useful future execution label, but no `Validation` section exists in the issue description and should not be required there. The plan should explicitly say this is a future workpad label commitment, not proof already present.

Suggested repair:

- Add wording: “description mapping labels reserve the expected proof source; execution must later provide checked workpad evidence with the same label.”

### L4. DynamicTool test name says `linear_graphql`, but the file under test is `dynamic_tool_test.exs`

Result type: lower-priority naming concern.

Target references: `docs/reports/let-741-plan-first-pass-correctness-remediation.md:199`.

Impact:

- This is not functionally wrong if existing tests use that naming pattern, but it blurs whether the test should exercise the DynamicTool guard directly or a higher-level Linear GraphQL wrapper.

Suggested repair:

- Name the regression around the actual guard path: `dynamic_tool blocks_issue_update_description_with_noncanonical_mode_plan_proof_mapping`.

## Recommendations

- Prefer one new public or semi-public helper in an existing module over changing the meaning of `proof_contract_errors/1`. This honors the no-new-module/no-new-script constraint while preserving caller semantics.
- Use distinct internal structs/maps or a source marker for parsed mappings: `source: :issue_description` versus `source: :workpad`. Do not let description mappings enter `checked_proof_mapping_items/1`.
- In SpecCheck, add description proof mapping diagnostics to `missing_items` only after the mode/legacy predicate is true and the matrix is otherwise parseable enough to compare AM ids.
- In DynamicTool, fetch issue context before applying the new mode-scoped description Proof Mapping guard, or keep the unconditional guard limited to current matrix parse errors.
- Keep policy untouched; the current project contract is sufficient. The required changes are authoring guidance, existing workflow prose, existing Elixir validators, and tests.

## Compact Ledger

- Target document: `docs/reports/let-741-plan-first-pass-correctness-remediation.md`.
- Focus used: completeness and correctness of dependencies, prerequisites, and interface impacts across issue-description plain bullets, workpad checkbox parsing, SpecCheck, HandoffCheck, DynamicTool `issueUpdate` guard, and no-new-scripts/no-new-policy constraint.
- Main findings: direct `proof_contract_errors/1` reuse conflates description syntax with execution evidence; proposed plain-bullet grammar conflicts with current backtick-only workpad mapping extraction; DynamicTool could over-block non-plan descriptions; description mappings/workpad mappings coexistence is undefined; runtime/reference type pair validation needs explicit design.
- Exact ordered fix list for repair round: 1. Define a description-only proof mapping diagnostic surface inside an existing module, separate from execution/handoff proof validation. 2. Specify exact issue-description grammar for `- AM-1 -> validation:am-1`, including whether backticks are optional and how diagnostics differ from workpad diagnostics. 3. State that issue-description mappings are syntax/cardinality commitments only and never checked execution evidence. 4. Make SpecCheck use the description-only diagnostics only for `mode:plan` and a precisely defined legacy spec-prep predicate. 5. Reorder or scope DynamicTool guards so new Proof Mapping blocking is mode-aware before it runs. 6. Add explicit proof_type-to-reference-type checks: `test -> validation`, `runtime_smoke -> runtime`, `artifact -> artifact`. 7. Expand tests for missing section, duplicate AM mapping, unknown AM id, invalid pairings, positive canonical description, bad `test:` prefix, mode-scoped DynamicTool blocking, non-plan non-regression, and combined description+workpad handoff compatibility. 8. Keep the no-new-scripts/no-new-policy constraint by limiting changes to existing skill/workflow docs, existing Elixir modules, and existing test files.
