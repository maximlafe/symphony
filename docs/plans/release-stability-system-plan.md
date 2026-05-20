# Release Stability System Plan

## Document Spec

Objective: build a practical release system where production only receives tested changes, promotions are explicitly gated, and every release has an immutable version record.

Scope:
- `release-image`
- `deploy-production`
- release candidate promotion rules
- Linear-based release governance
- versioning and rollback rules
- release audit trail and verification

Out of scope:
- feature work in the app itself
- unrelated CI cleanup
- broad Git flow changes
- tracker routing changes outside release governance
- new deployment infrastructure that is not needed for the gate

Baseline:
- stable reference branch: `codex/let-single-mechanism-e2e-implementation-2026-05-19`
- stable reference commit: `7fb55b2`
- baseline message: `chore: checkpoint working branch state`

Success criteria:
- `release-image` remains the first release proof and no longer implies direct production promotion
- `deploy-production` only consumes a validated release contract
- production rollout requires explicit human approval and does not auto-deploy from `main`
- release versioning is visible as an immutable contract tuple, not as a floating branch tip
- Linear records each release approval state, artifact link, and rollback reference
- rollback can redeploy a prior approved contract without rebuilding from the latest `main`

Working assumptions:
- the current release artifact tuple already contains `git_sha`, `image_tag`, and `image_digest`
- that tuple is the explicit release version for this plan
- `main` remains the release-candidate source, but not the deploy trigger by itself
- Linear is available as the release governance surface

Prerequisites:
- the current `deploy-production` path must be rewritten so production cannot auto-promote from `main` without an explicit approval gate
- the release contract must remain the only deploy input, and the deploy job must fail closed if that contract is missing, stale, or not validated
- Linear must carry one authoritative release issue per production release, and that issue must be linked to the same release contract used by deploy

Term Lock:
- `release issue`: the single authoritative Linear issue for one production release
- `release contract artifact`: the published `production-image-contract.json`
- `approval state`: the explicit Linear approval status on the release issue
- `deployed state`: the runtime state after a successful production deploy
- `rollback reference`: the linked prior approved contract and release issue used for rollback traceability

## Release System

### 1. Build and prove first

- Every candidate release must pass the existing `release-image` workflow before any production deploy is allowed.
- `release-image` stays responsible for building the production image, smoke-testing startup, and publishing the digest-pinned image contract.
- The published contract is the only deploy input; production must never pull from a mutable branch ref.
- The baseline commit above is the comparison anchor for release-system stability, not a deploy target.

### 2. Gate promotion

- `deploy-production` must consume the exact published release contract, not a rebuilt image or a branch head.
- The deploy workflow must validate the contract artifact before it can promote anything; if the contract cannot be downloaded, parsed, or matched to the expected tuple, deployment must stop.
- Production rollout requires explicit approval in Linear and the production GitHub Environment, and those approvals are prerequisites rather than post-hoc records.
- Auto-deploy from `main` is disabled in steady state.
- If `release-image` publishes a candidate contract from `main`, that only makes the release eligible for promotion; it does not deploy on its own.

### 3. Promotion Order

- Step 1: `release-image` must complete successfully and publish the contract artifact.
- Step 2: the release issue in Linear must record approval for the exact tuple from that artifact.
- Step 3: `deploy-production` must resolve the published contract and validate that it matches the expected tuple before any deploy action starts.
- Step 4: the production GitHub Environment gate must be approved before the deploy job is allowed to act on the contract.
- Step 5: only after the contract and approval gates are satisfied may the deploy job run `scripts/symphony_deploy.sh`.
- Step 6: the deploy step must complete its post-deploy health check and only then count as a successful promotion.
- Step 7: if any earlier step fails, the promotion must stop before the next step begins and no partial approval state may be treated as a successful release.

### 4. Make versioning explicit

- The release version is the immutable tuple: `git_sha`, `image_tag`, `image_digest`.
- Every release issue in Linear must reference the same tuple and the same published contract artifact.
- A release is invalid if Linear, the workflow artifact, and the deployed runtime do not agree on that tuple.
- Floating names like `main` or an unpinned image tag are not acceptable as the production version reference.

### 5. Govern releases in Linear

- Each production release gets one Linear release issue that captures the candidate version, approval state, deploy result, artifact link, and rollback reference.
- The Linear release issue is the human governance surface for release approval, not a second source of truth for the version.
- The release contract artifact remains the deployment source of truth.
- The authoritative Linear release issue must reference the same `git_sha`, `image_tag`, and `image_digest` tuple used by the deploy contract, and it must link to the published contract artifact.
- The approval state on that issue must be explicit, and if the issue is missing, unapproved, or does not match the contract tuple, the release is not ready for production.

### 6. Roll back by contract

- Rollback must use a previously approved release contract.
- `deploy-production` must support redeploying an older digest through its manual dispatch path, with the selected historical contract passed explicitly rather than inferred from `main`.
- Rollback approval and outcome stay in Linear so the deployed state remains auditable.
- The rollback reference must point to the prior approved contract and the matching Linear release issue.
- A rollback is not a branch reset and not a rebuild from whatever is currently on `main`.

### 7. Rollback Failure Modes

- If the selected historical contract is missing, stale, or does not match the Linear rollback record, rollback must stop before any host change occurs.
- If the rollback deploy begins but the contract cannot be applied cleanly, the release state must remain marked as failed rather than partially rolled back.
- If the post-rollback health check fails, the rollback must be treated as unsuccessful and the prior deployed state must be called out explicitly in Linear.
- A rollback failure must never be described as a successful release just because the contract lookup succeeded.

## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| `stable-baseline-reference` | baseline branch and commit remain a stable starting point | the reference commit stays available as the comparison anchor for release-system changes | `test` | `codex/let-single-mechanism-e2e-implementation-2026-05-19` @ `7fb55b2` | `run_executed` | `review` |
| `release-image-validates-first` | a candidate release is built | `release-image` builds and smoke-tests before any deploy can proceed | `test` | `.github/workflows/release-image.yml` | `run_executed` | `review` |
| `contract-is-immutable-version` | a release is published | the published contract exposes the immutable version tuple and stays pinned | `artifact` | `production-image-contract.json` | `surface_exists` | `review` |
| `linear-governance-gate` | a release is approved | Linear contains the same version tuple, the approval state, the release issue, and the artifact link | `artifact` | Linear release issue and attachments | `surface_exists` | `review` |
| `deploy-is-gated` | a candidate exists on `main` | `deploy-production` does not auto-deploy until approval is present | `test` | `.github/workflows/deploy-production.yml` and workflow history | `run_executed` | `review` |
| `approval-required-before-deploy` | the release issue is not approved | deploy cannot start and the gate remains closed | `test` | Linear approval state + deploy workflow contract | `run_executed` | `review` |
| `artifact-missing-stale-or-malformed-blocks` | the published contract is missing, stale, or malformed | deploy stops before `scripts/symphony_deploy.sh` runs | `test` | `production-image-contract.json` validation path | `run_executed` | `review` |
| `contract-tuple-mismatch-blocks` | the published contract tuple does not match the release issue or deploy inputs | deploy stops before `scripts/symphony_deploy.sh` runs | `test` | contract tuple validation path | `run_executed` | `review` |
| `rollback-contract-mismatch-blocks` | the requested rollback contract is missing, stale, or mismatched | rollback stops before host state changes and remains marked failed | `test` | rollback selection path and Linear rollback record | `run_executed` | `review` |
| `rollback-health-failure-blocks` | rollback deploy starts but health check fails | rollback is reported as unsuccessful and the prior deployed state is retained explicitly | `runtime_smoke` | rollback health verification path | `runtime_smoke` | `done` |
| `rollback-by-contract` | a previous release must be restored | deploy can re-run against an older approved contract without rebuilding from `main` | `runtime_smoke` | `deploy-production` manual dispatch using prior contract | `runtime_smoke` | `done` |

## Proof Mapping

- `stable-baseline-reference` -> baseline branch and commit remain readable and usable as the release-stability comparison point.
- `release-image-validates-first` -> the `release-image` workflow run and its smoke-test output prove build-first release validation.
- `contract-is-immutable-version` -> the published `production-image-contract.json` proves the release version is explicit and pinned.
- `linear-governance-gate` -> the Linear release issue and its attachment/comments prove release governance is recorded in the tracker.
- `deploy-is-gated` -> the `deploy-production` workflow definition and run history prove production does not auto-deploy from `main`.
- `approval-required-before-deploy` -> the Linear release issue state and deploy workflow contract prove approval is a true precondition.
- `artifact-missing-stale-or-malformed-blocks` -> the contract validation path proves missing, stale, or malformed artifacts fail closed before deploy starts.
- `contract-tuple-mismatch-blocks` -> the tuple validation path proves deploy inputs that do not match the release issue fail closed before deploy starts.
- `rollback-contract-mismatch-blocks` -> the rollback selection path and rollback reference prove missing or stale rollback targets fail closed before host changes.
- `rollback-health-failure-blocks` -> the rollback health path proves a failed rollback stays marked failed rather than being treated as success.
- `rollback-by-contract` -> the manual `deploy-production` path against a prior contract plus the post-deploy state prove rollback is contract-based.

## Verification Plan

1. Treat the stable baseline branch and commit as the comparison reference before any release-system change is judged successful.
2. Confirm `scripts/test_symphony_deploy_contract.py` covers the deploy workflow contract path and the compose sync path, and add negative assertions for missing or stale release artifacts.
3. Confirm `elixir/test/symphony_elixir/deploy_contract_test.exs` still proves the runtime receives release metadata from compose.
4. Confirm the current `release-image` workflow validates the publish-and-upload path for `production-image-contract.json`.
5. Confirm the current `deploy-production` workflow requires Linear approval plus exact contract selection before deploy begins.
6. Confirm the release tuple is explicit everywhere it matters: workflow artifact, Linear release issue, and deployed runtime state.
7. Confirm rollback is modeled as prior-contract promotion, not as a rebuild from `main`.
8. Confirm the plan keeps Linear as the governance surface for approval, audit, and rollback traceability.
9. Confirm `image_ref` and `image_digest_ref` are treated as transport fields only, not as additional version identity.
10. Confirm the plan’s negative-path coverage includes approval absence, missing/stale artifact, tuple mismatch, rollback contract mismatch, and rollback health failure.
11. Confirm the promotion order prevents deploy steps from starting before the preceding gate is satisfied.

## Residual Risks

- Auto-deploy can regress if workflow variables or environment defaults are re-enabled without a corresponding policy update.
- Linear can drift into a parallel note-taking surface unless the release contract and approval decision are always tied to the same version tuple.
- Versioning can become ambiguous again if `main` or an unpinned tag is treated as an acceptable production reference.
- Rollback remains operator-sensitive unless the previous approved contract is easy to select and the Linear release issue is complete.
- The contract interface can still drift if future maintainers confuse transport fields with version identity or relax the fail-closed validation order.
- Negative-path test coverage can still be thin if the implementation does not add deterministic assertions for the new failure rows.
