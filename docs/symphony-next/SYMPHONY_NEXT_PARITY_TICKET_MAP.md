# Symphony Next Parity Ticket Map

This file turns the parity documents into a working backlog.

It is not another architecture document. It is a prioritization layer for
execution:

- what must be done before replacement
- what should be done before replacement if the risk is real
- what can wait until after stable replacement
- what should not be ported at all unless a hard requirement appears

## Relationship To Other Files

Use the files in this order:

1. [SYMPHONY_NEXT_FEATURE_PARITY.md](./SYMPHONY_NEXT_FEATURE_PARITY.md)
   - what the gap is
2. [SYMPHONY_NEXT_FEATURE_PARITY_CHECKLIST.md](./SYMPHONY_NEXT_FEATURE_PARITY_CHECKLIST.md)
   - what must eventually be evidenced
3. [SYMPHONY_NEXT_PARITY_EXECUTION_PLAN.md](./SYMPHONY_NEXT_PARITY_EXECUTION_PLAN.md)
   - in what order to close it
4. [SYMPHONY_NEXT_CODEX_APP_SERVER_DESIGN.md](./SYMPHONY_NEXT_CODEX_APP_SERVER_DESIGN.md)
   - how the richer Codex runner should be implemented without breaking the new
     architecture
5. [SYMPHONY_NEXT_FINAL_OPS_AND_CUTOVER_MODEL.md](./SYMPHONY_NEXT_FINAL_OPS_AND_CUTOVER_MODEL.md)
   - which old operational behaviors must survive in the final system, which
     budget behavior is intentionally excluded, and how migration gates collapse
     after replacement
6. [SYMPHONY_NEXT_PARITY_INVENTORY.md](./SYMPHONY_NEXT_PARITY_INVENTORY.md)
   - which behaviors are already covered, partial, or still missing
7. this file
   - how to turn that into actionable work items

## How To Use This File

Each row is a candidate ticket, PR stream, or work package.

The important fields are:

- `Class`
  - `blocking_for_replacement`
  - `strongly_recommended_pre_replacement`
  - `after_replacement`
  - `intentionally_obsolete_until_required`
- `Why now`
  - why the item belongs in that class
- `Done when`
  - evidence-based exit condition

Do not move a row to a lower class just because implementation is expensive.

Also do not split one unresolved parity gap into several "green" tickets if the
replacement risk is still singular. Close the risk, not just the paperwork.

## Priority Classes

### 1. `blocking_for_replacement`

If this is not closed, `Symphony-next` should not become the primary
orchestrator for overlapping production scope.

### 2. `strongly_recommended_pre_replacement`

Not all of these are mathematically blocking, but skipping them increases the
odds of an operationally ugly replacement.

### 3. `after_replacement`

These are useful hardening or cleanup items that should wait until the new
system is already the stable primary runtime.

### 4. `intentionally_obsolete_until_required`

These are old-system capabilities that should not be ported by default.
Reintroduce them only if they become explicit requirements.

## Reclassification Rule

This backlog is allowed to change class only under explicit evidence.

Examples:

- if a real production requirement expands or narrows the final ops/resilience
  subset, update the active backlog class accordingly
- if an "obsolete" capability blocks a real replacement-scope workflow, it
  stops being obsolete and becomes active backlog
- if a row becomes fully evidenced in executable parity artifacts, it can move
  out of the active backlog

## Ticket Backlog

### A. Blocking For Replacement

