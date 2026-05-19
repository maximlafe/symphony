# Red-Team Critique: LET Single Mechanism First-Pass Unification Plan

Target: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md)

Round: 4, targeted hardening

Focus: strict closure against user wording, with full runtime call-site inventory and explicit closure quality for all four requested points.

## Route State

- `ACTIVE`: runtime call-site inventory is still only an observed subset.
- `ACTIVE`: closure quality is not explicit enough across all four closure points.
- `CLOSED`: legacy compatibility wording audit outside named LET surfaces.
- `CLOSED`: branch-contract confirmation for the swarm-assisted path.
- `CLOSED`: helper-copy smoke separated from canonical proof.

## Findings

### 1. Verified issue: the runtime call-site claim is still underclaimed and therefore not closed against the user wording

Location: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:33-35`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L33)
and [`...:265-279`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L265)

The document explicitly downgrades the runtime evidence to `closed observed-coverage finding, not an exhaustive inventory claim`, then repeats that downgrade in the closure addendum as `Observed runtime call-site coverage`. That is the opposite of the requested closure quality: the user asked for a full runtime call-site inventory, not a partial observed subset.

This is not just a wording preference. The repo-wide search surface includes additional runtime references outside the addendum’s cited anchors, including [`elixir/lib/mix/tasks/handoff.check.ex:45-59`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/mix/tasks/handoff.check.ex#L45), [`elixir/lib/symphony_elixir/run_phase.ex:391-445`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/run_phase.ex#L391), and [`elixir/lib/symphony_elixir/orchestrator.ex:6766-6792`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L6766) plus [`...:7520-7529`](/Users/lafe/.codex/worktrees/a262/Symphony/elixir/lib/symphony_elixir/orchestrator.ex#L7520). The current document does not state a repo-wide search boundary or prove exhaustiveness, so the closure is materially incomplete.

Result type: `verified issue`

### 2. Verified issue: the closure quality for all four requested points is not explicit enough

Location: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:248-316`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L248)

The closure addendum uses the same generic header, `Closed with evidence`, for all four points, but the actual closure quality differs:

- point 1 is compatibility-scoped and intentionally outside named LET surfaces;
- point 2 is only observed coverage, not a full inventory;
- point 3 is a branch-contract confirmation;
- point 4 is canonical-proof-vs-helper-smoke separation, not a full proof of the canonical mechanism.

That means the addendum does not make the closure strength explicit enough for each requested point. A reader cannot tell from the headings alone which points are complete, which are scoped compatibility findings, and which are intentionally secondary or partial.

Result type: `bounded concern`

## Mechanism Audit

### What the target explicitly promises

The document promises `first-pass correctness`, one canonical vocabulary, and explicit compatibility behavior. In the closure addendum, it also implies the four closure points are resolved.

### What the mechanism actually guarantees

The mechanism currently guarantees:

- compatibility wording outside the named LET surfaces is grounded;
- a subset of runtime call sites has been observed;
- the swarm-assisted path is subordinate to the short plan;
- helper-copy smoke is separated from canonical proof.

### Where the stronger reading fails

The stronger reading fails at the runtime inventory boundary. `Observed coverage` is not the same as `full inventory`, and the document never states a repo-wide search boundary that would justify the stronger claim. The closure layer also does not label the four requested points by quality class, so the reader has to infer which ones are fully closed and which are not.

### Minimal fix set

P0:

- Replace the runtime call-site closure language with a true inventory claim or explicitly downgrade the document’s success criteria to the weaker observed-coverage statement.
- State the repo-wide search boundary and exhaustiveness criteria if the inventory claim is meant to be complete.

P1:

- Tag each of the four closure points with an explicit closure quality label so the report distinguishes complete, compatibility-scoped, observed-only, and smoke-only evidence.

## Exact Ordered Fix List

1. Rewrite the runtime closure point from `Observed runtime call-site coverage` to `Full runtime call-site inventory`, or else state plainly that the document is not claiming full inventory.
2. Add the missing repo-wide search boundary and exhaustiveness rule for the runtime call-site section, then align the supporting anchors to that boundary.
3. Split the closure addendum into per-point quality labels so each of the four requested points is explicitly marked as complete, compatibility-scoped, observed-only, or smoke-only as appropriate.
4. Re-run the closure wording pass and remove any residual phrases that still say `observed coverage` where the document intends to claim full closure.

## Bottom Line

The target document is close on mechanism shape, but it still misses the user’s stricter closure bar in one important place: runtime evidence is acknowledged as partial instead of inventory-complete. The closure addendum also needs explicit quality tags so the four requested points do not blur together under the same `Closed with evidence` banner.
