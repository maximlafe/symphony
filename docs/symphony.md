# Symphony Workflow Boundaries

Symphony core orchestration is responsible for launching, routing, and
supervising repository work. It selects the workflow, starts the appropriate
agent stage, observes state transitions, and enforces runtime handoff checks.

Follow-up Linear issue creation is not core orchestration behavior. It is
agent/workflow behavior triggered by the repository workflow contract when an
agent finds meaningful out-of-scope work. The agent performs those Linear writes
through available Linear tooling and must follow the workflow's state, team,
project, relation, and dependency semantics.

For the LET workflow, meaningful out-of-scope improvements, defects, or
follow-on work stay outside the active task scope. The agent creates a separate
Backlog follow-up issue when Linear writes are available, links the current issue
as `related`, and adds `blockedBy` only when the follow-up is blocked by the
current issue.

When Linear write tooling or auth is missing, the workflow requires
`make symphony-preflight` before declaring a blocker. If the capability remains
unavailable, the correct result is a classified workflow checkpoint, not a claim
that the core orchestrator created or will create the follow-up automatically.
