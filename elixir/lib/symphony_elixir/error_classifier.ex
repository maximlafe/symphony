defmodule SymphonyElixir.ErrorClassifier do
  @moduledoc """
  Classifies agent/runtime failures into retry policy buckets.
  """

  @typedoc "Retry strategy class for a failed agent attempt."
  @type error_class :: :transient | :permanent | :semi_permanent

  @semi_permanent_retry_limit 3

  @permanent_patterns [
    "compileerror",
    "compilation failed",
    "compile failed",
    "approval required",
    "turn_input_required",
    "turn input required",
    "input required",
    "permission denied",
    "workflow_unavailable",
    "invalid workflow.md",
    "workflow_parse_error",
    "workflow_front_matter_not_a_map",
    "missing_workflow_file",
    "workspace_equals_root",
    "workspace_symlink_escape",
    "workspace_outside_root",
    "invalid_workspace_cwd",
    "gh_token is required",
    "is required for unattended",
    "github auth is unavailable",
    "failed to configure git credentials via gh auth setup-git",
    "missing required auth",
    "missing required permissions",
    "missing required tools"
  ]

  @semi_permanent_patterns [
    "test failed",
    "tests failed",
    "failing test",
    "mix test",
    "exunit",
    "git push",
    "push rejected",
    "non-fast-forward",
    "failed to push",
    "fetch first",
    "needs rebase",
    "requires rebase"
  ]

  @transient_patterns [
    "rate limit",
    "429",
    "timeout",
    "timed out",
    "connection reset",
    "connection refused",
    "econnreset",
    "econnrefused",
    "enotfound",
    "eai_again",
    "temporarily unavailable",
    "service unavailable",
    "retry poll failed",
    "linear api",
    "port_exit",
    "turn_failed",
    "turn_cancelled",
    "issue_state_refresh_failed"
  ]

  @spec classify(term()) :: error_class()
  def classify({:agent_run_failed, nested_reason}), do: classify(nested_reason)
  def classify({:turn_input_required, _payload}), do: :permanent
  def classify({:approval_required, _payload}), do: :permanent
  def classify({:invalid_workspace_cwd, _reason, _path}), do: :permanent
  def classify({:invalid_workspace_cwd, _reason, _path, _root}), do: :permanent
  def classify({:workspace_equals_root, _workspace, _root}), do: :permanent
  def classify({:workspace_symlink_escape, _workspace, _root}), do: :permanent
  def classify({:workspace_outside_root, _workspace, _root}), do: :permanent
  def classify({:workspace_path_unreadable, _path, _reason}), do: :permanent
  def classify({:workspace_hook_failed, _hook_name, _status, output}) when is_binary(output), do: output |> normalize_reason_text() |> classify_by_text()
  def classify({:workspace_hook_timeout, _hook_name, _timeout_ms}), do: :transient
  def classify({:issue_state_refresh_failed, _reason}), do: :transient
  def classify({:turn_timeout}), do: :transient
  def classify({:turn_timeout, _payload}), do: :transient
  def classify({:turn_cancelled, _payload}), do: :transient
  def classify({:turn_failed, _payload}), do: :transient
  def classify({:response_timeout}), do: :transient
  def classify({:port_exit, _status}), do: :transient

  def classify({reason, _stacktrace}) when is_map(reason) do
    classify(reason)
  end

  def classify(%{error_class: error_class})
      when error_class in [:transient, :permanent, :semi_permanent] do
    error_class
  end

  def classify(reason) do
    reason
    |> normalize_reason_text()
    |> classify_by_text()
  end

  @spec retry_allowed?(error_class(), integer()) :: boolean()
  def retry_allowed?(:transient, _attempt), do: true

  def retry_allowed?(:semi_permanent, attempt)
      when is_integer(attempt) and attempt <= @semi_permanent_retry_limit,
      do: true

  def retry_allowed?(:semi_permanent, _attempt), do: false
  def retry_allowed?(:permanent, _attempt), do: false

  @spec retry_limit() :: integer()
  def retry_limit, do: @semi_permanent_retry_limit

  @spec to_string(error_class() | nil) :: String.t()
  def to_string(:transient), do: "transient"
  def to_string(:permanent), do: "permanent"
  def to_string(:semi_permanent), do: "semi_permanent"
  def to_string(_), do: "transient"

  @spec summarize_reason(term(), integer()) :: String.t()
  def summarize_reason(reason, max_chars \\ 280) when is_integer(max_chars) and max_chars > 0 do
    reason
    |> inspect(pretty: false, printable_limit: max_chars * 2, limit: 50)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(max_chars)
  end

  defp classify_by_text(text) when is_binary(text) do
    cond do
      matches_any_pattern?(text, @permanent_patterns) ->
        :permanent

      matches_any_pattern?(text, @semi_permanent_patterns) ->
        :semi_permanent

      matches_any_pattern?(text, @transient_patterns) ->
        :transient

      true ->
        :transient
    end
  end

  defp normalize_reason_text(%{message: message}) when is_binary(message) do
    message
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_reason_text(reason) do
    reason
    |> inspect(pretty: false, printable_limit: 8_000, limit: 100)
    |> String.downcase()
  end

  defp matches_any_pattern?(text, patterns) do
    Enum.any?(patterns, &String.contains?(text, &1))
  end

  defp truncate(text, max_chars) when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars - 3) <> "..."
    else
      text
    end
  end
end
