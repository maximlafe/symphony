defmodule SymphonyElixir.ErrorClassifier do
  @moduledoc """
  Classifies agent/runtime failures into retry policy buckets.
  """

  @typedoc "Retry strategy class for a failed agent attempt."
  @type error_class :: :transient | :permanent | :semi_permanent

  @typedoc "Detailed runtime failure category used for account-aware handling."
  @type failure_class ::
          :approval_required
          | :auth_failure
          | :invalid_workspace
          | :process_error
          | :quota_exhausted
          | :semi_permanent_failure
          | :transient_worker_failure
          | :turn_input_required
          | :workspace_hook_failed

  @typedoc "How the runtime should react after a classified worker failure."
  @type retry_action :: :retry_same_account | :switch_account | :stop

  @typedoc "Runtime health override for the Codex account that produced the failure."
  @type account_state :: :ready | :cooldown | :broken

  defmodule FailureDetails do
    @moduledoc false

    @enforce_keys [:error_class, :failure_class, :retry_action, :account_state, :summary]
    defstruct [:error_class, :failure_class, :retry_action, :account_state, :summary]

    @type t :: %__MODULE__{
            error_class: SymphonyElixir.ErrorClassifier.error_class(),
            failure_class: SymphonyElixir.ErrorClassifier.failure_class(),
            retry_action: SymphonyElixir.ErrorClassifier.retry_action(),
            account_state: SymphonyElixir.ErrorClassifier.account_state(),
            summary: String.t()
          }
  end

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
    "is required for repo bootstrap",
    "no rule to make target 'symphony-bootstrap'",
    "repo bootstrap",
    "acceptance capability preflight failed",
    "acceptance_matrix_parse_error",
    "missing required auth",
    "missing required permissions",
    "missing required tools"
  ]

  @quota_patterns [
    "quota exhausted",
    "quota exceeded",
    "resource_exhausted",
    "resource exhausted",
    "requests per day limit reached",
    "usage limit"
  ]

  @auth_patterns [
    "not logged in",
    "login required",
    "unauthorized",
    "authentication failed",
    "authentication required",
    "invalid api key",
    "token expired",
    "token has expired"
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

  @failure_class_lookup %{
    "approval_required" => :approval_required,
    "auth_failure" => :auth_failure,
    "invalid_workspace" => :invalid_workspace,
    "process_error" => :process_error,
    "quota_exhausted" => :quota_exhausted,
    "semi_permanent_failure" => :semi_permanent_failure,
    "transient_worker_failure" => :transient_worker_failure,
    "turn_input_required" => :turn_input_required,
    "workspace_hook_failed" => :workspace_hook_failed
  }
  @failure_class_values Map.values(@failure_class_lookup)

  @retry_action_lookup %{
    "retry_same_account" => :retry_same_account,
    "switch_account" => :switch_account,
    "stop" => :stop
  }
  @retry_action_values Map.values(@retry_action_lookup)

  @account_state_lookup %{
    "ready" => :ready,
    "cooldown" => :cooldown,
    "broken" => :broken
  }
  @account_state_values Map.values(@account_state_lookup)

  @spec classify(term()) :: error_class()
  def classify(reason), do: reason |> classify_details() |> Map.fetch!(:error_class)

  @spec classify_details(term()) :: FailureDetails.t()
  def classify_details({:agent_run_failed, nested_reason}), do: classify_details(nested_reason)

  def classify_details({:turn_input_required, payload}) do
    failure_details(:permanent, :turn_input_required, :stop, :ready, summarize_reason(payload))
  end

  def classify_details({:approval_required, payload}) do
    failure_details(:permanent, :approval_required, :stop, :ready, summarize_reason(payload))
  end

  def classify_details({:invalid_workspace_cwd, _reason, _path}) do
    failure_details(:permanent, :invalid_workspace, :stop, :ready, "invalid workspace cwd")
  end

  def classify_details({:invalid_workspace_cwd, _reason, _path, _root}) do
    failure_details(:permanent, :invalid_workspace, :stop, :ready, "invalid workspace cwd")
  end

  def classify_details({:workspace_equals_root, _workspace, _root}) do
    failure_details(:permanent, :invalid_workspace, :stop, :ready, "workspace equals root")
  end

  def classify_details({:workspace_symlink_escape, _workspace, _root}) do
    failure_details(:permanent, :invalid_workspace, :stop, :ready, "workspace symlink escape")
  end

  def classify_details({:workspace_outside_root, _workspace, _root}) do
    failure_details(:permanent, :invalid_workspace, :stop, :ready, "workspace outside root")
  end

  def classify_details({:workspace_path_unreadable, _path, _reason}) do
    failure_details(:permanent, :invalid_workspace, :stop, :ready, "workspace path unreadable")
  end

  def classify_details({:workspace_capability_rejected, details}) when is_map(details) do
    failure_details(:permanent, :process_error, :stop, :ready, summarize_workspace_capability(details))
  end

  def classify_details({:acceptance_capability_preflight_failed, report}) when is_map(report) do
    failure_details(
      :permanent,
      :process_error,
      :stop,
      :ready,
      SymphonyElixir.AcceptanceCapability.summarize_failure(report)
    )
  end

  def classify_details({:workspace_hook_failed, _hook_name, _status, output}) when is_binary(output) do
    classify_workspace_hook_output(output)
  end

  def classify_details({:workspace_hook_timeout, _hook_name, _timeout_ms}) do
    failure_details(:transient, :transient_worker_failure, :retry_same_account, :ready, "workspace hook timed out")
  end

  def classify_details({:issue_state_refresh_failed, _reason}) do
    failure_details(:transient, :transient_worker_failure, :retry_same_account, :ready, "issue state refresh failed")
  end

  def classify_details({:turn_timeout}) do
    failure_details(:transient, :transient_worker_failure, :retry_same_account, :ready, "turn timed out")
  end

  def classify_details({:turn_timeout, payload}) do
    failure_details(:transient, :transient_worker_failure, :retry_same_account, :ready, summarize_reason(payload))
  end

  def classify_details({:turn_cancelled, payload}) do
    failure_details(:transient, :transient_worker_failure, :retry_same_account, :ready, summarize_reason(payload))
  end

  def classify_details({:turn_failed, payload}) do
    payload
    |> classify_turn_failed_payload()
    |> fallback_failure_class(:transient_worker_failure)
  end

  def classify_details({:response_timeout}) do
    failure_details(:transient, :transient_worker_failure, :retry_same_account, :ready, "response timed out")
  end

  def classify_details({:port_exit, status}) do
    failure_details(
      :transient,
      :transient_worker_failure,
      :retry_same_account,
      :ready,
      summarize_reason({:port_exit, status})
    )
  end

  def classify_details({reason, _stacktrace}) when is_map(reason) do
    classify_details(reason)
  end

  def classify_details(%{reason: nested_reason} = reason) when not is_nil(nested_reason) do
    nested_reason
    |> classify_details()
    |> maybe_override_error_class(Map.get(reason, :error_class) || Map.get(reason, "error_class"))
  end

  def classify_details(%{error_class: error_class} = reason)
      when error_class in [:transient, :permanent, :semi_permanent] do
    reason
    |> summarize_reason()
    |> failure_details(
      error_class,
      fallback_failure_class_for(error_class),
      retry_action_for(error_class),
      account_state_for(error_class)
    )
  end

  def classify_details(reason) do
    reason
    |> classify_text_failure(summarize_reason(reason))
    |> fallback_failure_class(:transient_worker_failure)
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

  @spec failure_class_to_string(failure_class() | nil) :: String.t()
  def failure_class_to_string(:approval_required), do: "approval_required"
  def failure_class_to_string(:auth_failure), do: "auth_failure"
  def failure_class_to_string(:invalid_workspace), do: "invalid_workspace"
  def failure_class_to_string(:process_error), do: "process_error"
  def failure_class_to_string(:quota_exhausted), do: "quota_exhausted"
  def failure_class_to_string(:semi_permanent_failure), do: "semi_permanent_failure"
  def failure_class_to_string(:transient_worker_failure), do: "transient_worker_failure"
  def failure_class_to_string(:turn_input_required), do: "turn_input_required"
  def failure_class_to_string(:workspace_hook_failed), do: "workspace_hook_failed"
  def failure_class_to_string(_), do: "transient_worker_failure"

  @spec summarize_reason(term(), integer()) :: String.t()
  def summarize_reason(reason, max_chars \\ 280) when is_integer(max_chars) and max_chars > 0 do
    reason
    |> inspect(pretty: false, printable_limit: max_chars * 2, limit: 50)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(max_chars)
  end

  defp classify_workspace_hook_output(output) when is_binary(output) do
    output
    |> classify_text_failure(summarize_reason(output))
    |> then(fn failure ->
      failure_details(failure.error_class, :workspace_hook_failed, :stop, :ready, failure.summary)
    end)
  end

  defp classify_turn_failed_payload(payload) do
    case structured_failure_details(payload) do
      %FailureDetails{} = failure ->
        failure

      nil ->
        summary_source = turn_failed_summary_source(payload)

        payload
        |> turn_failed_text_source()
        |> classify_text_failure(summarize_reason(summary_source))
        |> demote_untrusted_account_failure()
    end
  end

  defp classify_text_failure(reason, summary) do
    text = normalize_reason_text(reason)

    cond do
      matches_any_pattern?(text, @auth_patterns) ->
        failure_details(:semi_permanent, :auth_failure, :switch_account, :broken, summary)

      matches_any_pattern?(text, @quota_patterns) ->
        failure_details(:semi_permanent, :quota_exhausted, :switch_account, :cooldown, summary)

      matches_any_pattern?(text, @permanent_patterns) ->
        failure_details(:permanent, :process_error, :stop, :ready, summary)

      matches_any_pattern?(text, @semi_permanent_patterns) ->
        failure_details(:semi_permanent, :semi_permanent_failure, :retry_same_account, :ready, summary)

      matches_any_pattern?(text, @transient_patterns) ->
        failure_details(:transient, :transient_worker_failure, :retry_same_account, :ready, summary)

      true ->
        failure_details(:transient, :transient_worker_failure, :retry_same_account, :ready, summary)
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

  defp fallback_failure_class(%FailureDetails{} = failure, _default_failure_class), do: failure

  defp structured_failure_details(payload) when is_map(payload) do
    with error_class when not is_nil(error_class) <-
           normalize_error_class(payload_field(payload, :error_class)),
         failure_class when not is_nil(failure_class) <-
           normalize_failure_class(payload_field(payload, :failure_class)),
         retry_action when not is_nil(retry_action) <-
           normalize_retry_action(payload_field(payload, :retry_action)),
         account_state when not is_nil(account_state) <-
           normalize_account_state(payload_field(payload, :account_state)) do
      summary = summarize_reason(payload_field(payload, :summary) || turn_failed_summary_source(payload))

      failure_details(error_class, failure_class, retry_action, account_state, summary)
    else
      _ -> nil
    end
  end

  defp structured_failure_details(_payload), do: nil

  # Quota exhaustion at the turn boundary is emitted by Codex itself; auth-looking text can still
  # come from downstream commands, so only auth failures are demoted without explicit metadata.
  defp demote_untrusted_account_failure(%FailureDetails{failure_class: :auth_failure} = failure) do
    failure_details(
      failure.error_class,
      fallback_failure_class_for(failure.error_class),
      retry_action_for(failure.error_class),
      account_state_for(failure.error_class),
      failure.summary
    )
  end

  defp demote_untrusted_account_failure(%FailureDetails{} = failure), do: failure

  defp maybe_override_error_class(%FailureDetails{} = details, error_class) do
    case normalize_error_class(error_class) do
      nil ->
        details

      normalized ->
        %{details | error_class: normalized}
    end
  end

  defp normalize_error_class(value) when value in [:transient, :permanent, :semi_permanent], do: value
  defp normalize_error_class("transient"), do: :transient
  defp normalize_error_class("permanent"), do: :permanent
  defp normalize_error_class("semi_permanent"), do: :semi_permanent
  defp normalize_error_class(_value), do: nil

  defp normalize_failure_class(value) when value in @failure_class_values, do: value
  defp normalize_failure_class(value) when is_binary(value), do: Map.get(@failure_class_lookup, value)
  defp normalize_failure_class(_value), do: nil

  defp normalize_retry_action(value) when value in @retry_action_values, do: value
  defp normalize_retry_action(value) when is_binary(value), do: Map.get(@retry_action_lookup, value)
  defp normalize_retry_action(_value), do: nil

  defp normalize_account_state(value) when value in @account_state_values, do: value
  defp normalize_account_state(value) when is_binary(value), do: Map.get(@account_state_lookup, value)
  defp normalize_account_state(_value), do: nil

  defp fallback_failure_class_for(:permanent), do: :process_error
  defp fallback_failure_class_for(:semi_permanent), do: :semi_permanent_failure
  defp fallback_failure_class_for(_error_class), do: :transient_worker_failure

  defp retry_action_for(:permanent), do: :stop
  defp retry_action_for(:semi_permanent), do: :retry_same_account
  defp retry_action_for(_error_class), do: :retry_same_account

  defp account_state_for(:permanent), do: :ready
  defp account_state_for(:semi_permanent), do: :ready
  defp account_state_for(_error_class), do: :ready

  defp payload_field(payload, key) when is_map(payload) and is_atom(key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_field(_payload, _key), do: nil

  defp turn_failed_text_source(payload) do
    cond do
      is_map(payload) and is_binary(get_in(payload, ["error", "message"])) ->
        get_in(payload, ["error", "message"])

      is_map(payload) and is_binary(get_in(payload, [:error, :message])) ->
        get_in(payload, [:error, :message])

      is_binary(payload_field(payload, :message)) ->
        payload_field(payload, :message)

      true ->
        payload
    end
  end

  defp turn_failed_summary_source(payload) do
    payload_field(payload, :summary) || turn_failed_text_source(payload)
  end

  defp summarize_workspace_capability(details) when is_map(details) do
    reason = capability_detail(details, :reason)
    command_class = capability_detail(details, :command_class)

    case {reason, capability_detail(details, :tool), capability_detail(details, :target)} do
      {:missing_tool, tool, _target} when is_binary(tool) ->
        "workspace capability rejected #{command_class}: missing required tool `#{tool}`"

      {:missing_make_target, _tool, target} when is_binary(target) ->
        "workspace capability rejected #{command_class}: missing required make target `#{target}`"

      _other ->
        summarize_reason(details)
    end
  end

  defp capability_detail(details, key) when is_map(details) and is_atom(key) do
    case Map.fetch(details, key) do
      {:ok, value} -> value
      :error -> Map.get(details, Atom.to_string(key))
    end
  end

  defp failure_details(summary, error_class, failure_class, retry_action, account_state)
       when is_binary(summary) do
    failure_details(error_class, failure_class, retry_action, account_state, summary)
  end

  defp failure_details(error_class, failure_class, retry_action, account_state, summary) do
    %FailureDetails{
      error_class: error_class,
      failure_class: failure_class,
      retry_action: retry_action,
      account_state: account_state,
      summary: summary
    }
  end

  defp truncate(text, max_chars) when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars - 3) <> "..."
    else
      text
    end
  end
end
