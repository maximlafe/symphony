# LET-741: Plan First Persisted Description Correctness Remediation

## 1. Назначение документа

Этот документ задает план правок, чтобы Symphony в `mode:plan` сохраняла первый
persisted task-spec description корректным после pre-write self-correction, без
ручного дописывания `Proof Mapping` и без принятия неканоничного плана как
`passed`.

Документ ограничен существующими поверхностями Symphony. Новые функции/helpers
в существующих модулях и тесты разрешены; новые standalone modules, scripts,
policy-файлы, services, persisted runtime concepts и отдельные внешние линтеры
не добавляются.

Главная граница дизайна: `Proof Mapping` в Linear issue description является
spec-prep contract для синтаксиса, покрытия и совместимости типов proof source.
Он не является execution evidence. Проверка checked workpad evidence остается
отдельной handoff-проверкой и не должна ослабляться или запускаться как
обязательное требование для plan description на этапе `Spec Prep`.

## 2. Наблюдаемый дефект

На smoke-задаче LET-741 план в итоге прошел `symphony_spec_check`, но в
описании issue был сгенерирован `Proof Mapping` в человекочитаемой форме:

```md
* AM-1 -> test:file list diff.
* AM-2 -> test:literal content check.
* AM-3 -> runtime:GitHub PR snapshot.
```

Это не соответствует `docs/policy/project-contract.md`, где mapping references
должны использовать только:

- `validation:<label>`
- `artifact:<title>`
- `runtime:<label>`

Для `proof_type=runtime_smoke` canonical mapping должен идти через
`runtime:<label>`, обычно `runtime:runtime smoke`.

## 3. Root Cause

1. `plan-mode` authoring-инструкция задает правило, но не задает жесткий
   заполняемый шаблон для `Proof Mapping`.
2. `workflows/letterl/maxime/let.WORKFLOW.md` требует `Proof Mapping`, но
   не заставляет агента писать конкретный issue-description формат.
3. `symphony_spec_check` на spec-gate проверяет наличие `Acceptance Matrix`
   и explicit `required_before`, но не проверяет полноту и canonical syntax
   `Proof Mapping` для issue description.
4. Существующий строгий parser proof mapping в `HandoffCheck` рассчитан на
   workpad checkbox-строки вида `- [x] ...`, тогда как issue description
   должен использовать hyphen bullets без чекбоксов.
5. Текущее имя `HandoffCheck.proof_contract_errors/1` относится к
   execution/handoff proof validation: checked `### Proof Mapping`, checked
   `### Validation`, checked `### Artifacts` и attachment requirements. Его
   нельзя напрямую переиспользовать как description-only gate без смешения
   spec-prep syntax validation и execution evidence validation.

## 4. Non-Goals

- Не менять Linear issue вручную как способ исправления проблемы.
- Не добавлять новый скрипт, новый policy-файл, новую runtime-сущность или
  отдельный внешний валидатор.
- Не менять execution/handoff семантику за пределами plan authoring и
  существующего spec-gate.
- Не разрешать markdown-checklist в issue description.
- Не переносить рабочий журнал, `Execution Evidence` или `Checkpoint` в issue
  description.
- Не требовать на этапе `Spec Prep` checked workpad `Validation`, checked
  workpad `Artifacts` или Linear attachments как условие валидности issue
  description.

## 5. Целевое поведение

Для `mode:plan` Symphony должна сохранять первый persisted issue description
после pre-write self-correction как task-spec, в котором:

- есть `Acceptance Matrix` с колонкой `required_before`;
- есть `Proof Mapping` в hyphen plain-bullet формате (`- AM-n -> ...`), без
  чекбоксов; asterisk bullets (`* AM-n -> ...`) noncanonical;
- каждая строка `Proof Mapping` ссылается на существующий `Acceptance Matrix`
  item;
- каждый acceptance item имеет ровно один description mapping;
- prefix mapping строго один из `validation:`, `artifact:`, `runtime:`;
- `test:*` и `runtime_smoke:*` не используются как mapping prefixes;
- `proof_type=test` mapped только на `validation:<label>`;
- `proof_type=runtime_smoke` mapped только на `runtime:<label>`;
- `proof_type=artifact` mapped только на `artifact:<title>`;
- при `planning.swarm_assist_enabled=true` есть `plan_revision`,
  `artifact_path`, `artifact_revision`, и `artifact_revision == plan_revision`;
