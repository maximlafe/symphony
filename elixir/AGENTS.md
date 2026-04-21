# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).
- Fresh target-repo bootstrap from the repo root is `make symphony-bootstrap`.
- Run `make symphony-preflight` once per task before treating auth or tooling gaps as blockers.


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.
- When workflow-driven branch naming matters, honor an explicit `Working branch:` override before falling back to generated branch names.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

Repo-owned task validation targets at the repository root:

```bash
make symphony-validate
make symphony-handoff-check
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

## Hegemonikon And Mode Contract

- Canonical Hegemonikon policy source for local workflows and skills: `/Users/lafe/.codex/skills/policy/hegemonikon.md` (synced with the public gist).
- Keep that file as the single local canon; do not duplicate policy text in repo docs or skills.
- Mode chain for LET orchestration: `research-mode -> plan-mode -> execute-mode`.
- Mode obligations by R-rules:
  - `research-mode`: `R0`, `R3`, `R4`, `R5`, `R11`, `R13`
  - `plan-mode`: `R0`, `R5`, `R10`, `R14`, `R15`
  - `execute-mode`: `R0`, `R1`, `R2`, `R5`, `R6`, `R7`, `R8`, `R9`, `R12`, `R13`
- For execution handoff/reporting, always capture: verification level (`R1`), blast radius (`R7`), separated verifier phase (`R9`), material risks (`R13`), and rollback notes.
- Keep routing semantics centralized in `../workflows/letterl/maxime/let.WORKFLOW.md`; do not duplicate parallel routing entities in other workflow docs.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
