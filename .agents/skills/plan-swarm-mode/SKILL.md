---
name: plan-swarm-mode
description: Guarded swarm-assisted quality loop for LET `mode:plan` spec-prep. Use only when workflow gate `planning.swarm_assist_enabled` is enabled.
---

# Plan Swarm Mode

Overlay skill for `Spec Prep` planning passes.

Canonical delivery/proof/handoff semantics live in:
[`docs/policy/project-contract.md`](../../docs/policy/project-contract.md)

## Activation

- Run only when workflow gate `planning.swarm_assist_enabled` is true.
- If swarm skills are unavailable, fall back to legacy `plan-mode` path and
  note the fallback in workpad `Заметки`.

## Goal

Improve plan quality with bounded critique/repair while keeping routing and
handoff semantics unchanged.

## Required loop

1. Run `swarm-mode` to produce:
   - concrete document specification;
   - first draft implementation contour.
2. Run `swarm-red-team` on the same target document with focus on:
   - dependency and interface completeness;
   - rollback and failure-mode safety;
   - evidence and validation adequacy.
3. Run `swarm-mode` repair pass:
   - fix findings sequentially, including low-priority recommendations;
   - explicitly retire any item only with justification.
4. For high-risk tasks, run one additional critique/repair pass.
5. Merge final result into canonical task-spec/workpad sections used by LET.

## Output contract

- Keep canonical section vocabulary (`Проблема`, `Цель`, `Скоуп`,
  `Критерии приемки`, `Acceptance Matrix`, `Proof Mapping`).
- Keep matrix IDs stable and mapping semantics canonical.
- Keep final recommendation implementation-ready without hidden chat context.

## Guardrails

- Do not edit product code as a shipped fix.
- Do not mutate issue state transitions from this overlay.
- Do not replace `project-contract.md` semantics with swarm-specific terms.
