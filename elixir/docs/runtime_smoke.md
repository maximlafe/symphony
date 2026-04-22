# Runtime Smoke

Pass 1 adds a single local runtime-smoke entrypoint for cheap deterministic validation of runtime and workflow changes without disposable Linear resources.

## Run

From the repo root:

```bash
make symphony-runtime-smoke SCENARIO=all
```

Run a single scenario:

```bash
make symphony-runtime-smoke SCENARIO=hooks_stall_guard
```

Valid scenarios:

- `hooks_stall_guard`
- `retry_reconcile`
- `resume_checkpoint`
- `workflow_contract`
- `all`

## CI Integration

The repo-level PR gate uses two separate GitHub Actions workflows:

- `runtime-proof` runs `make symphony-runtime-smoke SCENARIO=all`
- `infra-pass` runs `make symphony-validate`

Keep them separate so failures show whether the breakage is in the cheap runtime-smoke layer or in
the full repo validation layer. On GitHub, the required check contexts for `main` are:

- `runtime-proof / run`
- `infra-pass / run`

## What Each Scenario Proves

- `hooks_stall_guard`: long `before_run` hook still completes cleanly under a low local stall budget in direct agent smoke. This is the cheap local hook-path baseline before any stricter orchestrator-specific false-stall regression is added.
- `retry_reconcile`: stalled worker restart produces the expected retry entry and exposes the retry lifecycle in orchestrator snapshot output.
- `resume_checkpoint`: retry reload prefers a loaded workspace checkpoint over stale queued fallback data.
- `workflow_contract`: updating `WORKFLOW.md` and forcing reload changes future hook execution and runtime config without touching live Linear.

## Scenario Mapping

- hooks / bootstrap / `before_run` / `after_create` / stall-adjacent hook work: run `hooks_stall_guard`
- retry / backoff / reconcile / running-vs-retrying lifecycle: run `retry_reconcile`
- continuation / restart / resume checkpoint / checkpoint lineage: run `resume_checkpoint`
- workflow frontmatter / config / reload / runtime contract: run `workflow_contract`

If a change spans more than one surface, run each matching scenario.

## Ticket Loop

- Before starting the ticket, run `make symphony-runtime-smoke SCENARIO=all` from the repo root. If
  it is already red, fix or isolate that before trusting any new regression signal.
- During the fix, rerun only the named scenario(s) that match the surface you changed. This keeps
  the loop cheap while you are iterating.
- Before finishing the ticket, run `make symphony-validate` and make sure the PR is green on both
  `runtime-proof / run` and `infra-pass / run`.

## Failure Triage

- `runtime-proof` failed: download `runtime-proof-diagnostics` from GitHub Actions and rerun
  `make symphony-runtime-smoke SCENARIO=all` locally, or rerun the matching scenario directly.
- `infra-pass` failed: download `infra-pass-diagnostics` and rerun `make symphony-validate`
  locally. Treat this as a repo-contract failure, not a single-scenario regression.

## When Local Smoke Is Enough

Local runtime smoke is the default for runtime-contract and orchestration changes that can be modeled with the in-memory tracker and the test Codex harness.

Use `make symphony-live-e2e` only when the change must prove the real external contract with live Linear or a real Codex session.
