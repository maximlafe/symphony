---
name: plan-mode
description: Use when the LET workflow routes a `Todo` issue with label `mode:plan` into `Spec Prep`. Convert a high-level problem or solution outline into a concrete Russian engineering task-spec and execution plan without shipping product code.
---

# Plan Mode

## Goal

Turn a high-level issue into an implementation-ready engineering spec with a concrete execution contour.

## Allowed

- Read the relevant code, comments, and PR context.
- Run lightweight fact checks that remove critical ambiguity.
- Capture a reproducer only when it materially improves the plan.

## Forbidden

- Do not edit product code as a shipped fix.
- Do not commit, push, or publish a PR.
- Do not add speculative cleanup or future-proofing that is not required for the stated task.

## Description contract

Rewrite or normalize the issue description into a Russian task-spec that includes, when relevant:

- `Проблема`
- `Цель`
- `Скоуп`
- `Вне скоупа`
- `Критерии приемки`
- `Зависимости`
- `Заметки`
- final `## Symphony` section

Preserve all material user facts and always keep the final `## Symphony` block intact.

## Workpad expectations

- Produce a concrete implementation contour, not a vague brainstorming note.
- Make the minimum validation plan explicit.
- Call out only the uncertainties that still change execution or acceptance.
- If several implementation options exist, recommend one and explain briefly why it is the minimal sufficient path.

## Exit bar

Before handing off to `Spec Review`:

- The issue description is implementation-ready.
- The workpad contains a concrete execution plan and validation outline.
- No shipped product code changes remain in the workspace.
