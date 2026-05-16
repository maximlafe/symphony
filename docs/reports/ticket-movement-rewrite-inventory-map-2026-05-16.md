# Ticket Movement Rewrite Inventory and Boundary Map (2026-05-16)

## Scope
Concrete inventory for the ticket-movement runtime surfaces referenced by the rewrite plan.

## Lifecycle path inventory
- `Plan` entry contract and execution admission:
  - `symphony_spec_check` tool path in `DynamicTool` (`execute_symphony_spec_check/2`) validates issue description before execution transition.
  - Evidence: `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:655`.
- `Execute` runtime loop and retry/failover:
  - `Orchestrator` dispatches and tracks runs, applies retry budget transitions through `ExecutionContract`.
  - Evidence: `elixir/lib/symphony_elixir/orchestrator.ex:4140`, `:4163`; `elixir/lib/symphony_elixir/execution_contract.ex:217`, `:263`.
- `Review` gate and handoff:
  - `ControllerFinalizer.run/3` performs pre-handoff proof gate and then `symphony_handoff_check`.
  - Evidence: `elixir/lib/symphony_elixir/controller_finalizer.ex:53`, `:196`, `:265`.
  - `HandoffCheck.evaluate/2` enforces acceptance/validation contract and git proof freshness.
  - Evidence: `elixir/lib/symphony_elixir/handoff_check.ex:302`, `:561`.
- Terminal transitions (`Done` or `Blocked`):
  - Success path transitions via tracker state update; failure paths produce blocker comments + state transitions.
  - Evidence: `elixir/lib/symphony_elixir/orchestrator.ex:2029`, `:3967`, `:4049`.

## Guard path inventory
- Plan-side preflight guards:
  - `symphony_spec_check` contract lock + manifest guard before execution transition.
  - Evidence: `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:655`.
- Review-side guards:
  - `ControllerFinalizer` pre-handoff proof diagnostic + changed-path classification.
  - Evidence: `elixir/lib/symphony_elixir/controller_finalizer.ex:224`, `:744`.
  - `HandoffCheck` validation gate resolution + missing required proof checks.
  - Evidence: `elixir/lib/symphony_elixir/handoff_check.ex:2968`, `:2559`.
- Changed paths fallback guards:
  - Finalizer fallback fail-closed for explicit empty `changed_files` contexts.
  - Evidence: `elixir/lib/symphony_elixir/controller_finalizer.ex:744`.
  - Dynamic tool handoff context fallback fail-closed to `runtime_contract` when classification fails.
  - Evidence: `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:804`.

## Linear side-effect inventory
- Wrapper boundary:
  - `Tracker.create_comment/2`, `Tracker.update_issue_state/2`.
  - Evidence: `elixir/lib/symphony_elixir/tracker.ex:36`, `:41`.
- Linear adapter implementation:
  - `Linear.Adapter.create_comment/2`, `Linear.Adapter.update_issue_state/2`.
  - Evidence: `elixir/lib/symphony_elixir/linear/adapter.ex:54`, `:66`.
- Runtime call sites (ticket movement):
  - Orchestrator blocker/comment/state transitions route through `Tracker` wrapper.
  - Evidence: `elixir/lib/symphony_elixir/orchestrator.ex:3967`, `:4049`, `:6825`.

## Current state -> target state mapping
| Current runtime state/surface | Target canonical state | Owner boundary | Gate requirement |
| --- | --- | --- | --- |
| `Spec Review` + valid spec contract lock | `Plan -> Execute` | Plan boundary (`DynamicTool` spec check) | spec contract + transition guard |
| Active orchestrator run with admitted issue | `Execute` | Execution boundary (`Orchestrator` + `ExecutionContract`) | retry budget + failover policy |
| Finalizer pre-handoff pass | `Execute -> Review` | Review boundary (`ControllerFinalizer` pre-handoff + `HandoffCheck`) | required proof checks + handoff manifest |
| Handoff manifest pass + review-ready state allowed | `Review -> Done/In Review terminal handoff` | Review boundary | final gate proof freshness |
| Guard violation / retry budget exhausted / blocker decision | `Blocked` | Execution + review boundary handoff | classified blocker comment + state transition |

## Ownership map confirmation
- Plan boundary (concrete): `ValidationGate` + `ControllerFinalizer` pre-handoff path.
- Execution boundary (concrete): `ExecutionContract` + `Orchestrator` retry/failover machinery.
- Review boundary (concrete): `HandoffCheck` + `ControllerFinalizer` final handoff path.
- Linear side effects boundary (concrete): `Tracker` wrapper backed by `Linear.Adapter`.

## Notes
- This inventory is evidence-only and introduces no runtime behavior changes.
