# Red Team Critique, Pass 2 Round 3

Target: `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`

Focus: wording precision, consistency, and internal coherence of stage vocabulary and success claims.

Result type: critique-first review, not a repair spec.

## Active Critique Routes

- `ACTIVE`: success-claim wording does not fully match the lifecycle vocabulary used elsewhere in the document.
- `ACTIVE`: stage labels are introduced as canonical, but the document also uses narrower and broader lifecycle terms without clearly separating them.
- `SUPPORTING`: terminology normalization drift (`Spec Prep` vs `spec-prep`, `handoff state` vs `handoff`) is weakening coherence.

## Critical Findings

1. The success-criteria vocabulary is incomplete relative to the lifecycle vocabulary the document itself uses.
   - Evidence: the success criteria promise a “one canonical vocabulary” for `Spec Prep`, `Spec Review`, `In Progress`, `In Review`, `Blocked`, and `Merging` (`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:18-25`), but the same document later treats `Todo` intake, `Rework`, `Done`, and `Backlog` as operational stage terms in the single-mechanism flow and status map (`docs/reports/...:37-45`, `703-717`).
   - Why this matters: the success claim reads as if it closes the stage vocabulary, but the document continues to use additional lifecycle states as first-class routing terms. That makes the claim internally incomplete: it is unclear whether those extra states are intentionally outside the canonical vocabulary or simply omitted from the claim.

2. The phrase “later handoff state” is too singular for the stage model the document actually defines.
   - Evidence: the success criteria say “the later handoff state is already valid when execution reaches handoff” (`docs/reports/...:23-25`), while the first-pass rules distinguish `In Review` and `Blocked` as separate classified handoff outcomes (`docs/reports/...:90-101`), and the workflow later treats `Rework` as a distinct follow-on state (`workflows/letterl/maxime/let.WORKFLOW.md:713-717`).
   - Why this matters: the success claim collapses multiple post-execution outcomes into one phrase. That makes it harder to tell whether the document is promising validity for a single state, a pair of handoff outcomes, or the entire post-execution branch. The wording is too loose for the control-flow model it is meant to guarantee.

## Lower-Priority Findings

1. The document mixes canonical state names with adjective forms of the same states without clearly delimiting which are state labels and which are prose modifiers.
   - Evidence: `Spec Prep` is used as a canonical stage name, but the document also uses `spec-prep`, `spec-prep/research`, and `spec-prep-only` as descriptive forms in several places (`docs/reports/...:29-33`, `41-45`, `703-717` in the supporting workflow context).
   - Why this matters: the reader has to infer when the hyphenated forms are just prose and when they refer to the canonical state. That is a small but real coherence leak in a document whose central claim is single-mechanism precision.

2. The success phrase `first-pass correctness` is treated as both a named slogan and a gating property, but the text does not explicitly separate those roles.
   - Evidence: it is introduced as the “Canonical success phrase” (`docs/reports/...:27`), then later repeated as the branch implementation goal and as the proof-sequence conclusion (`docs/reports/...:205-235`).
   - Why this matters: the document is consistent in intent, but the repeated reuse of the phrase across slogan, goal, and proof bar blurs whether it is a label for the document or a testable property. That is a wording precision issue rather than a structural one.

## Recommendations

1. Split the lifecycle vocabulary into “canonical stage labels” and “supporting routing states” so the success criteria can state exactly which states are in scope.
2. Reword “later handoff state” into the specific handoff outcomes it refers to, or explicitly say it means the `In Review` / `Blocked` branch.
3. Normalize the hyphenated `spec-prep` forms so the document clearly distinguishes canonical state names from descriptive prose.
4. Keep `first-pass correctness` as the slogan, but state the testable property in a separate sentence so the success claim reads unambiguously.

## Compact Ledger

- Target document: `docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`
- Focus used: wording precision, consistency, and internal coherence of stage vocabulary and success claims
- Main findings: the success-criteria vocabulary is narrower than the lifecycle vocabulary used later; “later handoff state” is too singular for the branch structure the document defines; stage-name normalization still leaks through hyphenated prose forms
- Exact ordered fix list for repair round:
  1. Separate canonical stage labels from supporting routing states in the success criteria.
  2. Reword the “later handoff state” claim to name the actual post-execution outcomes.
  3. Normalize `spec-prep`/`Spec Prep` wording so prose forms cannot be mistaken for state labels.
  4. Separate the `first-pass correctness` slogan from the testable property sentence.