- `Остаточные риски` присутствуют в description;
- `## Symphony` остается последним H2-разделом.

Description mapping labels reserve expected future proof sources. Execution must
later provide checked workpad evidence with matching labels/titles where the
handoff contract requires it.

Legacy spec-prep входит в accepted scope только если implementation определяет
и тестирует точный existing predicate через существующий issue context
(например, label/state/workflow path) без расширения non-plan behavior. Если
такого predicate нет, authoring и enforcement ship only for `mode:plan`.

Terminology used below:

- `first persisted description correctness`: the first issue description that is
  actually written to Linear after any DynamicTool pre-write rejection and
  self-correction is canonical.
- `first private LLM draft`: any internal draft before an attempted
  `issueUpdate(description)` payload; it is not directly observable and is not
  the acceptance target.
- `attempted issueUpdate payload`: the description payload submitted to
  DynamicTool before persistence; if it is invalid, DynamicTool may block it and
  require correction before write.
- `description mapping`: issue-description `## Proof Mapping` commitment using
  hyphen bullets and `validation:`, `artifact:`, or `runtime:` references.
- `checked workpad mapping`: execution/handoff checkbox evidence in the workpad;
  it remains a separate surface.

## 6. Interface Invariants

These invariants are mandatory for the implementation slices below.

1. `HandoffCheck.proof_contract_errors/1` remains the execution/handoff proof
   validation surface. It continues to validate checked workpad `### Proof
   Mapping`, checked `### Validation`, checked `### Artifacts`, and Linear
   attachment requirements where applicable.
2. Add a separate description-only diagnostic helper/API in an existing module,
   preferably `HandoffCheck.issue_description_proof_mapping_errors/1`, or an
   explicitly mode-selected variant such as
   `HandoffCheck.proof_contract_errors(markdown, mode: :description_contract)`.
   Do not change the default meaning of `proof_contract_errors/1`.
3. The description-only diagnostic validates only issue-description contract
   shape: section presence, hyphen-bullet grammar, AM id coverage, duplicate AM
   ids, unknown AM ids, allowed prefixes, and `proof_type` to reference-prefix
   compatibility.
4. The description-only diagnostic must not require checked workpad validation
   items, checked workpad artifact items, or Linear attachments. Absence of
   execution evidence is expected during `Spec Prep`.
5. Parsed mappings should carry source information internally, for example
   `source: :issue_description` versus `source: :workpad`. Description mappings
   must not enter the workpad `checked_proof_mapping_items/1` path and must not
   satisfy handoff coverage.
6. During final handoff, description mappings and workpad mappings coexist as
   different surfaces. The issue description records the spec-prep commitment;
   the workpad records checked execution proof. A checked workpad mapping for
   the same AM id is not a duplicate of a description mapping.

## 7. Plan правок

Implementation is split into dependency-aware groups, not independent file-only
changes. Minimum shippable states are:

- `A+B guidance only`: authoring guidance is hardened, but LET-741 is not closed
  and no first persisted description correctness claim is made.
- `A+B+C+D spec-gate correctness`: bad `mode:plan` descriptions, plus legacy
  only if a precise predicate is implemented and tested, fail
  `symphony_spec_check` after write; this is not a first persisted description
  guarantee.
- `A+B+C+D+E full first persisted description correctness`: authoring guidance,
  post-write SpecCheck enforcement, and before-write DynamicTool blocking are
  all green.

`C` is the parser/interface foundation. `D` and `E` are dependent call-sites.
For the full first persisted description guarantee, `E` is mandatory and
non-optional because it is the only planned before-write guard for
`issueUpdate(description)`.

### Slice A: authoring template in `plan-mode`

Файл: `.agents/skills/plan-mode/SKILL.md`

Добавить в `Pre-write checklist` не только правило, но и обязательный шаблон
для `mode:plan` issue description:

```md
## Acceptance Matrix

| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
| --- | --- | --- | --- | --- | --- | --- |
| AM-1 | <scenario> | <expected outcome> | test | <command or named target> | run_executed | review |
| AM-2 | <scenario> | <expected outcome> | runtime_smoke | <runtime label> | runtime_smoke | review |

## Proof Mapping

- AM-1 -> validation:am-1
- AM-2 -> runtime:runtime smoke
```

Дополнить инструкцию:

