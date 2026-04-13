# Design Policy

## Purpose

This policy is mandatory for any Symphony workflow that produces a design document, task-spec, engineering plan, or implementation-ready ticket description.

The goal is to reduce avoidable spec churn by forcing critique, code grounding, and explicit scope decisions before a spec is treated as ready for execution.

This policy applies to:

- `plan-mode`
- `research-mode` when it ends in a fix contour or implementation-ready spec
- any manual planning request that rewrites or normalizes a ticket into an execution contract

## Core rule

Do not treat the first coherent draft as a ready spec.

Every spec must go through structured critique before handoff. Risky tasks must also be grounded in the real code before the spec is considered complete.

## Non-negotiable rules

### Self-contained contract

Critical planning constraints must live in the local spec-producing workflow or document itself.

Do not rely on the model to reconstruct important planning rules from scattered higher-level context.

### One Ticket, One MVP

Each implementation ticket must choose one explicit MVP.

A spec may mention alternatives, but the final contract must recommend exactly one primary path. The execution pass must not mix multiple competing MVPs.

### No live contradiction

The issue description is the canonical implementation contract.

If comments or follow-up discussion materially change the solution, the description must be rewritten to match. Do not leave the body and the comments pointing to different MVPs.

### New axis contract

If a spec introduces a new field, mode, role, disposition, state, or routing axis, it must explicitly define:

- where it lives
- which existing fields or decisions it replaces or complements
- which layers read it
- which layers write it
- which invariants must remain unchanged

Do not introduce a new semantic axis without mapping it against the current contract surface.

### Operational acceptance

Acceptance criteria must be testable and operational.

If the task claims better coverage, lower error rate, safer routing, or better quality, the spec must define:

- the fixed regression dataset or case set
- the baseline
- the target delta or threshold
- the false positive ceiling or equivalent guardrail
- any runtime or cost budget that matters

### Split threshold

If a spec simultaneously changes multiple contracts such as semantics, storage, runtime routing, diagnostics, proof artifacts, or rollout, it must either:

- justify why this is still the smallest coherent change, or
- split the work into follow-up tickets

### Authoritative artifact mapping

If the issue refers to named cases, runs, IDs, chats, or document pairs, the spec must either:

- map them to authoritative runtime artifacts, or
- mark the mapping as inconclusive

Do not silently treat a guessed mapping as source of truth.

### Systemic-fix claim bar

A spec may not claim that a class of failures is "fixed systemically" unless the proof plan covers both:

- positive examples that must improve
- negative examples that must not regress

## Required flow

For normal tasks, the minimum required flow is:

1. Draft the smallest coherent spec.
2. Run critique pass 1.
3. Revise the spec.
4. Run critique pass 2.
5. Revise the spec.
6. Check stop condition.
7. Hand off only if the spec is implementation-ready.

For risky tasks, the minimum required flow is:

1. Draft the smallest coherent spec.
2. Run critique pass 1.
3. Revise the spec.
4. Ground the spec in the real code.
5. Run critique pass 2.
6. Revise the spec.
7. Run critique pass 3 if material risk remains.
8. Revise the spec.
9. Check stop condition.
10. Hand off only if the spec is implementation-ready.

## Risk classification

Treat a task as risky if any of the following are true:

- it changes persistence, migrations, or stored identifiers
- it changes runtime boundaries, public interfaces, or cross-module contracts
- it involves concurrency, retries, state machines, or ordering-sensitive logic
- it relies on backward compatibility or staged rollout constraints
- it changes external integrations, queues, webhooks, or third-party APIs
- it introduces a new decision/routing axis or semantic role
- it changes storage and runtime behavior in the same ticket
- it depends on code that may not yet exist in the current checkout
- it introduces ambiguous scope boundaries with neighboring tickets

If there is real doubt, classify the task as risky.

## Drafting rules

The initial draft must:

- define the problem and intended outcome clearly
- prefer the smallest coherent change that solves the stated problem
- separate confirmed facts from assumptions
- make scope boundaries explicit
- name dependencies and sequencing constraints
- define how the result will be validated
- avoid leaving key architectural decisions implicit
- choose one recommended implementation path
- call out what is intentionally not included

A draft is not ready just because it sounds plausible.

