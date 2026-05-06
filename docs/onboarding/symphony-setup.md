# Symphony Setup (Onboarding)

This document is onboarding/meta guidance for configuring Symphony in a target
repository. It is intentionally not a worker runtime skill and must not live
under `.agents/skills/`.

## Scope

- prepare host machine and auth prerequisites;
- install worker runtime skills into the target repo;
- copy and configure `WORKFLOW.md`;
- run first local Symphony launch and sanity checks.

## Preflight

Run and verify:

1. `codex --version`
2. `mise --version`
3. `gh auth status`
4. `test -n "$LINEAR_API_KEY" && echo set || echo missing`
5. non-interactive git clone for target remote

If any check fails, fix before continuing.

## Build Symphony

```bash
git clone https://github.com/odysseus0/symphony
cd symphony
make symphony-bootstrap
cd elixir
mise exec -- mix build
```

## Prepare Target Repo

1. Install worker runtime skills:

```bash
npx skills add odysseus0/symphony -a codex -s linear land commit push pull debug zoom-out diagnose tdd --copy -y
```

2. Copy `elixir/WORKFLOW.md` to the target repo as `WORKFLOW.md`.
3. Configure routing in `WORKFLOW.md` (`tracker.project_slug` or
   `tracker.team_key`, plus `hooks.after_create`).
4. Ensure Linear workflow states required by your workflow are present.

## Contract References

- Workflow/state-machine contract: `WORKFLOW.md`
- Canonical delivery/proof/handoff contract:
  `docs/policy/project-contract.md`
- Worker runtime skills: `.agents/skills/`

## First Local Launch

```bash
cd elixir
mise exec -- ./bin/symphony ./WORKFLOW.md --port 4101
```

Use local test tickets first. Do not rely on this onboarding doc as a runtime
worker instruction set.
