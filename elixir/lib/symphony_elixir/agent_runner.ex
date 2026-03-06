defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, Orchestrator, PromptBuilder, Tracker, Workspace}

  @lead_workspace_identifier "__lead__"

  defmodule RunSpec do
    @moduledoc false

    defstruct [
      :role,
      :workspace_subject,
      :issue,
      :context,
      :run_label,
      :codex_update_recipient,
      opts: []
    ]
  end

  @doc "The well-known workspace identifier used for lead-agent runs."
  def lead_workspace_identifier, do: @lead_workspace_identifier
  @lead_issue %{
    id: "__lead__",
    identifier: @lead_workspace_identifier,
    title: "Lead check-in"
  }

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    issue
    |> worker_run_spec(codex_update_recipient, opts)
    |> run_spec()
  end

  @doc """
  Executes a single lead-agent run in the dedicated lead workspace.
  """
  @spec run_lead(pid() | nil, keyword()) :: :ok | no_return()
  def run_lead(codex_update_recipient \\ nil, opts \\ []) do
    codex_update_recipient
    |> lead_run_spec(opts)
    |> run_spec()
  end

  defp worker_run_spec(issue, codex_update_recipient, opts) do
    %RunSpec{
      role: :worker,
      workspace_subject: issue,
      issue: issue,
      context: issue_context(issue),
      run_label: "Agent run",
      codex_update_recipient: codex_update_recipient,
      opts: opts
    }
  end

  defp lead_run_spec(codex_update_recipient, opts) do
    %RunSpec{
      role: :lead,
      workspace_subject: @lead_workspace_identifier,
      issue: @lead_issue,
      context: "workspace_identifier=#{@lead_workspace_identifier}",
      run_label: "Lead run",
      codex_update_recipient: codex_update_recipient,
      opts: opts
    }
  end

  defp run_spec(%RunSpec{context: context, role: role, run_label: run_label} = spec) do
    Logger.info("Starting #{role} run #{context}")

    with_workspace(spec.workspace_subject, run_label, context, fn workspace ->
      run_in_workspace(workspace, spec)
    end)
  end

  defp message_handler(%RunSpec{role: :worker, codex_update_recipient: recipient, issue: issue}) do
    fn message ->
      maybe_request_lead(message, issue)
      send_codex_update(recipient, issue, message)
    end
  end

  defp message_handler(%RunSpec{role: :lead, codex_update_recipient: recipient}) do
    fn message ->
      send_lead_update(recipient, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_lead_update(recipient, message) when is_pid(recipient) do
    send(recipient, {:codex_lead_update, message})
    :ok
  end

  defp send_lead_update(_recipient, _message), do: :ok

  defp maybe_request_lead(%{event: :lead_requested} = message, issue) do
    reason = normalize_reason(Map.get(message, :reason)) || "n/a"

    Logger.info("Worker requested lead check-in for #{issue_context(issue)} reason=#{inspect(reason)}")
    _ = Orchestrator.trigger_lead_check_in()
    :ok
  end

  defp maybe_request_lead(_message, _issue), do: :ok

  defp run_in_workspace(workspace, %RunSpec{role: :worker} = spec) do
    max_turns = Keyword.get(spec.opts, :max_turns, Config.agent_max_turns())

    issue_state_fetcher =
      Keyword.get(spec.opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace) do
      try do
        do_run_codex_turns(session, workspace, spec, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_in_workspace(workspace, %RunSpec{role: :lead, issue: issue} = spec) do
    run_single_turn(
      workspace,
      PromptBuilder.build_lead_prompt(spec.opts),
      issue,
      message_handler(spec),
      "lead run"
    )
  end

  defp do_run_codex_turns(
         app_session,
         workspace,
         %RunSpec{issue: issue} = spec,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(spec, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: message_handler(spec)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          next_spec = %{spec | issue: refreshed_issue}

          do_run_codex_turns(
            app_session,
            workspace,
            next_spec,
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

  defp build_turn_prompt(%RunSpec{role: :worker, issue: issue, opts: opts}, 1, _max_turns),
    do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(%RunSpec{role: :worker}, turn_number, max_turns) do
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

  defp with_workspace(issue_or_identifier, run_label, context, runner)
       when is_function(runner, 1) do
    case Workspace.create_for_issue(issue_or_identifier) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue_or_identifier),
               :ok <- runner.(workspace) do
            :ok
          else
            {:error, reason} ->
              raise_run_failure(run_label, context, reason)
          end
        after
          Workspace.run_after_run_hook(workspace, issue_or_identifier)
        end

      {:error, reason} ->
        raise_run_failure(run_label, context, reason)
    end
  end

  defp run_single_turn(workspace, prompt, issue, on_message, label) do
    with {:ok, session} <- AppServer.start_session(workspace) do
      try do
        with {:ok, turn_session} <-
               AppServer.run_turn(session, prompt, issue, on_message: on_message) do
          Logger.info("Completed #{label} workspace=#{workspace} session_id=#{turn_session[:session_id]}")
          :ok
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp raise_run_failure(run_label, context, reason) do
    Logger.error("#{run_label} failed for #{context}: #{inspect(reason)}")
    raise RuntimeError, "#{run_label} failed for #{context}: #{inspect(reason)}"
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_reason(_reason), do: nil

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
