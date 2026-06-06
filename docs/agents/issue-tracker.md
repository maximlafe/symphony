# Issue Tracker: Linear

Issues and PRDs for this repo live in Linear.

## Repo scope

- Linear team: `LetterL`
- Primary project for this repo: `Symphony`
- Project slug: `symphony-bd5bc5b51675`
- Repo routing label: `repo:symphony`

## Workflow

Use the Linear connector or the repo-local `linear_graphql` workflow when available.

Relevant statuses:

- `Backlog` means out of active scope.
- `Todo` is ready for autonomous execution and is moved to `In Progress` when work starts.
- `Spec Prep` is used for planning or research preparation.
- `Spec Review` is human review of a prepared spec.
- `In Progress` is active implementation.
- `In Review` is human handoff or review-ready state.
- `Rework` is a fresh retry after feedback.
- `Merging` means approved by a human and ready for landing.
- `Blocked` means manual intervention is required.
- `Done`, `Canceled`, and `Duplicate` are terminal states.

Important labels:

- `repo:symphony` routes work to this repository.
- `mode:plan` routes a `Todo` issue into planning/spec preparation.
- `mode:research` routes a `Todo` issue into research/spec preparation.
- `delivery:tdd` requires deterministic red/green proof where applicable.
- `verification:*` labels select the verification profile.
