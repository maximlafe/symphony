defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, ErrorClassifier, RunPhase, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Codex.{AccountProbe, Accounts}
  alias SymphonyElixir.Linear.Issue

  @continuation_base_delay_ms 5_000
  @continuation_max_delay_ms 300_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :workspace_usage_bytes,
      :workspace_cleanup_ref,
      :workspace_usage_refresh_ref,
      :workspace_threshold_exceeded?,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_accounts: %{},
      preferred_codex_account_id: nil,
      active_codex_account_id: nil,
      codex_totals: nil,
      codex_rate_limits: nil,
      codex_dispatch_reason: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      codex_accounts: %{},
      preferred_codex_account_id: nil,
      active_codex_account_id: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil,
      codex_dispatch_reason: nil
    }

    state = run_workspace_housekeeping(state, :startup)
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = refresh_codex_accounts(state)
    state = maybe_dispatch(state)
    state = run_workspace_housekeeping(state, :poll)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        handle_background_task_down(state, ref, reason)

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)
        trace_id = running_entry_trace_id(running_entry)
        identifier = Map.get(running_entry, :identifier)
        log_metadata = issue_log_metadata(issue_id, identifier, session_id, trace_id)

        state =
          with_log_metadata(log_metadata, fn ->
            handle_agent_exit_reason(
              state,
              issue_id,
              running_entry,
              identifier,
              session_id,
              trace_id,
              reason
            )
          end)

        with_log_metadata(log_metadata, fn ->
          Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")
        end)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        updated_running_entry =
          maybe_publish_run_phase_transition(issue_id, running_entry, updated_running_entry)

        tracked_account_id = Map.get(updated_running_entry, :codex_account_id)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update, tracked_account_id)

        notify_dashboard()

        case maybe_failover_running_issue(
               state,
               issue_id,
               updated_running_entry,
               tracked_account_id
             ) do
          {:failover, state} ->
            {:noreply, state}

          {:keep_running, state} ->
            {:noreply, %{state | running: Map.put(state.running, issue_id, updated_running_entry)}}
        end
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(
        {ref, {:workspace_cleanup_completed, source, cleanup_result}},
        %{workspace_cleanup_ref: ref} = state
      )
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | workspace_cleanup_ref: nil}
    state = apply_workspace_cleanup_result(state, cleanup_result, source)
    {:noreply, state}
  end

  def handle_info({ref, {:workspace_cleanup_completed, _source, _cleanup_result}}, state)
      when is_reference(ref),
      do: {:noreply, state}

  def handle_info(
        {:workspace_usage_sample, refresh_ref, source, usage_result},
        %{workspace_usage_refresh_ref: refresh_ref} = state
      )
      when is_reference(refresh_ref) do
    state =
      state
      |> Map.put(:workspace_usage_refresh_ref, nil)
      |> apply_workspace_usage_result(usage_result, source)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:workspace_usage_sample, _refresh_ref, _source, _usage_result}, state),
    do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0,
         true <- active_codex_account_available?(state) do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_polling_scope} ->
        Logger.error("Linear polling scope missing in WORKFLOW.md (set tracker.project_slug or tracker.team_key)")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    running_entry = Map.get(state.running, issue.id)
    log_metadata = running_entry_log_metadata(issue.id, issue.identifier, running_entry)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        with_log_metadata(log_metadata, fn ->
          Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")
        end)

        terminate_running_issue(state, issue.id, false)

      !issue_routable_to_worker?(issue) ->
        with_log_metadata(log_metadata, fn ->
          Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")
        end)

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        with_log_metadata(log_metadata, fn ->
          Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")
        end)

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} = running_entry ->
        with_log_metadata(
          running_entry_log_metadata(issue_id, identifier, running_entry),
          fn ->
            Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")
          end
        )

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)
      trace_id = running_entry_trace_id(running_entry)

      with_log_metadata(issue_log_metadata(issue_id, identifier, session_id, trace_id), fn ->
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")
      end)

      next_attempt = next_failure_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        trace_id: trace_id,
        error: "stalled for #{elapsed_ms}ms without codex activity",
        error_class: ErrorClassifier.to_string(:transient)
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(
         %State{} = state,
         issue,
         attempt \\ nil,
         trace_id \\ nil,
         retry_delay_type \\ nil
       ) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, trace_id, retry_delay_type)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")

        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, trace_id, retry_delay_type) do
    case active_codex_account(state) do
      nil ->
        state

      codex_account ->
        dispatch_issue_with_account(
          state,
          issue,
          attempt,
          codex_account,
          dispatch_trace_id(issue, trace_id),
          retry_delay_type
        )
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_integer(attempt) and attempt > 0 and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    delay_ms = retry_delay(attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    trace_id = pick_retry_trace_id(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    error_class = pick_retry_error_class(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""
    error_class_suffix = if is_binary(error_class), do: " error_class=#{error_class}", else: ""

    with_log_metadata(issue_log_metadata(issue_id, identifier, nil, trace_id), fn ->
      Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{attempt})#{error_class_suffix}#{error_suffix}")
    end)

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            trace_id: trace_id,
            error: error,
            error_class: error_class,
            delay_type: metadata[:delay_type]
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
       when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          trace_id: Map.get(retry_entry, :trace_id),
          error: Map.get(retry_entry, :error),
          error_class: Map.get(retry_entry, :error_class),
          delay_type: Map.get(retry_entry, :delay_type)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    identifier = metadata[:identifier] || issue_id
    trace_id = metadata[:trace_id]

    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        with_log_metadata(issue_log_metadata(issue_id, identifier, nil, trace_id), fn ->
          Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{identifier}: #{inspect(reason)}")
        end)

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           next_failure_retry_attempt(attempt, metadata[:delay_type]),
           Map.merge(metadata, %{
             error: "retry poll failed: #{inspect(reason)}",
             error_class: ErrorClassifier.to_string(:transient),
             delay_type: nil
           })
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        with_log_metadata(
          issue_log_metadata(issue_id, issue.identifier, nil, metadata[:trace_id]),
          fn ->
            Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; releasing claim")
          end
        )

        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        with_log_metadata(
          issue_log_metadata(issue_id, issue.identifier, nil, metadata[:trace_id]),
          fn ->
            Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")
          end
        )

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, metadata) do
    with_log_metadata(
      issue_log_metadata(issue_id, metadata[:identifier] || issue_id, nil, metadata[:trace_id]),
      fn ->
        Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
      end
    )

    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier)
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  defp handle_agent_exit_reason(
         state,
         issue_id,
         running_entry,
         identifier,
         session_id,
         trace_id,
         :normal
       ) do
    continuation_attempt = next_continuation_attempt(running_entry)

    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check (attempt #{continuation_attempt})")

    state
    |> complete_issue(issue_id)
    |> schedule_issue_retry(issue_id, continuation_attempt, %{
      identifier: identifier,
      trace_id: trace_id,
      delay_type: :continuation
    })
  end

  defp handle_agent_exit_reason(
         state,
         issue_id,
         running_entry,
         identifier,
         session_id,
         trace_id,
         reason
       ) do
    failure_attempt =
      case next_failure_attempt_from_running(running_entry) do
        attempt when is_integer(attempt) and attempt > 0 -> attempt
        _ -> 1
      end

    failure = ErrorClassifier.classify_details(reason)
    error_class_label = ErrorClassifier.to_string(failure.error_class)
    failure_class_label = ErrorClassifier.failure_class_to_string(failure.failure_class)

    Logger.warning(
      "Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)} error_class=#{error_class_label} failure_class=#{failure_class_label} next_retry_attempt=#{failure_attempt}"
    )

    handle_worker_failure(
      state,
      Map.get(running_entry, :issue),
      reason,
      failure,
      failure_attempt,
      %{
        issue_id: issue_id,
        identifier: identifier,
        trace_id: trace_id,
        codex_account_id: Map.get(running_entry, :codex_account_id)
      }
    )
  end

  defp dispatch_issue_with_account(
         %State{} = state,
         %Issue{} = issue,
         attempt,
         codex_account,
         trace_id,
         retry_delay_type
       ) do
    recipient = self()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(
             issue,
             recipient,
             attempt: attempt,
             codex_account: codex_account,
             trace_id: trace_id
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        with_log_metadata(issue_log_metadata(issue.id, issue.identifier, nil, trace_id), fn ->
          Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} codex_account_id=#{codex_account.id}")
        end)

        started_at = DateTime.utc_now()

        running =
          Map.put(
            state.running,
            issue.id,
            RunPhase.initialize(
              %{
                pid: pid,
                ref: ref,
                identifier: issue.identifier,
                issue: issue,
                trace_id: trace_id,
                session_id: nil,
                codex_account_id: codex_account.id,
                last_codex_message: nil,
                last_codex_timestamp: nil,
                last_codex_event: nil,
                codex_app_server_pid: nil,
                codex_input_tokens: 0,
                codex_output_tokens: 0,
                codex_total_tokens: 0,
                codex_last_reported_input_tokens: 0,
                codex_last_reported_output_tokens: 0,
                codex_last_reported_total_tokens: 0,
                turn_count: 0,
                retry_attempt: normalize_retry_attempt(attempt),
                retry_delay_type: retry_delay_type,
                started_at: started_at
              },
              started_at
            )
          )

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        with_log_metadata(issue_log_metadata(issue.id, issue.identifier, nil, trace_id), fn ->
          Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        end)

        next_attempt = next_failure_retry_attempt(attempt, retry_delay_type)

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          trace_id: trace_id,
          error: "failed to spawn agent: #{inspect(reason)}",
          error_class: ErrorClassifier.to_string(:transient),
          delay_type: nil
        })
    end
  end

  defp maybe_failover_running_issue(
         %State{} = state,
         issue_id,
         updated_running_entry,
         tracked_account_id
       )
       when is_binary(issue_id) do
    account_health_after = codex_account_health(state, tracked_account_id)
    replacement_account_id = active_codex_account_id_or_nil(state)

    if failover_required?(
         tracked_account_id,
         updated_running_entry,
         account_health_after,
         replacement_account_id
       ) do
      {:failover,
       preempt_running_issue_for_failover(
         state,
         issue_id,
         updated_running_entry,
         tracked_account_id,
         replacement_account_id,
         account_health_after
       )}
    else
      {:keep_running, state}
    end
  end

  defp maybe_failover_running_issue(
         %State{} = state,
         _issue_id,
         _updated_running_entry,
         _tracked_account_id
       ) do
    {:keep_running, state}
  end

  defp failover_required?(tracked_account_id, running_entry, false, replacement_account_id)
       when is_map(running_entry) and is_binary(tracked_account_id) and is_binary(replacement_account_id) do
    Map.get(running_entry, :codex_account_id) == tracked_account_id and
      replacement_account_id != tracked_account_id
  end

  defp failover_required?(_tracked_account_id, _running_entry, _account_health_after, _replacement_account_id),
    do: false

  defp preempt_running_issue_for_failover(
         %State{} = state,
         issue_id,
         running_entry,
         from_account_id,
         to_account_id,
         account_health_after
       ) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    trace_id = Map.get(running_entry, :trace_id)
    session_id = running_entry_session_id(running_entry)
    attempt = next_failure_attempt_from_running(running_entry)
    health_reason = codex_account_health_reason(state, from_account_id) || "account became unhealthy"

    state =
      state
      |> record_session_completion_totals(running_entry)
      |> Map.put(:running, Map.delete(state.running, issue_id))
      |> Map.put(:retry_attempts, Map.delete(state.retry_attempts, issue_id))

    with_log_metadata(issue_log_metadata(issue_id, identifier, session_id, trace_id), fn ->
      Logger.warning(
        "Failing over issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} from codex_account_id=#{from_account_id} to codex_account_id=#{to_account_id} reason=#{health_reason} previous_health=#{inspect(account_health_after)} attempt=#{attempt}"
      )
    end)

    running_entry
    |> Map.get(:ref)
    |> cancel_running_monitor()

    running_entry
    |> Map.get(:pid)
    |> terminate_task()

    schedule_issue_retry(state, issue_id, attempt, %{
      identifier: identifier,
      trace_id: trace_id,
      error: "account failover: #{health_reason}",
      error_class: ErrorClassifier.to_string(:transient),
      delay_type: :failover
    })
  end

  defp run_workspace_housekeeping(%State{} = state, source) do
    state = maybe_schedule_workspace_usage_refresh(state, source)
    state = maybe_schedule_terminal_workspace_cleanup(state, source)
    state
  end

  defp maybe_schedule_workspace_usage_refresh(
         %State{workspace_usage_refresh_ref: refresh_ref} = state,
         _source
       )
       when is_reference(refresh_ref),
       do: state

  defp maybe_schedule_workspace_usage_refresh(%State{} = state, source) do
    refresh_ref = make_ref()
    orchestrator = self()

    Task.start(fn ->
      usage_result = Workspace.root_usage_bytes()
      send(orchestrator, {:workspace_usage_sample, refresh_ref, source, usage_result})
    end)

    %{state | workspace_usage_refresh_ref: refresh_ref}
  end

  defp maybe_schedule_terminal_workspace_cleanup(
         %State{workspace_cleanup_ref: cleanup_ref} = state,
         _source
       )
       when is_reference(cleanup_ref),
       do: state

  defp maybe_schedule_terminal_workspace_cleanup(%State{} = state, source) do
    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        {:workspace_cleanup_completed, source, run_terminal_workspace_cleanup(source)}
      end)

    %{state | workspace_cleanup_ref: task.ref}
  end

  defp run_terminal_workspace_cleanup(source) do
    keep_recent = workspace_cleanup_keep_recent()
    terminal_cleanup_states = terminal_cleanup_states()

    case Tracker.fetch_issues_by_states(terminal_cleanup_states) do
      {:ok, issues} ->
        {:ok, %{removed: removed}} =
          Workspace.cleanup_completed_issue_workspaces(issues, keep_recent: keep_recent)

        if removed != [] do
          Logger.info("Workspace retention cleanup source=#{source} removed=#{length(removed)} keep_recent=#{keep_recent}")
        end

        :ok

      {:error, reason} ->
        Logger.warning("Skipping terminal workspace cleanup source=#{source}; failed to fetch terminal issues: #{inspect(reason)}")

        :ok
    end
  end

  defp apply_workspace_cleanup_result(%State{} = state, :ok, _source), do: state

  defp apply_workspace_cleanup_result(%State{} = state, cleanup_result, source) do
    Logger.warning("Workspace retention cleanup returned unexpected result source=#{source}: #{inspect(cleanup_result)}")

    state
  end

  defp handle_background_task_down(%State{workspace_cleanup_ref: ref} = state, ref, reason)
       when is_reference(ref) do
    Logger.warning("Workspace retention cleanup crashed: #{inspect(reason)}")
    {:noreply, %{state | workspace_cleanup_ref: nil}}
  end

  defp handle_background_task_down(state, _ref, _reason), do: {:noreply, state}

  defp terminal_cleanup_states do
    states =
      Config.settings!().tracker.terminal_states
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if states == [] do
      ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    else
      states
    end
  end

  defp apply_workspace_usage_result(%State{} = state, usage_result, source) do
    warning_threshold_bytes = workspace_warning_threshold_bytes()

    case usage_result do
      {:ok, usage_bytes} when is_integer(usage_bytes) and usage_bytes >= 0 ->
        threshold_exceeded? = usage_exceeds_threshold?(usage_bytes, warning_threshold_bytes)

        maybe_log_workspace_threshold_transition(
          state.workspace_threshold_exceeded?,
          threshold_exceeded?,
          usage_bytes,
          warning_threshold_bytes,
          source
        )

        %{
          state
          | workspace_usage_bytes: usage_bytes,
            workspace_threshold_exceeded?: threshold_exceeded?
        }

      {:error, reason} ->
        Logger.warning("Failed to compute workspace disk usage source=#{source}: #{inspect(reason)}")

        state
    end
  end

  defp usage_exceeds_threshold?(usage_bytes, warning_threshold_bytes)
       when is_integer(usage_bytes) and is_integer(warning_threshold_bytes) and
              warning_threshold_bytes > 0 do
    usage_bytes > warning_threshold_bytes
  end

  defp usage_exceeds_threshold?(_usage_bytes, _warning_threshold_bytes), do: false

  defp maybe_log_workspace_threshold_transition(
         previous_exceeded?,
         true,
         usage_bytes,
         warning_threshold_bytes,
         source
       )
       when previous_exceeded? != true do
    Logger.warning("Workspace disk usage exceeded warning threshold source=#{source} usage_bytes=#{usage_bytes} threshold_bytes=#{warning_threshold_bytes}")
  end

  defp maybe_log_workspace_threshold_transition(
         true,
         false,
         usage_bytes,
         warning_threshold_bytes,
         source
       ) do
    Logger.info("Workspace disk usage back under threshold source=#{source} usage_bytes=#{usage_bytes} threshold_bytes=#{warning_threshold_bytes}")
  end

  defp maybe_log_workspace_threshold_transition(
         _previous_exceeded?,
         _current_exceeded?,
         _usage_bytes,
         _warning_threshold_bytes,
         _source
       ),
       do: :ok

  defp workspace_cleanup_keep_recent do
    case Config.settings!().workspace.cleanup_keep_recent do
      keep_recent when is_integer(keep_recent) and keep_recent >= 0 -> keep_recent
      _ -> 5
    end
  end

  defp workspace_warning_threshold_bytes do
    case Config.settings!().workspace.warning_threshold_bytes do
      threshold when is_integer(threshold) and threshold > 0 -> threshold
      _ -> 10 * 1024 * 1024 * 1024
    end
  end

  defp workspace_snapshot(%State{} = state) do
    keep_recent = workspace_cleanup_keep_recent()

    %{
      usage_bytes: max(0, state.workspace_usage_bytes || 0),
      warning_threshold_bytes: workspace_warning_threshold_bytes(),
      done_closed_keep_count: keep_recent,
      cleanup_keep_recent: keep_recent
    }
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    cond do
      not active_codex_account_available?(state) ->
        with_log_metadata(
          issue_log_metadata(issue.id, issue.identifier, nil, metadata[:trace_id]),
          fn ->
            Logger.debug("No healthy codex account for retrying #{issue_context(issue)}; keeping retry queued")
          end
        )

        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: "no healthy codex account available",
             error_class: metadata[:error_class] || ErrorClassifier.to_string(:transient),
             delay_type: nil
           })
         )}

      retry_candidate_issue?(issue, terminal_state_set()) and
          dispatch_slots_available?(issue, state) ->
        {:noreply, dispatch_issue(state, issue, attempt, metadata[:trace_id], metadata[:delay_type])}

      true ->
        with_log_metadata(
          issue_log_metadata(issue.id, issue.identifier, nil, metadata[:trace_id]),
          fn ->
            Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")
          end
        )

        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           next_failure_retry_attempt(attempt, metadata[:delay_type]),
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: "no available orchestrator slots",
             error_class: ErrorClassifier.to_string(:transient),
             delay_type: nil
           })
         )}
    end
  end

  defp handle_worker_failure(
         state,
         issue,
         reason,
         failure,
         failure_attempt,
         context
       ) do
    issue_id = context.issue_id
    identifier = context.identifier
    trace_id = context.trace_id
    codex_account_id = context.codex_account_id

    state = maybe_apply_account_runtime_failure(state, codex_account_id, failure, failure_attempt)
    error_class_label = ErrorClassifier.to_string(failure.error_class)
    failure_class_label = ErrorClassifier.failure_class_to_string(failure.failure_class)

    cond do
      failure.retry_action == :switch_account and not active_codex_account_available?(state) ->
        escalate_issue_for_manual_intervention(
          state,
          issue,
          reason,
          failure_attempt,
          Map.merge(context, %{
            error_class: error_class_label,
            failure_class: failure_class_label,
            retry_action: failure.retry_action
          })
        )

      failure.retry_action == :switch_account ->
        schedule_issue_retry(state, issue_id, failure_attempt, %{
          identifier: identifier,
          trace_id: trace_id,
          error: "agent exited: #{failure.summary}",
          error_class: error_class_label
        })

      ErrorClassifier.retry_allowed?(failure.error_class, failure_attempt) ->
        schedule_issue_retry(state, issue_id, failure_attempt, %{
          identifier: identifier,
          trace_id: trace_id,
          error: "agent exited: #{failure.summary}",
          error_class: error_class_label
        })

      true ->
        escalate_issue_for_manual_intervention(
          state,
          issue,
          reason,
          failure_attempt,
          Map.merge(context, %{
            error_class: error_class_label,
            failure_class: failure_class_label,
            retry_action: failure.retry_action
          })
        )
    end
  end

  defp maybe_apply_account_runtime_failure(
         %State{} = state,
         codex_account_id,
         %{retry_action: :switch_account, account_state: account_state} = failure,
         failure_attempt
       )
       when is_binary(codex_account_id) and account_state in [:cooldown, :broken] do
    cooldown_ms =
      if account_state == :cooldown do
        failure_retry_delay(max(failure_attempt, 1))
      end

    update_codex_account_runtime_state(
      state,
      codex_account_id,
      account_state,
      "#{ErrorClassifier.failure_class_to_string(failure.failure_class)}: #{failure.summary}",
      cooldown_ms
    )
  end

  defp maybe_apply_account_runtime_failure(state, _codex_account_id, _failure, _failure_attempt),
    do: state

  defp escalate_issue_for_manual_intervention(
         state,
         %Issue{id: tracker_issue_id},
         reason,
         failure_attempt,
         context
       )
       when is_binary(tracker_issue_id) do
    blocker_comment =
      blocker_comment_body(
        context.identifier,
        context.trace_id,
        reason,
        context.error_class,
        context.failure_class,
        failure_attempt,
        context.codex_account_id,
        context.retry_action
      )

    intervention_state = manual_intervention_state()

    with :ok <- Tracker.create_comment(tracker_issue_id, blocker_comment),
         :ok <- Tracker.update_issue_state(tracker_issue_id, intervention_state) do
      with_log_metadata(
        issue_log_metadata(context.issue_id, context.identifier, nil, context.trace_id),
        fn ->
          Logger.warning(
            "Escalated issue_id=#{context.issue_id} issue_identifier=#{context.identifier} to #{intervention_state} after #{context.error_class}/#{context.failure_class} failure (attempt #{failure_attempt})"
          )
        end
      )

      state
      |> complete_issue(context.issue_id)
      |> release_issue_claim(context.issue_id)
    else
      {:error, tracker_reason} ->
        with_log_metadata(
          issue_log_metadata(context.issue_id, context.identifier, nil, context.trace_id),
          fn ->
            Logger.error("Failed to escalate issue_id=#{context.issue_id} issue_identifier=#{context.identifier} to #{intervention_state}: #{inspect(tracker_reason)}")
          end
        )

        schedule_issue_retry(state, context.issue_id, failure_attempt, %{
          identifier: context.identifier,
          trace_id: context.trace_id,
          error: "failed to escalate #{context.identifier} to #{intervention_state}: #{inspect(tracker_reason)}",
          error_class: ErrorClassifier.to_string(:transient)
        })
    end
  end

  defp escalate_issue_for_manual_intervention(
         state,
         issue,
         _reason,
         failure_attempt,
         context
       ) do
    with_log_metadata(
      issue_log_metadata(context.issue_id, context.identifier, nil, context.trace_id),
      fn ->
        Logger.error("Failed to escalate issue_id=#{context.issue_id} issue_identifier=#{context.identifier} to #{manual_intervention_state()}: missing issue id in #{inspect(issue)}")
      end
    )

    schedule_issue_retry(state, context.issue_id, failure_attempt, %{
      identifier: context.identifier,
      trace_id: context.trace_id,
      error: "failed to escalate #{context.identifier} to #{manual_intervention_state()}: missing issue id",
      error_class: ErrorClassifier.to_string(:transient)
    })
  end

  defp blocker_comment_body(
         identifier,
         trace_id,
         reason,
         error_class,
         failure_class,
         failure_attempt,
         codex_account_id,
         retry_action
       ) do
    trace_id_line =
      if is_binary(trace_id) and trace_id != "" do
        "- trace_id: `#{trace_id}`\n"
      else
        ""
      end

    account_line =
      if is_binary(codex_account_id) and codex_account_id != "" do
        "- codex_account_id: `#{codex_account_id}`\n"
      else
        ""
      end

    retry_action_line =
      case retry_action do
        action when action in [:retry_same_account, :switch_account, :stop] ->
          "- retry_action: `#{action}`\n"

        _ ->
          ""
      end

    """
    ### Blocker (auto-classified)

    - error_class: `#{error_class}`
    - failure_class: `#{failure_class}`
    - failed_attempt: `#{failure_attempt}`
    - issue: `#{identifier}`
    #{trace_id_line}#{account_line}#{retry_action_line}- reason: `#{ErrorClassifier.summarize_reason(reason)}`
    """
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp manual_intervention_state do
    Config.settings!().tracker.manual_intervention_state
  end

  defp retry_delay(attempt, %{delay_type: :failover})
       when is_integer(attempt) and attempt > 0,
       do: 0

  defp retry_delay(attempt, %{delay_type: :continuation})
       when is_integer(attempt) and attempt > 0,
       do:
         min(
           @continuation_base_delay_ms * (1 <<< min(attempt - 1, 6)),
           @continuation_max_delay_ms
         )

  defp retry_delay(attempt, metadata)
       when is_integer(attempt) and attempt > 0 and is_map(metadata),
       do: failure_retry_delay(attempt)

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_continuation_attempt(%{retry_delay_type: :continuation, retry_attempt: attempt})
       when is_integer(attempt) and attempt > 0,
       do: attempt + 1

  defp next_continuation_attempt(_running_entry), do: 1

  defp next_failure_attempt_from_running(%{retry_delay_type: :continuation}), do: 1

  defp next_failure_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> 1
    end
  end

  defp next_failure_retry_attempt(_attempt, :continuation), do: 1

  defp next_failure_retry_attempt(attempt, _retry_delay_type)
       when is_integer(attempt) and attempt > 0,
       do: attempt + 1

  defp next_failure_retry_attempt(_attempt, _retry_delay_type), do: 1

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_trace_id(previous_retry, metadata) do
    metadata[:trace_id] || Map.get(previous_retry, :trace_id)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_error_class(previous_retry, metadata) do
    case metadata[:error_class] || Map.get(previous_retry, :error_class) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        if metadata[:delay_type] == :continuation do
          nil
        else
          ErrorClassifier.to_string(:transient)
        end
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp running_entry_trace_id(%{trace_id: trace_id}) when is_binary(trace_id), do: trace_id
  defp running_entry_trace_id(_running_entry), do: nil

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @spec select_active_codex_account(String.t()) ::
          {:ok, String.t() | nil} | {:error, :invalid_account | :unhealthy_account | :unavailable}
  def select_active_codex_account(account_id) when is_binary(account_id) do
    select_active_codex_account(__MODULE__, account_id)
  end

  @spec select_active_codex_account(GenServer.server(), String.t()) ::
          {:ok, String.t() | nil} | {:error, :invalid_account | :unhealthy_account | :unavailable}
  def select_active_codex_account(server, account_id) when is_binary(account_id) do
    if Process.whereis(server) do
      GenServer.call(server, {:select_active_codex_account, account_id})
    else
      {:error, :unavailable}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        runtime_fields =
          RunPhase.snapshot_fields(metadata, now, Config.settings!().codex.stall_timeout_ms)

        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          codex_account_id: Map.get(metadata, :codex_account_id),
          trace_id: Map.get(metadata, :trace_id),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
        |> Map.merge(runtime_fields)
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          trace_id: Map.get(retry, :trace_id),
          error: Map.get(retry, :error),
          error_class: Map.get(retry, :error_class)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       active_codex_account_id: state.active_codex_account_id,
       codex_accounts: snapshot_codex_accounts(state),
       codex_totals: state.codex_totals,
       rate_limits: active_codex_rate_limits(state),
       workspace: workspace_snapshot(state),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:select_active_codex_account, account_id}, _from, state)
      when is_binary(account_id) do
    case Map.get(state.codex_accounts, account_id) do
      %{healthy: true} ->
        state =
          state
          |> Map.put(:preferred_codex_account_id, account_id)
          |> reselect_active_codex_account()

        notify_dashboard()
        {:reply, {:ok, state.active_codex_account_id}, state}

      %{} ->
        {:reply, {:error, :unhealthy_account}, state}

      _ ->
        {:reply, {:error, :invalid_account}, state}
    end
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)

    codex_account_id =
      Map.get(update, :codex_account_id) ||
        Map.get(update, "codex_account_id") ||
        Map.get(running_entry, :codex_account_id)

    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    updated_running_entry =
      running_entry
      |> Map.merge(%{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        trace_id: trace_id_for_update(Map.get(running_entry, :trace_id), update),
        session_id: session_id_for_update(running_entry.session_id, update),
        codex_account_id: codex_account_id,
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      })
      |> RunPhase.apply_update(update)

    {updated_running_entry, token_delta}
  end

  defp maybe_publish_run_phase_transition(issue_id, previous_running_entry, current_running_entry) do
    with true <- should_publish_run_phase_comment?(previous_running_entry, current_running_entry),
         comment when is_binary(comment) <- RunPhase.phase_signal_comment(current_running_entry),
         :ok <- Tracker.create_comment(issue_id, comment) do
      RunPhase.mark_phase_reported(current_running_entry)
    else
      {:error, reason} ->
        Logger.warning("Failed to publish run phase transition for issue_id=#{issue_id}: #{inspect(reason)}")
        current_running_entry

      _ ->
        current_running_entry
    end
  end

  defp should_publish_run_phase_comment?(previous_running_entry, current_running_entry) do
    phase_unreported?(current_running_entry) and
      RunPhase.reportable_phase?(Map.get(current_running_entry, :run_phase)) and
      (RunPhase.transition_reportable?(previous_running_entry, current_running_entry) or
         retrying_unreported_phase_comment?(previous_running_entry, current_running_entry))
  end

  defp retrying_unreported_phase_comment?(previous_running_entry, current_running_entry) do
    RunPhase.phase_label(Map.get(previous_running_entry, :run_phase)) ==
      RunPhase.phase_label(Map.get(current_running_entry, :run_phase))
  end

  defp phase_unreported?(running_entry) do
    Map.get(running_entry, :last_reported_phase) != Map.get(running_entry, :run_phase)
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp trace_id_for_update(_existing, %{trace_id: trace_id}) when is_binary(trace_id),
    do: trace_id

  defp trace_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp new_trace_id do
    Ecto.UUID.generate()
  end

  defp dispatch_trace_id(_issue, trace_id) when is_binary(trace_id) and trace_id != "",
    do: trace_id

  defp dispatch_trace_id(issue, _trace_id) do
    case Map.get(issue, :trace_id) do
      trace_id when is_binary(trace_id) and trace_id != "" -> trace_id
      _ -> new_trace_id()
    end
  end

  defp issue_log_metadata(issue_id, issue_identifier, session_id, trace_id) do
    []
    |> maybe_put_logger_metadata(:issue_id, issue_id)
    |> maybe_put_logger_metadata(:issue_identifier, issue_identifier)
    |> maybe_put_logger_metadata(:session_id, session_id)
    |> maybe_put_logger_metadata(:trace_id, trace_id)
  end

  defp running_entry_log_metadata(issue_id, identifier, running_entry) do
    issue_log_metadata(
      issue_id,
      identifier,
      running_entry_session_id(running_entry),
      running_entry_trace_id(running_entry)
    )
  end

  defp with_log_metadata(metadata, fun) when is_list(metadata) and is_function(fun, 0) do
    previous_metadata = Logger.metadata()

    if metadata != [] do
      Logger.metadata(metadata)
    end

    try do
      fun.()
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  defp maybe_put_logger_metadata(metadata, _key, value) when value in [nil, "", "n/a"],
    do: metadata

  defp maybe_put_logger_metadata(metadata, key, value), do: Keyword.put(metadata, key, value)

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp refresh_codex_accounts(%State{} = state) do
    accounts = Config.codex_accounts()

    probed_accounts =
      AccountProbe.probe_accounts(
        accounts,
        cwd: System.tmp_dir!(),
        monitored_windows_mins: Config.codex_monitored_windows_mins(),
        minimum_remaining_percent: Config.codex_minimum_remaining_percent(),
        timeout_ms: max(Config.settings!().codex.read_timeout_ms * 2, 2_000)
      )

    codex_accounts =
      probed_accounts
      |> Enum.map(fn account_status ->
        existing =
          Map.get(
            state.codex_accounts,
            account_status.id,
            default_codex_account_status(account_status.id)
          )

        incoming =
          account_status
          |> Map.put(:probe_healthy, Map.get(account_status, :healthy, false))
          |> Map.put(:probe_health_reason, Map.get(account_status, :health_reason))

        {account_status.id, merge_codex_account_status(existing, incoming, :probe)}
      end)
      |> Map.new()

    state
    |> Map.put(:codex_accounts, codex_accounts)
    |> reselect_active_codex_account()
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update, account_id) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits when is_binary(account_id) ->
        existing =
          Map.get(state.codex_accounts, account_id, default_codex_account_status(account_id))

        health =
          Accounts.health(
            rate_limits,
            Config.codex_monitored_windows_mins(),
            Config.codex_minimum_remaining_percent()
          )

        updated_account =
          merge_codex_account_status(
            existing,
            %{
              rate_limits: rate_limits,
              checked_at: DateTime.utc_now(),
              missing_windows_mins: health.missing_windows_mins,
              insufficient_windows_mins: health.insufficient_windows_mins,
              probe_health_reason: health.reason,
              probe_healthy: existing_logged_in?(existing) and health.healthy?
            },
            :live_rate_limits
          )

        state
        |> Map.put(:codex_accounts, Map.put(state.codex_accounts, account_id, updated_account))
        |> reselect_active_codex_account()

      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    find_rate_limits_snapshot(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp find_rate_limits_snapshot(payload) when is_map(payload) do
    Accounts.select_rate_limits_snapshot(payload) ||
      payload
      |> Map.values()
      |> Enum.reduce_while(nil, fn
        value, nil ->
          case find_rate_limits_snapshot(value) do
            nil -> {:cont, nil}
            rate_limits -> {:halt, rate_limits}
          end

        _value, result ->
          {:halt, result}
      end)
  end

  defp find_rate_limits_snapshot(payload) when is_list(payload) do
    Enum.reduce_while(payload, nil, fn
      value, nil ->
        case find_rate_limits_snapshot(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp find_rate_limits_snapshot(_payload), do: nil

  defp update_codex_account_runtime_state(
         %State{} = state,
         codex_account_id,
         runtime_state,
         runtime_health_reason,
         cooldown_ms
       )
       when is_binary(codex_account_id) do
    existing =
      Map.get(
        state.codex_accounts,
        codex_account_id,
        default_codex_account_status(codex_account_id)
      )

    now = DateTime.utc_now()

    updated_account =
      merge_codex_account_status(
        existing,
        %{
          runtime_state: runtime_state,
          runtime_health_reason: runtime_health_reason,
          runtime_marked_at: now,
          runtime_cooldown_until: runtime_cooldown_until(runtime_state, now, cooldown_ms)
        },
        :runtime_override,
        now
      )

    state
    |> Map.put(:codex_accounts, Map.put(state.codex_accounts, codex_account_id, updated_account))
    |> reselect_active_codex_account()
  end

  defp runtime_cooldown_until(:cooldown, %DateTime{} = now, cooldown_ms)
       when is_integer(cooldown_ms) and cooldown_ms > 0 do
    DateTime.add(now, cooldown_ms, :millisecond)
  end

  defp runtime_cooldown_until(_runtime_state, _now, _cooldown_ms), do: nil

  defp merge_codex_account_status(existing, attrs, source, now \\ DateTime.utc_now())

  defp merge_codex_account_status(existing, attrs, source, now)
       when is_map(existing) and is_map(attrs) do
    probe_healthy =
      Map.get(
        attrs,
        :probe_healthy,
        Map.get(existing, :probe_healthy, Map.get(existing, :healthy, false))
      )

    probe_health_reason =
      Map.get(
        attrs,
        :probe_health_reason,
        Map.get(existing, :probe_health_reason, Map.get(existing, :health_reason))
      )

    account =
      existing
      |> Map.merge(attrs)
      |> Map.put(:probe_healthy, probe_healthy)
      |> Map.put(:probe_health_reason, probe_health_reason)
      |> reconcile_account_runtime_state(source, now)

    runtime_ready? = runtime_account_ready?(account, now)

    account
    |> Map.put(:healthy, probe_healthy and runtime_ready?)
    |> Map.put(:health_reason, final_account_health_reason(account, runtime_ready?))
  end

  defp merge_codex_account_status(existing, _attrs, _source, _now), do: existing

  defp reconcile_account_runtime_state(account, source, now) when is_map(account) do
    account = clear_expired_runtime_state(account, now)

    case {source, Map.get(account, :runtime_state)} do
      {:probe, :broken} ->
        if probe_confirms_broken_recovery?(account) do
          clear_account_runtime_state(account)
        else
          account
        end

      {source_name, :cooldown} when source_name in [:probe, :live_rate_limits] ->
        if cooldown_recovery_confirmed?(account) do
          clear_account_runtime_state(account)
        else
          account
        end

      _ ->
        account
    end
  end

  defp clear_expired_runtime_state(account, now) when is_map(account) do
    case {Map.get(account, :runtime_state), Map.get(account, :runtime_cooldown_until)} do
      {:cooldown, %DateTime{} = until_at} ->
        if DateTime.compare(until_at, now) == :gt do
          account
        else
          clear_account_runtime_state(account)
        end

      _ ->
        account
    end
  end

  defp clear_account_runtime_state(account) when is_map(account) do
    account
    |> Map.put(:runtime_state, nil)
    |> Map.put(:runtime_health_reason, nil)
    |> Map.put(:runtime_marked_at, nil)
    |> Map.put(:runtime_cooldown_until, nil)
  end

  # Preserve active cooldowns until their deadline expires. The probe/live-rate-limit
  # path may only clear legacy cooldown states that predate runtime_cooldown_until.
  defp cooldown_recovery_confirmed?(account) when is_map(account) do
    Map.get(account, :probe_healthy) == true and
      not match?(%DateTime{}, Map.get(account, :runtime_cooldown_until))
  end

  defp runtime_account_ready?(account, now) when is_map(account) do
    case Map.get(account, :runtime_state) do
      :broken ->
        false

      :cooldown ->
        case Map.get(account, :runtime_cooldown_until) do
          %DateTime{} = until_at -> DateTime.compare(until_at, now) != :gt
          _ -> false
        end

      _ ->
        true
    end
  end

  defp final_account_health_reason(account, true) when is_map(account) do
    Map.get(account, :probe_health_reason)
  end

  defp final_account_health_reason(account, false) when is_map(account) do
    Map.get(account, :runtime_health_reason) || Map.get(account, :probe_health_reason)
  end

  defp default_codex_account_status(account_id) when is_binary(account_id) do
    account_definition =
      Enum.find(Config.codex_accounts(), fn account ->
        account.id == account_id
      end)

    %{
      id: account_id,
      explicit?: if(is_map(account_definition), do: account_definition.explicit?, else: true),
      healthy: false,
      probe_healthy: false,
      probe_health_reason: "not yet probed",
      health_reason: "not yet probed",
      auth_mode: "unknown",
      email: nil,
      plan_type: nil,
      requires_openai_auth: false,
      rate_limits: nil,
      account: nil,
      runtime_state: nil,
      runtime_health_reason: nil,
      runtime_marked_at: nil,
      runtime_cooldown_until: nil
    }
  end

  defp default_codex_account_status(_account_id), do: default_codex_account_status("unknown")

  defp existing_logged_in?(existing) when is_map(existing) do
    Map.get(existing, :requires_openai_auth) != true
  end

  defp existing_logged_in?(_existing), do: true

  defp probe_confirms_broken_recovery?(account) when is_map(account) do
    Map.get(account, :requires_openai_auth) == false and is_map(Map.get(account, :rate_limits))
  end

  defp codex_account_health(%State{} = state, account_id) when is_binary(account_id) do
    case Map.get(state.codex_accounts, account_id) do
      %{healthy: healthy} when is_boolean(healthy) -> healthy
      _ -> nil
    end
  end

  defp codex_account_health(_state, _account_id), do: nil

  defp codex_account_health_reason(%State{} = state, account_id) when is_binary(account_id) do
    case Map.get(state.codex_accounts, account_id) do
      %{} = account -> Map.get(account, :health_reason)
      _ -> nil
    end
  end

  defp codex_account_health_reason(_state, _account_id), do: nil

  defp active_codex_account_id_or_nil(%State{active_codex_account_id: account_id})
       when is_binary(account_id),
       do: account_id

  defp active_codex_account_id_or_nil(_state), do: nil

  defp cancel_running_monitor(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp cancel_running_monitor(_ref), do: :ok

  defp active_codex_account_available?(%State{active_codex_account_id: account_id})
       when is_binary(account_id), do: true

  defp active_codex_account_available?(_state), do: false

  defp active_codex_account(%State{
         active_codex_account_id: account_id,
         codex_accounts: codex_accounts
       })
       when is_binary(account_id) do
    Map.get(codex_accounts, account_id)
  end

  defp active_codex_account(_state), do: nil

  defp active_codex_rate_limits(%State{} = state) do
    case active_codex_account(state) do
      %{rate_limits: rate_limits} -> rate_limits
      _ -> state.codex_rate_limits
    end
  end

  defp snapshot_codex_accounts(%State{} = state) do
    Config.codex_accounts()
    |> Enum.map(fn account ->
      Map.get(state.codex_accounts, account.id, default_codex_account_status(account.id))
    end)
  end

  defp reselect_active_codex_account(%State{} = state) do
    active_codex_account_id =
      preferred_active_codex_account_id(state) ||
        first_healthy_codex_account_id(state)

    %{
      state
      | active_codex_account_id: active_codex_account_id,
        codex_rate_limits:
          if(is_binary(active_codex_account_id),
            do: get_in(state.codex_accounts, [active_codex_account_id, :rate_limits]),
            else: nil
          ),
        codex_dispatch_reason: if(is_binary(active_codex_account_id), do: nil, else: "no healthy codex account")
    }
  end

  defp preferred_active_codex_account_id(%State{} = state) do
    preferred_id = state.preferred_codex_account_id

    if is_binary(preferred_id) and healthy_codex_account?(state, preferred_id) do
      preferred_id
    end
  end

  defp first_healthy_codex_account_id(%State{} = state) do
    config_ordered_id =
      Config.codex_accounts()
      |> Enum.find_value(fn account ->
        if healthy_codex_account?(state, account.id), do: account.id
      end)

    config_ordered_id ||
      Enum.find_value(state.codex_accounts, fn
        {account_id, %{healthy: true}} -> account_id
        _entry -> nil
      end)
  end

  defp healthy_codex_account?(%State{} = state, account_id) when is_binary(account_id) do
    match?(%{healthy: true}, Map.get(state.codex_accounts, account_id))
  end

  defp healthy_codex_account?(_state, _account_id), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
