# Red Team Round 2 — LET-738 Plan Authoring Remediation

## Scope and focus

Targeted focus for this round:
- execution order;
- rollback/failure modes;
- test coverage adequacy.

Assessed document:
- [let-738-plan-authoring-remediation-plan.md](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md)

Evidence boundary:
- repo-grounded references only.

## Critical findings

1. **Parser-hardening coverage is not tied to the canonical workflow hook implementation** (`verified issue`).

Why this is critical:
- The plan schedules parser changes in canonical workflow hooks ([...remediation-plan.md:121](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:121)-[123](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:123)).
- The proposed parser tests are in `workspace_and_config_test` ([...:153](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:153)-[161](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:161)), but those tests execute local helper strings (`repository_routing_hook` / `repository_retry_hook`) defined in test code, not extracted from `let.WORKFLOW.md`.
  - helper definitions: [workspace_and_config_test.exs:3633](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/workspace_and_config_test.exs:3633), [workspace_and_config_test.exs:3865](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/workspace_and_config_test.exs:3865)
  - helper execution sites: [workspace_and_config_test.exs:410](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/workspace_and_config_test.exs:410), [workspace_and_config_test.exs:985](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/workspace_and_config_test.exs:985)
- Failure mode: canonical hook changed, helper not updated; tests can stay green while production hook drifts.

2. **Execution order does not include slice-level gates before crossing boundaries** (`verified issue`).

Why this is critical:
- Plan order is A->B->C->D->E ([...remediation-plan.md:179](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:179)-[183](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:183)).
- Rollback is stated only as generic boundary ([...:185](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:185)-[186](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:186)); there is no explicit per-slice gate/stop policy.
- All named tests are bundled in section 5 as post-change proof ([...:190](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:190)-[205](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:205)).
- Failure mode: regression introduced in slice A or B is discovered only after multiple additional slices, increasing rollback blast radius and complicating causal attribution.

3. **Failure-mode coverage for parser hardening remains underspecified** (`verified issue`).

Why this is critical:
- Planned parser behavior change: stop parsing on first non-marker content line ([...remediation-plan.md:75](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:75)-[77](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:77)).
- Test plan lists only two generic parser checks ([...:158](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:158)-[161](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:161)).
- Missing explicit cases for branch/fallback consequences already enforced by routing logic:
  - marker multiplicity and invalid markers in `## Symphony` paths ([let.WORKFLOW.md:216](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:216)-[231](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:231), [440](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:440)-[461](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:461));
  - retry-path fallback behavior and error writing ([let.WORKFLOW.md:470](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:470)-[487](/Users/lafe/.codex/worktrees/a262/Symphony/workflows/letterl/maxime/let.WORKFLOW.md:487)).
- Failure mode: parser hardening silently alters marker detection semantics in one path (init/retry) without dedicated regression for that path’s fallback/error behavior.

## Lower-priority findings

1. **Proof commands are coarse for touched surface triage** (`bounded concern`).
- Full-file suites are listed (`handoff_check_test`, `dynamic_tool_test`) ([...remediation-plan.md:198](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:198)-[205](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:205)).
- For slice-local failures this increases noise and makes rollback decisions slower.

2. **No explicit two-attempt/defer clause at slice level** (`working criticism`).
- Plan states rollback independence but not per-slice attempt ceiling or defer rule.
- This weakens execution discipline under repeated red test outcomes.

## Recommendations

1. Add a **parity gate** ensuring canonical workflow hooks and tested hook strings stay aligned (or switch parser tests to execute hooks loaded from workflow config instead of local helper copies).
2. Add **slice-level gates** in section 4: which minimal tests must pass before moving to next slice, and explicit stop/defer policy after two failed attempts.
3. Expand parser test plan with **failure-mode cases per hook path** (init + retry): non-marker interruption, fallback/default branch behavior, and marker-collision scenarios.
4. Add targeted test commands (or named test groups) for each slice before full-suite runs.

## Compact ledger

- Target document:
  - `/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md`
- Focus used:
  - execution order, rollback/failure modes, test coverage adequacy.
- Main findings:
  - 3 critical: missing canonical-hook coverage coupling; no slice-level gates; parser failure-mode coverage underspecified.
  - 2 lower-priority: coarse proof commands for triage; no explicit two-attempt/defer clause.
- Exact ordered fix list for repair round:
  1. **P0**: Add canonical-hook parity verification (or workflow-loaded hook execution) so parser tests assert real `let.WORKFLOW.md` behavior, not only helper copies.
  2. **P0**: Add slice-level execution gates and boundary checks in section 4 with explicit “must-pass-before-next-slice” criteria.
  3. **P0**: Add explicit per-slice failure handling: max two attempts, then rollback/defer with recorded reason and no hidden carry-over.
  4. **P0**: Expand parser regression plan to include init+retry failure modes: first non-marker interruption, fallback/default behavior, marker-collision scenarios.
  5. **P1**: Split proof commands into slice-targeted checks first, then full-suite confirmation, to improve rollback diagnostics.
