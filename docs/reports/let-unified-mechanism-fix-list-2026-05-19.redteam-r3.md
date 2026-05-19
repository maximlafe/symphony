# Red-Team Critique: LET Unified Mechanism Fix List (Round 3 of 3)

Focus: wording precision, consistency, and internal coherence. Remove ambiguity, duplication, and unclear scope statements.

## Critical Findings

1. The checkpoint-flow language repeats the same dependency in three different forms, which makes the repair order harder to read and risks readers treating one formulation as optional.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:55-76`, `:148-163`, `:165-191`.
   - Why this is a problem: the same requirement appears as `Execution order`, `Required prerequisite`, and again in the validation slice. Those are not distinct concepts in the current wording; they are the same dependency stated three times with different labels. That creates false emphasis and weakens the precision of the sequence.

## Lower-Priority Findings

1. The document uses several near-synonyms for the same artifact without pinning one canonical term.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:27-30`, `:61-76`.
   - Terms in conflict: `hand-off payload`, `transition payload`, `handoff assembly path`, `handoff manifest mirror`, `workpad / handoff manifest mirror`.
   - Why this matters: the checkpoint requirement is already narrow; the naming drift makes it unclear whether the source data lives in the workpad, the manifest, the transition payload, or some composed mirror. That ambiguity is purely wording-level, but it blurs the ownership boundary the report is trying to establish.

2. The proof-mapping item narrows to `plan-mode issue-description mapping` only in the closing note, after the broader grammar problem has already been described.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:90-103`, `:148-163`.
   - Why this matters: the headline says “Proof Mapping bullet grammar drift,” but the ownership note later introduces a narrower scope. Readers have to infer whether the repair is about the issue-description grammar only, the workpad parser too, or both. The report should declare that scope up front instead of retrofitting it in the explanatory note.

3. `Rollback And Stop Rules` and `Validation Slice For Each Fix` overlap semantically with the repair order, but the document does not say which section is authoritative if they conflict.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:129-146`, `:148-191`.
   - Why this matters: the report now has three procedural sections with partially duplicated sequencing content. That is workable only if the document states which one is binding. Without that, a reader can reasonably disagree about whether the fix order, the rollback rules, or the validation slice defines the actual implementation protocol.

4. The last item in the repair order is worded as a conditional policy statement, while the matching validation slice treats it as an active gate.
   - Target anchors: `docs/reports/let-unified-mechanism-fix-list-2026-05-19.md:161-163`, `:185-188`.
   - Why this matters: “Keep merge-ready `UNKNOWN` only as a named regression gate” and “green: that same regression gate if the item remains in the active repair sequence” are compatible, but the wording leaves the status of the item uncertain. Is it a required fix, a temporary gate, or a deferred hardening item? The document should choose one label and use it consistently.

## Recommendations

1. Collapse the checkpoint-flow language into a single authoritative step description, then reuse that exact wording everywhere else.
2. Pick one canonical term for the data object being propagated and use it consistently throughout the document.
3. Move the proof-mapping scope statement into the item headline or first bullet, not the closing note.
4. Add one sentence that declares whether `Recommended Fix Order`, `Rollback And Stop Rules`, or `Validation Slice For Each Fix` is the authoritative procedure when they differ.
5. Rephrase the `UNKNOWN` item so its status is explicit: required fix, named regression gate, or deferred hardening.

## Repair Round Order

1. Deduplicate the checkpoint-flow wording into one authoritative formulation.
2. Standardize the payload terminology across the ownership boundary and checkpoint sections.
3. State the proof-mapping scope up front instead of narrowing it only in the note.
4. Declare which procedural section is authoritative when procedural sections overlap.
5. Fix the status wording for merge-ready `UNKNOWN` so the item has one clear classification.

## Ledger

- Target document: `/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-unified-mechanism-fix-list-2026-05-19.md`
- Focus used: wording precision, consistency, and internal coherence
- Main findings: duplicated checkpoint dependency wording; inconsistent terminology for the same payload; proof-mapping scope narrowed too late; overlapping procedural sections without an authoritative rule; unclear status wording for `UNKNOWN`
- Exact ordered fix list for final repair:
  1. Deduplicate the checkpoint-flow wording into one authoritative formulation.
  2. Standardize the payload terminology across the ownership boundary and checkpoint sections.
  3. State the proof-mapping scope up front instead of narrowing it only in the note.
  4. Declare which procedural section is authoritative when procedural sections overlap.
  5. Fix the status wording for merge-ready `UNKNOWN` so the item has one clear classification.
