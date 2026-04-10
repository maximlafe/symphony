---
name: research-mode
description: Use when the LET workflow routes a `Todo` issue with label `mode:research` into `Spec Prep`. Investigate first, confirm the root cause or rank hypotheses with evidence, and normalize the issue into an implementation-ready task-spec without shipping product code.
---

# Research Mode

## Goal

Turn a raw or underspecified issue into a stable Russian task-spec backed by evidence and a minimal fix contour, without shipping product code.

## Engineering frame

- Do not widen scope beyond what is required to explain the root cause and define the minimum sufficient fix contour.
- Prefer the smallest coherent explanation and plan.
- Apply `DRY`, `KISS`, and `YAGNI` throughout the investigation and the proposed fix contour.

## Required investigation flow

- Start from the relevant repo instructions plus the current issue, branch, PR, checks, and review context when that context materially affects the investigation.
- Gather factual context from code, data, logs, tests, and runtime instead of leaning on prior assumptions.
- Reproduce the signal only when it is safe and materially increases confidence.
- Separate symptoms from causes.
- Confirm the root cause; or narrow the problem to the smallest evidence-backed set of plausible causes.
- Check whether a partial fix, linked PR, unmerged branch, or recent regression already explains part of the signal.
- Decide whether execution should be opt-in TDD. Use `delivery:tdd` only when a cheap deterministic failing test or reproducer can prove the changed behavior in a narrow core-logic path; avoid it for docs, deploy, CI, visual-only UI work, and flaky integration/runtime-heavy tasks.

## Required outcomes

- Confirmed root cause; or
- top hypotheses ranked by confidence with supporting evidence; and
- the exact affected surface in code, data, and/or runtime; and
- a minimal fix plan without scope creep.

## Allowed

- Read code, logs, relevant comments, and PR context.
- Reproduce the current signal only when it materially sharpens confidence.
- Run safe local diagnostics and lightweight runtime checks.
- Make temporary local proof edits or temporary tests only when they are required to prove the root cause; revert them before handoff.

## Forbidden

- Do not edit product code as a shipped fix.
- Do not commit, push, or publish a PR.
- Do not widen scope beyond the minimum needed to explain the root cause and define the implementation contour.
- Do not present uncertainty as confidence.

## Description contract

Rewrite or normalize the issue description into a Russian task-spec that lets the next execution pass start without hidden chat context.

Include, when relevant:

- `Проблема`
- `Цель`
- `Скоуп`
- `Вне скоупа`
- `Критерии приемки`
- `Зависимости`
- `Заметки`
- final `## Symphony` section

Preserve all material user facts, capture the observed behavior and expected behavior inside the task-spec where they belong, and always keep the final `## Symphony` block intact.

## Workpad expectations

- Separate confirmed facts from open hypotheses.
- Record investigation context that materially affects the conclusion: current branch state, related PR/check/review context, reproducer notes, and recent-change signals.
- Separate symptoms from causes explicitly.
- If the root cause is confirmed, say so explicitly.
- If the evidence is still incomplete, rank the hypotheses by confidence and explain what evidence supports each one.
- Record whether a recent regression, linked PR, partial fix, or unmerged branch was checked and what that check proved.
- Record the minimal recommended implementation contour and the minimum validation needed after the fix lands.

## Linear expectations

- Update Linear in Russian with what was checked, what was found, what is considered the cause, and what minimal next steps are recommended.
- Normalize `delivery:tdd` through `linear_graphql`: add it when the research result shows true TDD is warranted, otherwise remove stale `delivery:tdd`.
- If an external blocker remains after the workflow-required preflight, record the exact blocker evidence instead of a generic tooling complaint.

## Final result format

The final research output should be ordered as follows:

1. confirmed root cause; or top hypotheses ranked by confidence with evidence;
2. exact problem location in code, data, and/or runtime;
3. minimal fix plan;
4. risks, unknowns, and what still needs checking.

## Exit bar

Before handing off to `Spec Review`:

- The issue description is implementation-ready.
- The workpad captures the evidence trail and the recommended fix contour.
- The final research result can be summarized as:
  - confirmed root cause or top hypotheses with evidence;
  - exact problem location in code, data, and/or runtime;
  - minimal fix plan;
  - risks, unknowns, and what still needs checking.
- No shipped product code changes remain in the workspace.
