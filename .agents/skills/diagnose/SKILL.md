---
name: diagnose
description: LET-native diagnosis loop for bugs and regressions. Use when a
  task reports broken behavior, flaky failures, performance regressions, or
  unclear runtime signals that need reproducible evidence before fixing.
---

# Diagnose

Use a disciplined loop: reproduce -> minimize -> hypothesize -> instrument ->
confirm -> handoff.

## Goal

Produce evidence strong enough to either:

- confirm a root cause and minimal fix contour, or
- rank top hypotheses with explicit confidence and unblock conditions.

## Phase 1: Build A Repro Signal

- Create the cheapest deterministic signal that distinguishes fail/pass.
- Prefer in order:
  - targeted failing test
  - deterministic command/script reproducer
  - focused runtime/API reproducer
- If the bug is flaky, raise reproduction rate with looped runs and bounded
  stress until it becomes debuggable.
- If no usable signal can be built, record what was attempted and what external
  input is required.

## Phase 2: Hypothesize And Probe

- List 3-5 falsifiable hypotheses before deep edits.
- Add narrow instrumentation/probes tied to hypothesis predictions.
- Change one variable at a time where possible.
- Keep temporary instrumentation tagged and removable.

## Phase 3: Confirm Or Bound

- Confirm root cause when evidence is sufficient; otherwise provide ranked
  hypotheses with confidence and exact missing evidence.
- Map findings to concrete code/runtime surfaces.
- Record a minimal fix contour and minimum post-fix validation needed.

## LET Contract Rules

- In `Spec Prep`, this skill is analysis-only: no shipped product code changes.
- In `In Progress`, this skill may inform execution fixes but must not bypass
  the repo validation/handoff contract.
- If progress is blocked by missing external capability, prepare blocker
  evidence for classified `Checkpoint`/`Blocked` handoff.
- Update workpad evidence in Russian using concise factual entries.
