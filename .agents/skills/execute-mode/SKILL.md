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
2. Implement minimal scoped change and required proof.
3. When `delivery:tdd` is active, run [`tdd`](../tdd/SKILL.md) for explicit
   red/green evidence before final handoff.
4. When runtime failure signal is unclear or flaky, run
   [`diagnose`](../diagnose/SKILL.md) before speculative fixes.
5. Run required cheap/final gate sequence for the touched change class.
6. Keep `Acceptance Matrix` and `Proof Mapping` internally consistent before
   handoff.
7. Publish/update PR only after repo PR contract is satisfied.

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
