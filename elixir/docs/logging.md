# Logging Best Practices

This guide defines logging conventions for Symphony so Codex can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Make each issue run attempt correlatable via a stable `trace_id`.
- Capture enough execution context to identify root cause without reruns.
- Emit one structured JSON object per log line for machine parsing.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Codex execution lifecycle events, include:

- `session_id`: combined Codex thread/turn identifier.
- `trace_id`: stable identifier for the current issue run attempt across orchestrator, runner, app-server, hooks, and worker updates.

Structured runtime logs are emitted as JSON lines. Put correlation fields in logger metadata whenever possible so they become top-level JSON fields instead of only being embedded in message text.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields when they materially help local debugging.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it, and preserve `trace_id` across retry metadata.
- `Codex.AppServer`: log session start/completion/error with issue context, `session_id`, and `trace_id`.
- `Workspace`: log hook start/failure/timeout with issue context and `trace_id`, and export `SYMPHONY_TRACE_ID` into hook environments.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Codex session? Include `session_id`.
- Is this event part of an issue run attempt? Include `trace_id`.
- Is the failure reason present and concise?
- Is the log emitted as structured JSON without losing the key correlation fields?
