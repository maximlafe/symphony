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
   swarm planning helper from [`plan-swarm-mode`](../plan-swarm-mode/SKILL.md)
   and merge its outputs into the same canonical task-spec/workpad contract.

## Optional swarm-assisted loop (guarded)

- This loop is opt-in and controlled by workflow gate
  `planning.swarm_assist_enabled`.
- If the gate is disabled, keep legacy `plan-mode` path unchanged.
- If the gate is enabled, use this minimal sequence:
  1. `swarm-mode` for document specification and first plan draft.
  2. `swarm-red-team` for critique of dependency impact, rollback safety, and
     proof readiness.
  3. `swarm-mode` repair pass to resolve findings sequentially.
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
