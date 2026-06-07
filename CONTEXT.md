# Symphony

Symphony is the product context for coordinating issue-driven coding-agent work from tracker intake through review handoff.

## Language

### Core Model

**Symphony Runtime**:
The current product: the production-oriented automation service that coordinates Linear issue intake, per-issue agent work, retries, recovery, handoff, and operator visibility.
_Avoid_: current product, Symphony-next, upstream Symphony, one-off worker script

**Issue**:
The unit of work that Symphony Runtime coordinates from tracker intake through execution, retry, review handoff, or terminal cleanup.
_Avoid_: Ticket, task, job

**Issue Run**:
The active lifecycle of Symphony Runtime processing one Issue, including execution, retries, recovery, and eventual handoff or release.
_Avoid_: Run attempt, live session, Codex turn, job

**Issue State**:
The tracker-visible state of an Issue that controls how Symphony Runtime routes, starts, pauses, hands off, merges, or cleans up the Issue.
_Avoid_: Run phase, status badge, lifecycle state, milestone

**Issue Dependency**:
A tracker relationship where one Issue must reach a terminal Issue State before another Issue is eligible to start.
_Avoid_: Blocker, blocked_by, dependency ticket, prerequisite task

### Execution

**Workflow Contract**:
The repository-owned contract that tells Symphony Runtime which Issues to run, how to prepare Workspaces, how agents should operate, and what Review Evidence is required for Handoff.
_Avoid_: Plan, spec, prompt, agent instructions, workflow file

**Target Repository**:
The repository whose Issues are processed by Symphony Runtime and whose Workflow Contract governs those Issue Runs.
_Avoid_: Repo copy, checkout, project, codebase

**Workspace**:
The Issue-scoped filesystem area where Symphony Runtime runs the agent and preserves execution state across attempts for the same Issue Run.
_Avoid_: Repo, sandbox, temp directory, checkout

**Workpad**:
The persistent execution record for an Issue Run, synchronized between the Workspace and the tracker, that captures plan, acceptance, validation, artifacts, and blockers.
_Avoid_: Issue description, comment log, scratchpad, task spec

**Issue Tracker**:
The external system that owns Issues, Issue States, tracker comments, and tracker-visible handoff records consumed or updated during an Issue Run.
_Avoid_: Linear, board, task list, project

**Coding Agent**:
The external execution agent that Symphony Runtime launches inside a Workspace to work on an Issue according to the Workflow Contract.
_Avoid_: Codex, worker, bot, model

**Coding Agent Account**:
An authenticated account that Symphony Runtime can use to launch new Coding Agent work, with health and rate-limit status affecting dispatch and failover.
_Avoid_: Account, user, Codex account, worker account

**Retry**:
Symphony Runtime's recovery path for continuing an Issue Run after a failed or interrupted attempt while preserving the Issue and Workspace continuity.
_Avoid_: Retry entry, backoff queue, restart, rerun

**Continuation**:
Symphony Runtime's normal path for starting another Coding Agent turn when an Issue remains active after a completed turn.
_Avoid_: Retry, rerun, restart, recovery

### Handoff and Evidence

**Handoff**:
A classified transfer of an Issue from Symphony Runtime to a human or external process, backed by the evidence needed to continue or decide.
_Avoid_: Done, completion, stop, final message

**Handoff Classification**:
The declared reason a Handoff needs human attention: human verification, human decision, or human action.
_Avoid_: Checkpoint type, review type, blocker type, pause reason

**Review Evidence**:
The fresh checks, artifacts, and execution metadata appropriate to the Handoff Classification that justify handing an Issue to a human or external process.
_Avoid_: Handoff manifest, gate output, proof blob, validation log

**Runtime Tool**:
A capability exposed by Symphony Runtime to the Coding Agent during an Issue Run for controlled tracker access, workspace command execution, evidence handling, or Handoff checks.
_Avoid_: Command, script, plugin, skill, helper

### Operations

**Operator Visibility**:
The runtime-facing visibility that helps humans monitor and debug Issue Runs, retries, Coding Agent Accounts, Workspaces, Review Evidence, and Handoffs.
_Avoid_: Dashboard, status page, logs, API response

**Failover**:
Symphony Runtime's decision to route new Coding Agent work to a different healthy Coding Agent Account when the current account cannot safely accept new starts.
_Avoid_: Retry, account switch, migration, restart

**Issue-Scoped Artifact**:
An external file or directory explicitly namespaced to an Issue so Symphony Runtime can treat it as eligible for per-Issue cleanup.
_Avoid_: Artifact, temp file, shared cache, workspace file
