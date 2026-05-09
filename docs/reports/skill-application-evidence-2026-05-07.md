# Skill Application Evidence (2026-05-07)

This document is a concrete proof package for local LET/Symphony skill usage,
including a real ticket run, workpad artifacts, and implementation commit.

## 1) Real ticket + plan/workpad evidence

- Linear issue: `LET-695` (`mode:plan`, `repo:symphony`)
- Local runtime workspace:
  `/private/var/folders/19/hr934cw96dnfs0wybtywhjhr0000gn/T/symphony_workspaces/LET-695`
- Workpad file:
  `/private/var/folders/19/hr934cw96dnfs0wybtywhjhr0000gn/T/symphony_workspaces/LET-695/workpad.md`

Excerpt from `LET-695` workpad (`### План`):

```md
- [ ] 1. Подтвердить `mode:plan -> Spec Prep` stage routing и контракт entrypoint
- [ ] 2. Подтвердить загрузку repo-local skill bundle из `.agents/skills`
- [ ] 3. Проверить консистентность contract semantics (`Acceptance Matrix` + `Proof Mapping`) между workflow и skills
- [ ] 4. Выполнить валидацию и собрать доказательства для review-ready handoff
```

Excerpt from `LET-695` workpad (`### Проверка`):

```md
- [x] preflight: `make symphony-preflight`
- [ ] targeted tests: `cd elixir && mix test ...`
- [ ] skill-load-evidence: `ls -la .agents/skills > skill-load-evidence.txt ...`
- [ ] repo validation: `make symphony-validate`
```

## 2) Contract lock evidence (Acceptance Matrix / Proof Mapping)

Generated lock artifact:

- `/private/var/folders/19/hr934cw96dnfs0wybtywhjhr0000gn/T/symphony_workspaces/LET-695/.symphony/verification/acceptance-contract.lock.json`

Observed locked matrix IDs: `A1`, `A2`, `A3` with explicit proof targets:

- `A1 -> targeted tests` (`test`, `run_executed`)
- `A2 -> skill-load-evidence` (`artifact`, `surface_exists`)
- `A3 -> repo validation` (`test`, `run_executed`)

## 3) Runtime-loaded skill bundle evidence

Workspace skill bundle for `LET-695` contains:

- `research-mode`, `plan-mode`, `execute-mode`
- `zoom-out`, `diagnose`, `tdd`
- `linear`, `pull`, `push`, `land`, `commit`, `debug`

And does **not** contain `symphony-setup` in `.agents/skills`.

Skill list source:

- `/private/var/folders/19/hr934cw96dnfs0wybtywhjhr0000gn/T/symphony_workspaces/LET-695/.agents/skills`

## 4) Implementation evidence (actual code changes)

Local implementation commit:

- `b1ff4ea` — `refactor let skill contract and stage architecture`

Key implementation scope:

- Added canonical contract:
  `docs/policy/project-contract.md`
- Added worker skills:
  `.agents/skills/zoom-out/SKILL.md`,
  `.agents/skills/diagnose/SKILL.md`,
  `.agents/skills/tdd/SKILL.md`
- Refactored stage skills:
  `.agents/skills/research-mode/SKILL.md`,
  `.agents/skills/plan-mode/SKILL.md`,
  `.agents/skills/execute-mode/SKILL.md`
- Removed worker meta skill:
  `.agents/skills/symphony-setup/SKILL.md`

## 5) Validation commands executed

- `make symphony-runtime-smoke SCENARIO=all` — pass
- `make symphony-validate` — pass
- `env SYMPHONY_LIVE_LINEAR_TEAM_KEY=LET SYMPHONY_LIVE_CODEX_COMMAND='codex --yolo app-server' make symphony-live-e2e` — pass

