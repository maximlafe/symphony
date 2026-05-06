---
name: research-mode
description: Use when the LET workflow routes a `Todo` issue with label `mode:research` into `Spec Prep`. Investigate first, confirm the root cause or rank hypotheses with evidence, and normalize the issue into an implementation-ready task-spec without shipping product code.
---

# Research Mode

Entry-point skill for `Spec Prep` research passes.

Canonical delivery/proof/handoff semantics live in:
[`docs/policy/project-contract.md`](../../docs/policy/project-contract.md)

## Goal

Turn an underspecified issue into an implementation-ready task spec backed by
evidence, without shipping product code.

## Required flow

1. Build context from issue + code + runtime signal.
2. If this is bug/regression diagnosis, run [`diagnose`](../diagnose/SKILL.md)
   to confirm root cause or ranked hypotheses with evidence.
3. If the touched area is unfamiliar, run [`zoom-out`](../zoom-out/SKILL.md)
   before deep analysis.
4. Keep clarification/spec sharpening inside this stage:
   - resolve ambiguous terms;
   - separate confirmed facts from hypotheses;
   - choose one minimal recommended contour.
5. Normalize task spec and workpad so execution can start without hidden chat
   context.
6. Decide whether `delivery:tdd` should be added/removed based on cheap
   deterministic proof feasibility.

## Contract hooks

- `delivery:tdd` normalization rules: see project contract.
- Acceptance/proof vocabulary used by downstream execution: see project
  contract.
- Classified `Checkpoint` is not used for `Spec Prep -> Spec Review` handoff.

## Guardrails

- Do not edit product code as a shipped fix.
- Do not commit, push, or publish a PR.
- Update Linear in Russian with factual findings and recommended next step.