## Mandatory critique passes

Each critique pass must look for material weaknesses in the current spec, not just wording issues.

The critique must explicitly check for:

- hidden dependencies on code, data, or infra not yet confirmed
- scope bleed into adjacent tickets, migrations, cleanup, or follow-up work
- multiple MVPs accidentally merged into one ticket
- contradictions between description, comments, and current recommendation
- unclear ownership between modules, layers, or systems
- undefined invariants or compatibility constraints
- missing runtime, storage, or interface consequences
- vague acceptance criteria
- validation plans that cannot actually prove the change
- new semantics introduced without a full axis contract
- decisions silently pushed onto the future implementer
- assumptions stated as facts without evidence
- unnecessary abstractions, refactors, or future-proofing

A critique pass should try to break the design, not approve it.

## Code grounding

Risky tasks must be grounded in the actual code before handoff.

Grounding means checking the current implementation to verify:

- the real DTOs and data shapes
- the actual call sites and control flow
- the current persistence keys and identity model
- existing invariants and compatibility constraints
- whether referenced carriers, helpers, or abstractions exist in the current checkout
- whether the proposed ownership boundaries match the current code layout
- whether each claimed routing signal or state transition is real in the current code
- whether existing contracts already cover part of the proposed change

Grounding must correct the spec when the code disagrees with the draft.

Do not write a spec as if a dependency already exists unless that dependency is actually present or explicitly marked as an external prerequisite.

## Spec contract

An implementation-ready spec should include, when relevant:

- `Проблема`
- `Цель`
- `Скоуп`
- `Вне скоупа`
- `Критерии приемки`
- `Ограничения и инварианты`
- `Риски`
- `Зависимости`
- `План валидации`
- `Заметки`
- `Alternatives considered` when more than one credible path exists
- final `## Symphony` section when the workflow requires it

The spec must be explicit enough that execution does not depend on hidden chat context.

## Acceptance and proof requirements

If the task is about quality, coverage, routing, classification, merge behavior, or risk reduction, the spec must define the proof plan explicitly.

The proof plan should name, when relevant:

- the regression dataset or fixture set
- positive cases that must improve
- negative cases that must stay unchanged
- exact success metrics or thresholds
- false positive or regression ceilings
- runtime artifact format for proof
- cost, latency, or LLM-call budget if applicable

Qualitative language such as "better", "higher coverage", or "safer" is insufficient without proof criteria.

## Required quality bar

A spec is only ready if all of the following are true:

- the main implementation contour is concrete
- important boundaries are explicit
- the minimal validation plan is stated
- one MVP is clearly chosen
- description and latest recommendation are aligned
- remaining unknowns are few and clearly labeled
- those unknowns do not change the execution path materially
- no major architectural decision is deferred to the implementer by accident
- the spec does not conflict with the current code reality
- the acceptance criteria can actually prove success or failure

## Stop condition

Stop iterating only when critique no longer finds material issues.

Do not stop because:

- the spec is long
- the draft is readable
- two versions look similar
- the remaining problems feel small but still change execution or acceptance
- the body is detailed but still contains contradictory scope

If critique still finds material ambiguity, the spec is not ready.

## Forbidden patterns

Do not:

- present unverified assumptions as settled facts
- widen scope without explicit need
- keep multiple conflicting MVPs in one ticket
- rely on nonexistent abstractions without marking them as dependencies
- introduce a new semantic axis without mapping it to existing contracts
- hide risky decisions inside vague wording
- claim systemic improvement without positive and negative proof cases
- leave acceptance to subjective interpretation
- call a plan complete if validation is still unclear
- produce a spec that only the current chat can interpret correctly

## Output expectations

When a planning workflow completes, the final result should make clear:

- what is confirmed
- what remains uncertain
- which MVP was chosen and why
- the recommended implementation contour
- the validation plan
- the dependencies or blockers, if any
- for risky tasks, what code grounding changed or confirmed in the spec
- if alternatives existed, why they were rejected or deferred

## Enforcement

Planning workflows must follow this policy by default, not as an optional extra.

If a workflow produces an implementation-ready spec without the required critique passes, without code grounding for a risky task, with unresolved contract contradictions, or without operational acceptance criteria, that output does not meet the planning bar.
