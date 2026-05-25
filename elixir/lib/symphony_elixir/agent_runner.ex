defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  import Bitwise
  alias SymphonyElixir.AcceptanceCapability
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.ErrorClassifier
  alias SymphonyElixir.HandoffCheck
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Linear.Telemetry, as: LinearTelemetry
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workspace

  defmodule RunError do
    @moduledoc false
    defexception [:message, :issue_id, :issue_identifier, :error_class, :reason]
  end

  @empty_turn_threshold_ms 5_000
  @max_consecutive_empty_turns 3
  @empty_turn_backoff_base_ms 2_000
  @issue_state_refresh_min_interval_ms 12_000
  @type error_class :: ErrorClassifier.error_class()

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    trace_id = trace_id(issue, opts)
    LinearTelemetry.reset_current_process_summary()

    issue_with_trace =
      case hydrate_issue_for_execution(issue, Keyword.get(opts, :issue_for_execution_fetcher)) do
        {:ok, hydrated_issue} ->
          attach_trace_id(hydrated_issue, trace_id)

        {:error, reason} ->
          raise_run_error(issue, {:issue_execution_context_hydration_failed, reason})
      end

    maybe_send_linear_graphql_summary(
      codex_update_recipient,
      issue_with_trace,
      :execution_hydration,
      trace_id,
      LinearTelemetry.consume_current_process_summary()
    )

    pre_run_hook_window? = pre_run_hook_window_enabled?()

    with_issue_logger_metadata(issue_with_trace, trace_id, fn ->
      Logger.info("Starting agent run for #{issue_context(issue)}")

      maybe_send_pre_run_hook_phase_update(
        codex_update_recipient,
        issue_with_trace,
        :pre_run_hook_enter,
        trace_id,
        pre_run_hook_window?
      )

      case Workspace.create_for_issue(issue_with_trace) do
        {:ok, workspace} ->
          try do
            before_run_result =
              Workspace.run_before_run_hook(workspace, issue_with_trace, trace_id: trace_id)

            maybe_send_pre_run_hook_phase_update(
              codex_update_recipient,
              issue_with_trace,
              :pre_run_hook_exit,
              trace_id,
              pre_run_hook_window?
            )

            with :ok <- before_run_result,
                 :ok <- run_acceptance_capability_preflight(workspace, issue_with_trace),
                 :ok <- freeze_acceptance_contract_lock(workspace, issue_with_trace),
                 :ok <- run_codex_turns(workspace, issue_with_trace, codex_update_recipient, opts) do
              :ok
            else
              {:error, reason} ->
                raise_run_error(issue_with_trace, reason)
            end
          after
            maybe_send_pre_run_hook_phase_update(
              codex_update_recipient,
              issue_with_trace,
              :pre_run_hook_exit,
              trace_id,
              pre_run_hook_window?
            )

            Workspace.run_after_run_hook(workspace, issue_with_trace, trace_id: trace_id)
          end

        {:error, reason} ->
          maybe_send_pre_run_hook_phase_update(
            codex_update_recipient,
            issue_with_trace,
            :pre_run_hook_exit,
            trace_id,
            pre_run_hook_window?
          )

          raise_run_error(issue_with_trace, reason)
      end
    end)
  end

  defp run_acceptance_capability_preflight(workspace, issue) do
    case AcceptanceCapability.evaluate(workspace, issue) do
      {:ok, _report} ->
        :ok

      {:error, report} ->
        {:error, {:acceptance_capability_preflight_failed, report}}
    end
  end

  defp freeze_acceptance_contract_lock(workspace, issue) do
    case HandoffCheck.write_acceptance_contract_lock(workspace, issue) do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, {:acceptance_contract_lock_failed, reason}}
    end
  end

  defp codex_message_handler(recipient, issue, trace_id) do
    fn message ->
      send_codex_update(recipient, issue, message, trace_id)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message, trace_id)
       when is_binary(issue_id) and is_pid(recipient) do
    message =
      if is_binary(trace_id) do
        Map.put_new(message, :trace_id, trace_id)
      else
        message
      end

    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message, _trace_id), do: :ok

  defp maybe_send_pre_run_hook_phase_update(
         recipient,
         issue,
         phase,
         trace_id,
         true
       )
       when is_pid(recipient) do
    issue_id = issue_id(issue)
    timeout_ms = hook_timeout_ms()

    if is_binary(issue_id) and phase in [:pre_run_hook_enter, :pre_run_hook_exit] do
      payload = %{
        phase: phase,
        timestamp: DateTime.utc_now(),
        trace_id: trace_id,
        pre_run_hook_timeout_ms: timeout_ms
      }

      send(recipient, {:worker_phase_update, issue_id, payload})
    end

    :ok
  end

  defp maybe_send_pre_run_hook_phase_update(_recipient, _issue, _phase, _trace_id, _pre_run_hook_window?),
    do: :ok

  defp maybe_send_linear_graphql_summary(recipient, issue, phase, trace_id, %{request_count: count} = summary)
       when is_pid(recipient) and count > 0 do
    issue_id = issue_id(issue)

    if is_binary(issue_id) do
      send(recipient, {
        :codex_worker_update,
        issue_id,
        %{
          event: :linear_graphql_summary,
          timestamp: DateTime.utc_now(),
          trace_id: trace_id,
          linear_graphql_phase: phase,
          linear_graphql_summary: LinearTelemetry.summarize(summary)
        }
      })
    end

    :ok
  end

  defp maybe_send_linear_graphql_summary(_recipient, _issue, _phase, _trace_id, _summary), do: :ok

  defp pre_run_hook_window_enabled? do
    hooks = Config.settings!().hooks
    hook_command_present?(hooks.after_create) or hook_command_present?(hooks.before_run)
  end

  defp hook_command_present?(command) when is_binary(command), do: String.trim(command) != ""
  defp hook_command_present?(_command), do: false

  defp hook_timeout_ms do
    case Config.settings!().hooks.timeout_ms do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _ -> nil
    end
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    codex_account = Keyword.get(opts, :codex_account)
    monotonic_time_ms = Keyword.get(opts, :monotonic_time_ms, &default_monotonic_time_ms/0)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
    issue_state_refresh_interval_ms = issue_state_refresh_interval_ms(opts)
    trace_id = trace_id(issue, opts)
    execution_attempt_token = execution_attempt_token(opts)

    session_opts =
      codex_launch_options(codex_account)
      |> Keyword.put(:issue, issue)
      |> maybe_put_cost_profile_key_opt(Keyword.get(opts, :cost_profile_key))
      |> maybe_put_cost_stage_opt(Keyword.get(opts, :cost_stage))
      |> maybe_put_trace_id_opt(trace_id)
      |> maybe_put_execution_attempt_token_opt(execution_attempt_token)

    with {:ok, session} <- AppServer.start_session(workspace, session_opts) do
      session_context = %{
        app_session: session,
        workspace: workspace,
        codex_update_recipient: codex_update_recipient,
        opts: opts,
        issue_state_fetcher: issue_state_fetcher,
        issue_state_refresh_interval_ms: issue_state_refresh_interval_ms,
        last_issue_state_refresh_at_ms: nil,
        max_turns: max_turns,
        monotonic_time_ms: monotonic_time_ms,
        sleep_fn: sleep_fn,
        trace_id: trace_id,
        execution_attempt_token: execution_attempt_token
      }

      try do
        do_run_codex_turns(session_context, issue, 1, 0)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(session_context, issue, turn_number, consecutive_empty) do
    turn_start_ms = monotonic_time_ms(session_context)
    prompt = build_turn_prompt(issue, session_context.opts, turn_number, session_context.max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             session_context.app_session,
             prompt,
             issue,
             on_message:
               codex_message_handler(
                 session_context.codex_update_recipient,
                 issue,
                 session_context.trace_id
               ),
             trace_id: session_context.trace_id
           ) do
      continue_after_turn(
        session_context,
        issue,
        turn_session,
        turn_number,
        turn_start_ms,
        consecutive_empty
      )
    end
  end

  defp continue_after_turn(
         session_context,
         issue,
         turn_session,
         turn_number,
         turn_start_ms,
         consecutive_empty
       ) do
    turn_elapsed_ms = monotonic_time_ms(session_context) - turn_start_ms
    empty_turn? = turn_elapsed_ms < @empty_turn_threshold_ms

    Logger.info(
      "Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{session_context.workspace} turn=#{turn_number}/#{session_context.max_turns} elapsed_ms=#{turn_elapsed_ms}"
    )

    case continue_with_issue?(issue, session_context) do
      {:continue, refreshed_issue, updated_session_context} ->
        maybe_continue_turn(
          updated_session_context,
          refreshed_issue,
          turn_number,
          consecutive_empty,
          empty_turn?
        )

      {:done, _refreshed_issue, _updated_session_context} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_continue_turn(
         %{max_turns: max_turns},
         refreshed_issue,
         turn_number,
         _consecutive_empty,
         _empty_turn?
       )
       when turn_number >= max_turns do
    Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

    :ok
  end

  defp maybe_continue_turn(session_context, refreshed_issue, turn_number, consecutive_empty, empty_turn?) do
    next_consecutive_empty = next_consecutive_empty_turns(consecutive_empty, empty_turn?)

    if next_consecutive_empty >= @max_consecutive_empty_turns do
      Logger.warning(
        "Empty turn circuit breaker: #{next_consecutive_empty} consecutive empty turns (<#{@empty_turn_threshold_ms}ms) for #{issue_context(refreshed_issue)}; returning control to orchestrator"
      )

      :ok
    else
      maybe_backoff_empty_turn(
        refreshed_issue,
        turn_number,
        session_context.max_turns,
        empty_turn?,
        next_consecutive_empty,
        session_context.sleep_fn
      )

      Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{session_context.max_turns}")

      do_run_codex_turns(session_context, refreshed_issue, turn_number + 1, next_consecutive_empty)
    end
  end

  defp next_consecutive_empty_turns(consecutive_empty, true), do: consecutive_empty + 1
  defp next_consecutive_empty_turns(_consecutive_empty, false), do: 0

  defp maybe_backoff_empty_turn(_issue, _turn_number, _max_turns, false, _consecutive_empty, _sleep_fn), do: :ok

  defp maybe_backoff_empty_turn(issue, turn_number, max_turns, true, consecutive_empty, sleep_fn) do
    backoff_ms = @empty_turn_backoff_base_ms * (1 <<< min(consecutive_empty - 1, 4))

    Logger.info("Empty turn detected for #{issue_context(issue)} turn=#{turn_number}/#{max_turns}; backing off #{backoff_ms}ms")

    sleep_fn.(backoff_ms)
  end

  defp monotonic_time_ms(%{monotonic_time_ms: now_fun}) when is_function(now_fun, 0), do: now_fun.()
  defp monotonic_time_ms(_session_context), do: default_monotonic_time_ms()

  defp default_monotonic_time_ms, do: System.monotonic_time(:millisecond)

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, session_context) when is_binary(issue_id) do
    if issue_state_refresh_due?(session_context) do
      issue_state_fetcher = session_context.issue_state_fetcher
      refreshed_context = mark_issue_state_refresh_attempt(session_context)

      case issue_state_fetcher.([issue_id]) do
        {:ok, [%Issue{} = refreshed_issue | _]} ->
          continue_with_refreshed_issue(refreshed_issue, refreshed_context)

        {:ok, []} ->
          {:done, issue, refreshed_context}

        {:error, reason} ->
          {:error, {:issue_state_refresh_failed, reason}}
      end
    else
      Logger.debug("Skipping issue state refresh due to debounce window for #{issue_context(issue)}")
      {:continue, issue, session_context}
    end
  end

  defp continue_with_issue?(issue, session_context), do: {:done, issue, session_context}

  defp continue_with_refreshed_issue(%Issue{} = refreshed_issue, refreshed_context) do
    if active_issue_state?(refreshed_issue.state) do
      {:continue, refreshed_issue, refreshed_context}
    else
      {:done, refreshed_issue, refreshed_context}
    end
  end

  defp issue_state_refresh_due?(
         %{
           issue_state_refresh_interval_ms: interval_ms,
           last_issue_state_refresh_at_ms: last_refresh_at_ms
         } = session_context
       )
       when is_integer(interval_ms) and interval_ms > 0 and is_integer(last_refresh_at_ms) do
    monotonic_time_ms(session_context) - last_refresh_at_ms >= interval_ms
  end

  defp issue_state_refresh_due?(_session_context), do: true

  defp mark_issue_state_refresh_attempt(session_context) do
    Map.put(session_context, :last_issue_state_refresh_at_ms, monotonic_time_ms(session_context))
  end

  defp issue_state_refresh_interval_ms(opts) do
    case Keyword.get(opts, :issue_state_refresh_min_interval_ms, @issue_state_refresh_min_interval_ms) do
      interval_ms when is_integer(interval_ms) and interval_ms >= 0 -> interval_ms
      _ -> @issue_state_refresh_min_interval_ms
    end
  end

  defp hydrate_issue_for_execution(%Issue{} = issue, fetcher) when is_function(fetcher, 1) do
    if is_binary(issue_execution_lookup_key(issue)) do
      issue
      |> issue_execution_lookup_key()
      |> fetcher.()
      |> case do
        {:ok, %Issue{} = hydrated_issue} ->
          {:ok, merge_execution_issue_context(issue, hydrated_issue)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, issue}
    end
  end

  defp hydrate_issue_for_execution(issue, _fetcher), do: {:ok, issue}

  defp issue_execution_lookup_key(%Issue{id: issue_id}) when is_binary(issue_id) and issue_id != "", do: issue_id

  defp issue_execution_lookup_key(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "",
    do: identifier

  defp issue_execution_lookup_key(_issue), do: nil

  @execution_issue_overlay_fields [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :project_slug,
    :project_name,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :created_at,
    :updated_at
  ]

  defp merge_execution_issue_context(%Issue{} = issue, %Issue{} = hydrated_issue) do
    issue
    |> merge_execution_issue_scalar_fields(hydrated_issue)
    |> merge_execution_issue_labels(hydrated_issue.labels)
    |> Map.put(:attachments, hydrated_issue.attachments)
    |> Map.put(:comments, hydrated_issue.comments)
  end

  defp merge_execution_issue_scalar_fields(%Issue{} = issue, %Issue{} = hydrated_issue) do
    Enum.reduce(@execution_issue_overlay_fields, issue, fn field, acc ->
      case Map.get(hydrated_issue, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp merge_execution_issue_labels(%Issue{} = issue, []), do: issue
  defp merge_execution_issue_labels(%Issue{} = issue, labels) when is_list(labels), do: Map.put(issue, :labels, labels)

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp raise_run_error(issue, reason) do
    context = issue_context(issue)
    error_class = ErrorClassifier.classify(reason)
    message = "Agent run failed for #{context} error_class=#{error_class}: #{inspect(reason)}"

    Logger.error(message)

    raise RunError,
      message: message,
      issue_id: issue_id(issue),
      issue_identifier: issue_identifier(issue),
      error_class: error_class,
      reason: reason
  end

  defp issue_id(%Issue{id: issue_id}) when is_binary(issue_id), do: issue_id

  defp issue_id(issue) when is_map(issue) do
    case Map.get(issue, :id) do
      issue_id when is_binary(issue_id) -> issue_id
      _ -> nil
    end
  end

  defp issue_id(_issue), do: nil

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: nil

  defp trace_id(issue, opts) when is_list(opts) do
    Keyword.get(opts, :trace_id) || Map.get(issue, :trace_id)
  end

  defp execution_attempt_token(opts) when is_list(opts) do
    case Keyword.get(opts, :execution_attempt_token) do
      token when is_binary(token) ->
        case String.trim(token) do
          "" -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end
  end

  defp attach_trace_id(%Issue{} = issue, trace_id) when is_binary(trace_id) and trace_id != "" do
    Map.put(issue, :trace_id, trace_id)
  end

  defp attach_trace_id(issue, _trace_id), do: issue

  defp maybe_put_trace_id_opt(opts, trace_id) when is_binary(trace_id) and trace_id != "" do
    Keyword.put(opts, :trace_id, trace_id)
  end

  defp maybe_put_trace_id_opt(opts, _trace_id), do: opts

  defp maybe_put_execution_attempt_token_opt(opts, token) when is_binary(token) and token != "" do
    Keyword.put(opts, :execution_attempt_token, token)
  end

  defp maybe_put_execution_attempt_token_opt(opts, _token), do: opts

  defp with_issue_logger_metadata(issue, trace_id, fun) when is_function(fun, 0) do
    previous_metadata = Logger.metadata()

    metadata =
      []
      |> maybe_put_logger_metadata(:issue_id, Map.get(issue, :id))
      |> maybe_put_logger_metadata(:issue_identifier, Map.get(issue, :identifier))
      |> maybe_put_logger_metadata(:trace_id, trace_id)

    if metadata != [] do
      Logger.metadata(metadata)
    end

    try do
      fun.()
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  defp maybe_put_logger_metadata(metadata, _key, value) when value in [nil, ""], do: metadata
  defp maybe_put_logger_metadata(metadata, key, value), do: Keyword.put(metadata, key, value)

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp codex_launch_options(%{id: id, codex_home: codex_home})
       when is_binary(id) and is_binary(codex_home) do
    [
      account_id: id,
      command_env: [{"CODEX_HOME", codex_home}]
    ]
  end

  defp codex_launch_options(_codex_account), do: []

  defp maybe_put_cost_profile_key_opt(opts, profile_key) when is_binary(profile_key) and profile_key != "",
    do: Keyword.put(opts, :cost_profile_key, profile_key)

  defp maybe_put_cost_profile_key_opt(opts, _profile_key), do: opts

  defp maybe_put_cost_stage_opt(opts, cost_stage) when is_binary(cost_stage) and cost_stage != "",
    do: Keyword.put(opts, :cost_stage, cost_stage)

  defp maybe_put_cost_stage_opt(opts, _cost_stage), do: opts
end
