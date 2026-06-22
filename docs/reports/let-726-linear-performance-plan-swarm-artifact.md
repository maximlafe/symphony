# LET-726 Linear Performance Plan Swarm Artifact

Supporting artifact only. The canonical short plan belongs in Linear; this document preserves planning context, decision deltas, risks, rollback notes, and evidence anchors for LET-726.

## Concrete Document Specification

Core problem: Symphony's Linear integration may spend avoidable time and API quota on repeated viewer lookup when `tracker.assignee = "me"`, unconditional execution issue hydration before every `AgentRunner` workspace/prompt setup, and insufficient per-operation GraphQL telemetry to prove which calls dominate orchestrator poll/run latency.

Scope:
- Plan cache/deduplication for Linear viewer lookup used by `"me"` assignee routing.
- Plan conditional/lazy execution issue hydration, or instrumentation sufficient to decide whether hydration should stay eager.
- Plan Linear GraphQL telemetry with operation name, latency, response size, and counts per orchestrator poll/run.
- Define validation evidence for behavior, performance, and rollback readiness.

Out of scope:
- Product code changes in this artifact.
- Changing Linear polling semantics, issue assignment rules, or canonical Linear issue content.
- Replacing the Linear GraphQL client or introducing a broad observability subsystem.
- Reworking prompt construction beyond preserving existing attachment/comment behavior.

Success criteria:
- A future implementation can reduce duplicate viewer lookups without changing routing parity.
- Hydration work is either skipped when not needed or measured clearly enough to justify keeping it eager.
- Every relevant Linear GraphQL request can be attributed to an operation and summarized per poll/run.
- Tests and runtime evidence can demonstrate unchanged issue selection plus measurable call-count/latency impact.

Uncertainties:
- The current runtime cost distribution between polling, viewer lookup, execution hydration, attachment download, and comment fetching is not measured in the inspected code.
- It is not yet proven which prompt/workspace paths require fully hydrated execution context for all runs.
- Telemetry schema shape should align with existing `TelemetrySchema` conventions before implementation.

Swarm configuration: engineering planning, high grounding need, moderate route branching. Expert lenses used: performance implementer, observability critic, workflow correctness critic, and operations rollback synthesizer.

## Evidence Anchors

- `elixir/lib/symphony_elixir/linear/client.ex`: `@viewer_query` defines `query SymphonyLinearViewer`; `resolve_viewer_assignee_filter/0` calls `graphql(@viewer_query, %{})` whenever routing resolves `"me"`.
- `elixir/lib/symphony_elixir/linear/client.ex`: `fetch_candidate_issues/0` and `fetch_issue_states_by_ids/1` both pass through `routing_assignee_filter/0`, so `"me"` can trigger viewer lookup on poll and state-refresh paths.
- `elixir/lib/symphony_elixir/linear/client.ex`: `graphql/3` centralizes Linear request execution and already accepts `:operation_name` in payload construction, making it the smallest hook point for telemetry.
- `elixir/lib/symphony_elixir/linear/client.ex`: `fetch_issue_for_execution/1` uses `@execution_issue_query`, fetching attachments and comments for execution context before decoding.
- `elixir/lib/symphony_elixir/agent_runner.ex`: `run/3` calls `hydrate_issue_for_execution/2` before `Workspace.create_for_issue/1`, acceptance preflight, lock writing, and `PromptBuilder.build_prompt/2`.
- Existing tests called out by the issue are relevant coverage anchors: `core_test.exs` hydration/prompt behavior, Linear client tests or client helper coverage, `orchestrator_status_test.exs`, and `telemetry_schema_test.exs`.

## Decision Deltas

1. Viewer lookup: prefer a process-local cached/deduplicated viewer identity for `tracker.assignee = "me"` over calling `SymphonyLinearViewer` each time `routing_assignee_filter/0` runs.

   Delta from current behavior: `resolve_viewer_assignee_filter/0` currently performs a GraphQL request directly. Planned behavior should reuse a cached viewer id for the same Linear API token/config context, with a bounded invalidation story.

2. Execution hydration: do not blindly remove hydration. First preserve behavior for prompts that depend on attachments/comments, then choose either conditional hydration or explicit instrumentation gates.

   Delta from current behavior: `AgentRunner.run/3` currently hydrates before workspace creation. Planned behavior may defer `fetch_issue_for_execution/1` until prompt/workflow context proves it needs execution-only fields, or keep eager hydration while emitting enough telemetry to identify cost and justify a later lazy change.

3. GraphQL telemetry: instrument at `Linear.Client.graphql/3` so all client-owned operations get consistent metrics.

   Delta from current behavior: Linear failures are logged, but the inspected client does not expose per-operation latency, response size, or per-poll/run aggregation. Planned behavior should emit operation-tagged events and allow orchestrator summaries to report counts and timings.

4. Validation: require both unit-level correctness and runtime measurement evidence.

   Delta from generic performance work: acceptance is not just "tests pass"; it needs before/after call counts and latency evidence for `SymphonyLinearViewer`, execution issue hydration, and aggregate Linear GraphQL activity per poll/run.

