# LET-741 Plan First-Pass Correctness Remediation Red-Team R3

## Phase 1: Problem Definition

Core problem: critique `docs/reports/let-741-plan-first-pass-correctness-remediation.md` for wording precision, consistency, and internal coherence after prior repair rounds.

Scope: wording ambiguity, guarantee precision, no-new-entities consistency, first-pass authoring versus validator blocking, and executable acceptance criteria.

Out of scope: editing the target document, proposing broad architecture changes, relitigating earlier parser/scope design unless wording now creates a new contradiction.

Success criteria: identify only findings that can change implementation behavior, acceptance interpretation, or closure confidence; distinguish critical findings, lower-priority findings, and recommendations; end with an ordered fix list.

Uncertainties: this review is based on the document text only, not on current implementation details in the Elixir modules or workflow files.

## Phase 2: Expert Assembly

Team size: 4.

Role mix:

- Critic / Completer-Finisher: searches for ambiguous wording, missing closure conditions, and internal inconsistencies.
- Critic / Implementer: tests whether an engineer can execute the acceptance criteria without inventing unstated policy.
- Balanced / Monitor-Evaluator: separates verified document issues from lower-confidence style concerns.
- Evangelist / Synthesizer: preserves the useful guarantee structure while minimizing fix scope.

Evidence boundary: local target document only, with line references from the rendered file.

## Iteration 1: Wording And Guarantee Audit

Moderator reasoning: The current round asks for precision and coherence, not new design. The highest-value route is therefore a mechanism audit: compare what the document promises against what its proposed authoring, DynamicTool, and SpecCheck layers actually guarantee.

Executor result: bounded document review found two critical wording issues. Both are not architecture defects, but they can cause incorrect closure or mismatched implementation expectations if left unresolved.

Route status: guarantee precision is ACTIVE; no-new-entities consistency is SUPPORTING; acceptance crispness is ACTIVE.

## Mechanism Audit

What the target explicitly promises:

- Symphony in `mode:plan` creates a correct task-spec description on the first pass, without manual `Proof Mapping` edits and without accepting a noncanonical plan as `passed` (lines 5-7).
- Full first-pass correctness requires authoring guidance, post-write SpecCheck enforcement, and before-write DynamicTool blocking (lines 133-138, 296-298).
- Acceptance includes a new generated `mode:plan` issue description using canonical `Proof Mapping` on the first completed planning pass (lines 486-487).

What the mechanism actually guarantees as written:

- Authoring guidance can improve the initial payload shape, but tests may be doc-level assertions if no prompt-rendering surface exists (lines 213-217, 524-526).
- DynamicTool can block invalid `issueUpdate(description)` payloads before persistence (lines 311-316, 320-331).
- SpecCheck can reject stored invalid descriptions after write (lines 344-376).
- Live smoke confirms one fresh issue produced a canonical first completed description or captured first attempted payload if available (lines 424-437).

Where the stronger reading fails:

- A blocked first attempted payload is still a first-pass authoring failure, even if DynamicTool prevents persistence and a later retry succeeds. The document alternates between “first-pass write correctness” and “first completed planning pass” without defining whether blocked attempts count as failed first passes.
- Legacy spec-prep is sometimes included in the target behavior and sometimes explicitly deferrable. The document mostly handles this, but the top-level target behavior still reads as mandatory for both `mode:plan` and a legacy predicate if one is defined.

Minimal fix set:

- P0: define “first-pass correctness” as either first attempted description payload correctness or first persisted/completed description correctness, and align acceptance plus live smoke language to that definition.
- P0: make the legacy spec-prep top-level target conditional in the same language used later: enforce legacy only when a precise predicate is implemented; otherwise the accepted scope is `mode:plan` only.
- P1: replace remaining ambiguous words such as “scoped”, “predicate”, and “surface” in acceptance-facing sections with concrete caller/context examples.

## Critical Findings

### C1: “First-pass correctness” still mixes authoring correctness with before-write blocking

Type: verified issue.

Evidence: The document opens by saying Symphony should create the task-spec description correctly “с первого прохода” (lines 5-7). Later it defines full first-pass correctness as including DynamicTool before-write blocking (lines 133-138, 296-298), and acceptance says the description is canonical on the “first completed planning pass” (lines 486-487). The live smoke may capture the first attempted payload “if available, otherwise” the first written description (lines 428-429).

