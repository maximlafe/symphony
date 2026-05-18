---
name: execute-mode
description: Use when the LET workflow routes an execution-ready issue into `In Progress`, or when a task must be finished end-to-end without a manual engineering handoff. Drive the task from confirmed context through implementation, validation, PR handling, merge readiness, runtime/deploy proof, and final Linear update.
---

# Execute Mode

Entry-point skill for `In Progress` execution passes.

Canonical delivery/proof/handoff semantics live in:
[`docs/policy/project-contract.md`](../../docs/policy/project-contract.md)

## Goal

Ship the smallest safe change and produce review-ready evidence for `In Review`,
or produce a classified blocker handoff to `Blocked`.

## Required flow

1. Start from the current issue contract and known failing signal.
2. For `mode:plan` with `planning.swarm_assist_enabled=true`, run a two-layer
   execution preflight before implementation:
   - read machine-readable `plan_revision`, `artifact_path`, and
     `artifact_revision` from issue description;
   - read the artifact at `artifact_path` as supporting-only context (residual
     risks, rollback/failure modes, diagnostics expansion), never as scope,
     revision, proof-mapping, artifact-correctness, or PR-verification
     authority;
   - do not require `plan_revision` / `artifact_revision` fields inside the
     artifact file body;
   - write a dedicated `Execution Evidence` workpad section with runtime-owned
     fields:
     - `status` (`passed` or `blocked`)
     - `run_token` (fresh per attempt)
     - `artifact_file`
     - `revision_pair.plan_revision`
     - `revision_pair.artifact_revision`
     - `consumed_sections`
     - `note` (explicitly: artifact is secondary, short plan is canonical)
   - if preflight is blocked, partial, stale, or divergent, fail closed and use
     classified blocker handoff to `Blocked`.
3. Implement minimal scoped change and required proof.
4. When `delivery:tdd` is active, run [`tdd`](../tdd/SKILL.md) for explicit
   red/green evidence before final handoff.
5. When runtime failure signal is unclear or flaky, run
   [`diagnose`](../diagnose/SKILL.md) before speculative fixes.
6. Run required cheap/final gate sequence for the touched change class.
7. Keep `Acceptance Matrix` and `Proof Mapping` internally consistent before
   handoff.
   - issue `## Proof Mapping` is canonical;
   - checked workpad `### Proof Mapping` confirms execution against the same
     targets and must not redefine them;
   - PR evidence stays in linked PR / `github_wait_for_checks` /
     `github_pr_snapshot`, never in uploaded artifact rows.
8. Publish/update PR only after repo PR contract is satisfied.

## Contract hooks

- `Acceptance Matrix`, `Proof Mapping`, and artifact rules: see project contract.
- Classified `Checkpoint` (`human-verify` / `decision` / `human-action`): see
  project contract.
- `In Review` and `Blocked` transition semantics: see project contract.

## Guardrails

- Do not widen scope beyond issue contract.
- Do not treat CI green alone as acceptance proof.
- Do not bypass repo preflight/validation contract.
- Update Linear in Russian with objective evidence and final state claim.
