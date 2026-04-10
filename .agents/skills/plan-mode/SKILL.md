---
name: plan-mode
description: Use when the LET workflow routes a `Todo` issue with label `mode:plan` into `Spec Prep`. Convert a high-level problem or solution outline into a concrete Russian engineering task-spec and execution plan without shipping product code.
---

# Plan Mode

## Goal

Turn a high-level issue into an implementation-ready engineering spec with a concrete execution contour.

## Engineering frame

- Do not widen scope beyond what is required for an implementation-ready task contract.
- Prefer the smallest coherent spec that makes execution safe and deterministic.
- Apply `DRY`, `KISS`, and `YAGNI` throughout the planning pass.

## Required planning flow

- Start from the relevant repo instructions plus the current issue, branch, PR, and related context when that context materially affects the spec.
- Briefly record what is already confirmed by prior investigation and what still remains a hypothesis.
- If the root cause is already known, state it clearly.
- If the evidence is still incomplete, describe the most likely cause and the current confidence boundary without pretending certainty.
- Convert the current issue into a stable engineering contract instead of leaving planning details implicit in chat context.
- Decide whether execution should be opt-in TDD. Use `delivery:tdd` only when a cheap deterministic failing test or reproducer should be part of the fix contract; avoid it for docs, deploy, CI, visual-only UI work, and flaky integration/runtime-heavy tasks.

## Allowed

- Read the relevant code, comments, and PR context.
- Run lightweight fact checks that remove critical ambiguity.
- Capture a reproducer only when it materially improves the plan.

## Forbidden

- Do not edit product code as a shipped fix.
- Do not commit, push, or publish a PR.
- Do not add speculative cleanup or future-proofing that is not required for the stated task.
- Do not present open questions as settled facts.

## Description contract

Rewrite or normalize the issue description into a Russian task-spec that lets the next execution pass start without hidden chat context.

Include, when relevant:

- `Проблема`
- `Цель`
- `Скоуп`
- `Вне скоупа`
- `Критерии приемки`
- `Ограничения и инварианты`
- `Риски`
- `Зависимости`
- `План валидации`
- `Заметки`
- final `## Symphony` section

Preserve all material user facts, capture the observed behavior and expected behavior inside the task-spec where they belong, and always keep the final `## Symphony` block intact.

## Workpad expectations

- Produce a concrete implementation contour, not a vague brainstorming note.
- Make the minimum validation plan explicit.
- Record what was confirmed by prior research, what remains hypothetical, and which unknowns still affect execution or acceptance.
- Call out only the uncertainties that still change execution or acceptance.
- If several implementation options exist, recommend one and explain briefly why it is the minimal sufficient path.
- If important edge cases or minimum required tests exist, list them explicitly.

## Linear expectations

- Update Linear in Russian with the planning worklog and note that the description/spec was brought to the current engineering state.
- If the current issue description is stale, replace it with the updated task contract.
- Normalize `delivery:tdd` through `linear_graphql`: add it when the planning result requires TDD, otherwise remove stale `delivery:tdd`.
- If the original issue is closed or clearly no longer matches the real scope, reopen it or create a follow-up issue according to repo rules before treating the planning result as final.

## Final result format

The final planning output should be ordered as follows:

1. what was confirmed by prior research;
2. ready engineering spec in Markdown;
3. ready Linear description text in Russian;
4. what exactly was updated in Linear;
5. remaining risks and unknowns.

## Exit bar

Before handing off to `Spec Review`:

- The issue description is implementation-ready.
- The workpad contains a concrete execution plan, explicit validation outline, and any remaining uncertainties that still affect execution.
- No shipped product code changes remain in the workspace.
