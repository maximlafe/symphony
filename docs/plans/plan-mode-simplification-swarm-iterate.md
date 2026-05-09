# Plan-Mode Simplification With Swarm Iterate

## Objective

Simplify planning flow so `mode:plan` uses a single entrypoint while preserving
fail-closed contract behavior and runtime safety.

## Baseline Plan

1. Add one migration guard before any destructive change: if the workflow
   update, `plan-mode` update, `docs/policy/project-contract.md` update, the
   workflow-contract tests, and the handoff/runtime tests do not land together,
   keep the legacy path active and do not delete
   `.agents/skills/plan-swarm-mode/SKILL.md` yet. Treat that as an explicit
   rollback state, not an implied fallback. Execute the migration in this
   order: land the contract/routing/skill/validator changes together, run the
   workflow-contract bucket, run the runtime/handoff bucket, run the
   end-to-end smoke bucket, and only then allow overlay deletion.
2. Update `docs/policy/project-contract.md` to use one canonical failure term:
   `blocking divergence`. Define it once as fail-closed behavior for all
   enabled-path checks, including missing artifact, stale `artifact_path`, and
   `plan_revision` / `artifact_revision` mismatch. Make the term visible in the
   validator and its tests so the runtime contract and the documented contract
   stay aligned.
3. Update `.agents/skills/plan-mode/SKILL.md` so `plan-mode` is the only
   planning entrypoint. Make it the owner of short-plan `plan_revision`
   generation, define `artifact_revision` as an exact copy of that value, and
   state that the short plan stays authoritative when `blocking divergence` is
   detected.
4. Update `workflows/letterl/maxime/let.WORKFLOW.md` so `mode:plan` routes
   only through `plan-mode`; the disabled path stays unchanged; the enabled
   path uses the same guarded planning flow already described in `plan-mode`.
   Say explicitly that `In Progress` may read the artifact as supporting
   context only, but handoff validation still fails closed on `blocking
   divergence`.
5. Remove `.agents/skills/plan-swarm-mode/SKILL.md` only after all references
   are rewritten and the compatibility checks are green. Rewrite or retire all
   live references in `elixir/WORKFLOW.md`, `workflows/letterl/maxime/README.md`,
   `workflows/letterl/maxime/let.WORKFLOW.md`, `elixir/test/symphony_elixir/let_workflow_contract_test.exs`,
   and any other prompt, skill, or test that still points at the old overlay.
   If any one of those surfaces still references the old overlay, keep the file
   and retain the legacy path.
6. Make rollback language explicit and stateful: if a partial update lands and
   any later step fails, restore the legacy path, keep the overlay file, and
   stop before deletion. Revert any partially introduced metadata or wording at
   the same time, including `plan_revision`, `artifact_path`,
   `artifact_revision`, and `blocking divergence`. Roll back by failure bucket:
   - if the workflow-contract bucket fails, revert the workflow prose and
     reference-cleanup edits, keep `.agents/skills/plan-swarm-mode/SKILL.md`,
     and leave the contract and runtime code untouched;
   - if the runtime/handoff bucket fails, also revert the contract text, skill
     text, validator updates, and their tests;
   - if the end-to-end smoke bucket fails, revert every previously landed
     simplification edit and stop before any deletion step.
   After any failed bucket, assert that `.agents/skills/plan-swarm-mode/SKILL.md`
   still exists. Do not describe this as a vague “revert”; describe it as
   preserving the old route until the full migration is complete.
7. Split validation into three named buckets and tie them to concrete branches:
   workflow-contract tests in
   `elixir/test/symphony_elixir/let_workflow_contract_test.exs` for routing and
   reference cleanup; runtime/handoff enforcement tests in
   `elixir/test/symphony_elixir/handoff_check_test.exs` for missing artifact,
   stale `artifact_path`, and revision mismatch; end-to-end smoke via
   `make symphony-handoff-check` with `ISSUE_ID`, `WORKPAD_FILE`, `REPO`, and
   `PR_NUMBER` set, covering one enabled-path happy case with a valid short
   plan and matching artifact plus one fail-closed case with missing or stale
   `artifact_path` or a revision mismatch.
8. Run the full validation set, then delete the old overlay only if all three
   buckets pass and the reference rewrite is complete. If any bucket fails,
   leave the legacy path and overlay in place until the failure is fixed.

## Target Outcome

- One planning entrypoint: `plan-mode`.
- No separate `plan-swarm-mode` overlay; guarded swarm assist is invoked
  directly from `plan-mode`.
- Short plan in issue stays SSOT.
- Wide swarm artifact stays supporting context.
- Runtime handoff remains fail-closed.