| ID | Work item | Source gap | Class | Why now | Done when | Suggested owner |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-01` | Freeze canonical Linear routing contract | Broad Linear routing parity | `blocking_for_replacement` | Without this, route parity stays hand-wavy and replacement-scope `unknown` can hide inside labels/project/team combinations | Replacement-scope routing matrix is explicit, fixture-backed, and live-sanitized cases pass | Tracker parity |
| `PARITY-02` | Freeze canonical issue trace contract | Exact issue trace parity | `blocking_for_replacement` | Operators depend on comments, workpad, attachments, and handoff traces; functional parity without trace parity is not enough | Comment/workpad/artifact/handoff trace contract is written and validated against old real issues | Tracker parity |
| `PARITY-03` | Prove old-trace resume compatibility | Resume from legacy traces | `blocking_for_replacement` | Replacement fails in practice if Next cannot safely continue old in-flight issues | Resume scenarios from real sanitized legacy traces pass with no ambiguous recovery | Tracker parity + runtime parity |
| `PARITY-04` | Freeze PR evidence contract | PR discovery parity | `blocking_for_replacement` | If PR evidence recovery is fuzzy, review and merge decisions drift silently | Branch/comment/workpad/workspace PR discovery contract is explicit and executable | GitHub parity |
| `PARITY-05` | Encode review/finalizer semantics explicitly | Review-ready/finalizer parity | `blocking_for_replacement` | This is where subtle regressions hide: checks, review comments, merge readiness, handoff order | Old finalizer decisions are captured as executable scenarios and pass under Next | GitHub parity + verification parity |
| `PARITY-06` | Prove merge gating parity | Merge-readiness semantics | `blocking_for_replacement` | Incorrect merge decisions are high-cost production regressions | All replacement-scope merge-ready / not-ready / stale-proof scenarios are explicit and green | GitHub parity + verification parity |
| `PARITY-07` | Close long-lived runtime recovery parity | Recovery/replay parity | `blocking_for_replacement` | Replacement cannot rely only on short canaries; it must survive restarts, repeated polling, and partial progress | Long-running restart/recovery scenarios pass and event-log replay yields stable state | Runtime parity |
| `PARITY-08` | Decide and implement target live Codex runner depth | Missing app-server-class runtime richness | `blocking_for_replacement` | Current biggest feature gap is live agent execution depth, not adapter presence | Required runner contract is frozen, implementation follows [SYMPHONY_NEXT_CODEX_APP_SERVER_DESIGN.md](./SYMPHONY_NEXT_CODEX_APP_SERVER_DESIGN.md), and the chosen implementation satisfies replacement-scope behaviors | Codex runtime parity |
| `PARITY-09` | Prove continuation-turn parity | Missing continuation-turn behavior | `blocking_for_replacement` | Old Symphony is materially better at long-lived partially completed tasks; replacement without this is weaker in the exact risky path | Continuation, interruption, and resume scenarios are explicit and passing | Codex runtime parity |
| `PARITY-10` | Freeze skills policy for Next | Skills can become hidden runtime again | `blocking_for_replacement` | If skills carry orchestration logic, source-of-truth discipline collapses | Allowed vs forbidden skill roles are explicit and verified against runtime boundaries | Skills policy |
| `PARITY-19` | Freeze the final ops/resilience model | Operations/resilience gap | `blocking_for_replacement` | The final system must preserve old production resilience behavior except budget-only forced handoff; this is now explicit replacement scope | [SYMPHONY_NEXT_FINAL_OPS_AND_CUTOVER_MODEL.md](./SYMPHONY_NEXT_FINAL_OPS_AND_CUTOVER_MODEL.md) is accepted as the final-state decision and reflected in implementation work | Operations / resilience |
| `PARITY-20` | Implement the mandatory final ops/resilience subset | Operations/resilience gap | `blocking_for_replacement` | Start gating, account health, failover, retry discipline, escalation, and observability are required in the final version | The mandatory subset defined in [SYMPHONY_NEXT_FINAL_OPS_AND_CUTOVER_MODEL.md](./SYMPHONY_NEXT_FINAL_OPS_AND_CUTOVER_MODEL.md) exists with executable evidence | Operations / resilience |
| `PARITY-11` | Prove broad shadow parity on representative production scope | Broad production-proof replacement | `blocking_for_replacement` | Canary is necessary but insufficient; replacement needs overlapping real scope proof | Shadow artifacts show no replacement-scope `unknown` rows on representative production sample | Migration / cutover |
| `PARITY-12` | Prove limited cutover without duplicate work | Production scheduler semantics + cutover safety | `blocking_for_replacement` | The replacement must not race with the old orchestrator or duplicate work during rollout | Limited cutover evidence shows no duplicated work, no lost work, and clean rollback | Migration / cutover + runtime parity |
| `PARITY-13` | Prove rollback under realistic production conditions | Rollback proof | `blocking_for_replacement` | A replacement without rollback proof is operationally unserious | Rollback command/procedure is exercised and leaves old scope healthy | Migration / cutover |

### B. Strongly Recommended Pre-Replacement

| ID | Work item | Source gap | Class | Why now | Done when | Suggested owner |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-14` | Complete actionable review feedback classification | Actionable review feedback parity | `strongly_recommended_pre_replacement` | This may not block every rollout, but review regressions are expensive and hard to detect late | Review comment states are classified explicitly and tied to workflow decisions | GitHub parity |
| `PARITY-15` | Strengthen workspace safety property coverage | Property-style safety coverage can still be stronger | `strongly_recommended_pre_replacement` | Safety is already good in Next; closing the last edge cases is cheaper before wide writes | Property-style or exhaustive path-safety tests cover remaining edge cases | Workspace security |
| `PARITY-16` | Inventory and close operator-critical dashboard gaps | Operator UX parity | `strongly_recommended_pre_replacement` | A technically correct replacement can still be painful to run if key visibility is missing | Required operator workflows are enumerated and each has a supported API/dashboard path | Web/API parity |
| `PARITY-17` | Freeze which old tools are truly replacement-critical | Tool surface breadth gap | `strongly_recommended_pre_replacement` | Avoid porting useless dynamic-tool sprawl while still closing real workflow blockers | Old tools are classified as required, obsolete, or replaced by first-class adapters | Tool parity |
| `PARITY-18` | Add only the missing required tool surface | Missing workflow-critical tool paths | `strongly_recommended_pre_replacement` | If a real workflow still depends on an old tool, replacement may look complete until it hits that path | Every required additional tool is capability-gated, audited, and covered by tests | Tool parity |