## Proposed Work Plan

### 1. Viewer Lookup Cache and Deduplication

Plan:
- Add a small cache boundary for Linear viewer identity used by `"me"` assignee filters.
- Key the cache by the effective Linear API token identity or another config-derived value that changes when credentials change; avoid sharing viewer identity across credentials.
- Deduplicate concurrent cache misses if the orchestrator can trigger overlapping poll/state-refresh paths.
- Keep failure behavior conservative: if viewer identity cannot be resolved, return the existing `:missing_linear_viewer_identity` or request error path.

Validation:
- Unit test that repeated `fetch_candidate_issues/0` or state refresh with `tracker.assignee = "me"` resolves viewer once within the cache window.
- Unit test cache invalidation when credentials/config changes.
- Unit test Linear API error path is not cached permanently unless an explicit short negative-cache policy is chosen.
- Runtime evidence: before/after count of `SymphonyLinearViewer` per orchestrator poll interval.

### 2. Conditional or Instrumented Execution Hydration

Plan:
- Inventory the fields supplied by candidate issue polling versus `fetch_issue_for_execution/1`.
- Preserve attachment/comment inclusion for workflows and prompts that reference execution-only context.
- Choose one implementation route:
  - Conditional hydration: hydrate only when prompt/workflow rendering or pre-run checks require execution-only fields.
  - Instrument-first route: keep eager hydration for behavior safety but emit telemetry around execution hydration query and attachment download time/size.
- Ensure any lazy path happens before the first prompt render that can observe attachments/comments.

Validation:
- Extend existing hydration tests in `core_test.exs` to prove prompts still include attachment/comment content when required.
- Add a no-hydration-required test proving the execution fetcher is not called for a minimal issue/workflow route if conditional hydration is implemented.
- Add failure-path coverage proving hydration errors still fail closed when required context is mandatory.
- Runtime evidence: execution issue hydration count, latency, and response/attachment byte sizes per run.

### 3. Linear GraphQL Telemetry

Plan:
- Emit telemetry from `Linear.Client.graphql/3` around request execution.
- Include at least: operation name, latency, response size in bytes, success/failure status, and a request count increment.
- Derive operation name from explicit `:operation_name` when supplied; otherwise parse or classify known query documents such as `SymphonyLinearPoll`, `SymphonyLinearTeamPoll`, `SymphonyLinearIssuesById`, `SymphonyLinearViewer`, and `SymphonyLinearExecutionIssue`.
- Aggregate or expose counts per orchestrator poll/run using existing orchestrator/status telemetry patterns rather than a separate reporting channel unless the existing schema cannot represent it.

Validation:
- Add telemetry schema tests for the new event fields and units.
- Add Linear client tests proving success and failure events contain operation, latency, response size, and status classification.
- Add orchestrator/status tests proving a poll/run snapshot can include GraphQL operation counts and latency summaries without leaking query bodies or secrets.

### 4. Measurement Evidence

Before implementation:
- Capture a baseline poll/run sample with `tracker.assignee = "me"`.
- Record counts for `SymphonyLinearViewer`, poll issue queries, issue state refresh queries, execution issue queries, and Linear mutation/comment queries if present.
- Record latency distribution or at minimum min/max/total latency by operation for one representative orchestrator cycle and one execution run.

After implementation:
- Repeat the same scenario and compare call counts and latency totals.
- Confirm `SymphonyLinearViewer` is not repeated within the intended cache/dedupe scope.
- Confirm execution hydration is skipped only in routes where required context is absent, or quantify hydration cost if the instrument-first route is selected.
- Attach or summarize measurement evidence in the Linear issue as the canonical short-plan proof.

## Risks and Rollback Notes

- Stale viewer identity risk: caching `"me"` across credential changes could route issues incorrectly. Mitigation: cache key must include credential/config identity and support explicit invalidation. Rollback: bypass cache and restore direct viewer lookup.
- Hidden prompt dependency risk: lazy hydration could omit attachments/comments from prompts. Mitigation: preserve eager hydration until dependency detection is tested, or make lazy hydration fail closed when required fields are referenced. Rollback: return to eager `hydrate_issue_for_execution/2`.
- Telemetry overhead risk: response-size measurement or aggregation could add cost on hot paths. Mitigation: use already-materialized response bodies and cheap byte-size calculations; avoid logging full query or body. Rollback: disable telemetry emission behind a config flag or reduce aggregation to counters.
- Cardinality risk: operation names or issue identifiers in telemetry could create high-cardinality metrics. Mitigation: operation names should be bounded query names; do not tag by issue id.
- Measurement ambiguity risk: runtime variance could obscure improvements. Mitigation: compare call counts first, latency second; record the same orchestrator scenario before and after.

## Residual Open Issues

- Decide cache lifetime and invalidation mechanism after checking existing process/supervision patterns.
- Decide whether conditional hydration can be derived safely from workflow/prompt requirements, or whether LET-726 should ship telemetry first and defer lazy hydration.
- Confirm the exact telemetry event names and aggregation location against the existing telemetry schema.
- Identify the canonical Linear comment format for the short plan and final measurement evidence.
