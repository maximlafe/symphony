# Swarm Two-Layer Plan Contract

## Document Spec

- Objective: define a two-layer plan contract where the canonical short plan remains the single source of truth and the larger swarm-produced material is stored as a linked artifact, with explicit gates and fail-closed checks.
- Scope: `mode:plan` spec-prep output shape, swarm-assisted drafting boundaries, artifact linkage rules, and gate behavior for enabled and disabled paths.
- Out of scope: workflow routing, issue-state transitions, delivery/handoff semantics, production runtime behavior, and any new proof vocabulary outside the canonical contract.
- Success criteria:
  - the short plan is always the authoritative plan body;
  - swarm output can expand analysis without replacing the short plan;
  - disabled gate behavior preserves the legacy `plan-mode` contract;
  - enabled gate behavior still maps to canonical contract fields;
  - missing or stale artifact linkage fails closed instead of silently degrading the plan.
- Working assumptions:
  - `planning.swarm_assist_enabled` is the only toggle for the swarm-assisted path;
  - `docs/policy/project-contract.md` remains the source of truth for acceptance, proof, and handoff semantics;
  - local validation can discriminate between compatibility, existence, and divergence cases.
  - `plan_revision` is the short-plan revision token that `artifact_revision` must match.

## Contract Summary

The plan contract has two layers:

1. `Canonical Short Plan`
   - Compact, reviewer-facing, and always present.
   - Carries the actual plan claim, scope, dependencies, validation, and handoff shape.
   - Must remain readable and sufficient on its own.
2. `Swarm Artifact`
   - Larger, critique-heavy, or exploratory output produced during swarm-assisted planning.
   - Lives as a durable artifact and is referenced from the short plan.
   - May contain options, discarded routes, red-team notes, and evidence that would be too verbose for the SSOT plan body.

The short plan owns the decision. The swarm artifact owns the supporting reasoning. If the two disagree, the short plan wins and the artifact must be regenerated or discarded before the plan is treated as review-ready.

## Artifact Interface Contract

- Durable swarm artifacts live as repo-relative markdown reports under `docs/reports/` using the task slug plus a `-swarm-artifact.md` suffix.
- In this document, `swarm artifact`, `artifact`, and `linked artifact` are synonyms for that same repo file.
- The short plan carries one durable link field, `artifact_path`, whose value is the repo-relative path to that file.
- The artifact freshness signal is `artifact_revision`, which must match `plan_revision`.
- `artifact_path` is required only when `planning.swarm_assist_enabled` is `true`.
- If a review flow mirrors the artifact into Linear, that mirror is supplemental and does not replace the repo file or the `artifact_path` link.

## Lifecycle Vocabulary

- `provisional`: the short plan exists, but the enabled path has not yet validated the artifact pair.
- `review-ready`: the required checks have passed and the output can move to review handoff.
- `invalid`: a required check failed, so the output must not be handed off.
- `valid` is used only as a verb or adjective for validation checks, not as a lifecycle state.

## Canonical Short Plan Rules

- The short plan is the only SSOT for the plan output.
- It must contain the canonical task-spec fields expected by the repo contract in both enabled and disabled modes:
  - `Document Spec`
  - `Acceptance Matrix` when the task is execution/review oriented
  - `Proof Mapping` when the task is execution/review oriented
  - `Verification Plan`
  - `Residual Risks`
- It must not depend on reading the swarm artifact to understand the chosen plan.
- It must not embed parallel vocabulary for approval, proof, or handoff.
- In enabled mode, it must name `artifact_path` only as supporting evidence, not as a substitute for the plan body.

## Swarm Artifact Rules

- The swarm artifact is additive and subordinate.
- It may expand the solution space, record rejected routes, and preserve critique context that would otherwise be lost.
- It must exist as a durable repo file at the path named by `artifact_path`.
- It must be versioned or regenerated whenever the plan changes in a way that invalidates the reasoning.
- It must carry `artifact_revision` so freshness can be checked against the citing short plan.
- It must never be treated as authoritative if it conflicts with the canonical short plan.

## Gates

### Disabled Gate

- When `planning.swarm_assist_enabled` is `false`, the legacy `plan-mode` path remains unchanged.
- The output must still satisfy the canonical task-spec shape expected by `docs/policy/project-contract.md`, including the required `Document Spec` fields and any required `Acceptance Matrix` / `Proof Mapping` sections for review-oriented work.
- No swarm artifact is required for acceptance in this path.
- The disabled path is the compatibility proof.

### Enabled Gate

- When `planning.swarm_assist_enabled` is `true`, swarm assistance may expand the drafting process, but the final output still resolves to the same canonical task-spec contract.
- The enabled path must prove that the output still maps to canonical fields rather than introducing a parallel plan format.
- The enabled path is the existence proof.
- The enabled path remains provisional until both the short plan and `artifact_path` validate against the same revision.
- The enabled path must fail closed if `artifact_path` is missing, if `artifact_revision` does not match the short plan revision, if the repo file cannot be regenerated, or if the artifact contradicts the short plan.

### Gate Ordering

