# Project Contract

This file is the canonical repository contract for delivery, proof, and handoff
semantics in Symphony LET workflows.

Scope:

- `delivery:tdd` delivery semantics
- `Acceptance Matrix` and `Proof Mapping`
- classified `Checkpoint` and `risk_level`
- `cheap gate` / `final gate`
- `In Review` / `Blocked` handoff rules
- workpad and Linear attachment evidence rules

Out of scope:

- tracker state machine routing logic
- issue intake mode routing (`mode:research`, `mode:plan`)
- tool invocation syntax details

Workflow files own routing and state machine. This file owns delivery/proof
semantics used by workflow, stage skills, and ops skills.

## Source Of Truth

When guidance differs:

1. this file (`docs/policy/project-contract.md`)
2. repo-local stage and ops skills under `.agents/skills/`
3. workflow prose examples

If a rule must change, update this file first and then align workflows/skills.

## Spec Prep Planning Contract (Two-Layer, Swarm-Assisted)

- This applies only to `mode:plan` and only when workflow gate
  `planning.swarm_assist_enabled` is enabled.
- Default contract is enabled (`true`): disable the gate only when you need
  explicit compatibility fallback to legacy `plan-mode`.
- In enabled mode, plan output has two layers:
  1. canonical short plan (single source of truth, reviewer-facing);
  2. linked swarm artifact (supporting analysis only).
- The short plan must stay standalone and keep canonical task-spec fields:
  `Document Spec`, `Verification Plan`, `Residual Risks`, and for
  execution/review-oriented work also `Acceptance Matrix` and `Proof Mapping`.
- For `mode:plan` paths (including legacy spec-prep fallback and the
  `planning.swarm_assist_enabled=true` two-layer flow), `Acceptance Matrix` is
  mandatory and cannot be substituted by `Required capabilities`.
- In enabled mode, the short plan must additionally carry:
  - `plan_revision`: short-plan revision token;
  - `artifact_path`: repo-relative artifact path under `docs/reports/`;
  - `artifact_revision`: artifact token that must equal `plan_revision`.
- Canonical failure vocabulary for enabled mode:
  - `blocking divergence`: any mismatch or unresolved state that must fail
    closed before review-ready handoff.
- Swarm artifact rules:
  - durable repo file, normally `docs/reports/<task-slug>-swarm-artifact.md`;
  - additive/subordinate only; it cannot replace plan claims;
  - must be uploaded to Linear issue attachments before `Spec Review` handoff;
  - attachment title should match either full `artifact_path` or artifact
    filename;
  - if artifact and short plan diverge, short plan is authoritative.
- Minimum loop for enabled `mode:plan` path:
  1. run `swarm-iterate` as the planning critique/repair orchestrator
     (default: three critique/repair rounds);
  2. produce or refresh linked swarm artifact under `docs/reports/`;
  3. compress the result into the canonical short plan (SSOT) with aligned
     `plan_revision` / `artifact_revision`.
- Lifecycle semantics for enabled path:
  - `provisional`: short plan exists but artifact pair is not validated yet;
  - `review-ready`: required compatibility/existence checks passed;
  - `invalid`: any required check failed.
- Compatibility proof (gate disabled): `plan-mode` output still satisfies
  canonical task-spec requirements and canonical `Acceptance Matrix` /
  `Proof Mapping` semantics.
- Existence proof (gate enabled): output still maps to canonical fields and
  linked artifact remains subordinate.
- Fail-closed checks for enabled mode:
  - missing `artifact_path` is `blocking divergence` and blocks acceptance;
  - missing artifact file at `artifact_path` is `blocking divergence` and
    blocks acceptance;
  - missing Linear attachment for `artifact_path` is `blocking divergence` and
    blocks acceptance;
  - `artifact_revision != plan_revision` is `blocking divergence` and blocks
    acceptance until artifact is regenerated or reset;
  - provisional state is `blocking divergence` and is not review-ready;
  - short-plan/artifact divergence is `blocking divergence` until repaired.
- High-risk planning tasks may run extra critique/repair rounds; low-risk tasks
  may use a single critique/repair pass.
- During `Spec Prep`, swarm planning loop must stay read-only for tracker state
  and execution handoff semantics.

## Execution-Time Secondary Artifact Contract

- Applies only to `In Progress` execution when:
  - issue has `mode:plan`;
  - workflow gate `planning.swarm_assist_enabled=true`.
- Canonical precedence:
  - short plan in issue description is SSOT for scope/acceptance;
  - linked swarm artifact is supporting-only and may refine risk/rollback/
    diagnostics context;
  - artifact is not allowed to redefine scope, acceptance, or proof semantics.
- Required execution preflight before implementation:
  1. read issue machine-readable `plan_revision`, `artifact_path`,
     `artifact_revision`;
  2. confirm `artifact_revision == plan_revision`;
  3. confirm artifact file exists/readable under `docs/reports/`;
  4. confirm matching Linear attachment exists (title match by full path or
     filename);
  5. consume supporting sections only and keep short plan canonical.
