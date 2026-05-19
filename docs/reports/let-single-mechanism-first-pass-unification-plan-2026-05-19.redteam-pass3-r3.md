# Red-Team Critique: LET Single Mechanism First-Pass Unification Plan

Round 3 of 3

Focus: wording precision, internal consistency, and no-overclaim discipline for the 4 closed points and their replay instructions.

## Phase Snapshot

- Target: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md)
- Evidence boundary: local repo files only
- Result typing: verified issue, bounded concern, recommendation

## Critical Findings

### 1) The helper-copy subsection still overclaims by naming "alignment" when the body proves separation

**Status:** `verified issue`

The fourth closure subsection is now structurally replayable, but its title still overstates the result. The body proves that canonical proof and helper-copy smoke are separated; it does not prove that helper-copy tests are "aligned" to canonical surfaces in the strong sense that the title suggests.

- The subsection title at [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:297`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L297) says "Helper-copy tests alignment to canonical surfaces."
- The replay order at [`...:301-306`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L301) explicitly tells the reviewer to keep the canonical proof lane and helper-copy smoke lane separate.
- The body at [`...:310-316`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L310) then splits the evidence into a "Canonical proof lane" and a "Helper-copy compatibility smoke" lane.
- That is an internal-consistency mismatch: the section title still asserts alignment while the evidence only supports separation plus canonical primacy.

### 2) The runtime subsection is disciplined, but the wording still leans toward exhaustiveness unless read carefully

**Status:** `bounded concern`

The runtime closure was corrected to say "observed coverage," which is better. The remaining risk is that the section still uses a mix of "coverage," "call set," and "completing" language that can be read as stronger than the stated limitation.

- The replay order at [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:269-274`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L269) correctly says this is observed coverage, not repo-wide exhaustiveness.
- But the evidence bullets at [`...:276-279`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L276) still say "establishing the first observed runtime consumer" and "completing the observed finalizer-facing runtime call set," which is close to an inventory claim.
- The section is not wrong, but the vocabulary is close enough to a full inventory claim that it should stay consistently qualified as "observed call-site coverage" throughout.

### 3) The legacy wording audit replay order still asks the reviewer to infer more than the cited line directly states

**Status:** `bounded concern`

The first closure subsection is mostly sound, but replay step 3 still asks the reviewer to "verify the repo-local canon instruction that makes this wording explicitly peripheral rather than authoritative." That is slightly stronger than what the cited AGENTS line directly states.

- The replay order at [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:254-259`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L254) is clear about the order of checks.
- The cited README lines at [`...:256-257`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L256) are what actually show the leftover compatibility wording.
- The AGENTS anchor at [`...:258`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L258) supports the "do not duplicate routing semantics" rule, but it does not by itself prove that the legacy wording is peripheral; that conclusion is an inference from the README plus AGENTS together.
- This is a precision issue, not a correctness failure, but the replay text should not imply that one line proves the full compatibility-scoping conclusion on its own.

## Lower-Priority Findings

### 4) The branch-contract subsection is accurate but still slightly under-specified as a replay check

**Status:** `bounded concern`

The branch-contract closure has the right sources and the right order, but its concluding replay step could be more explicit about what counts as success.

- The replay order at [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md:287-290`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L287) names the exact contract and workflow anchors to inspect.
- The support bullets at [`...:292-295`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L292) show the subordinate-short-plan rule and the compatibility-baseline wording.
- However, the conclusion at [`...:290`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md#L290) is still phrased as a descriptive restatement rather than a pass/fail rule, so the replay instruction is correct but not maximally self-checking.

## Recommendations

1. Rename the helper-copy subsection so the title matches the proof: "helper-copy smoke separated from canonical proof" is closer than "alignment."
2. Standardize the runtime subsection to "observed call-site coverage" everywhere and avoid "call set" language unless the section explicitly means a bounded observed set.
3. Rephrase the legacy wording replay step so AGENTS.md is described as supporting the compatibility conclusion, not proving it alone.
4. Add a one-line success criterion to the branch-contract replay order, such as "pass only if the inspected anchors collectively show SSOT precedence and compatibility-only fallback."

## Ledger

- Target document: [`docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md`](/Users/lafe/.codex/worktrees/a262/Symphony/docs/reports/let-single-mechanism-first-pass-unification-plan-2026-05-19.md)
- Focus: wording precision, internal consistency, and no-overclaim discipline
- Main findings:
  - helper-copy subsection title still overclaims "alignment" where the body proves separation;
  - runtime subsection is disciplined but could still read as exhaustiveness unless wording is tightened further;
  - legacy wording replay step 3 slightly overstates what AGENTS.md proves on its own;
  - branch-contract replay is accurate but would benefit from an explicit pass/fail criterion
- Exact ordered fix list for the repair round:
  1. Rename the helper-copy subsection so the title matches the proof.
  2. Standardize the runtime wording to observed coverage only.
  3. Rephrase the legacy audit replay text so AGENTS.md is supporting evidence, not standalone proof.
  4. Add an explicit success criterion to the branch-contract replay order.
