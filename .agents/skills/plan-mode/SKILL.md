---
name: plan-mode
description: Use when the LET workflow routes a `Todo` issue with label `mode:plan` into `Spec Prep`. Convert a high-level problem or solution outline into a concrete Russian engineering task-spec and execution plan without shipping product code.
---

# Plan Mode

Entry-point skill for `Spec Prep` planning passes.

Canonical delivery/proof/handoff semantics live in:
[`docs/policy/project-contract.md`](../../docs/policy/project-contract.md)

## Goal

Turn a high-level request into an implementation-ready task spec and execution
contour without shipping product code.

## Required flow

1. Start from confirmed context and unresolved assumptions from prior research
   (if any).
2. Keep clarification/spec shaping inside this stage:
   - define precise terms and scope boundaries;
   - choose one explicit MVP;
   - reject/defer alternatives with rationale.
3. Build execution-ready decomposition using vertical slices, not horizontal
   layer splits.
4. Produce or normalize required spec sections, including `Acceptance Matrix`
   when execution/review handoff is expected.
5. Define minimum validation plan and evidence mapping expectations.
6. Decide `delivery:tdd` add/remove based on deterministic failing proof
   feasibility.
7. If workflow gate `planning.swarm_assist_enabled` is true, run the guarded
   swarm planning loop through `swarm-iterate` (prefer repo-local
   `.agents/skills/swarm-iterate/SKILL.md` when present; otherwise use
   `$CODEX_HOME/skills/swarm-iterate/SKILL.md`) and emit a two-layer plan
   contract:
   - short plan remains SSOT and fully standalone;
   - swarm output is linked as supporting artifact only;
   - `plan_revision` is owned by this stage and must be copied into
     `artifact_revision` for the linked artifact.

## Optional swarm-assisted path (guarded)

- This loop is opt-in and controlled by workflow gate
  `planning.swarm_assist_enabled`.
- If the gate is disabled, keep legacy `plan-mode` path unchanged.
- If the gate is enabled, run `swarm-iterate` with default three
  critique/repair rounds unless task risk requires additional rounds.
- For enabled mode, keep these fields in the short plan:
  - `plan_revision`
  - `artifact_path` (repo-relative path under `docs/reports/`)
  - `artifact_revision` (must equal `plan_revision` and is copied from it)
- Enabled path stays `provisional` until short plan + linked artifact validate
  together. `provisional` is never review-ready.
- If artifact is missing, stale, or contradicts short plan, classify it as
  `blocking divergence`, fail closed, and regenerate/reset artifact link before
  handoff.
- High-risk tasks may run one extra critique/repair pass; low-risk tasks may
  stop after one pass.
- Keep swarm outputs inside canonical contract vocabulary; do not invent
  parallel proof or handoff terms.

## Contract hooks

- `Acceptance Matrix` and `Proof Mapping` semantics: see project contract.
- `delivery:tdd` normalization semantics: see project contract.
- `In Review`/`Blocked` handoff semantics are consumed by execution stage from
  the same contract.

## Guardrails

- Do not edit product code as a shipped fix.
- Do not commit, push, or publish a PR.
- Update Linear in Russian with the planning result and current task-spec state.