Why this matters: these are different claims. If the first `issueUpdate(description)` payload is noncanonical and DynamicTool blocks it, the system has preserved storage correctness but has not achieved first-pass authoring correctness. The current wording lets an implementation pass by blocking bad text and then succeeding after retry while still claiming “first-pass correctness”. That conflicts with the round focus: first-pass authoring versus validator blocking.

Required correction: choose one invariant and state it everywhere. If LET-741 requires true first-attempt authoring correctness, acceptance must require the first attempted `issueUpdate(description)` payload to be canonical, with DynamicTool only a safety net. If the intended guarantee is first persisted/completed description correctness, rename the milestone away from “first-pass correctness” and explicitly say blocked invalid attempts do not satisfy authoring correctness.

### C2: Top-level target behavior over-includes legacy spec-prep despite later deferral rules

Type: verified issue.

Evidence: Section 5 says “Для `mode:plan` и для явно определенного legacy spec-prep predicate” Symphony must create a correct task-spec from the first description (lines 73-75). Later sections repeatedly say legacy enforcement is conditional and should be deferred if no precise predicate exists (lines 173-175, 204-206, 356-359, 480-482, 630-631).

Why this matters: the document mostly protects against broad non-plan tightening, but the target behavior still reads as if legacy support is part of the mandatory final behavior whenever the phrase “явно определенного legacy spec-prep predicate” can be argued to exist. That can pressure implementers to invent or broaden a predicate to satisfy the top-level promise, conflicting with the no-broadening constraint.

Required correction: rewrite section 5 to say the accepted target is `mode:plan`; legacy spec-prep is included only if the implementation identifies and tests a precise existing predicate without broadening non-plan behavior. This should mirror the rollback/defer language.

## Lower-Priority Findings

### L1: “No new runtime entities” is mostly preserved, but “diagnostic surface” and “no-op shim” could be misread as new entities

Type: bounded concern.

Evidence: The document prohibits new runtime entities and external validators (lines 9-10, 60-61, 507). It also asks for a separate description-only diagnostic surface in an existing module (lines 103-107) and allows a no-op shim if C rolls back (lines 287-290, 463-465).

Why this matters: the intent is clear enough to an informed reader, but “surface” and “shim” are entity-like terms. A strict reviewer could read the text as conflicting with the no-new-entities constraint.

Suggested correction: add one sentence near the no-new-entities constraint: new functions/helpers inside existing modules and tests are permitted; new standalone modules, scripts, policy files, services, or persisted runtime concepts are not. If the no-op shim remains, specify it is an existing-module compatibility function only, not a new runtime abstraction.

### L2: Acceptance criteria are close, but not fully executable as a checklist because several criteria lack direct proof names or pass/fail boundaries

Type: bounded concern.

Evidence: Acceptance criteria list desired outcomes (lines 486-507), while slice sections define concrete tests. The final criteria do not explicitly bind each outcome to the local test, live smoke artifact, or both.

Why this matters: execution can still infer the mapping, but final acceptance is crisper when each bullet names the proof source. This is especially important for the first-pass claim, because the live smoke wording currently permits fallback from attempted payload to resulting description (lines 428-429).

Suggested correction: annotate final acceptance bullets with proof source classes, for example `[unit]`, `[contract]`, `[integration]`, `[live smoke]`, and make the first-pass bullet require either first attempted payload evidence or explicitly scoped persisted-description evidence after renaming.

### L3: The word “scoped” appears in acceptance-facing requirements without restating the scope predicate

Type: working criticism.

Evidence: Acceptance says DynamicTool blocks missing mapping for “scoped `mode:plan` descriptions” (lines 493-494). Earlier sections define mode scoping and possible legacy predicates, but the final acceptance bullet does not restate whether “scoped” means only `mode:plan`, `mode:plan` plus implemented legacy, or any issue already inside Spec Prep.

Why this matters: the surrounding document resolves most of this, so this is not a design blocker. But acceptance criteria should be executable without reinterpreting a term that has been used for several slightly different contexts.

Suggested correction: replace “scoped `mode:plan` descriptions” with “descriptions for issues positively identified as `mode:plan` by the existing issue context”, and add “plus legacy only if a precise predicate is implemented and tested” if legacy remains in scope.

### L4: “Proof Mapping” grammar prohibits observed asterisk bullets but the prose only says “plain bullets”

Type: bounded concern.