1. Validate the disabled path first.
2. Validate the enabled path only after compatibility is proven.
3. Promote the gated path only when both paths remain canonical.

## Fail-Closed Checks

- If `planning.swarm_assist_enabled` is `true` and `artifact_path` is missing, the final plan is invalid.
- If `artifact_revision` does not match `plan_revision`, the plan is invalid until the artifact is discarded and rewritten or `artifact_path` is reset.
- If the enabled path is still provisional because the artifact has not validated yet, the plan must not be treated as review-ready.
- If the swarm artifact is missing, the final plan must not imply swarm-backed conclusions.
- If the artifact link is stale, the plan is invalid until the artifact is discarded and `artifact_path` is reset.
- If the short plan and artifact diverge, the short plan is authoritative and the artifact must be repaired before the plan is accepted.
- If the short plan cannot stand alone, the output fails closed even if the artifact is complete.
- If canonical plan fields are missing, the output is incomplete regardless of how detailed the artifact is.
- If a review would require interpreting the artifact as the real plan, the contract has failed.

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `short-plan-compat` | `planning.swarm_assist_enabled=false` | legacy `plan-mode` still yields an accepted canonical short plan | `test` | `plan-mode` output shape | `surface_exists` | `review` |
| `swarm-enabled-exists` | `planning.swarm_assist_enabled=true` | swarm-assisted output still maps to canonical fields and links a durable artifact | `artifact` | plan body + artifact link | `surface_exists` | `review` |
| `enabled-provisional` | artifact write pending or artifact not yet validated | enabled path is provisional and must not be review-ready | `test` | draft-time lifecycle state | `run_executed` | `review` |
| `artifact-missing` | enabled path without artifact linkage | plan fails closed instead of silently degrading | `test` | gate enforcement | `run_executed` | `review` |
| `artifact-write-failed` | short plan written, artifact write fails | partial artifact is not accepted and enabled path rolls back to short-plan-only state | `test` | draft-time recovery branch | `run_executed` | `review` |
| `artifact-revision-mismatch` | artifact regenerated but revision check fails | stale artifact is discarded and `artifact_path` is reset before acceptance | `test` | validation-time recovery branch | `run_executed` | `review` |
| `plan-divergence` | short plan conflicts with swarm artifact | short plan wins and the artifact must be regenerated or discarded | `test` | divergence check | `run_executed` | `review` |

## Proof Mapping

- `short-plan-compat` -> disabled-path regression proof that the legacy plan-mode output still satisfies the canonical task-spec contract.
- `swarm-enabled-exists` -> enabled-path artifact proof that the large swarm output is linked and subordinate to the short plan.
- `enabled-provisional` -> failure-mode regression proof that the enabled path is not review-ready until both files validate.
- `artifact-missing` -> fail-closed check proving the planner does not accept an unlinked swarm artifact.
- `artifact-write-failed` -> rollback regression proof that a partial artifact write forces a return to short-plan-only state.
- `artifact-revision-mismatch` -> rollback regression proof that a stale regenerated artifact is discarded and `artifact_path` is reset before acceptance.
- `plan-divergence` -> fail-closed check proving the short plan remains authoritative when the two layers disagree.

## Implementation Constraints

- Keep the canonical short plan small enough to review directly.
- Keep the swarm artifact large enough to hold the critique and exploration that would otherwise clutter the short plan.
- Preserve the exact repo-contract vocabulary for acceptance, proof, checkpoint, and handoff terms.
- Treat the artifact link as supporting metadata, not as a second plan channel.
- Keep the integration read-only with respect to tracker state and handoff semantics.

## Verification Plan

- Draft-time: produce the short plan first, then write the swarm artifact only if `planning.swarm_assist_enabled` is `true`, and store its path in `artifact_path`.
- Draft-time recovery: if artifact write fails after the short plan exists, discard any partial artifact output, keep the short plan as the only valid state, and leave the enabled path provisional rather than review-ready.
- Validation-time: verify that `artifact_path` resolves to a repo file, `artifact_revision` matches `plan_revision`, and the artifact is readable before treating it as supporting evidence.
- Validation-time recovery: if artifact regeneration succeeds but the revision check fails, discard the regenerated artifact, reset `artifact_path`, and return the plan to short-plan-only semantics until a matching artifact exists.
- Review-time: run the disabled-path compatibility proof first, then the enabled-path existence proof only after the disabled path is green.
- Review-time: add a divergence check that compares the short plan against the linked swarm artifact and fails closed on mismatch.
- Review-time: add a missing-artifact check that blocks acceptance when `artifact_path` is absent or stale.
- Review-time: add regression coverage for the provisional enabled-path state, the partial artifact-write failure state, and the artifact-regeneration revision mismatch state.
- Re-run the repository validation gate after any change to the workflow, stage skill, or contract language that affects this plan shape.

## Residual Risks

- The main risk is subtle drift: the swarm artifact can become the de facto plan if reviewers are forced to consult it first.
- Another risk is false confidence: a rich artifact can hide a weak short plan unless the SSOT rule is enforced aggressively.
- The final risk is vocabulary drift: if the plan starts inventing parallel terms for proof or handoff, the canonical contract will be harder to validate.