- Required workpad section: `Execution Evidence`.
- Runtime-owned `Execution Evidence` fields:
  - `status` (`passed` or `blocked`);
  - `run_token` (fresh per preflight attempt);
  - expected run token source in handoff runtime:
    `runtime_execution_attempt_token` (preferred), `argument_fallback`
    (compatibility mode only), or `missing`;
  - `artifact_file` (normalized path);
  - `revision_pair.plan_revision`;
  - `revision_pair.artifact_revision`;
  - `consumed_sections` (non-empty list);
  - `note` (explicit canonicality statement: artifact secondary, short plan
    canonical).
- Runtime mirror:
  - `symphony_handoff_check` must parse `Execution Evidence` and mirror it into
    handoff manifest under `execution_evidence`.
  - strict runtime mode is controlled by
    `verification.execution_evidence.strict_runtime_token_required`.
    When enabled, fallback token from tool arguments is not accepted.
- Fail-closed rules for execution preflight:
  - missing/invalid `Execution Evidence` fields is `blocking divergence`;
  - `status=blocked` is `blocking divergence` for review-ready handoff;
  - `status=partial` or any unsupported status is `blocking divergence`;
  - stale marker (`run_token` mismatch for current attempt) is
    `blocking divergence`;
  - `artifact_file` mismatch with issue `artifact_path` is
    `blocking divergence`;
  - revision pair mismatch with issue contract is `blocking divergence`;
  - any artifact-vs-short-plan scope/acceptance conflict is
    `blocking divergence`.

## Delivery Label: `delivery:tdd`

- `delivery:tdd` is an opt-in delivery label, not an intake-routing label.
- Normalize the label during spec-prep:
  - add when a cheap deterministic failing proof is feasible for the changed
    core behavior;
  - remove stale label when that proof style is not justified.
- For `delivery:tdd` execution:
  - capture `red proof` before the fix;
  - implement the smallest behavior change;
  - capture `green proof` on the same behavior;
  - keep refactor optional and behavior-preserving.
- Do not require `delivery:tdd` for docs-only, deploy-only, CI-only, pure visual
  polish, or flaky runtime-heavy paths.

## Acceptance Matrix

Execution/review-oriented specs must use `Acceptance Matrix` rows with stable
IDs and canonical fields. For `mode:plan`, this section is mandatory in the
task-spec contract and cannot be replaced by `Required capabilities`:

- `id`
- `scenario`
- `expected_outcome`
- `proof_type` (`test`, `artifact`, `runtime_smoke`)
- `proof_target`
- `proof_semantic` (`surface_exists`, `run_executed`, `runtime_smoke`)
- `required_before` (`review`, `done`)

Rules:

- `required_before=review` for proof required before `In Review`.
- `required_before=done` only for proof that cannot be valid before review.
- Do not reuse one matrix ID for different scenarios in the same task.
- `Required capabilities` can declare external prerequisites, but it is
  supplementary metadata and never satisfies a missing `Acceptance Matrix`.

## Proof Mapping

`Proof Mapping` links each required acceptance item to exactly one concrete
proof source.

Rules:

- Every required matrix item must have exactly one checked mapping entry.
- Mapping type must match matrix `proof_type`.
- Required `test` + `run_executed` items should map through deterministic
  validation entries (for example `validation:am-<id>` in workpad validation).
- `runtime_smoke` items map with runtime smoke proof entries.
- `artifact` items require both:
  - checked workpad artifact entry;
  - matching Linear attachment with the same title.

## Classified Checkpoint

Execution handoffs to `In Review` or `Blocked` must include classified
`Checkpoint` in workpad:

- `checkpoint_type`: `human-verify`, `decision`, or `human-action`
- `risk_level`: justified severity for the handoff
- `summary`: one-line status summary

Rules:

- `In Review` is for `human-verify` review-ready handoff.
- `Blocked` is for unresolved `decision` or `human-action` blockers.
- Do not perform unclassified execution handoff.

## Validation Gates

Canonical local gates:

- `cheap gate`: local stabilization proof for the current change batch
- `final gate`: publish/review gate on clean committed `HEAD`

Rules:

- `final gate` requires successful cheap proof on the same `HEAD`.
- Repo-wide validation command for final gate is `make symphony-validate`.
- Rerun final gate after shipped code/config/workflow-contract changes.
- Dirty-workspace proof may count for cheap gate only; final gate runs on clean
  committed `HEAD`.

## In Review And Blocked Rules

- Do not move to `In Review` until review-ready proof is complete and checkpoint
  is `human-verify`.
- Use `Blocked` only when autonomous progress is not possible without external
  action or decision.
- Blocked handoff must state:
  - what is missing;
  - why it blocks acceptance;
  - exact unblock action.

## Workpad And Linear Evidence

- Keep one persistent live workpad comment per issue.
- Use local `workpad.md` as source and sync at milestones, not after every edit.
- Upload durable evidence artifacts to Linear attachments.
- Do not treat raw transient upload URLs as final evidence.
- PR references stay in linked PR context; attachments are for durable artifacts.

## Change Control

Any contract change should include:

- updated workflow references
- updated affected skills
- updated tests that assert contract text
- local validation proof (`make symphony-runtime-smoke SCENARIO=all` and
  `make symphony-validate`)