Evidence: The observed bad text uses `* AM-1 -> ...` (lines 23-27). The canonical grammar accepts only `-` bullets (lines 244-248). Many sections say “plain bullets” (lines 77, 198, 235, 433), which could be read as allowing either `-` or `*` markdown bullets.

Why this matters: if the implementation follows the regex, `*` is invalid; if an author follows the phrase “plain bullets”, they may think `*` is allowed as long as it is not a checkbox. This is a small but real wording mismatch.

Suggested correction: define canonical plain bullet as hyphen bullet only: `- AM-n -> <prefix>:<label>`. If asterisk bullets are intentionally accepted, update the regex and tests accordingly; otherwise say asterisk bullets are noncanonical.

## Recommendations

1. Replace global “first-pass correctness” with one of two precise terms: “first attempted payload correctness” or “first persisted description correctness”. Use the chosen term in title, minimum shippable states, Slice E, validation plan, acceptance criteria, and ledgers.
2. In section 5, separate mandatory target scope from optional legacy scope. Recommended wording: “For `mode:plan`, and for legacy spec-prep only if a precise existing predicate is implemented and tested, Symphony must...”
3. Add a short terminology block before the slices: “description mapping”, “checked workpad mapping”, “scoped plan description”, “first attempted payload”, and “first completed/persisted description”. This would remove most remaining ambiguity without adding implementation scope.
4. In final acceptance criteria, add proof tags and exact evidence boundaries. The live smoke criterion should not allow fallback to resulting description if the accepted guarantee is first attempted payload correctness.
5. Clarify no-new-entities by distinguishing permitted in-module helpers/tests from prohibited standalone modules/scripts/policies/services/persisted concepts.

## Checkpoint

Progress assessment: the document is internally coherent on the major architecture after R1/R2, especially separation of description diagnostics from handoff evidence and mode-scoped non-plan protection.

Unresolved concerns: the largest remaining risk is semantic: “first-pass” can still mean either first LLM-authored attempted payload or first persisted successful description. That ambiguity can materially change implementation and acceptance.

Quality assessment: no broad rewrite is needed. Fixes are wording-level but high-impact.

Active criticism routes:

- Guarantee precision: ACTIVE, because C1 affects closure criteria.
- Legacy scope consistency: ACTIVE, because C2 affects no-broadening behavior.
- No-new-entities consistency: SUPPORTING, because the likely intent is clear but wording can be hardened.
- Acceptance crispness: ACTIVE, because final criteria can be made directly executable.

What would retire the current criticism: a revised target document that defines first-pass terminology, scopes legacy support conditionally at the top level, and tags acceptance criteria with exact proof sources.

## Compact Ledger

Target document: `docs/reports/let-741-plan-first-pass-correctness-remediation.md`.

Focus used: wording precision, consistency, internal coherence, no-new-entities consistency, first-pass authoring versus validator blocking, and executable final acceptance criteria.

Main findings:

- C1: “first-pass correctness” still mixes first attempted authoring correctness with before-write blocking and first completed/persisted description correctness.
- C2: top-level target behavior over-includes legacy spec-prep relative to later deferral rules.
- L1: no-new-entities is mostly preserved, but “diagnostic surface” and “no-op shim” could be misread.
- L2: final acceptance criteria are close but should bind each outcome to a proof source and clarify first-pass evidence.
- L3: “scoped” remains ambiguous in acceptance-facing text.
- L4: “plain bullets” should explicitly mean hyphen bullets if the regex intentionally rejects `*` bullets.

Exact ordered fix list:

1. Define whether the guarantee is first attempted payload correctness or first persisted/completed description correctness.
2. Rename or rewrite all “first-pass correctness” language to match that definition, including title or milestone names if needed.
3. Update live smoke evidence rules so the first-pass criterion cannot be satisfied by a fallback artifact that omits the first attempted payload when that payload exists.
4. Rewrite section 5 to make `mode:plan` mandatory and legacy spec-prep optional only under a precise implemented predicate.
5. Add a no-new-entities clarification allowing in-module helpers/tests but forbidding standalone modules, scripts, policy files, services, and persisted runtime concepts.
6. Replace “scoped `mode:plan` descriptions” in acceptance with the exact positive identification rule.
7. Define “plain bullet” as hyphen-only or update grammar/tests to accept asterisk bullets.
8. Tag each final acceptance criterion with its proof source: unit, contract, integration, live smoke, or no-new-entity review.
