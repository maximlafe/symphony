# ADR Index

Architectural decisions for the Symphony product context.

- [0001: Keep delivery policy out of the runtime](./0001-keep-delivery-policy-out-of-runtime.md) — Symphony Runtime owns orchestration; delivery behavior belongs to the Workflow Contract and agent tooling.
- [0002: Target repository owns the workflow contract](./0002-target-repository-owns-workflow-contract.md) — Target Repository policy is versioned with the code it governs.
- [0003: Route classified handoffs to In Review](./0003-route-classified-handoffs-to-in-review.md) — Human verification, decision, and action handoffs share the review gate state.
- [0004: Failover does not migrate running sessions](./0004-failover-does-not-migrate-running-sessions.md) — Failover affects new starts, not active provider sessions.
- [0005: Require issue-scoped cleanup boundaries](./0005-require-issue-scoped-cleanup-boundaries.md) — Automatic cleanup is limited to exact Workspaces and Issue-Scoped Artifacts.
- [0006: Use the workpad as the execution record](./0006-use-workpad-as-execution-record.md) — Issue description is task input; Workpad is persistent execution state.
- [0007: Retry preserves workspace continuity](./0007-retry-preserves-workspace-continuity.md) — Retry continues the same Issue Run in the same Workspace.
- [0008: Use the issue tracker as terminal truth](./0008-use-issue-tracker-as-terminal-truth.md) — Terminal completion comes from tracker-visible Issue States.
- [0009: Run unattended until classified handoff](./0009-run-unattended-until-classified-handoff.md) — Human intervention enters through Handoff, not ad hoc mid-run prompts.
- [0010: Use lightweight evidence for decision and action handoffs](./0010-use-lightweight-evidence-for-decision-and-action-handoffs.md) — Decision and human-action Handoffs do not require PR-ready evidence.
