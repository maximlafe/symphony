defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    trace_id = trace_id(issue, opts)
    issue_with_trace = attach_trace_id(issue, trace_id)

    with_issue_logger_metadata(issue_with_trace, trace_id, fn ->
      Logger.info("Starting agent run for #{issue_context(issue)}")

      case Workspace.create_for_issue(issue_with_trace) do
        {:ok, workspace} ->
          try do
            with :ok <- Workspace.run_before_run_hook(workspace, issue_with_trace, trace_id: trace_id),
                 :ok <- run_codex_turns(workspace, issue_with_trace, codex_update_recipient, opts) do
              :ok
            else
              {:error, reason} ->
                Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
                raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
            end
          after
            Workspace.run_after_run_hook(workspace, issue_with_trace, trace_id: trace_id)
          end

        {:error, reason} ->
          Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
      end
    end)
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

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    codex_account = Keyword.get(opts, :codex_account)
    trace_id = trace_id(issue, opts)

    session_opts =
      codex_launch_options(codex_account)
      |> Keyword.put(:issue, issue)
      |> maybe_put_trace_id_opt(trace_id)

    with {:ok, session} <- AppServer.start_session(workspace, session_opts) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue, trace_id(issue, opts)),
             trace_id: trace_id(issue, opts)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

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

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

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

  defp trace_id(issue, opts) when is_list(opts) do
    Keyword.get(opts, :trace_id) || Map.get(issue, :trace_id)
  end

  defp attach_trace_id(%Issue{} = issue, trace_id) when is_binary(trace_id) and trace_id != "" do
    Map.put(issue, :trace_id, trace_id)
  end

  defp attach_trace_id(issue, _trace_id), do: issue

  defp maybe_put_trace_id_opt(opts, trace_id) when is_binary(trace_id) and trace_id != "" do
    Keyword.put(opts, :trace_id, trace_id)
  end

  defp maybe_put_trace_id_opt(opts, _trace_id), do: opts

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
end
