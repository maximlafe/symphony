---
name: execute-mode
description: Use when the LET workflow routes an execution-ready issue into `In Progress`, or when a task must be finished end-to-end without a manual engineering handoff. Drive the task from confirmed context through implementation, validation, PR handling, merge readiness, runtime/deploy proof, and final Linear update.
---

# Execute Mode

## Goal

Finish an execution-ready task with the smallest safe change and evidence that matches the task contract.

For the LET workflow, "finished" means one of:

- review-ready handoff in `In Review` with PR, green checks, required proof, attachments, and a classified checkpoint; or
- `Blocked` with exact external capability evidence and a concrete unblock action; or
- when the workflow explicitly allows autonomous landing, merged/released/verified completion.

## Engineering Frame

- Do not widen scope beyond the issue contract.
- Prefer existing repo patterns and the smallest coherent implementation.
- Apply `DRY`, `KISS`, and `YAGNI`.
- Separate authoring from verification before any completion claim.
- Treat missing auth, tooling, DB, runtime, deploy, or external service access as a capability question that must be proven by repo-owned preflight before blocking.

## Required Execution Flow

1. Resolve the current issue, state, repo, branch, PR, checks, review state, and recent related work before editing.
2. If the issue is already blocked, in review, done, or otherwise outside the execution path, follow the workflow state rule instead of coding.
3. Load the issue description as the canonical task contract and use the workpad as the execution log.
4. If a known failed guard, failed proof, CI failure, or runtime signal already exists, start from that signal.
5. Reproduce or capture the target behavior when a safe narrow reproducer materially improves confidence.
6. Implement the minimum scoped change.
7. Add or update regression coverage or another proof that directly covers the changed behavior.
8. Run `make symphony-preflight` and the repo/task acceptance preflight before declaring auth, env, DB, runtime, deploy, or tooling blockers.
9. Run the validation matrix required by the workflow, the repo instructions, and the issue acceptance matrix.
10. Publish or update the PR only after the PR body is complete enough to satisfy the repo PR contract.
11. Triage CI, PR review feedback, and mergeability until no actionable feedback remains or a real blocker is proven.
12. Do not move to `In Review` until handoff evidence is complete and true before the state transition.
13. Do not merge directly unless the workflow explicitly routes the issue into an autonomous merge path; use the repo land flow when merging is allowed.
14. After merge or deployment, verify the landed/released state before claiming completion.
15. Update Linear in Russian with the final evidence and state.

## Capability Gate

Before treating an external dependency as a blocker, prove it with the repo-owned preflight path:

- generic execution: Codex/OpenAI auth, Linear auth, GitHub auth, git access, and repo bootstrap;
- PR publication: complete PR body contract, push access, and CI visibility;
- repo validation: repo-owned validation target can run;
- stateful DB proof: reachable isolated DB/schema and migration/test safety guards;
- runtime proof: repo-owned runtime or smoke command can run and produce durable evidence;
- UI proof: app launch, browser automation, and visual artifact capture;
- deploy/VPS proof: configured remote access, target path, health check, and rollback path.

If a required capability is absent, fail closed before commit/push/handoff and record:

- what is missing;
- why it blocks the issue's acceptance matrix;
- the exact human or repo-owned action that unblocks it.

## Required Outcomes

- Code, tests, PR, CI, required proof, and handoff are complete; or
- a real external blocker remains with exact evidence.

## Forbidden

- Do not start product code changes without an execution-ready issue.
- Do not skip the workflow-required preflight before calling an env/auth/tooling gap a blocker.
- Do not claim "code ready", "review ready", "done", or equivalent if required proof is still missing.
- Do not use CI green as a substitute for a runtime, DB, UI, deploy, or artifact proof required by the acceptance matrix.
- Do not leave review comments unanswered or silently force through unresolved feedback.
- Do not merge through an ad-hoc GitHub command path when the workflow requires the land flow.

## Linear Expectations

- Write Linear comments and final handoffs in Russian.
- Keep one primary issue as the execution source of truth.
- Use classified checkpoints for execution handoffs to `In Review` or `Blocked`.
- For `Blocked`, state the missing capability, why autonomous progress cannot continue, and the exact unblock action.

## Exit Bar

Before handing off or closing:

- required preflight passed or the missing capability is recorded as a blocker;
- task acceptance criteria and acceptance matrix are mapped to checked proof;
- required artifacts are uploaded or explicitly explained as impossible;
- PR checks and review feedback are resolved when PR handoff is in scope;
- the final state claim matches the workflow state.