- для `proof_type=test` использовать `validation:am-<n>` или другой
  конкретный validation label, который execution затем обязан отразить в
  workpad validation;
- для `proof_type=runtime_smoke` использовать `runtime:runtime smoke`;
- для `proof_type=artifact` использовать `artifact:<attachment title>`;
- не писать `test:<...>`, `runtime_smoke:<...>`, `GitHub PR snapshot` как
  mapping prefix;
- использовать hyphen bullets exactly as `- AM-n -> <prefix>:<label>`; `*`
  bullets are noncanonical even though they are markdown bullets;
- не использовать `- [x]` в description;
- не описывать `validation:am-1` как уже проверенное evidence; это label
  reservation для будущего checked workpad validation;
- legacy spec-prep guidance applies only when the workflow can precisely
  identify the issue as legacy spec-prep; otherwise keep authoring and
  enforcement limited to positively identified `mode:plan` issues first.

Slice-local green proof:

- `let_workflow_contract_test` asserts the skill text contains the exact
  copyable template with `## Acceptance Matrix`, `required_before`,
  `## Proof Mapping`, `- AM-1 -> validation:am-1`, and
  `- AM-2 -> runtime:runtime smoke`.
- The same test asserts the skill forbids `test:` and `runtime_smoke:` mapping
  prefixes and warns that description labels are future proof reservations, not
  checked evidence.

Rollback boundary: `.agents/skills/plan-mode/SKILL.md` plus the Slice A
contract-test assertion. If Slice A is kept without C/D/E, record the shipped
state as guidance only and do not close LET-741.

### Slice B: workflow prose alignment

Файл: `workflows/letterl/maxime/let.WORKFLOW.md`

В разделе spec-prep task-spec requirements добавить тот же canonical
description template и явно указать:

- `Proof Mapping` в issue description использует hyphen bullets only
  (`- AM-n -> ...`), not asterisk bullets or checkboxes;
- workpad checkbox mapping остается только для execution/handoff workpad;
- spec-prep handoff в `Spec Review` не считается готовым, если description
  содержит неканонический mapping prefix;
- issue-description mapping не заменяет checked workpad mapping на execution
  handoff;
- legacy spec-prep language is conditional on a precise legacy predicate; if no
  predicate exists, the workflow text must state that enforcement ships for
  `mode:plan` first.

Slice-local green proof:

- `let_workflow_contract_test` asserts the workflow text contains the exact
  canonical issue-description template, says hyphen bullets are for issue
  description, and says checkbox proof mapping belongs to execution workpad.
- The test must prove the generated instruction/output shape expected from the
  authoring contract, not merely that later validators block bad text. Prefer a
  prompt-rendering assertion if an existing rendering path exists; otherwise
  use doc-level exact-template assertions as the deterministic authoring
  contract.
- The test asserts the template and `## Proof Mapping` guidance appear before
  final `## Symphony` guidance so an authoring pass is not encouraged to append
  proof mapping after the final Symphony section.

Rollback boundary: workflow prose plus the Slice B contract-test assertion. If
B is kept without C/D/E, record the shipped state as guidance only and do not
claim first persisted description correctness.

### Slice C: description parser/support function

Файл: `elixir/lib/symphony_elixir/handoff_check.ex`

Расширить существующую proof-contract область без нового модуля, но не менять
семантику default execution validator:

- добавить отдельный description-only diagnostic helper, например
  `issue_description_proof_mapping_errors/1`;
- parser должен читать `## Proof Mapping` из issue description hyphen
  plain-bullets;
- поддержать строки вида `- AM-1 -> validation:am-1`;
- запретить checklist syntax `- [x]` в issue description;
- сохранить текущий checkbox parser для workpad без изменения поведения;
- не использовать workpad-only extraction rule, который требует backticked AM
  id, для description parser;
- нормализовать id и reference по отдельной description grammar, совместимой с
  hyphen plain-bullets.

Issue-description grammar:

