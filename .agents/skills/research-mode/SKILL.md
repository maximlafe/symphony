---
name: research-mode
description: Use when the LET workflow routes a `Todo` issue with label `mode:research` into `Planning`. Investigate first, confirm the root cause or rank hypotheses with evidence, and normalize the issue into an implementation-ready task-spec without shipping product code.
---

# Research Mode

## Goal

Turn a raw or underspecified issue into a stable Russian task-spec backed by evidence.

## Required outcomes

- Confirm the root cause; or
- narrow the problem to the smallest evidence-backed set of plausible causes; and
- update the issue description so the next execution pass can start from the description and workpad without hidden chat context.

## Allowed

- Read code, logs, relevant comments, and PR context.
- Reproduce the current signal only when it materially sharpens confidence.
- Run safe local diagnostics and lightweight runtime checks.
- Make temporary local proof edits or temporary tests only when they are required to prove the root cause; revert them before handoff.

## Forbidden

- Do not edit product code as a shipped fix.
- Do not commit, push, or publish a PR.
- Do not widen scope beyond the minimum needed to explain the root cause and define the implementation contour.

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

- Separate confirmed facts from open hypotheses.
- If the root cause is confirmed, say so explicitly.
- If the evidence is still incomplete, rank the hypotheses by confidence and explain what evidence supports each one.
- Record the minimal recommended implementation contour and the minimum validation needed after the fix lands.

## Exit bar

Before handing off to `Plan Review`:

- The issue description is implementation-ready.
- The workpad captures the evidence trail and the recommended fix contour.
- No shipped product code changes remain in the workspace.
