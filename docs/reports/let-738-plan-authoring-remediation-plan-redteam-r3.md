# Red Team Round 3 — LET-738 Plan Authoring Remediation

## Scope and focus

Round focus:
- wording precision;
- consistency;
- internal coherence.

Assessed document:
- [let-738-plan-authoring-remediation-plan.md](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md)

Evidence boundary:
- text and repo-grounded anchors only.

## Critical findings

1. **Parity-gate requirement is internally weakened by conditional wording** (`verified issue`).

Why critical:
- Section 3.4 declares canonical-hook binding as mandatory ([...remediation-plan.md:155](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:155)).
- The same block then makes parity assertion conditional: “если helper-копии сохраняются” ([...:163](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:163)-[164](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:164)).
- Result: two interpretations remain valid (strict canonical-only vs helper+optional parity), so acceptance criteria are not single-valued.

2. **Implementation wording references an undeclared test anchor, reducing precision** (`verified issue`).

Why critical:
- Plan prescribes `Workflow.load(@let_workflow_path)` inside `workspace_and_config_test` ([...remediation-plan.md:158](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:158)-[160](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:160)).
- Current test module uses local helper hooks (`repository_routing_hook`/`repository_retry_hook`) and does not expose this anchor pattern in-place ([workspace_and_config_test.exs:3633](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/workspace_and_config_test.exs:3633), [workspace_and_config_test.exs:3865](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/test/symphony_elixir/workspace_and_config_test.exs:3865)).
- Wording gap: the plan does not specify where `@let_workflow_path` is declared and how canonical hook extraction coexists with env-substitution strategy, leaving implementation ambiguity.

3. **Gate taxonomy mixes “targeted” and full-suite semantics without strict boundaries** (`verified issue`).

Why critical:
- Section 5 claims targeted-first proof model ([...remediation-plan.md:230](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:230)).
- Yet Tier-1 includes full-file execution for `workspace_and_config_test.exs` ([...:237](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:237)-[238](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:238)), while Tier-2 repeats it as full confirmation ([...:250](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:250)).
- Internal signal quality drops: “targeted” and “full” are no longer reliably discriminative terms for execution control.

## Lower-priority findings

1. **Terminology alternates between near-synonyms without normalization** (`bounded concern`).
- The document alternates `authoring-контракт`, `description contract`, `task-spec контракт`, `generator contract` ([...remediation-plan.md:7](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:7), [...:87](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:87), [...:206](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:206)).
- Meaning is close but not locked; this can cause wording drift in downstream edits/tests.

2. **Residual-status phrasing is logically valid but stylistically contradictory** (`working criticism`).
- Ledger states “none at plan-design level; execution proof pending” ([...remediation-plan.md:309](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md:309)).
- This is semantically bounded, but rhetorically reads as simultaneous closure + incompleteness.

## Recommendations

1. Make parity-gate language single-path and non-conditional:
- either canonical-hook extraction is mandatory and helper copies are auxiliary only with required parity check,
- or helper copies are removed from acceptance surface entirely.

2. Replace undeclared anchor wording with explicit actionable text:
- declare exact canonical workflow path constant usage or equivalent deterministic lookup in the test plan text.

3. Normalize gate taxonomy:
- define `targeted gate` as narrow command subset;
- move full-file suites strictly to full-confirmation stage;
- avoid placing the same full suite in both tiers unless explicitly marked as boundary exception.

4. Add a short terminology normalization line:
- one preferred term for the contract layer and one for runtime consume layer.

5. Rephrase residual-status lines to remove rhetorical ambiguity:
- e.g. “design-level conflicts resolved; execution-level proof pending.”

## Compact ledger

- Target document:
  - `/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-738-plan-authoring-remediation-plan.md`
- Focus used:
  - wording precision, consistency, internal coherence.
- Main findings:
  - 3 critical: parity-gate conditional ambiguity; undeclared implementation anchor wording; targeted/full gate taxonomy blur.
  - 2 lower-priority: terminology drift risk; residual-status phrasing ambiguity.
- Exact ordered fix list for repair round:
  1. **P0**: Rewrite section 3.4 parity-gate wording to one strict contract path (no conditional ambiguity).
  2. **P0**: Replace `Workflow.load(@let_workflow_path)` wording with explicit declared anchor strategy in the plan text.
  3. **P0**: Tighten section 5 taxonomy so Tier-1 is truly targeted and Tier-2 is strictly full confirmation.
  4. **P1**: Normalize terminology for contract layers to one canonical phrasing set.
  5. **P1**: Rephrase residual-status lines to bounded, non-contradictory wording.
