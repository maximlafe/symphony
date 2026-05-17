# Red Team Critique: ticket-movement-rewrite-plan Round 3

## Scope

- Focus for this round: wording precision, consistency, and internal coherence.
- Non-goal: re-litigating the dependency order or rollback completeness already covered in round 2.
- Evidence boundary: the current plan text at [docs/plans/ticket-movement-rewrite-plan.md](../plans/ticket-movement-rewrite-plan.md).

## Critical Findings

### 1. The document still overstates what its own matrix can prove

**Type:** `verified issue`

The validation matrix now names concrete tests, but several rows still claim a stronger guarantee than those tests can actually establish. For example, the “Stage boundary mapping” row says the listed tests prove that “Concrete plan/execution/review surfaces do not cross each other's side effects.” The named tests are about `ExecutionContract` normalization, `HandoffCheck` acceptance, and `AppServer` validation dedupe. That is not the same thing as proving that the three stage boundaries are correctly separated in the plan’s sense of ownership.

This is a wording problem, not a coverage complaint. The matrix is presenting a contract-level guarantee while the actual proof targets are still behavior slices from adjacent surfaces. The reader is left with a stronger conclusion than the evidence supports.

### 2. The stage labels are presented as planning labels, but the surrounding prose still reads like a real contract split

**Type:** `verified issue`

The ownership map says the stage names are “planning labels, not new Elixir modules,” and that the concrete implementation surfaces are `ValidationGate`, `ExecutionContract`, `Orchestrator`, `HandoffCheck`, and `controller_finalizer`. But the rest of the document keeps using the stage labels as if they were already stable architectural boundaries:

- “ownership-карта for plan / execution / review boundaries”
- “contract split по стадиям”
- “Plan -> Execute -> Review -> Done/Blocked”
- “Stage boundary mapping”

That creates an internal wobble: the document denies that the labels are implementation modules, then repeatedly uses them as if they are already the canonical partition of the codebase. The plan can be a roadmap or a design assertion, but it should not sound like both at once.

### 3. The language for rollback and stop rules is not uniform enough for a document that relies on hard gates

**Type:** `bounded concern`

The rollback section mixes English and Russian imperatives, alternates between “Retire abstract naming,” “Откат,” and “remove only the wrapper call-site migration,” and sometimes uses policy-style statements while other lines read like annotations. The result is understandable, but the enforcement strength is uneven.

This matters because the document is supposed to be read as an execution plan with hard gates. If the reader has to infer whether a line is a rule, a note, or a suggested action, precision suffers. The same issue shows up in places like “No new defaults may be introduced while this step is incomplete,” which is clear in isolation but not phrased in the same register as the adjacent rollback items.

## Lower-Priority Findings

### 4. The document switches between “boundary,” “surface,” “stage,” and “contract” without pinning the relationship between those words

**Type:** `working criticism`

The plan uses at least four overlapping nouns for the same conceptual layer:

- boundary
- surface
- stage
- contract

Sometimes they are clearly distinct, sometimes not. For example, the plan says “stage names are planning labels, not new Elixir modules,” then later says “contract split по стадиям,” and the validation matrix uses “Stage boundary mapping.” The reader can infer the intended meaning, but the terminology is not normalized enough for a document that is explicitly trying to reduce drift.

### 5. The matrix mixes file-level identifiers, quoted sentence fragments, and conceptual guarantees in one column

**Type:** `working criticism`

The “Named regression tests” column is not consistently named. Some entries are file plus test title fragments, others are conceptual descriptions stitched to a file, and others are a file name plus a long prose clause. That is readable, but it weakens precision because the document does not say whether a named regression test means:

- a literal test function name,
- a file-level bucket,
- or a human-readable proof slice.

Because of that ambiguity, the matrix looks more exact than it is. It would be better if the doc chose one naming rule and used it everywhere.

### 6. The ownership map and the fallback section overlap without saying which surface owns the fallback decision

**Type:** `bounded concern`

The plan says the plan boundary owns the source of `changed_paths`, and later says `changed_paths` fallback semantics must be fail-closed. But it never states whether fallback policy is owned by the plan boundary, execution boundary, or review boundary.

That omission does not break the plan, but it does leave a small semantic hole: “who owns the fallback?” is not the same as “where is the fallback implemented?” The document currently answers the second question better than the first.

## Recommendations

1. Downgrade matrix prose so it claims only what the named tests can actually prove.
2. Pick one terminology set for the layer model, then use it consistently.
3. Make rollback and stop rules use one language register and one formatting style.
4. Define which boundary owns `changed_paths` fallback policy, not just its implementation.
5. Decide whether “named regression test” means a literal test name or a proof slice label, then normalize the matrix accordingly.

## Compact Fix List For Repair Round

1. Reduce matrix claims to match the actual proof targets.
2. Normalize the layer terminology across the whole document.
3. Standardize rollback and stop-rule wording.
4. Assign `changed_paths` fallback ownership explicitly.
5. Standardize what counts as a named regression test.

## Ledger

- **Target document:** [docs/plans/ticket-movement-rewrite-plan.md](../plans/ticket-movement-rewrite-plan.md)
- **Focus used:** wording precision, consistency, and internal coherence
- **Main findings:** the validation matrix still overstates what its proof targets can show; stage labels are used as both planning labels and de facto architecture boundaries; rollback and naming language remain uneven
- **Exact ordered fix list for the repair round:** `1) reduce matrix claims to match actual proof targets; 2) normalize the layer terminology; 3) standardize rollback and stop-rule wording; 4) assign changed_paths fallback ownership explicitly; 5) standardize what counts as a named regression test`