### C. After Replacement

| ID | Work item | Source gap | Class | Why later | Done when | Suggested owner |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-21` | Remove legacy-only migration scaffolding that no longer serves operators | Legacy cleanup | `after_replacement` | Cleanup before stable replacement destroys useful evidence and rollback aids | Legacy-only docs/snippets/configs are removed after stable replacement proof | Cleanup |
| `PARITY-22` | Prune duplicated migration truth | Duplicated truth across planning and migration docs | `after_replacement` | During migration, some duplication is acceptable if it helps proof and rollback | Only live contracts + concise migration history remain | Cleanup |
| `PARITY-23` | Final audit that skills/prompts are not hidden orchestration state | Skills policy hardening | `after_replacement` | Easier to verify after the runtime is stable and old fallback paths are gone | Audit finds no orchestration-critical behavior living only in skills/prompts | Skills policy |
| `PARITY-24` | Expand operator UX beyond minimum viable parity | Operator ergonomics | `after_replacement` | First replace safely, then improve comfort and visibility | Non-critical dashboards and operator shortcuts are added intentionally | Web/API parity |

### D. Intentionally Obsolete Until Required

These should not be treated as automatic parity obligations.

| ID | Capability | Old-system value | Class | Why not port by default | Re-open if | Suggested owner |
| --- | --- | --- | --- | --- | --- | --- |
| `PARITY-25` | Full old dynamic-tool breadth | Flexible but sprawling app-server tool surface | `intentionally_obsolete_until_required` | Porting all of it would recreate hidden complexity and weaken capability discipline | A replacement-critical workflow is blocked without a specific tool | Tool parity |
| `PARITY-26` | Old dashboard feature-for-feature UI parity | Familiar operator surface | `intentionally_obsolete_until_required` | UI sameness is less important than preserving operator-critical workflows | Operators cannot complete a required workflow via the new surface | Web/API parity |
| `PARITY-27` | Every historical operational quirk | Some quirks may reflect accumulated accident, not requirement | `intentionally_obsolete_until_required` | Replacement should preserve required behavior, not every artifact of historical implementation | A quirk turns out to be relied on by real production workflow | Cross-functional review |
| `PARITY-28` | Blind app-server port just because old Symphony uses it | Rich runner behavior | `intentionally_obsolete_until_required` | The requirement is runtime behavior parity, not necessarily process parity | CLI-based or hybrid runner cannot satisfy replacement-scope behaviors | Codex runtime parity |

## Suggested PR Packaging

This is one pragmatic way to translate the backlog into implementation streams.

### Stream 1. Tracker / Linear Replacement Proof

Includes:

- `PARITY-01`
- `PARITY-02`
- `PARITY-03`

Should finish before broad cutover work.

### Stream 2. GitHub / Review / Merge Semantics

Includes:

- `PARITY-04`
- `PARITY-05`
- `PARITY-06`
- `PARITY-14`

Should finish before claiming review/handoff/merge parity.

### Stream 3. Runtime / Codex Depth

Includes:

- `PARITY-07`
- `PARITY-08`
- `PARITY-09`
- `PARITY-19`
- `PARITY-20`

This is the highest-risk stream.

### Stream 4. Skills / Boundary Discipline

Includes:

- `PARITY-10`
- `PARITY-23`

This protects the main architectural goal from silent drift.

### Stream 5. Cutover Proof

Includes:

- `PARITY-11`
- `PARITY-12`
- `PARITY-13`

Nothing should be called "full replacement" before this stream is closed.

### Stream 6. Pre-Replacement Hardening

Includes:

- `PARITY-15`
- `PARITY-16`
- `PARITY-17`
- `PARITY-18`

These are important, but they should not displace the critical path.

### Stream 7. Post-Replacement Cleanup

Includes:

- `PARITY-21`
- `PARITY-22`
- `PARITY-24`

Do this only after stable replacement.

## Critical Review Of This Backlog

This backlog is wrong if it does either of these:

1. treats "exists in code" as "safe for replacement"
2. treats every old-system feature as equally worth porting

The critical path should stay narrow:

- preserve required behavior
- prove replacement on real scope
- preserve rollback
- avoid recreating the old system's accidental complexity

This backlog is also wrong if it treats a planning decision as implementation
evidence. A ticket is only closed when the associated executable proof exists.

## Minimal Replacement Gate

Do not call `Symphony-next` replacement-ready unless all of these are closed:

- `PARITY-01` through `PARITY-13`
- `PARITY-19`
- `PARITY-20`
- no replacement-scope parity row remains `unknown`
- no replacement-critical row remains
  `missing_from_next_scope`
- rollback is proven and documented

Everything else is secondary.

## Execution Status Log

| Ticket | Status | Branch | PR | Merge commit | Evidence summary |
| --- | --- | --- | --- | --- | --- |
| `PARITY-01` | `done` | `parity/parity-01-freeze-linear-routing-contract` | `https://github.com/maximlafe/symphony/pull/143` | `094cbd9105e607aa7b303fe8b0b8655a5c92afaf` | Canonical routing contract + fixture-backed matrix + live-sanitized sample validated; CI green + merged; post-merge sanity passed (`make symphony-preflight`, `mix test test/symphony_elixir/linear_routing_parity_test.exs`). Evidence: `docs/symphony-next/evidence/PARITY-01/PARITY-01_EVIDENCE_2026-04-26.md` |
| `PARITY-02` | `done` | `parity/parity-02-freeze-issue-trace-contract` | `https://github.com/maximlafe/symphony/pull/144` | `1b101982afca8c4253925dd321501d3d7560ec89` | Canonical issue trace contract + deterministic/live fixtures + parity suite validated against historical LET traces; CI green + merged; post-merge sanity passed (`make symphony-preflight`, `mix test test/symphony_elixir/issue_trace_parity_test.exs`). Evidence: `docs/symphony-next/evidence/PARITY-02/PARITY-02_EVIDENCE_2026-04-26.md` |
| `PARITY-03` | `done` | `parity/parity-03-prove-old-trace-resume-compatibility` | `https://github.com/maximlafe/symphony/pull/145` | `a2d7c5630637f7330f0be6e59a7344f30b64f2c6` | Legacy resume compatibility contract + deterministic/live legacy resume fixtures + parity suite validated; fail-closed normalization for inconsistent `resume_mode` traces shipped; CI green + merged; post-merge sanity passed (`make symphony-preflight`, `mix test test/symphony_elixir/resume_legacy_parity_test.exs`). Evidence: `docs/symphony-next/evidence/PARITY-03/PARITY-03_EVIDENCE_2026-04-26.md` |
| `PARITY-04` | `done` | `parity/parity-04-freeze-pr-evidence-contract` | `https://github.com/maximlafe/symphony/pull/146` | `a013737db4d78693f7f97550a9a9159998edb572` | Canonical PR evidence contract + fail-closed resolver (`source=none`) + deterministic/live fixtures + executable parity suites (`pr_evidence_parity_test.exs`, `pr_evidence_test.exs`) validated on real LET traces for comment/attachment/branch channels; CI green + merged; post-merge sanity passed. Evidence: `docs/symphony-next/evidence/PARITY-04/PARITY-04_EVIDENCE_2026-04-26.md` |
| `PARITY-05` | `in_review_prep` | `parity/parity-05-encode-review-finalizer-semantics` | `-` | `-` | Canonical finalizer semantics contract + deterministic matrix + live-sanitized LET traces + executable parity suite validated (`make symphony-preflight`, `make symphony-acceptance-preflight`, `make all`); pending PR/CI/merge. Evidence: `docs/symphony-next/evidence/PARITY-05/PARITY-05_EVIDENCE_2026-04-26.md` |
