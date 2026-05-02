defmodule SymphonyElixir.BlockerNextSteps do
  @moduledoc """
  Deterministic operator guidance for classified blocker and retry/failover comments.
  """

  alias SymphonyElixir.RetryFailoverDecision

  @fallback_lines [
    "Use the technical metadata above for manual triage, correct the failing contract outside the run, then move the issue back to `In Progress` for a fresh attempt.",
    "Do not delete the workspace, rewrite branch history, close PRs, or take destructive action unless the same metadata is independently verified."
  ]

  @spec render_blocker(map()) :: [String.t()]
  def render_blocker(context) when is_map(context) do
    context
    |> Map.get(:reason)
    |> blocker_lines(context)
  end

  def render_blocker(_context), do: @fallback_lines

  @spec render_decision(RetryFailoverDecision.t(), map()) :: [String.t()]
  def render_decision(%RetryFailoverDecision{} = decision, extra_fields) when is_map(extra_fields) do
    cond do
      verification_guard_decision?(decision, extra_fields) ->
        verification_guard_lines(decision.log_fields)

      decision.selected_rule == :stale_workspace_head ->
        [
          "Refresh the workspace from the current base branch and rerun the required validation on the refreshed HEAD.",
          "If the branch or routing metadata was stale, correct that workspace contract first, then move the issue back to `In Progress`."
        ]

      decision.selected_rule == :retry_dedupe_hit ->
        [
          "Inspect the repeated retry signature and resolve the underlying failure before resuming automation.",
          "After the repeated failure is fixed or explicitly accepted, move the issue back to `In Progress`; do not start another blind retry."
        ]

      decision.selected_rule == :continuation_attempt_limit_exceeded ->
        [
          "Review the continuation attempts and choose whether to keep pursuing the current implementation direction or revise the task contract.",
          "Record the decision, then move the issue back to `In Progress` for the selected path."
        ]

      decision.selected_rule == :unsafe_preemption_required ->
        [
          "Preserve the current run evidence and inspect the preemption signal before starting another worker.",
          "Resume only after the unsafe preemption condition is cleared and the issue is manually moved back to `In Progress`."
        ]

      decision.selected_rule == :account_unhealthy_no_checkpoint ->
        [
          "Restore a healthy Codex account or checkpoint-capable runtime before resuming this issue.",
          "After the account/runtime health is confirmed, move the issue back to `In Progress`."
        ]

      decision.selected_rule == :validation_env_mismatch ->
        [
          "Fix the validation environment or proof contract reported by the structured metadata above.",
          "Rerun the failed validation/preflight guard, then move the issue back to `In Progress`."
        ]

      true ->
        @fallback_lines
    end
  end

  def render_decision(_decision, _extra_fields), do: @fallback_lines

  defp blocker_lines({:workspace_capability_rejected, details}, _context) when is_map(details) do
    workspace_capability_lines(details)
  end

  defp blocker_lines({:acceptance_capability_preflight_failed, report}, _context) when is_map(report) do
    acceptance_capability_lines(report)
  end

  defp blocker_lines(_reason, %{failure_class: "invalid_workspace"}) do
    [
      "Fix the issue routing labels or workspace bootstrap contract so the workspace is created inside the intended git repository.",
      "Refresh the workspace state after the routing fix, rerun preflight, then move the issue back to `In Progress`."
    ]
  end

  defp blocker_lines(_reason, _context), do: @fallback_lines

  defp workspace_capability_lines(details) do
    details
    |> detail(:reason)
    |> workspace_capability_lines_for_reason(details)
  end

  defp workspace_capability_lines_for_reason(reason, details)
       when reason in [:missing_make_target, "missing_make_target"] do
    target = detail(details, :target) || "required target"
    command_class = detail(details, :command_class) || "unknown"

    [
      "Restore the repo/workspace capability contract: make target `#{target}` must exist for `#{command_class}` commands in the routed repository.",
      "If this workspace points at the wrong repo, fix the issue routing labels or workspace bootstrap state; then rerun `make #{target}` and move the issue back to `In Progress`."
    ]
  end

  defp workspace_capability_lines_for_reason(reason, details)
       when reason in [:missing_tool, "missing_tool"] do
    tool = detail(details, :tool) || "required tool"
    command_class = detail(details, :command_class) || "unknown"

    [
      "Install or expose tool `#{tool}` for `#{command_class}` commands in the workspace environment.",
      "Rerun `make symphony-preflight` after the bootstrap fix, then move the issue back to `In Progress`."
    ]
  end

  defp workspace_capability_lines_for_reason(reason, details)
       when reason in [:unsupported_approval_policy, "unsupported_approval_policy"] do
    supported = details |> detail(:supported_approval_policies) |> list_text()
    policy = detail(details, :approval_policy) || "unknown"

    [
      "Change the workspace approval policy from `#{policy}` to one of the supported values: #{supported}.",
      "Rerun preflight with the corrected policy, then move the issue back to `In Progress`."
    ]
  end

  defp workspace_capability_lines_for_reason(_reason, details) do
    if is_nil(detail(details, :repo_root)) do
      [
        "Fix the issue routing labels or workspace bootstrap contract so the workspace resolves to the intended git repository.",
        "Refresh the workspace state after routing is corrected, rerun preflight, then move the issue back to `In Progress`."
      ]
    else
      @fallback_lines
    end
  end

  defp acceptance_capability_lines(report) do
    required = report |> detail(:required_capabilities) |> list_text()
    missing = report |> detail(:missing) |> missing_text()

    [
      "Satisfy the required capabilities: #{required}; missing: #{missing}.",
      "Run `make symphony-acceptance-preflight` after the bootstrap/env/artifact fix, then move the issue back to `In Progress`."
    ]
  end

  defp verification_guard_decision?(%RetryFailoverDecision{} = decision, extra_fields) do
    decision.selected_rule == :validation_env_mismatch and
      (field(extra_fields, :failure_class) == "verification_guard_failed" or
         not is_nil(field(decision.log_fields, :validation_guard_name)) or
         not is_nil(field(decision.log_fields, :verification_missing_items)))
  end

  defp verification_guard_lines(log_fields) do
    guard = field(log_fields, :validation_guard_name) || "unknown"
    missing = log_fields |> field(:verification_missing_items) |> missing_items_text()

    [
      "Fix the handoff proof/artifact contract for guard `#{guard}`; missing or invalid items: #{missing}.",
      "Update the workpad/artifacts/proof mapping, rerun the verification guard, then move the issue back to `In Progress`."
    ]
  end

  defp detail(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp detail(_map, _key), do: nil

  defp field(map, key), do: detail(map, key)

  defp list_text(values) when is_list(values) and values != [] do
    Enum.map_join(values, ", ", &"`#{&1}`")
  end

  defp list_text(_values), do: "`none`"

  defp missing_text(values) when is_list(values) and values != [] do
    Enum.join(values, "; ")
  end

  defp missing_text(_values), do: "none"

  defp missing_items_text(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "`unknown`"
      items -> Enum.map_join(items, ", ", &"`#{&1}`")
    end
  end

  defp missing_items_text(value) when is_list(value), do: list_text(value)
  defp missing_items_text(_value), do: "`unknown`"
end