```text
^-\s+`?([^`\s]+)`?\s*->\s*(validation|artifact|runtime):(.+)$
```

Backticks around AM ids in issue description are tolerated but not required.
Canonical authoring examples should omit backticks: `- AM-1 -> validation:am-1`.
The canonical bullet marker is hyphen (`-`) only; asterisk (`*`) rows are
malformed for this description contract unless a future implementation
explicitly changes both grammar and tests.
Diagnostics for description mappings must not say “missing matrix item id in
backticks” unless a future implementation explicitly makes backticks mandatory.
Workpad checkbox diagnostics may keep the existing backtick wording.

The description helper returns errors for:

- absent `## Proof Mapping` when a caller has positively identified the issue as
  `mode:plan`, or as legacy spec-prep through a precise implemented predicate,
  and the description has a non-empty `## Acceptance Matrix`;
- malformed hyphen plain-bullet row;
- unknown AM id;
- duplicate mapping for one AM id;
- missing mapping for an AM item;
- prefix outside `validation|artifact|runtime`;
- `proof_type=test` mapped to non-`validation`;
- `proof_type=runtime_smoke` mapped to non-`runtime`;
- `proof_type=artifact` mapped to non-`artifact`.

The description helper must not call checked workpad evidence lookup and must
not require checked validation/artifact rows or attachments.

Slice-local green proof:

- `handoff_check parses_plain_bullet_issue_description_proof_mapping` proves
  issue-description parser handles non-checkbox mapping.
- `handoff_check rejects_description_missing_proof_mapping_for_mode_plan` proves
  missing section is diagnosed by the description-only helper when the caller
  has positively identified the issue as `mode:plan`.
- `handoff_check rejects_duplicate_unknown_and_missing_description_mappings`
  covers duplicate AM id, unknown AM id, and missing AM mapping.
- `handoff_check rejects_invalid_description_proof_type_pairings` covers
  `test -> runtime`, `runtime_smoke -> validation`, and `artifact -> validation`.
- `handoff_check_keeps_description_mapping_separate_from_checked_workpad_mapping`
  proves description mappings neither duplicate nor satisfy checked handoff
  mappings.

Rollback boundary: parser/helper changes in `handoff_check.ex` plus Slice C
handoff tests. If C rolls back, D and E must roll back too unless a
feature-free compatibility function inside an existing module preserves
compile-time call-sites while intentionally providing no enforcement. This is
not a new runtime abstraction.

### Slice E: issueUpdate guard alignment

Файл: `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`

This slice is required for full first persisted description correctness. Do not
defer it while still claiming first persisted description correctness. If E is
deferred, the milestone must be explicitly renamed to post-write SpecCheck
enforcement only.

Do not reuse `HandoffCheck.proof_contract_errors/1` directly for description
proof-mapping enforcement. Align `issueUpdate(description)` with the new
mode-aware description diagnostic:

- fetch or inspect issue context before applying the new missing/malformed
  description `Proof Mapping` guard;
- apply the new description diagnostic only for `mode:plan` and any precisely
  defined legacy spec-prep predicate;
- keep any existing unconditional guard limited to behavior that was already
  generic, such as current acceptance-matrix parse protection, if that behavior
  exists today;
- block malformed `Proof Mapping` before write for issues positively identified
  as `mode:plan`, plus legacy only if a precise predicate is implemented and
  tested;
- block valid `Acceptance Matrix` without `Proof Mapping` before write only for
  issues positively identified as `mode:plan`, plus legacy only if a precise
  predicate is implemented and tested;
- allow valid hyphen-bullet mapping through;
- prove a non-plan description with an `Acceptance Matrix` but no description
  `Proof Mapping` is not newly blocked by this change.

Before-write blocking is a storage-correctness safety net, not proof that the
first private LLM draft was canonical. It may reject an invalid attempted
`issueUpdate(description)` payload, emit specific diagnostics to the planning
agent, and allow a corrected retry before any description is persisted. The full
LET-741 claim is satisfied only when the first persisted description is
canonical and there is no manual edit between persistence and SpecCheck.

Slice-local green proof:

- `dynamic_tool blocks_issue_update_description_with_noncanonical_mode_plan_proof_mapping`
  proves `issueUpdate(description)` fails before write through the actual
  DynamicTool guard path.
- `dynamic_tool blocks_issue_update_description_missing_mode_plan_proof_mapping`
  proves missing mapping is fail-closed before write for positively identified
  `mode:plan` issues.
- `dynamic_tool allows_issue_update_description_with_canonical_mode_plan_proof_mapping`
  proves canonical hyphen-bullet mapping passes the guard.
- `dynamic_tool allows_non_plan_acceptance_matrix_without_new_description_mapping_requirement`
  proves positive `mode:plan` identification does not over-block non-plan
  descriptions.
- DynamicTool diagnostics must include specific reason fragments for malformed
  prefix, missing mapping, duplicate AM id, unknown AM id, and
  proof_type/reference mismatch when those errors reach this guard.

Rollback boundary: `dynamic_tool.ex` plus Slice E DynamicTool tests, dependent
on C. If E rolls back while D remains, the shipped state is post-write gate only
and must not claim first persisted description correctness.

### Slice D: spec gate enforcement

Файл: `elixir/lib/symphony_elixir/spec_check.ex`

В `contract_requirement_findings/3` добавить использование description-only
proof mapping diagnostics for issue description:

- run the new description diagnostic only after existing issue context
  positively identifies the issue as `mode:plan`, plus legacy spec-prep only if
  a precise legacy predicate is explicitly implemented and tested;
- for `mode:plan`, missing or malformed `Proof Mapping` goes into
  `missing_items`;
- `symphony_spec_check` fails on LET-741-style mapping
  `AM-1 -> test:file list diff`;
- canonical `AM-1 -> validation:am-1` does not require checked workpad
  validation evidence at spec-gate time;
- non-plan behavior is not tightened beyond existing acceptance matrix
  diagnostics.

Legacy spec-prep predicate requirement: do not infer it from any issue with an
`Acceptance Matrix`. Either define a precise predicate using existing context
(labels/state/workflow path), or defer legacy enforcement and scope this slice to
`mode:plan` only.

Slice-local green proof:

- `spec_check rejects_mode_plan_description_with_test_prefix_proof_mapping`
  uses LET-741-style `Proof Mapping` with `test:file list diff`; expected:
  `passed=false`, diagnostic mentions canonical prefixes.
- `spec_check accepts_mode_plan_plain_bullet_canonical_proof_mapping` uses
  `AM-1 -> validation:am-1` and `AM-2 -> runtime:runtime smoke`; expected:
  `passed=true` without checked workpad validation evidence.
- `spec_check rejects_mode_plan_missing_duplicate_unknown_and_mismatched_mappings`
  is table-driven for missing mapping, duplicate AM id, unknown AM id, malformed
  prefix, and proof_type/reference mismatch.
- `spec_check leaves_non_plan_acceptance_matrix_behavior_unchanged` proves
  non-plan behavior is not newly tightened.
- SpecCheck diagnostics must be specific enough to repair: at least one asserted
  fragment distinguishes malformed prefix, missing mapping, duplicate AM id,
  unknown AM id, and proof_type/reference mismatch.

Rollback boundary: `spec_check.ex` plus Slice D SpecCheck tests, dependent on C.
If D rolls back while E remains, the system is before-write-only and must not
claim that existing bad descriptions are not accepted as passed.

### Slice F: cross-surface regression sweep

Файлы:

- `elixir/test/symphony_elixir/spec_check_test.exs`
- `elixir/test/symphony_elixir/handoff_check_test.exs`
- `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- `elixir/test/symphony_elixir/let_workflow_contract_test.exs`

Slice F must not be the first place slice ownership is tested. It is only the
final sweep after A-E have their local green proofs.

Cross-surface regressions:

1. Combined canonical mode-plan description passes DynamicTool guard and
   SpecCheck without checked workpad evidence.
2. Combined noncanonical mode-plan description is blocked before write by
   DynamicTool and also fails SpecCheck if evaluated as stored text.
3. Description mapping plus checked workpad mapping coexist without duplicate
   errors and without description mappings satisfying handoff evidence.
4. Skill and workflow authoring-contract tests prove the exact output shape that
   the authoring path is instructed to produce, not only validator blocking.

Rollback boundary: tests only. A failing Slice F signal must be attributed back
to A, B, C, D, or E before rolling back implementation code.

## 8. Validation Plan

Targeted slice gates:

- Slice A/B: `mix test test/symphony_elixir/let_workflow_contract_test.exs`
- Slice C: `mix test test/symphony_elixir/handoff_check_test.exs`
- Slice E: `mix test test/symphony_elixir/dynamic_tool_test.exs`
- Slice D: `mix test test/symphony_elixir/spec_check_test.exs`
- Slice F: rerun all four targeted test files together.

Broader confirmation after all slices:

- `make symphony-validate`

Live smoke after green local gates:

- create exactly one fresh minimal `mode:plan` Linear issue with a simple task,
  the required mode label/metadata, and no preexisting `Proof Mapping`;
- run local Symphony from the branch containing the fix until the first
  persisted description followed by a completed `Spec Prep -> Spec Review`
  transition, or until a bounded timeout;
- capture artifact 1: the first persisted issue description. Also capture any
  blocked attempted `issueUpdate(description)` payloads when DynamicTool exposes
  them, but blocked attempts are diagnostic evidence rather than the acceptance
  target;
- capture artifact 2: `symphony_spec_check` output for that issue;
- capture artifact 3: audit note or Linear history evidence that no manual
  description edit occurred between first write and SpecCheck;
- confirm the first persisted description contains canonical hyphen-bullet
  `Proof Mapping`, keeps `## Symphony` as the final H2 section, and was produced
  after any pre-write self-correction without manual editing;
- confirm `symphony_spec_check` reports `passed=true`;
- allow one bounded retry only for external Linear/auth/runtime availability
  failures before declaring the smoke inconclusive.

Failure attribution rules:

- if no issue update is attempted, attribute to authoring/run orchestration;
- if the first persisted description is missing or noncanonical, attribute to
  authoring contract, DynamicTool self-correction, or both depending on captured
  blocked payload evidence;
- if a canonical attempted payload is blocked, attribute to DynamicTool guard;
- if the first persisted description is written but SpecCheck fails, attribute
  to SpecCheck/helper interpretation;
- if Linear/auth/runtime fails before the planning path runs, mark the smoke
  inconclusive and rely on local deterministic tests.

The later execution-handoff independence check is not part of this live smoke.
It is covered by deterministic local handoff tests and may be run later as an
optional compatibility smoke if product-code execution is already in scope.

## 9. Rollback And Defer Rules

- Each slice gets at most two fix attempts per distinct failing signal.
- A slice is green only when its slice-local proof passes; do not wait until
  Slice F to discover basic ownership failures.
- If a slice is not green after two attempts, rollback that slice and record
  the exact failing signal.
- Do not carry partial parser, DynamicTool, or spec-gate changes into the next
  slice after rollback.
- Dependency rollback rules:
  - if C rolls back, D and E must roll back or compile against an explicit
    existing-module compatibility function with enforcement disabled and the
    milestone downgraded;
  - if D rolls back while E remains, the milestone is before-write-only and
    cannot claim stored bad descriptions fail SpecCheck;
  - if E rolls back while D remains, the milestone is post-write-only and
    cannot claim first persisted description correctness;
  - full LET-741 closure requires A+B+C+D+E plus slice-local tests and Slice F.
- If authoring template passes but enforcement slices fail, A+B may remain as
  guidance hardening, but the issue stays open and the shipped state is recorded
  as guidance only.
- If authoring template passes but spec-gate enforcement causes broad non-plan
  regressions, keep authoring changes and defer the enforcement change with a
  mode-scope failure report.
- If parser changes risk changing execution handoff behavior, keep
  `proof_contract_errors/1` unchanged and split issue-description hyphen bullets
  into the description-only diagnostic helper.
- If legacy spec-prep cannot be detected precisely without broadening
  enforcement to all non-plan descriptions, defer legacy authoring/enforcement
  and ship enforcement for positively identified `mode:plan` issues first.

## 10. Acceptance Criteria

- `[live smoke]` A new `mode:plan` issue generated by Symphony has a first
  persisted issue description with canonical hyphen-bullet `Proof Mapping`
  after any DynamicTool pre-write self-correction and before any manual edit.
- `[integration]` LET-741-style `AM-1 -> test:file list diff` fails
  `symphony_spec_check`.
- `[integration]` Valid hyphen-bullet `AM-1 -> validation:am-1` passes
  `symphony_spec_check` without checked workpad evidence at `Spec Prep`.
- `[unit]` `issueUpdate(description)` blocks malformed proof mapping before
  write for issues positively identified as `mode:plan`, plus legacy only if a
  precise legacy predicate is implemented and tested.
- `[unit]` `issueUpdate(description)` blocks missing proof mapping before write
  for issues positively identified as `mode:plan` with a non-empty
  `Acceptance Matrix`, plus legacy only if a precise legacy predicate is
  implemented and tested.
- `[unit]` `issueUpdate(description)` does not newly block non-plan descriptions
  merely because they contain an `Acceptance Matrix` without hyphen-bullet
  `Proof Mapping`.
- `[unit]` Workpad checkbox proof mapping behavior remains compatible with
  existing handoff tests.
- `[unit]` Description mappings and checked workpad mappings coexist without
  duplicate mapping errors and without description mappings satisfying handoff
  evidence.
- `[contract]` Authoring-contract tests prove the exact canonical
  template/instruction output shape, including `required_before`,
  `## Proof Mapping`, canonical hyphen bullets, forbidden prefixes, and
  placement before final `## Symphony` guidance.
- `[live smoke]` Live smoke is bounded to one fresh planning issue and captures
  first persisted description, any available blocked attempted payloads,
  SpecCheck output, and no-manual-edit evidence.
- `[review]` No new standalone modules, scripts, policy files, services,
  persisted runtime concepts, external validators, or runtime entities are
  introduced; in-module helpers/functions and tests are allowed.

## 11. Residual Risks

- The final generated text is still produced by an LLM, so the template must be
  concrete enough that the model copies the form instead of paraphrasing it.
- Tightening `symphony_spec_check` may expose existing legacy descriptions that
  relied on weaker proof mapping; keep enforcement limited to positively
  identified `mode:plan` issues first unless the legacy spec-prep predicate is
  precise and tested.
- Parser changes must not reinterpret execution workpad checkboxes as issue
  description bullets.
- If the existing handoff validator permits `runtime` references for non-runtime
  proof types, tightening that path may be a separate compatibility decision.
  The description-only path must still enforce deterministic pairings now.
- Live Linear smoke can fail for external reasons unrelated to this fix
  (auth, rate limits, unavailable local runtime); local deterministic tests
  remain the primary proof for the code change.
- If no prompt-rendering path exists, doc-level exact-template assertions are
  a weaker but deterministic authoring-contract proof; the live smoke remains
  the end-to-end confirmation of actual LLM output.

## 12. Repair Ledger R1

Target document: `docs/reports/let-741-plan-first-pass-correctness-remediation.md`.

Items fixed in order:

1. C1: split issue-description syntax/cardinality diagnostics from
   execution/handoff checked evidence validation; `proof_contract_errors/1`
   remains execution scoped.
2. C2: defined exact plain-bullet grammar, made AM id backticks optional in
   description, and kept workpad backtick/checklist expectations separate.
3. C3: made DynamicTool enforcement mode-aware before applying new missing or
   malformed description `Proof Mapping` blocking, preserving non-plan behavior.
4. C4: defined coexistence invariant: description mappings are spec commitments,
   workpad mappings are checked execution evidence, and they do not duplicate or
   satisfy each other.
5. C5: added explicit description-level proof type to reference-prefix pairings:
   `test -> validation`, `runtime_smoke -> runtime`, `artifact -> artifact`.
6. L1: required a precise legacy spec-prep predicate or deferral to `mode:plan`
   only.
7. L2: expanded regression coverage for missing mapping, duplicate mapping,
   unknown AM id, invalid pairings, canonical positive case, bad prefix,
   DynamicTool scoping, non-plan non-regression, and combined
   description/workpad compatibility.
8. L3: clarified that `validation:am-1` reserves a future workpad validation
   label and is not proof already present.
9. L4: renamed the DynamicTool regression around the actual guard path instead
   of `linear_graphql`.
10. Recommendation: prefer one new helper in an existing module over changing
    `proof_contract_errors/1` semantics.
11. Recommendation: use source-marked parsed mappings and keep description
    mappings out of checked workpad mapping collections.
12. Recommendation: add SpecCheck diagnostics only after existing context
    positively identifies `mode:plan` or a precise legacy predicate.
13. Recommendation: fetch issue context before the DynamicTool description
    mapping guard, or keep unconditional guards limited to existing generic
    parsing behavior.
14. Recommendation: keep policy untouched and limit implementation to existing
    skill/workflow docs, existing Elixir modules, and existing tests.

Items retired with justification:

- None. Every critical finding, lower-priority finding, and recommendation from
  the R1 repair source is represented in the target document.

Residual issues still open:

- The implementation still must decide whether to tighten existing workpad
  runtime-reference compatibility or limit strict pair validation to the new
  description-only diagnostic to avoid legacy handoff regressions.
- Legacy spec-prep enforcement remains conditional on defining a precise
  predicate; otherwise it should be deferred rather than broadening non-plan
  blocking.

## 13. Compact Ledger R2

Changed file paths:

- `docs/reports/let-741-plan-first-pass-correctness-remediation.md`

Items fixed in order:

1. C1: promoted DynamicTool Slice E from deferable alignment to a mandatory
   before-write enforcement slice for the full first persisted description
   guarantee; any E deferral now explicitly downgrades the milestone to
   post-write SpecCheck only.
2. C2: replaced file-only C/D/E rollback boundaries with dependency-safe groups:
   C is the foundation, D and E are dependent call-sites, and partial rollback
   states have downgraded guarantees.
3. C3: moved tests into slice-local green proofs for A, B, C, D, and E; Slice F
   is now only a cross-surface sweep and must attribute failures back to an
   owning slice.
4. C4: added authoring-contract tests that prove the exact canonical template
   and instruction output shape, including placement before final `## Symphony`,
   not only validator pass/fail behavior.
5. C5: tightened live smoke to one fresh minimal `mode:plan` issue, one local
   run, captured first persisted description plus available blocked payloads,
   captured SpecCheck output, no-manual-edit evidence, bounded external retry,
   and explicit failure attribution.
6. L1: clarified legacy spec-prep authoring and enforcement are conditional on a
   precise predicate; otherwise ship `mode:plan` first.
7. L2: added guidance-only partial shipment state for A+B and stated it cannot
   close LET-741 or claim first persisted description correctness.
8. L3: required D/E diagnostics-specific assertions for malformed prefix,
   missing mapping, duplicate AM id, unknown AM id, and proof_type/reference
   mismatch.
9. Recommendation: reordered implementation to A/B guidance, C helper, E
   before-write guard, D SpecCheck, then final sweep, while preserving the
   minimum shippable set distinctions.
10. Recommendation: split later execution-handoff independence from live smoke;
    it is covered by deterministic local handoff tests and optional later
    compatibility smoke.

Retired items with justification:

- No R2 finding was retired as out of scope. All critical findings,
  lower-priority findings, and recommendations were incorporated into the plan.

Residual issues still open:

- If no existing prompt-rendering path exists, authoring-contract tests remain
  doc-level exact-template assertions; the live smoke is still required for
  actual LLM-output confirmation.
- Legacy spec-prep support remains deferred unless implementation identifies a
  precise predicate without broadening non-plan enforcement.

## 14. Compact Ledger R3

Changed file paths:

- `docs/reports/let-741-plan-first-pass-correctness-remediation.md`

Items fixed in order:

1. C1: defined the guarantee as first persisted issue description correctness
   after DynamicTool pre-write self-correction, not correctness of the first
   private LLM draft.
2. C1: clarified that before-write blocking may reject invalid attempted
   `issueUpdate(description)` payloads, emit diagnostics, and allow corrected
   retry before persistence; it is a storage-correctness safety net.
3. C1/L2: rewrote live smoke and acceptance criteria around first persisted
   description evidence, with blocked attempted payloads captured only when
   available as diagnostic evidence.
4. C2: narrowed target behavior so `mode:plan` is mandatory; legacy spec-prep is
   included only if a precise existing predicate is implemented and tested
   without broadening non-plan behavior.
5. L1: clarified no-new-entities: in-module helpers/functions and tests are
   allowed; standalone modules, scripts, policy files, services, persisted
   runtime concepts, external validators, and new runtime entities are not.
6. L3: replaced ambiguous scoped acceptance language with positive
   identification by existing issue context for `mode:plan`, plus legacy only
   under a precise implemented predicate.
7. L4: defined canonical plain bullet as hyphen-only
   `- AM-n -> <prefix>:<label>` and marked asterisk bullets noncanonical.
8. L2: tagged final acceptance criteria by proof source: `[unit]`,
   `[contract]`, `[integration]`, `[live smoke]`, and `[review]`.

Retired items with justification:

- None retired as out of scope. Every R3 critical finding, lower-priority
  finding, and required repair was incorporated as document wording.

Residual issues still open:

- The plan still depends on implementation finding an existing
  prompt-rendering path; otherwise authoring-contract proof remains doc-level
  exact-template assertions plus live smoke.
- Legacy spec-prep support remains deferred unless implementation identifies
  and tests a precise predicate without broadening non-plan enforcement.
