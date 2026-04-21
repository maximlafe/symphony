defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    ControllerFinalizer,
    ErrorClassifier,
    ResumeCheckpoint,
    RetryFailoverDecision,
    RunPhase,
    StatusDashboard,
    TelemetrySchema,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Codex.{AccountProbe, Accounts}
  alias SymphonyElixir.Linear.Issue

  @continuation_base_delay_ms 5_000
  @continuation_max_delay_ms 300_000
  @max_continuation_attempts_default 3
  @failure_retry_base_ms 10_000
  @idle_codex_account_probe_interval_ms 60_000
  @idle_codex_account_full_reconcile_interval_ms 900_000
  @idle_housekeeping_interval_ms 60_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @github_pr_snapshot_tool "github_pr_snapshot"
  @github_wait_for_checks_tool "github_wait_for_checks"
  @symphony_handoff_check_tool "symphony_handoff_check"
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }
  @token_reason_categories [:polling, :git_gh_status, :validation, :linear_mutation, :other]
  @empty_token_reason_totals Enum.into(@token_reason_categories, %{}, fn category ->
                               {category, %{input_tokens: 0, output_tokens: 0, total_tokens: 0}}
                             end)

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
      :codex_account_probe_fun,
      :controller_finalizer_fun,
      :controller_finalizer_eligible_fun,
      :last_codex_account_probe_at_ms,
      :last_full_codex_account_probe_at_ms,
      :last_housekeeping_at_ms,
      :workspace_usage_bytes,
      :workspace_cleanup_ref,
      :workspace_usage_refresh_ref,
      :workspace_threshold_exceeded?,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      retry_dedupe_keys: %{},
      codex_accounts: %{},
      preferred_codex_account_id: nil,
      active_codex_account_id: nil,
      codex_totals: nil,
      codex_token_reason_totals: nil,
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
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()
    start_immediately? = Keyword.get(opts, :start_immediately?, true)
    run_startup_housekeeping? = Keyword.get(opts, :run_startup_housekeeping?, true)

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_account_probe_fun: Keyword.get(opts, :codex_account_probe_fun, &AccountProbe.probe_accounts/2),
      controller_finalizer_fun: Keyword.get(opts, :controller_finalizer_fun, &ControllerFinalizer.run/3),
      controller_finalizer_eligible_fun: Keyword.get(opts, :controller_finalizer_eligible_fun, &ControllerFinalizer.eligible?/2),
      last_codex_account_probe_at_ms: nil,
      last_full_codex_account_probe_at_ms: nil,
      last_housekeeping_at_ms: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      codex_accounts: %{},
      preferred_codex_account_id: nil,
      active_codex_account_id: nil,
      codex_totals: @empty_codex_totals,
      codex_token_reason_totals: @empty_token_reason_totals,
      codex_rate_limits: nil,
      codex_dispatch_reason: nil
    }

    state =
      if run_startup_housekeeping? do
        run_workspace_housekeeping(state, :startup)
      else
        state
      end

    state =
      if start_immediately? do
        schedule_tick(state, 0)
      else
        state
      end

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
    state = maybe_refresh_codex_accounts(state, :poll)
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
            handle_running_entry_exit(
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
          maybe_publish_run_milestones(issue_id, running_entry, updated_running_entry, update)

        tracked_account_id = Map.get(updated_running_entry, :codex_account_id)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_reason_delta(updated_running_entry, update, token_delta)
          |> apply_codex_rate_limits(update, tracked_account_id)

        notify_dashboard()

        state
        |> apply_running_update_policies(
          issue_id,
          updated_running_entry,
          update,
          tracked_account_id
        )
        |> finalize_running_update_result(issue_id, updated_running_entry)
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:controller_finalizer_result, issue_id, result}, %{running: running} = state) do
    case Map.get(running, issue_id) do
      %{worker_kind: :controller_finalizer} ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)

        if is_reference(running_entry.ref) do
          Process.demonitor(running_entry.ref, [:flush])
        end

        identifier = Map.get(running_entry, :identifier)
        trace_id = running_entry_trace_id(running_entry)

        state =
          with_log_metadata(issue_log_metadata(issue_id, identifier, nil, trace_id), fn ->
            handle_controller_finalizer_result(
              state,
              issue_id,
              running_entry,
              identifier,
              trace_id,
              result
            )
          end)

        notify_dashboard()
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

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

  defp apply_running_update_policies(
         %State{} = state,
         issue_id,
         updated_running_entry,
         update,
         tracked_account_id
       ) do
    case maybe_fail_close_verification_guard_failure(
           state,
           issue_id,
           updated_running_entry,
           update
         ) do
      {:verification_guard_stop, state} ->
        {:noreply, state}

      {:keep_running, state, running_entry_after_verification} ->
        continue_running_update_after_verification(
          state,
          issue_id,
          running_entry_after_verification,
          tracked_account_id
        )
    end
  end

  defp continue_running_update_after_verification(
         %State{} = state,
         issue_id,
         running_entry_after_verification,
         tracked_account_id
       ) do
    {:keep_running, state} =
      maybe_enforce_running_budget(state, issue_id, running_entry_after_verification, :token_update)

    continue_running_update_after_budget(
      state,
      issue_id,
      running_entry_after_verification,
      tracked_account_id
    )
  end

  defp continue_running_update_after_budget(
         %State{} = state,
         issue_id,
         running_entry_after_verification,
         tracked_account_id
       ) do
    maybe_failover_running_issue(
      state,
      issue_id,
      running_entry_after_verification,
      tracked_account_id
    )
  end

  defp maybe_fail_close_verification_guard_failure(
         %State{} = state,
         issue_id,
         running_entry,
         update
       )
       when is_binary(issue_id) and is_map(running_entry) and is_map(update) do
    with {:ok, manifest} <- failed_verification_manifest(update),
         %Issue{} = issue <- Map.get(running_entry, :issue) do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)
      trace_id = running_entry_trace_id(running_entry)
      failure_attempt = next_failure_attempt_from_running(running_entry)
      checkpoint = capture_resume_checkpoint(issue, running_entry)
      decision = verification_guard_failure_decision(running_entry, manifest)

      with_log_metadata(issue_log_metadata(issue_id, identifier, session_id, trace_id), fn ->
        Logger.warning("Fail-closing active run after failed verification guard for issue_id=#{issue_id} issue_identifier=#{identifier}")
      end)

      log_retry_failover_decision(issue_id, identifier, session_id, trace_id, decision)

      state =
        state
        |> Map.put(:running, Map.put(state.running, issue_id, running_entry))
        |> terminate_running_issue(issue_id, false)
        |> escalate_issue_for_retry_failover_handoff(
          issue,
          decision,
          failure_attempt,
          %{
            issue_id: issue_id,
            identifier: identifier,
            trace_id: trace_id,
            codex_account_id: Map.get(running_entry, :codex_account_id),
            error_class: ErrorClassifier.to_string(:permanent),
            failure_class: "verification_guard_failed",
            retry_action: :stop,
            resume_checkpoint: checkpoint
          }
          |> Map.merge(TelemetrySchema.validation_guard_payload(running_entry))
          |> Map.merge(retry_execution_metadata(running_entry, checkpoint))
        )

      {:verification_guard_stop, state}
    else
      _ -> {:keep_running, state, running_entry}
    end
  end

  defp maybe_fail_close_verification_guard_failure(state, _issue_id, running_entry, _update) do
    {:keep_running, state, running_entry}
  end

  defp failed_verification_manifest(update) when is_map(update) do
    with {:ok, manifest} <- verification_manifest_from_update(update),
         false <- manifest["passed"] == true do
      {:ok, manifest}
    else
      _ -> :error
    end
  end

  defp verification_guard_failure_decision(running_entry, manifest)
       when is_map(running_entry) and is_map(manifest) do
    profile = Map.get(running_entry, :verification_profile) || manifest["profile"] || "unknown"
    summary = Map.get(running_entry, :verification_summary) || manifest["summary"] || "verification guard failed"
    missing_items = normalize_manifest_missing_items(manifest["missing_items"])

    RetryFailoverDecision.decide(%{
      validation_env_mismatch: %{
        reason: "verification guard failed for profile `#{profile}`: #{summary}",
        checkpoint_type: "human-action",
        risk_level: "high",
        log_fields: %{
          validation_guard_name: profile,
          validation_guard_result: "failed",
          validation_guard_reason: summary,
          verification_missing_items: Enum.join(missing_items, ", ")
        }
      }
    })
  end

  defp finalize_running_update_result({:failover, state}, _issue_id, _updated_running_entry),
    do: {:noreply, state}

  defp finalize_running_update_result(
         {:keep_running, state, running_entry_to_store},
         issue_id,
         _updated_running_entry
       ),
       do: {:noreply, %{state | running: Map.put(state.running, issue_id, running_entry_to_store)}}

  defp finalize_running_update_result({:keep_running, state}, issue_id, updated_running_entry),
    do: {:noreply, %{state | running: Map.put(state.running, issue_id, updated_running_entry)}}

  defp finalize_running_update_result({:noreply, state}, _issue_id, _updated_running_entry),
    do: {:noreply, state}

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

        terminate_running_issue(state, issue.id, true)

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

      %{pid: pid, ref: ref} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        updated_state = %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id),
            retry_dedupe_keys: Map.delete(state.retry_dedupe_keys, issue_id)
        }

        if cleanup_workspace do
          maybe_schedule_terminal_workspace_cleanup(updated_state, :terminal_transition)
        else
          updated_state
        end

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

  defp restart_stalled_issue(state, _issue_id, %{worker_kind: :controller_finalizer}, _now, _timeout_ms),
    do: state

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
      checkpoint = capture_resume_checkpoint(Map.get(running_entry, :issue), running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(
        issue_id,
        next_attempt,
        %{
          identifier: identifier,
          trace_id: trace_id,
          error: "stalled for #{elapsed_ms}ms without codex activity",
          error_class: ErrorClassifier.to_string(:transient),
          resume_checkpoint: checkpoint
        }
        |> Map.merge(retry_execution_metadata(running_entry, checkpoint))
      )
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
         retry_delay_type \\ nil,
         resume_checkpoint \\ nil,
         retry_metadata \\ %{}
       ) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(
          state,
          refreshed_issue,
          attempt,
          trace_id,
          retry_delay_type,
          resume_checkpoint,
          retry_metadata
        )

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

  defp do_dispatch_issue(
         %State{} = state,
         issue,
         attempt,
         trace_id,
         retry_delay_type,
         resume_checkpoint,
         retry_metadata
       ) do
    resolved_resume_checkpoint = resolve_resume_checkpoint(issue, resume_checkpoint)
    trace_id = dispatch_trace_id(issue, trace_id)
    execution_head = capture_execution_head(issue, retry_delay_type, resolved_resume_checkpoint)

    case stale_execution_head_reason(execution_head) do
      nil ->
        dispatch_ready_issue(
          state,
          issue,
          attempt,
          trace_id,
          retry_delay_type,
          resolved_resume_checkpoint,
          execution_head,
          retry_metadata
        )

      stale_reason ->
        block_stale_workspace_head(
          state,
          issue,
          attempt,
          trace_id,
          resolved_resume_checkpoint,
          execution_head,
          stale_reason
        )
    end
  end

  defp dispatch_ready_issue(
         %State{} = state,
         issue,
         attempt,
         trace_id,
         retry_delay_type,
         resolved_resume_checkpoint,
         execution_head,
         retry_metadata
       ) do
    case maybe_dispatch_controller_finalizer(
           state,
           issue,
           attempt,
           trace_id,
           retry_delay_type,
           resolved_resume_checkpoint,
           execution_head,
           retry_metadata
         ) do
      {:dispatched, state} ->
        state

      :not_applicable ->
        dispatch_issue_via_account(
          state,
          issue,
          attempt,
          trace_id,
          retry_delay_type,
          resolved_resume_checkpoint,
          execution_head,
          retry_metadata
        )
    end
  end

  defp dispatch_issue_via_account(
         %State{} = state,
         issue,
         attempt,
         trace_id,
         retry_delay_type,
         resolved_resume_checkpoint,
         execution_head,
         retry_metadata
       ) do
    case active_codex_account(state) do
      nil ->
        state

      codex_account ->
        dispatch_issue_with_account(
          state,
          issue,
          attempt,
          codex_account,
          trace_id,
          retry_delay_type,
          resolved_resume_checkpoint,
          Map.put(execution_head, :retry_metadata, retry_metadata)
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
    resume_checkpoint = pick_retry_resume_checkpoint(previous_retry, metadata)
    runtime_head_sha = pick_retry_runtime_head_sha(previous_retry, metadata)
    expected_head_sha = pick_retry_expected_head_sha(previous_retry, metadata)
    execution_branch = pick_retry_execution_branch(previous_retry, metadata)
    error_signature = pick_retry_error_signature(previous_retry, metadata, error)
    issue_token_total = pick_retry_issue_token_total(previous_retry, metadata)
    cost_profile_key = pick_retry_cost_profile_key(previous_retry, metadata)
    cost_profile_reason = pick_retry_optional_string(previous_retry, metadata, :cost_profile_reason)
    cost_stage = pick_retry_optional_string(previous_retry, metadata, :cost_stage)
    command_source = pick_retry_optional_string(previous_retry, metadata, :command_source)
    codex_model = pick_retry_optional_string(previous_retry, metadata, :codex_model)
    codex_effort = pick_retry_optional_string(previous_retry, metadata, :codex_effort)
    observed_model = pick_retry_optional_string(previous_retry, metadata, :observed_model)
    observed_effort = pick_retry_optional_string(previous_retry, metadata, :observed_effort)

    observed_signal_source =
      pick_retry_optional_string(previous_retry, metadata, :observed_signal_source)

    routing_parity_status =
      pick_retry_optional_string(previous_retry, metadata, :routing_parity_status)

    routing_parity_reason =
      pick_retry_optional_string(previous_retry, metadata, :routing_parity_reason)

    continuation_reason =
      pick_retry_optional_string(previous_retry, metadata, :continuation_reason)

    resume_mode =
      pick_retry_optional_string(previous_retry, metadata, :resume_mode)

    resume_fallback_reason =
      pick_retry_optional_string(previous_retry, metadata, :resume_fallback_reason)

    feedback_digest = pick_retry_feedback_digest(previous_retry, metadata)
    failure_class = pick_retry_failure_class(previous_retry, metadata)

    validation_bundle_fingerprint =
      pick_retry_validation_bundle_fingerprint(previous_retry, metadata)

    workspace_diff_fingerprint =
      pick_retry_workspace_diff_fingerprint(previous_retry, metadata)

    retry_failover_decision = pick_retry_failover_decision(previous_retry, metadata)
    session_id = pick_retry_session_id(previous_retry, metadata)
    thread_id = pick_retry_optional_string(previous_retry, metadata, :thread_id)
    turn_id = pick_retry_optional_string(previous_retry, metadata, :turn_id)

    replacement_of_session_id =
      pick_retry_optional_string(previous_retry, metadata, :replacement_of_session_id) ||
        session_id

    replacement_session_id =
      pick_retry_optional_string(previous_retry, metadata, :replacement_session_id)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""
    error_class_suffix = if is_binary(error_class), do: " error_class=#{error_class}", else: ""

    with_log_metadata(issue_log_metadata(issue_id, identifier, session_id, trace_id), fn ->
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
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id,
            replacement_of_session_id: replacement_of_session_id,
            replacement_session_id: replacement_session_id,
            error: error,
            error_class: error_class,
            delay_type: metadata[:delay_type],
            resume_checkpoint: resume_checkpoint,
            runtime_head_sha: runtime_head_sha,
            expected_head_sha: expected_head_sha,
            execution_branch: execution_branch,
            error_signature: error_signature,
            issue_token_total: issue_token_total,
            cost_profile_key: cost_profile_key,
            cost_profile_reason: cost_profile_reason,
            cost_stage: cost_stage,
            command_source: command_source,
            codex_model: codex_model,
            codex_effort: codex_effort,
            observed_model: observed_model,
            observed_effort: observed_effort,
            observed_signal_source: observed_signal_source,
            routing_parity_status: routing_parity_status,
            routing_parity_reason: routing_parity_reason,
            continuation_reason: continuation_reason,
            resume_mode: resume_mode,
            resume_fallback_reason: resume_fallback_reason,
            feedback_digest: feedback_digest,
            failure_class: failure_class,
            validation_bundle_fingerprint: validation_bundle_fingerprint,
            workspace_diff_fingerprint: workspace_diff_fingerprint,
            retry_failover_decision: retry_failover_decision
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
          session_id: Map.get(retry_entry, :session_id),
          thread_id: Map.get(retry_entry, :thread_id),
          turn_id: Map.get(retry_entry, :turn_id),
          replacement_of_session_id: Map.get(retry_entry, :replacement_of_session_id),
          replacement_session_id: Map.get(retry_entry, :replacement_session_id),
          error: Map.get(retry_entry, :error),
          error_class: Map.get(retry_entry, :error_class),
          delay_type: Map.get(retry_entry, :delay_type),
          resume_checkpoint: Map.get(retry_entry, :resume_checkpoint),
          runtime_head_sha: Map.get(retry_entry, :runtime_head_sha),
          expected_head_sha: Map.get(retry_entry, :expected_head_sha),
          execution_branch: Map.get(retry_entry, :execution_branch),
          error_signature: Map.get(retry_entry, :error_signature),
          issue_token_total: Map.get(retry_entry, :issue_token_total),
          cost_profile_key: Map.get(retry_entry, :cost_profile_key),
          cost_profile_reason: Map.get(retry_entry, :cost_profile_reason),
          cost_stage: Map.get(retry_entry, :cost_stage),
          command_source: Map.get(retry_entry, :command_source),
          codex_model: Map.get(retry_entry, :codex_model),
          codex_effort: Map.get(retry_entry, :codex_effort),
          observed_model: Map.get(retry_entry, :observed_model),
          observed_effort: Map.get(retry_entry, :observed_effort),
          observed_signal_source: Map.get(retry_entry, :observed_signal_source),
          routing_parity_status: Map.get(retry_entry, :routing_parity_status),
          routing_parity_reason: Map.get(retry_entry, :routing_parity_reason),
          continuation_reason: Map.get(retry_entry, :continuation_reason),
          resume_mode: Map.get(retry_entry, :resume_mode),
          resume_fallback_reason: Map.get(retry_entry, :resume_fallback_reason),
          feedback_digest: Map.get(retry_entry, :feedback_digest),
          failure_class: Map.get(retry_entry, :failure_class),
          validation_bundle_fingerprint: Map.get(retry_entry, :validation_bundle_fingerprint),
          workspace_diff_fingerprint: Map.get(retry_entry, :workspace_diff_fingerprint),
          retry_failover_decision: Map.get(retry_entry, :retry_failover_decision)
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
        with_log_metadata(
          issue_log_metadata(issue_id, identifier, retry_metadata_session_id(metadata), trace_id),
          fn ->
            Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{identifier}: #{inspect(reason)}")
          end
        )

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
          issue_log_metadata(
            issue_id,
            issue.identifier,
            retry_metadata_session_id(metadata),
            metadata[:trace_id]
          ),
          fn ->
            Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; releasing claim")
          end
        )

        {:noreply,
         state
         |> release_issue_claim(issue_id)
         |> maybe_schedule_terminal_workspace_cleanup(:retry_terminal)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        with_log_metadata(
          issue_log_metadata(
            issue_id,
            issue.identifier,
            retry_metadata_session_id(metadata),
            metadata[:trace_id]
          ),
          fn ->
            Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")
          end
        )

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, metadata) do
    with_log_metadata(
      issue_log_metadata(
        issue_id,
        metadata[:identifier] || issue_id,
        retry_metadata_session_id(metadata),
        metadata[:trace_id]
      ),
      fn ->
        Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
      end
    )

    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_artifacts(identifier) when is_binary(identifier) do
    Workspace.cleanup_issue_artifacts(identifier)
  end

  defp handle_agent_exit_reason(
         state,
         issue_id,
         running_entry,
         identifier,
         session_id,
         trace_id,
         :normal
       ) do
    issue = Map.get(running_entry, :issue)
    continuation_attempt = next_continuation_attempt(running_entry)
    resume_checkpoint = capture_resume_checkpoint(Map.get(running_entry, :issue), running_entry)
    continuation_reason = Map.get(running_entry, :continuation_reason)

    if continuation_attempt_limit_exceeded?(continuation_attempt) do
      handle_continuation_attempt_limit_breach(
        state,
        continuation_attempt,
        %{
          issue_id: issue_id,
          issue: Map.get(running_entry, :issue),
          identifier: identifier,
          session_id: session_id,
          trace_id: trace_id,
          continuation_reason: continuation_reason,
          codex_account_id: Map.get(running_entry, :codex_account_id),
          resume_checkpoint: resume_checkpoint
        }
      )
    else
      issue_token_total =
        issue_token_total_before_attempt(running_entry) +
          running_entry_attempt_tokens(running_entry)

      decision = RetryFailoverDecision.decide(%{})

      log_retry_failover_decision(issue_id, identifier, session_id, trace_id, decision)

      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check (attempt #{continuation_attempt})")

      state
      |> complete_issue(issue_id)
      |> schedule_continuation_retry_or_dedupe_hit(
        issue_id,
        issue,
        continuation_attempt,
        %{
          identifier: identifier,
          trace_id: trace_id,
          delay_type: :continuation,
          resume_checkpoint: resume_checkpoint,
          issue_token_total: issue_token_total
        }
        |> Map.merge(retry_execution_metadata(running_entry, resume_checkpoint))
        |> Map.merge(retry_failover_metadata(decision))
      )
    end
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

    resume_checkpoint = capture_resume_checkpoint(Map.get(running_entry, :issue), running_entry)

    issue_token_total =
      issue_token_total_before_attempt(running_entry) +
        running_entry_attempt_tokens(running_entry)

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
        session_id: session_id,
        thread_id: Map.get(running_entry, :thread_id),
        turn_id: Map.get(running_entry, :turn_id),
        replacement_of_session_id: Map.get(running_entry, :replacement_of_session_id),
        replacement_session_id: Map.get(running_entry, :replacement_session_id),
        codex_account_id: Map.get(running_entry, :codex_account_id),
        failure_class: failure_class_label,
        resume_checkpoint: resume_checkpoint,
        issue_token_total: issue_token_total
      }
      |> Map.merge(retry_execution_metadata(running_entry, resume_checkpoint))
    )
  end

  defp handle_controller_finalizer_result(
         state,
         issue_id,
         running_entry,
         identifier,
         trace_id,
         result
       ) do
    issue = Map.get(running_entry, :issue)
    continuation_attempt = next_continuation_attempt(running_entry)
    fallback_attempt = next_failure_attempt_from_running(running_entry)

    case result do
      {:ok, %{checkpoint: checkpoint}} ->
        Logger.info("Controller finalizer succeeded for issue_id=#{issue_id} issue_identifier=#{identifier}; releasing claim")

        state
        |> complete_issue(issue_id)
        |> release_issue_claim(issue_id)
        |> Map.update!(:retry_attempts, &Map.delete(&1, issue_id))
        |> maybe_store_finalizer_checkpoint(issue_id, checkpoint)

      {:retry, %{checkpoint: checkpoint, reason: reason}} ->
        Logger.info("Controller finalizer requested retry for issue_id=#{issue_id} issue_identifier=#{identifier}: #{reason}")

        state
        |> complete_issue(issue_id)
        |> maybe_store_finalizer_checkpoint(issue_id, checkpoint)
        |> schedule_continuation_retry_or_dedupe_hit(
          issue_id,
          issue,
          continuation_attempt,
          %{
            identifier: identifier,
            trace_id: trace_id,
            delay_type: :continuation,
            resume_checkpoint: checkpoint,
            error: reason,
            error_class: ErrorClassifier.to_string(:transient)
          }
          |> Map.merge(retry_execution_metadata(running_entry, checkpoint))
        )

      {:fallback, %{checkpoint: checkpoint, reason: reason}} ->
        Logger.info("Controller finalizer returned action-required fallback for issue_id=#{issue_id} issue_identifier=#{identifier}: #{reason}")

        state
        |> complete_issue(issue_id)
        |> maybe_store_finalizer_checkpoint(issue_id, checkpoint)
        |> schedule_failure_retry_or_dedupe_hit(
          issue,
          fallback_attempt,
          %{
            identifier: identifier,
            trace_id: trace_id,
            delay_type: nil,
            resume_checkpoint: checkpoint,
            error: reason,
            error_class: ErrorClassifier.to_string(:transient)
          }
          |> Map.merge(retry_execution_metadata(running_entry, checkpoint))
        )

      {:not_applicable, _payload} ->
        Logger.info("Controller finalizer returned not_applicable for issue_id=#{issue_id} issue_identifier=#{identifier}; falling back to agent run")

        dispatch_issue(
          state |> complete_issue(issue_id),
          issue,
          fallback_attempt,
          trace_id,
          nil,
          nil
        )

      _ ->
        Logger.warning("Controller finalizer returned unexpected result for issue_id=#{issue_id} issue_identifier=#{identifier}: #{inspect(result)}")

        state
        |> complete_issue(issue_id)
        |> schedule_issue_retry(
          issue_id,
          fallback_attempt,
          %{
            identifier: identifier,
            trace_id: trace_id,
            error: "controller finalizer returned unexpected result",
            error_class: ErrorClassifier.to_string(:transient),
            delay_type: nil
          }
          |> Map.merge(retry_execution_metadata(running_entry, Map.get(running_entry, :resume_checkpoint)))
        )
    end
  end

  defp handle_controller_finalizer_exit_reason(
         state,
         issue_id,
         running_entry,
         identifier,
         trace_id,
         reason
       ) do
    attempt = next_failure_attempt_from_running(running_entry)
    checkpoint = Map.get(running_entry, :resume_checkpoint)

    Logger.warning("Controller finalizer worker exited for issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{inspect(reason)}")

    state
    |> complete_issue(issue_id)
    |> schedule_issue_retry(
      issue_id,
      attempt,
      %{
        identifier: identifier,
        trace_id: trace_id,
        error: "controller finalizer exited: #{inspect(reason)}",
        error_class: ErrorClassifier.to_string(:transient),
        delay_type: nil,
        resume_checkpoint: checkpoint
      }
      |> Map.merge(retry_execution_metadata(running_entry, checkpoint))
    )
  end

  defp maybe_store_finalizer_checkpoint(state, _issue_id, checkpoint) when not is_map(checkpoint), do: state

  defp maybe_store_finalizer_checkpoint(state, issue_id, checkpoint) do
    if Map.has_key?(state.retry_attempts, issue_id) do
      update_in(state.retry_attempts[issue_id][:resume_checkpoint], fn _ -> checkpoint end)
    else
      state
    end
  end

  defp maybe_dispatch_controller_finalizer(
         %State{} = state,
         %Issue{} = issue,
         attempt,
         trace_id,
         retry_delay_type,
         resume_checkpoint,
         execution_head,
         retry_metadata
       ) do
    eligible_fun = Map.get(state, :controller_finalizer_eligible_fun)

    if is_function(eligible_fun, 2) and eligible_fun.(issue, resume_checkpoint) do
      case dispatch_issue_with_controller_finalizer(
             state,
             issue,
             attempt,
             trace_id,
             retry_delay_type,
             resume_checkpoint,
             execution_head,
             retry_metadata
           ) do
        {:ok, updated_state} -> {:dispatched, updated_state}
        {:error, _reason} -> :not_applicable
      end
    else
      :not_applicable
    end
  end

  defp dispatch_issue_with_controller_finalizer(
         %State{} = state,
         %Issue{} = issue,
         attempt,
         trace_id,
         retry_delay_type,
         resume_checkpoint,
         execution_head,
         retry_metadata
       ) do
    recipient = self()
    finalizer_fun = Map.get(state, :controller_finalizer_fun, &ControllerFinalizer.run/3)

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           result = finalizer_fun.(issue, resume_checkpoint, trace_id: trace_id)
           send(recipient, {:controller_finalizer_result, issue.id, result})
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
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
                thread_id: nil,
                turn_id: nil,
                replacement_of_session_id: retry_metadata_replacement_of_session_id(retry_metadata),
                replacement_session_id: nil,
                codex_account_id: nil,
                worker_kind: :controller_finalizer,
                resume_checkpoint: resume_checkpoint,
                runtime_head_sha: Map.get(execution_head, :runtime_head_sha),
                expected_head_sha: Map.get(execution_head, :expected_head_sha),
                execution_branch: Map.get(execution_head, :execution_branch),
                continuation_reason: checkpoint_continuation_reason(resume_checkpoint),
                resume_mode: checkpoint_resume_mode(resume_checkpoint),
                resume_fallback_reason: checkpoint_resume_fallback_reason(resume_checkpoint),
                issue_token_total: retry_issue_token_total(retry_metadata, resume_checkpoint),
                retry_cost_profile_key: retry_cost_profile_key(retry_metadata, resume_checkpoint),
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

        with_log_metadata(issue_log_metadata(issue.id, issue.identifier, nil, trace_id), fn ->
          Logger.info("Dispatching issue to controller finalizer: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")
        end)

        {:ok,
         %{
           state
           | running: running,
             claimed: MapSet.put(state.claimed, issue.id),
             retry_attempts: Map.delete(state.retry_attempts, issue.id)
         }}

      {:error, reason} ->
        with_log_metadata(issue_log_metadata(issue.id, issue.identifier, nil, trace_id), fn ->
          Logger.warning("Controller finalizer dispatch failed for #{issue_context(issue)}: #{inspect(reason)}")
        end)

        {:error, reason}
    end
  end

  defp dispatch_issue_with_account(
         %State{} = state,
         %Issue{} = issue,
         attempt,
         codex_account,
         trace_id,
         retry_delay_type,
         resume_checkpoint,
         execution_head
       ) do
    retry_metadata = Map.get(execution_head, :retry_metadata, %{})
    recipient = self()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(
             issue,
             recipient,
             attempt: attempt,
             codex_account: codex_account,
             trace_id: trace_id,
             resume_checkpoint: resume_checkpoint,
             cost_profile_key: retry_cost_profile_key(retry_metadata, resume_checkpoint)
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
                thread_id: nil,
                turn_id: nil,
                replacement_of_session_id: retry_metadata_replacement_of_session_id(retry_metadata),
                replacement_session_id: nil,
                codex_account_id: codex_account.id,
                runtime_head_sha: Map.get(execution_head, :runtime_head_sha),
                expected_head_sha: Map.get(execution_head, :expected_head_sha),
                execution_branch: Map.get(execution_head, :execution_branch),
                continuation_reason: checkpoint_continuation_reason(resume_checkpoint),
                resume_mode: checkpoint_resume_mode(resume_checkpoint),
                resume_fallback_reason: checkpoint_resume_fallback_reason(resume_checkpoint),
                issue_token_total: retry_issue_token_total(retry_metadata, resume_checkpoint),
                retry_cost_profile_key: retry_cost_profile_key(retry_metadata, resume_checkpoint),
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

        schedule_issue_retry(
          state,
          issue.id,
          next_attempt,
          %{
            identifier: issue.identifier,
            trace_id: trace_id,
            error: "failed to spawn agent: #{inspect(reason)}",
            error_class: ErrorClassifier.to_string(:transient),
            delay_type: nil,
            resume_checkpoint: resume_checkpoint
          }
          |> Map.merge(retry_execution_metadata(execution_head, resume_checkpoint))
        )
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

    case running_failover_decision(
           state,
           tracked_account_id,
           updated_running_entry,
           account_health_after,
           replacement_account_id
         ) do
      {:preempt, failover_reason} ->
        resume_checkpoint = capture_resume_checkpoint(Map.get(updated_running_entry, :issue), updated_running_entry)
        health_reason = codex_account_health_reason(state, tracked_account_id) || "account became unhealthy"

        decision =
          RetryFailoverDecision.decide(retry_failover_account_unhealthy_signals(health_reason, resume_checkpoint))

        log_retry_failover_decision(
          issue_id,
          Map.get(updated_running_entry, :identifier, issue_id),
          running_entry_session_id(updated_running_entry),
          running_entry_trace_id(updated_running_entry),
          decision
        )

        case decision.selected_action do
          action when action in [:checkpoint_and_failover, :immediate_preemption] ->
            {:failover,
             preempt_running_issue_for_failover(
               state,
               issue_id,
               updated_running_entry,
               %{
                 from_account_id: tracked_account_id,
                 to_account_id: replacement_account_id,
                 account_health_after: account_health_after,
                 health_reason: health_reason,
                 resume_checkpoint: resume_checkpoint,
                 failover_reason: failover_reason,
                 decision: decision
               }
             )}

          _ ->
            {:keep_running, state, updated_running_entry}
        end

      {:drain, reason, safe_signal} ->
        drained_entry =
          mark_failover_drain_decision(
            state,
            issue_id,
            updated_running_entry,
            tracked_account_id,
            replacement_account_id,
            account_health_after,
            reason,
            safe_signal
          )

        {:keep_running, state, drained_entry}

      {:keep_running, _reason} ->
        {:keep_running, state, updated_running_entry}
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

  defp running_failover_decision(
         %State{} = state,
         tracked_account_id,
         running_entry,
         false,
         replacement_account_id
       )
       when is_map(running_entry) and is_binary(tracked_account_id) and is_binary(replacement_account_id) do
    cond do
      Map.get(running_entry, :codex_account_id) != tracked_account_id ->
        {:keep_running, :account_mismatch}

      replacement_account_id == tracked_account_id ->
        {:keep_running, :no_replacement_account}

      unsafe_failover_account_state?(state, tracked_account_id) ->
        {:preempt, :unsafe_account_runtime_state}

      safe_signal = safe_failover_drain_signal(running_entry) ->
        {:drain, :safe_boundary_reached, safe_signal}

      true ->
        {:preempt, :no_safe_drain_signal}
    end
  end

  defp running_failover_decision(_state, _tracked_account_id, _running_entry, _account_health_after, _replacement_account_id),
    do: {:keep_running, :account_healthy_or_no_replacement}

  defp unsafe_failover_account_state?(%State{} = state, account_id) when is_binary(account_id) do
    account = Map.get(state.codex_accounts, account_id, %{})
    runtime_state = Map.get(account, :runtime_state)
    health_reason = Map.get(account, :health_reason) || Map.get(account, :runtime_health_reason) || ""

    runtime_state == :broken or
      (is_binary(health_reason) and String.contains?(String.downcase(health_reason), "auth"))
  end

  defp safe_failover_drain_signal(running_entry) when is_map(running_entry) do
    safe_milestone_signal(running_entry) ||
      safe_phase_signal(running_entry) ||
      active_validation_wait_signal(running_entry) ||
      ready_resume_checkpoint_signal(running_entry) ||
      passed_verification_signal(running_entry) ||
      open_pr_snapshot_signal(running_entry) ||
      ci_wait_signal(running_entry)
  end

  defp safe_milestone_signal(running_entry) do
    safe_milestones = [:code_ready, :validation_running, :pr_opened, :handoff_ready]

    running_entry
    |> Map.get(:pending_milestones, MapSet.new())
    |> normalize_milestone_set()
    |> MapSet.to_list()
    |> RunPhase.sort_milestones()
    |> Enum.find(&(&1 in safe_milestones))
    |> then(fn
      nil -> nil
      milestone -> "pending_milestones:#{RunPhase.milestone_label(milestone)}"
    end)
  end

  defp safe_phase_signal(running_entry) do
    phase = Map.get(running_entry, :run_phase)

    if phase in [:targeted_tests, :verification, :runtime_proof, :full_validate, :waiting_ci, :publishing_pr] do
      "run_phase:#{RunPhase.phase_label(phase)}"
    end
  end

  defp active_validation_wait_signal(running_entry) do
    with "exec_wait" <- normalize_optional_string(Map.get(running_entry, :external_step)),
         validation_bundle_fingerprint
         when is_binary(validation_bundle_fingerprint) and validation_bundle_fingerprint != "" <-
           retry_validation_bundle_fingerprint(running_entry, Map.get(running_entry, :resume_checkpoint)) do
      "active_validation_snapshot:#{validation_bundle_fingerprint}"
    end
  end

  defp ready_resume_checkpoint_signal(running_entry) do
    case Map.get(running_entry, :resume_checkpoint) do
      %{"resume_ready" => true} -> "resume_checkpoint:ready"
      %{resume_ready: true} -> "resume_checkpoint:ready"
      _ -> nil
    end
  end

  defp passed_verification_signal(running_entry) do
    if Map.get(running_entry, :verification_result) in ["passed", :passed] do
      "verification_result:passed"
    end
  end

  defp open_pr_snapshot_signal(running_entry) do
    snapshot = Map.get(running_entry, :latest_pr_snapshot)

    if pr_snapshot_open?(snapshot) and not pr_snapshot_actionable_failure?(snapshot) do
      "latest_pr_snapshot:open"
    end
  end

  defp pr_snapshot_open?(snapshot) when is_map(snapshot) do
    snapshot
    |> map_any(["state", :state])
    |> to_string()
    |> String.upcase()
    |> Kernel.==("OPEN")
  end

  defp pr_snapshot_open?(_snapshot), do: false

  defp pr_snapshot_actionable_failure?(snapshot) when is_map(snapshot) do
    truthy?(map_any(snapshot, ["has_actionable_feedback", :has_actionable_feedback])) or
      truthy?(map_any(snapshot, ["has_failing_checks", :has_failing_checks])) or
      truthy?(map_any(snapshot, ["failed", :failed]))
  end

  defp pr_snapshot_actionable_failure?(_snapshot), do: true

  defp ci_wait_signal(running_entry) do
    result = Map.get(running_entry, :latest_ci_wait_result)

    if ci_wait_result_safe_for_drain?(result) do
      "latest_ci_wait_result:available"
    end
  end

  defp ci_wait_result_safe_for_drain?(result) when is_map(result) do
    all_green = normalize_optional_boolean(map_any(result, ["all_green", :all_green]))
    failed_checks = map_any(result, ["failed_checks", :failed_checks])

    not truthy?(map_any(result, ["failed", :failed])) and
      all_green != false and
      (not is_list(failed_checks) or failed_checks == [])
  end

  defp ci_wait_result_safe_for_drain?(_result), do: false

  defp truthy?(value), do: value in [true, "true", "TRUE", 1, "1"]

  defp map_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      if Map.has_key?(map, key) do
        {:halt, Map.get(map, key)}
      else
        {:cont, nil}
      end
    end)
  end

  defp map_any(_map, _keys), do: nil

  defp mark_failover_drain_decision(
         %State{} = state,
         issue_id,
         running_entry,
         from_account_id,
         to_account_id,
         account_health_after,
         reason,
         safe_signal
       ) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    trace_id = Map.get(running_entry, :trace_id)
    session_id = running_entry_session_id(running_entry)
    health_reason = codex_account_health_reason(state, from_account_id) || "account became unhealthy"

    decision = %{
      disposition: :drain,
      reason: reason,
      safe_signal: safe_signal,
      from_account_id: from_account_id,
      to_account_id: to_account_id,
      health_reason: health_reason
    }

    if Map.get(running_entry, :failover_drain_decision) != decision do
      with_log_metadata(issue_log_metadata(issue_id, identifier, session_id, trace_id), fn ->
        Logger.warning(
          "Failover decision disposition=drain issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} from codex_account_id=#{from_account_id} to codex_account_id=#{to_account_id} health_reason=#{health_reason} previous_health=#{inspect(account_health_after)} safe_boundary_signal=#{safe_signal} reason=#{reason}"
        )
      end)
    end

    Map.put(running_entry, :failover_drain_decision, decision)
  end

  defp preempt_running_issue_for_failover(%State{} = state, issue_id, running_entry, failover_context)
       when is_map(failover_context) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    trace_id = Map.get(running_entry, :trace_id)
    session_id = running_entry_session_id(running_entry)
    attempt = next_failure_attempt_from_running(running_entry)
    from_account_id = Map.get(failover_context, :from_account_id)
    to_account_id = Map.get(failover_context, :to_account_id)
    account_health_after = Map.get(failover_context, :account_health_after)
    health_reason = Map.get(failover_context, :health_reason)
    resume_checkpoint = Map.get(failover_context, :resume_checkpoint)
    failover_reason = Map.get(failover_context, :failover_reason, :no_safe_drain_signal)
    decision = Map.fetch!(failover_context, :decision)

    state =
      state
      |> record_session_completion_totals(running_entry)
      |> Map.put(:running, Map.delete(state.running, issue_id))
      |> Map.put(:retry_attempts, Map.delete(state.retry_attempts, issue_id))

    with_log_metadata(issue_log_metadata(issue_id, identifier, session_id, trace_id), fn ->
      Logger.warning(
        "Failover decision disposition=forced_preemption issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} from codex_account_id=#{from_account_id} to codex_account_id=#{to_account_id} health_reason=#{health_reason} previous_health=#{inspect(account_health_after)} forced_preemption_reason=#{failover_reason} attempt=#{attempt} selected_action=#{decision.selected_action} selected_rule=#{decision.selected_rule}"
      )
    end)

    running_entry
    |> Map.get(:ref)
    |> cancel_running_monitor()

    running_entry
    |> Map.get(:pid)
    |> terminate_task()

    schedule_issue_retry(
      state,
      issue_id,
      attempt,
      %{
        identifier: identifier,
        trace_id: trace_id,
        error: "account failover forced_preemption=#{failover_reason}: #{health_reason}",
        error_class: ErrorClassifier.to_string(:transient),
        delay_type: :failover,
        resume_checkpoint: resume_checkpoint
      }
      |> Map.merge(retry_execution_metadata(running_entry, resume_checkpoint))
      |> Map.merge(retry_failover_metadata(decision))
    )
  end

  defp run_workspace_housekeeping(%State{} = state, source) do
    if should_run_workspace_housekeeping?(state, source) do
      now_ms = System.monotonic_time(:millisecond)

      state
      |> maybe_schedule_workspace_usage_refresh(source)
      |> maybe_schedule_terminal_workspace_cleanup(source)
      |> Map.put(:last_housekeeping_at_ms, now_ms)
    else
      state
    end
  end

  defp should_run_workspace_housekeeping?(%State{} = state, source) do
    source != :poll or active_housekeeping_required?(state) or idle_housekeeping_due?(state)
  end

  defp active_housekeeping_required?(%State{running: running}) when is_map(running) do
    map_size(running) > 0
  end

  defp active_housekeeping_required?(_state), do: false

  defp idle_housekeeping_due?(%State{last_housekeeping_at_ms: nil}), do: true

  defp idle_housekeeping_due?(%State{last_housekeeping_at_ms: last_housekeeping_at_ms})
       when is_integer(last_housekeeping_at_ms) do
    System.monotonic_time(:millisecond) - last_housekeeping_at_ms >= @idle_housekeeping_interval_ms
  end

  defp idle_housekeeping_due?(_state), do: true

  defp maybe_refresh_codex_accounts(%State{} = state, source) do
    case codex_account_refresh_strategy(state, source) do
      :skip -> state
      :full -> refresh_codex_accounts(state)
      :active_only -> refresh_active_codex_account(state)
    end
  end

  defp codex_account_refresh_strategy(%State{} = state, _source) do
    cond do
      codex_account_refresh_required?(state) ->
        :full

      not idle_codex_account_probe_due?(state) ->
        :skip

      idle_codex_account_full_reconcile_due?(state) ->
        :full

      true ->
        :active_only
    end
  end

  defp codex_account_refresh_required?(%State{} = state) do
    orchestration_active?(state) or not active_codex_account_available?(state)
  end

  defp orchestration_active?(%State{running: running, retry_attempts: retry_attempts})
       when is_map(running) and is_map(retry_attempts) do
    map_size(running) > 0 or map_size(retry_attempts) > 0
  end

  defp orchestration_active?(_state), do: false

  defp idle_codex_account_probe_due?(%State{last_codex_account_probe_at_ms: nil}), do: true

  defp idle_codex_account_probe_due?(%State{last_codex_account_probe_at_ms: last_probe_at_ms})
       when is_integer(last_probe_at_ms) do
    System.monotonic_time(:millisecond) - last_probe_at_ms >= @idle_codex_account_probe_interval_ms
  end

  defp idle_codex_account_probe_due?(_state), do: true

  defp idle_codex_account_full_reconcile_due?(%State{
         last_full_codex_account_probe_at_ms: nil
       }),
       do: true

  defp idle_codex_account_full_reconcile_due?(%State{
         last_full_codex_account_probe_at_ms: last_probe_at_ms
       })
       when is_integer(last_probe_at_ms) do
    System.monotonic_time(:millisecond) - last_probe_at_ms >=
      @idle_codex_account_full_reconcile_interval_ms
  end

  defp idle_codex_account_full_reconcile_due?(_state), do: true

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
    busy_issue_ids = busy_issue_ids_for_cleanup(state)
    orchestrator = self()

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        {:workspace_cleanup_completed, source, run_terminal_workspace_cleanup(orchestrator, source, busy_issue_ids)}
      end)

    %{state | workspace_cleanup_ref: task.ref}
  end

  defp run_terminal_workspace_cleanup(orchestrator, source, busy_issue_ids)
       when is_pid(orchestrator) and is_map(busy_issue_ids) do
    keep_recent = workspace_cleanup_keep_recent()
    terminal_cleanup_states = terminal_cleanup_states()
    terminal_states = terminal_state_set()

    case Tracker.fetch_issues_by_states(terminal_cleanup_states) do
      {:ok, issues} ->
        run_revalidated_terminal_workspace_cleanup(
          orchestrator,
          source,
          issues,
          terminal_states,
          busy_issue_ids,
          keep_recent
        )

      {:error, reason} ->
        Logger.warning("Skipping terminal workspace cleanup source=#{source}; failed to fetch terminal issues: #{inspect(reason)}")

        :ok
    end
  end

  defp run_revalidated_terminal_workspace_cleanup(
         orchestrator,
         source,
         issues,
         terminal_states,
         busy_issue_ids,
         keep_recent
       ) do
    case revalidate_terminal_cleanup_issues(issues, terminal_states) do
      {:ok, terminal_issues} ->
        cleanup_revalidated_terminal_issues(
          orchestrator,
          source,
          terminal_issues,
          busy_issue_ids,
          keep_recent
        )

      {:error, reason} ->
        Logger.warning("Skipping terminal workspace cleanup source=#{source}; failed to revalidate terminal issues: #{inspect(reason)}")

        :ok
    end
  end

  defp cleanup_revalidated_terminal_issues(
         orchestrator,
         source,
         terminal_issues,
         busy_issue_ids,
         keep_recent
       ) do
    {kept_issues, removed_issues} =
      Workspace.partition_completed_issues(terminal_issues, keep_recent: keep_recent)

    Enum.each(kept_issues, fn issue ->
      cleanup_terminal_issue_external_artifacts(orchestrator, issue, busy_issue_ids)
    end)

    removed = removed_terminal_issue_identifiers(orchestrator, removed_issues, busy_issue_ids)

    if removed != [] do
      Logger.info("Workspace retention cleanup source=#{source} removed=#{length(removed)} keep_recent=#{keep_recent}")
    end

    :ok
  end

  defp removed_terminal_issue_identifiers(orchestrator, removed_issues, busy_issue_ids) do
    removed_issues
    |> Enum.reduce([], fn issue, acc ->
      case cleanup_terminal_issue_artifacts(orchestrator, issue, busy_issue_ids) do
        {:removed, identifier} -> [identifier | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
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

  defp busy_issue_ids_for_cleanup(%State{} = state) do
    state.running
    |> Map.keys()
    |> Kernel.++(Map.keys(state.retry_attempts))
    |> MapSet.new()
  end

  defp issue_cleanup_busy?(%State{} = state, issue_id) when is_binary(issue_id) do
    Map.has_key?(state.running, issue_id) or Map.has_key?(state.retry_attempts, issue_id)
  end

  defp revalidate_terminal_cleanup_issues(issues, terminal_states)
       when is_list(issues) and is_map(terminal_states) do
    issue_ids =
      issues
      |> Enum.flat_map(fn issue ->
        case terminal_cleanup_issue_id(issue) do
          issue_id when is_binary(issue_id) -> [issue_id]
          _ -> []
        end
      end)
      |> Enum.uniq()

    case issue_ids do
      [] ->
        {:ok, []}

      _ ->
        case Tracker.fetch_issue_states_by_ids(issue_ids) do
          {:ok, issues} ->
            {:ok,
             Enum.filter(issues, fn issue ->
               terminal_issue_state?(terminal_cleanup_issue_state(issue), terminal_states)
             end)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp cleanup_terminal_issue_external_artifacts(orchestrator, issue, busy_issue_ids) do
    if issue_cleanup_busy_now?(orchestrator, terminal_cleanup_issue_id(issue), busy_issue_ids) do
      :skipped
    else
      case terminal_cleanup_issue_identifier(issue) do
        identifier when is_binary(identifier) and identifier != "" ->
          Workspace.cleanup_issue_artifacts(identifier, remove_workspace: false)

        _ ->
          :skipped
      end
    end
  end

  defp cleanup_terminal_issue_artifacts(orchestrator, issue, busy_issue_ids) do
    if issue_cleanup_busy_now?(orchestrator, terminal_cleanup_issue_id(issue), busy_issue_ids) do
      :skipped
    else
      case terminal_cleanup_issue_identifier(issue) do
        identifier when is_binary(identifier) and identifier != "" ->
          cleanup_issue_artifacts(identifier)
          {:removed, identifier}

        _ ->
          :skipped
      end
    end
  end

  defp issue_cleanup_busy_now?(orchestrator, issue_id, busy_issue_ids)
       when is_pid(orchestrator) and is_binary(issue_id) and is_map(busy_issue_ids) do
    GenServer.call(orchestrator, {:issue_cleanup_busy?, issue_id}, 100)
    |> normalize_issue_cleanup_busy_response(issue_id, busy_issue_ids)
  catch
    :exit, _reason ->
      MapSet.member?(busy_issue_ids, issue_id)
  end

  defp issue_cleanup_busy_now?(_orchestrator, issue_id, busy_issue_ids)
       when is_binary(issue_id) and is_map(busy_issue_ids) do
    MapSet.member?(busy_issue_ids, issue_id)
  end

  defp issue_cleanup_busy_now?(_orchestrator, _issue_id, _busy_issue_ids), do: false

  defp normalize_issue_cleanup_busy_response(busy?, _issue_id, _busy_issue_ids)
       when is_boolean(busy?),
       do: busy?

  defp normalize_issue_cleanup_busy_response(_response, issue_id, busy_issue_ids)
       when is_binary(issue_id) and is_map(busy_issue_ids) do
    MapSet.member?(busy_issue_ids, issue_id)
  end

  defp terminal_cleanup_issue_id(%Issue{id: issue_id}) when is_binary(issue_id), do: issue_id
  defp terminal_cleanup_issue_id(%{id: issue_id}) when is_binary(issue_id), do: issue_id
  defp terminal_cleanup_issue_id(%{"id" => issue_id}) when is_binary(issue_id), do: issue_id
  defp terminal_cleanup_issue_id(_issue), do: nil

  defp terminal_cleanup_issue_identifier(%Issue{identifier: identifier})
       when is_binary(identifier),
       do: identifier

  defp terminal_cleanup_issue_identifier(%{identifier: identifier}) when is_binary(identifier),
    do: identifier

  defp terminal_cleanup_issue_identifier(%{"identifier" => identifier}) when is_binary(identifier),
    do: identifier

  defp terminal_cleanup_issue_identifier(_issue), do: nil

  defp terminal_cleanup_issue_state(%Issue{state: state_name}) when is_binary(state_name),
    do: state_name

  defp terminal_cleanup_issue_state(%{state: state_name}) when is_binary(state_name),
    do: state_name

  defp terminal_cleanup_issue_state(%{"state" => state_name}) when is_binary(state_name),
    do: state_name

  defp terminal_cleanup_issue_state(_issue), do: nil

  defp handle_active_retry(state, issue, attempt, metadata) do
    cond do
      not active_codex_account_available?(state) ->
        with_log_metadata(
          issue_log_metadata(
            issue.id,
            issue.identifier,
            retry_metadata_session_id(metadata),
            metadata[:trace_id]
          ),
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
        {:noreply,
         dispatch_issue(
           state,
           issue,
           attempt,
           metadata[:trace_id],
           metadata[:delay_type],
           metadata[:resume_checkpoint],
           metadata
         )}

      true ->
        with_log_metadata(
          issue_log_metadata(
            issue.id,
            issue.identifier,
            retry_metadata_session_id(metadata),
            metadata[:trace_id]
          ),
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

  defp handle_running_entry_exit(
         state,
         issue_id,
         running_entry,
         identifier,
         session_id,
         trace_id,
         reason
       ) do
    case running_entry_worker_kind(running_entry) do
      :controller_finalizer ->
        handle_controller_finalizer_exit_reason(
          state,
          issue_id,
          running_entry,
          identifier,
          trace_id,
          reason
        )

      _ ->
        handle_agent_exit_reason(
          state,
          issue_id,
          running_entry,
          identifier,
          session_id,
          trace_id,
          reason
        )
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
        schedule_failure_retry_or_dedupe_hit(
          state,
          issue,
          failure_attempt,
          %{
            identifier: identifier,
            trace_id: trace_id,
            session_id: context[:session_id],
            thread_id: context[:thread_id],
            turn_id: context[:turn_id],
            replacement_of_session_id: context[:replacement_of_session_id],
            replacement_session_id: context[:replacement_session_id],
            error: "agent exited: #{failure.summary}",
            error_class: error_class_label,
            resume_checkpoint: context[:resume_checkpoint],
            retry_failover_signals:
              retry_failover_account_unhealthy_signals(
                failure.summary,
                context[:resume_checkpoint]
              )
          }
          |> Map.merge(retry_execution_metadata(context, context[:resume_checkpoint]))
        )

      ErrorClassifier.retry_allowed?(failure.error_class, failure_attempt) ->
        schedule_failure_retry_or_dedupe_hit(
          state,
          issue,
          failure_attempt,
          %{
            identifier: identifier,
            trace_id: trace_id,
            session_id: context[:session_id],
            thread_id: context[:thread_id],
            turn_id: context[:turn_id],
            replacement_of_session_id: context[:replacement_of_session_id],
            replacement_session_id: context[:replacement_session_id],
            error: "agent exited: #{failure.summary}",
            error_class: error_class_label,
            resume_checkpoint: context[:resume_checkpoint]
          }
          |> Map.merge(retry_execution_metadata(context, context[:resume_checkpoint]))
        )

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

  defp maybe_enforce_running_budget(%State{} = state, _issue_id, _running_entry, _source),
    do: {:keep_running, state}

  defp running_entry_attempt_tokens(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :codex_total_tokens) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp issue_token_total_before_attempt(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :issue_token_total) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp retry_issue_token_total(retry_metadata, resume_checkpoint)
       when is_map(retry_metadata) do
    case map_any(retry_metadata, [:issue_token_total, "issue_token_total"]) do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> normalize_issue_token_total(value)
      _ -> checkpoint_issue_token_total(resume_checkpoint)
    end
  end

  defp retry_cost_profile_key(retry_metadata, resume_checkpoint)
       when is_map(retry_metadata) do
    normalize_optional_string(map_any(retry_metadata, [:cost_profile_key, "cost_profile_key"])) ||
      checkpoint_cost_profile_key(resume_checkpoint)
  end

  defp retry_cost_profile_key(_retry_metadata, resume_checkpoint),
    do: checkpoint_cost_profile_key(resume_checkpoint)

  defp checkpoint_issue_token_total(%{} = checkpoint) do
    checkpoint
    |> map_any([:issue_token_total, "issue_token_total"])
    |> normalize_issue_token_total()
  end

  defp normalize_issue_token_total(value) when is_integer(value) and value >= 0, do: value

  defp normalize_issue_token_total(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> 0
    end
  end

  defp normalize_issue_token_total(_value), do: 0

  defp checkpoint_cost_profile_key(%{} = checkpoint) do
    normalize_optional_string(map_any(checkpoint, [:cost_profile_key, "cost_profile_key"]))
  end

  defp checkpoint_continuation_reason(%{} = checkpoint) do
    normalize_optional_string(map_any(checkpoint, [:continuation_reason, "continuation_reason"]))
  end

  defp checkpoint_continuation_reason(_checkpoint), do: nil

  defp checkpoint_resume_mode(%{} = checkpoint) do
    normalize_optional_string(map_any(checkpoint, [:resume_mode, "resume_mode"]))
  end

  defp checkpoint_resume_mode(_checkpoint), do: nil

  defp checkpoint_resume_fallback_reason(%{} = checkpoint) do
    normalize_optional_string(map_any(checkpoint, [:resume_fallback_reason, "resume_fallback_reason"]))
  end

  defp checkpoint_resume_fallback_reason(_checkpoint), do: nil

  defp retry_failover_metadata(%RetryFailoverDecision{} = decision) do
    %{
      retry_failover_decision: RetryFailoverDecision.metadata(decision)
    }
    |> Map.merge(decision.retry_metadata)
  end

  defp log_retry_failover_decision(issue_id, identifier, session_id, trace_id, %RetryFailoverDecision{} = decision) do
    metadata =
      issue_log_metadata(issue_id, identifier, session_id, trace_id)
      |> Enum.into(%{})
      |> Map.merge(
        TelemetrySchema.logger_metadata(%{
          retry_failover_decision: RetryFailoverDecision.metadata(decision)
        })
      )
      |> Map.to_list()

    with_log_metadata(metadata, fn ->
      Logger.warning(
        "Retry/failover decision issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id || "n/a"} selected_rule=#{decision.selected_rule} selected_action=#{decision.selected_action} reason=#{inspect(decision.reason)} suppressed_rules=#{inspect(RetryFailoverDecision.suppressed_rule_labels(decision))}"
      )
    end)
  end

  defp retry_failover_account_unhealthy_signals(reason, resume_checkpoint) do
    checkpoint_available = retry_failover_checkpoint_available?(resume_checkpoint)

    %{
      account_unhealthy: %{
        reason: reason,
        retry_metadata: %{},
        log_fields: %{
          checkpoint_available: checkpoint_available
        }
      },
      checkpoint_available: checkpoint_available,
      milestone_near: false,
      unsafe_preemption_required: false
    }
  end

  defp retry_failover_checkpoint_available?(%{"resume_ready" => true}), do: true
  defp retry_failover_checkpoint_available?(%{"available" => true}), do: true
  defp retry_failover_checkpoint_available?(_checkpoint), do: false

  defp schedule_failure_retry_or_dedupe_hit(
         %State{} = state,
         %Issue{id: issue_id} = issue,
         attempt,
         metadata
       )
       when is_binary(issue_id) and is_integer(attempt) and attempt > 0 and is_map(metadata) do
    base_signals = Map.get(metadata, :retry_failover_signals, %{})

    case retry_dedupe_key(metadata) do
      nil ->
        schedule_retry_with_retry_failover_decision(
          state,
          issue,
          attempt,
          metadata,
          RetryFailoverDecision.decide(base_signals)
        )

      key ->
        if Map.get(state.retry_dedupe_keys, issue_id) == key do
          handle_retry_dedupe_hit(state, issue, attempt, metadata, base_signals)
        else
          schedule_retry_with_retry_failover_decision(
            state,
            issue,
            attempt,
            metadata,
            RetryFailoverDecision.decide(base_signals)
          )
          |> remember_retry_dedupe_key(issue_id, key)
        end
    end
  end

  defp schedule_continuation_retry_or_dedupe_hit(
         %State{} = state,
         issue_id,
         %Issue{} = issue,
         attempt,
         metadata
       )
       when is_binary(issue_id) and is_integer(attempt) and attempt > 0 and is_map(metadata) do
    continuation_metadata = Map.put(metadata, :delay_type, :continuation)
    base_signals = Map.get(continuation_metadata, :retry_failover_signals, %{})

    case retry_dedupe_key(continuation_metadata) do
      nil ->
        schedule_issue_retry(state, issue_id, attempt, continuation_metadata)

      key ->
        if Map.get(state.retry_dedupe_keys, issue_id) == key do
          handle_retry_dedupe_hit(state, issue, attempt, continuation_metadata, base_signals)
        else
          state
          |> schedule_issue_retry(issue_id, attempt, continuation_metadata)
          |> remember_retry_dedupe_key(issue_id, key)
        end
    end
  end

  defp schedule_continuation_retry_or_dedupe_hit(
         %State{} = state,
         issue_id,
         _issue,
         attempt,
         metadata
       )
       when is_binary(issue_id) and is_integer(attempt) and attempt > 0 and is_map(metadata) do
    schedule_issue_retry(state, issue_id, attempt, Map.put(metadata, :delay_type, :continuation))
  end

  defp handle_retry_dedupe_hit(state, issue, attempt, metadata, base_signals) do
    issue_id = issue.id
    dedupe_reason = retry_dedupe_reason(metadata)

    decision =
      RetryFailoverDecision.decide(Map.put(base_signals, :retry_dedupe_hit, retry_dedupe_signal(metadata, dedupe_reason)))

    log_retry_failover_decision(
      issue_id,
      issue.identifier,
      retry_metadata_session_id(metadata),
      metadata[:trace_id],
      decision
    )

    escalate_issue_for_retry_failover_handoff(
      state,
      issue,
      decision,
      attempt,
      %{
        issue_id: issue_id,
        identifier: issue.identifier,
        trace_id: metadata[:trace_id],
        codex_account_id: metadata[:codex_account_id],
        error_class: ErrorClassifier.to_string(:permanent),
        failure_class: "retry_dedupe_hit",
        retry_action: :stop,
        resume_checkpoint: metadata[:resume_checkpoint]
      }
    )
  end

  defp retry_dedupe_signal(metadata, dedupe_reason) when is_map(metadata) do
    %{
      reason: dedupe_reason,
      checkpoint_type: "human-action",
      risk_level: "medium",
      log_fields: retry_dedupe_log_fields(metadata)
    }
  end

  defp retry_dedupe_log_fields(metadata) when is_map(metadata) do
    %{
      error_signature: retry_dedupe_error_signature(metadata),
      failure_class: retry_metadata_or_unknown(metadata, :failure_class),
      runtime_head_sha: retry_metadata_or_unknown(metadata, :runtime_head_sha),
      feedback_digest: retry_metadata_or_unknown(metadata, :feedback_digest),
      validation_bundle_fingerprint: retry_metadata_or_unknown(metadata, :validation_bundle_fingerprint),
      workspace_diff_fingerprint: retry_metadata_or_unknown(metadata, :workspace_diff_fingerprint),
      workpad_digest: checkpoint_workpad_digest(metadata[:resume_checkpoint]) || "unknown",
      continuation_reason: retry_metadata_or_unknown(metadata, :continuation_reason)
    }
  end

  defp retry_dedupe_error_signature(metadata) when is_map(metadata) do
    metadata[:error_signature] || normalize_error_signature(metadata[:error]) || "unknown"
  end

  defp retry_metadata_or_unknown(metadata, key) when is_map(metadata) and is_atom(key) do
    case metadata[key] do
      value when is_binary(value) and value != "" -> value
      _ -> "unknown"
    end
  end

  defp retry_metadata_session_id(metadata) when is_map(metadata) do
    session_id =
      normalize_optional_string(metadata[:session_id]) ||
        normalize_optional_string(metadata[:replacement_of_session_id])

    if is_binary(session_id) and session_id != "", do: session_id
  end

  defp retry_metadata_replacement_of_session_id(metadata) when is_map(metadata) do
    normalize_optional_string(metadata[:replacement_of_session_id]) ||
      retry_metadata_session_id(metadata)
  end

  defp schedule_retry_with_retry_failover_decision(
         state,
         %Issue{id: issue_id} = issue,
         attempt,
         metadata,
         %RetryFailoverDecision{} = decision
       ) do
    log_retry_failover_decision(
      issue_id,
      issue.identifier,
      retry_metadata_session_id(metadata),
      metadata[:trace_id],
      decision
    )

    schedule_issue_retry(
      state,
      issue_id,
      attempt,
      metadata
      |> Map.merge(retry_failover_metadata(decision))
    )
  end

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

        schedule_issue_retry(
          state,
          context.issue_id,
          failure_attempt,
          %{
            identifier: context.identifier,
            trace_id: context.trace_id,
            error: "failed to escalate #{context.identifier} to #{intervention_state}: #{inspect(tracker_reason)}",
            error_class: ErrorClassifier.to_string(:transient),
            resume_checkpoint: context[:resume_checkpoint]
          }
          |> Map.merge(retry_execution_metadata(context, context[:resume_checkpoint]))
        )
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

    schedule_issue_retry(
      state,
      context.issue_id,
      failure_attempt,
      %{
        identifier: context.identifier,
        trace_id: context.trace_id,
        error: "failed to escalate #{context.identifier} to #{manual_intervention_state()}: missing issue id",
        error_class: ErrorClassifier.to_string(:transient),
        resume_checkpoint: context[:resume_checkpoint]
      }
      |> Map.merge(retry_execution_metadata(context, context[:resume_checkpoint]))
    )
  end

  defp escalate_issue_for_retry_failover_handoff(
         state,
         %Issue{id: tracker_issue_id},
         %RetryFailoverDecision{} = decision,
         failure_attempt,
         context
       )
       when is_binary(tracker_issue_id) do
    blocker_comment =
      decision_comment_body(
        decision,
        context.identifier,
        context.trace_id,
        %{
          failed_attempt: failure_attempt,
          error_class: context.error_class,
          failure_class: context.failure_class,
          codex_account_id: context.codex_account_id,
          retry_action: context.retry_action
        }
      )

    intervention_state = manual_intervention_state()

    with :ok <- Tracker.create_comment(tracker_issue_id, blocker_comment),
         :ok <- Tracker.update_issue_state(tracker_issue_id, intervention_state) do
      with_log_metadata(
        issue_log_metadata(context.issue_id, context.identifier, nil, context.trace_id),
        fn ->
          Logger.warning(
            "Escalated issue_id=#{context.issue_id} issue_identifier=#{context.identifier} to #{intervention_state} with selected_rule=#{decision.selected_rule} selected_action=#{decision.selected_action} (attempt #{failure_attempt})"
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

        schedule_issue_retry(
          state,
          context.issue_id,
          failure_attempt,
          %{
            identifier: context.identifier,
            trace_id: context.trace_id,
            error: "failed to escalate #{context.identifier} to #{intervention_state}: #{inspect(tracker_reason)}",
            error_class: ErrorClassifier.to_string(:transient),
            resume_checkpoint: context[:resume_checkpoint]
          }
          |> Map.merge(retry_execution_metadata(context, context[:resume_checkpoint]))
          |> Map.merge(retry_failover_metadata(decision))
        )
    end
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

  defp decision_comment_body(%RetryFailoverDecision{} = decision, identifier, trace_id, extra_fields) do
    suppressed_rules =
      case RetryFailoverDecision.suppressed_rule_labels(decision) do
        [] -> "[]"
        rules -> Enum.join(rules, ", ")
      end

    [
      "### Retry/failover decision (auto-classified)",
      "",
      decision_field_line("selected_rule", decision.selected_rule),
      decision_field_line("selected_action", decision.selected_action),
      decision_field_line("checkpoint_type", decision.checkpoint_type),
      decision_field_line("risk_level", decision.risk_level),
      decision_field_line("issue", identifier),
      decision_field_line("trace_id", trace_id),
      decision_field_line("reason", decision.reason),
      decision_field_line("suppressed_rules", suppressed_rules)
    ]
    |> Kernel.++(
      extra_fields
      |> Enum.map(fn {key, value} -> decision_field_line(Atom.to_string(key), value) end)
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp decision_field_line(_label, nil), do: nil
  defp decision_field_line(_label, ""), do: nil
  defp decision_field_line(_label, []), do: nil

  defp decision_field_line(label, value) when is_atom(value) do
    decision_field_line(label, Atom.to_string(value))
  end

  defp decision_field_line(label, value) when is_list(value) do
    decision_field_line(label, Enum.map_join(value, ", ", &to_string/1))
  end

  defp decision_field_line(label, value), do: "- #{label}: `#{value}`"

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        retry_dedupe_keys: Map.delete(state.retry_dedupe_keys, issue_id)
    }
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

  defp continuation_attempt_limit_exceeded?(attempt)
       when is_integer(attempt) and attempt > 0,
       do: attempt > max_continuation_attempts()

  defp continuation_attempt_limit_exceeded?(_attempt), do: false

  defp max_continuation_attempts do
    case Config.settings!().codex.max_continuation_attempts do
      value when is_integer(value) and value > 0 -> value
      _ -> @max_continuation_attempts_default
    end
  end

  defp handle_continuation_attempt_limit_breach(
         %State{} = state,
         continuation_attempt,
         context
       )
       when is_integer(continuation_attempt) and continuation_attempt > 0 and is_map(context) do
    issue_id = Map.get(context, :issue_id)
    issue = Map.get(context, :issue)
    identifier = Map.get(context, :identifier)
    session_id = Map.get(context, :session_id)
    trace_id = Map.get(context, :trace_id)
    continuation_reason = Map.get(context, :continuation_reason)
    codex_account_id = Map.get(context, :codex_account_id)
    resume_checkpoint = Map.get(context, :resume_checkpoint)

    if is_binary(issue_id) do
      identifier = normalize_optional_string(identifier) || issue_id
      max_attempts = max_continuation_attempts()
      normalized_reason = normalize_optional_string(continuation_reason) || "normal_exit"

      decision =
        %RetryFailoverDecision{
          selected_rule: :continuation_attempt_limit_exceeded,
          selected_action: :stop_with_classified_handoff,
          reason: "continuation_attempt_limit_exceeded",
          signals: %{
            continuation_attempt_limit: %{
              active: true,
              reason: "continuation_attempt_limit_exceeded",
              continuation_reason: normalized_reason,
              continuation_attempt: continuation_attempt,
              max_continuation_attempts: max_attempts
            }
          },
          checkpoint_type: "decision",
          risk_level: "medium",
          retry_metadata: %{
            continuation_reason: normalized_reason,
            continuation_attempt: continuation_attempt,
            max_continuation_attempts: max_attempts
          },
          log_fields: %{
            continuation_reason: normalized_reason,
            continuation_attempt: continuation_attempt,
            max_continuation_attempts: max_attempts
          }
        }

      issue_for_handoff =
        case issue do
          %Issue{} = tracker_issue -> tracker_issue
          _ -> %Issue{id: issue_id, identifier: identifier, state: "In Progress"}
        end

      with_log_metadata(issue_log_metadata(issue_id, identifier, session_id, trace_id), fn ->
        Logger.warning(
          "Continuation attempt ceiling reached issue_id=#{issue_id} issue_identifier=#{identifier} continuation_reason=#{normalized_reason} attempt=#{continuation_attempt} max_continuation_attempts=#{max_attempts}; escalating to #{manual_intervention_state()}"
        )
      end)

      log_retry_failover_decision(issue_id, identifier, session_id, trace_id, decision)

      escalate_issue_for_retry_failover_handoff(
        state,
        issue_for_handoff,
        decision,
        continuation_attempt,
        %{
          issue_id: issue_id,
          identifier: identifier,
          trace_id: trace_id,
          codex_account_id: codex_account_id,
          error_class: ErrorClassifier.to_string(:permanent),
          failure_class: "continuation_attempt_limit_exceeded",
          retry_action: :stop,
          resume_checkpoint: resume_checkpoint
        }
      )
    else
      state
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_trace_id(previous_retry, metadata) do
    metadata[:trace_id] || Map.get(previous_retry, :trace_id)
  end

  defp pick_retry_session_id(previous_retry, metadata) do
    pick_retry_optional_string(previous_retry, metadata, :session_id) ||
      pick_retry_optional_string(previous_retry, metadata, :replacement_of_session_id)
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

  defp pick_retry_resume_checkpoint(previous_retry, metadata) do
    checkpoint = metadata[:resume_checkpoint] || Map.get(previous_retry, :resume_checkpoint)

    if is_map(checkpoint), do: ResumeCheckpoint.for_prompt(checkpoint)
  end

  defp pick_retry_runtime_head_sha(previous_retry, metadata) do
    metadata[:runtime_head_sha] || Map.get(previous_retry, :runtime_head_sha)
  end

  defp pick_retry_expected_head_sha(previous_retry, metadata) do
    metadata[:expected_head_sha] || Map.get(previous_retry, :expected_head_sha)
  end

  defp pick_retry_execution_branch(previous_retry, metadata) do
    metadata[:execution_branch] || Map.get(previous_retry, :execution_branch)
  end

  defp pick_retry_error_signature(previous_retry, metadata, error) do
    metadata[:error_signature] ||
      Map.get(previous_retry, :error_signature) ||
      normalize_error_signature(error)
  end

  defp pick_retry_issue_token_total(previous_retry, metadata) do
    case metadata[:issue_token_total] || Map.get(previous_retry, :issue_token_total) do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp pick_retry_optional_string(previous_retry, metadata, key)
       when is_map(previous_retry) and is_map(metadata) and is_atom(key) do
    case metadata[key] || Map.get(previous_retry, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp pick_retry_cost_profile_key(previous_retry, metadata) do
    pick_retry_optional_string(previous_retry, metadata, :cost_profile_key)
  end

  defp pick_retry_feedback_digest(previous_retry, metadata) do
    metadata[:feedback_digest] || Map.get(previous_retry, :feedback_digest)
  end

  defp pick_retry_failure_class(previous_retry, metadata) do
    case metadata[:failure_class] || Map.get(previous_retry, :failure_class) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp pick_retry_validation_bundle_fingerprint(previous_retry, metadata) do
    case metadata[:validation_bundle_fingerprint] ||
           Map.get(previous_retry, :validation_bundle_fingerprint) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp pick_retry_workspace_diff_fingerprint(previous_retry, metadata) do
    case metadata[:workspace_diff_fingerprint] ||
           Map.get(previous_retry, :workspace_diff_fingerprint) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp pick_retry_failover_decision(previous_retry, metadata) do
    case metadata[:retry_failover_decision] || Map.get(previous_retry, :retry_failover_decision) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp retry_execution_metadata(source, resume_checkpoint)
       when is_map(source) and (is_map(resume_checkpoint) or is_nil(resume_checkpoint)) do
    checkpoint_routing_payload = TelemetrySchema.runtime_payload(resume_checkpoint || %{})

    %{}
    |> maybe_put_retry_metadata(
      :cost_profile_key,
      retry_routing_field(source, checkpoint_routing_payload, :cost_profile_key)
    )
    |> maybe_put_retry_metadata(
      :cost_profile_reason,
      retry_routing_field(source, checkpoint_routing_payload, :cost_profile_reason)
    )
    |> maybe_put_retry_metadata(
      :cost_stage,
      retry_routing_field(source, checkpoint_routing_payload, :cost_stage)
    )
    |> maybe_put_retry_metadata(
      :command_source,
      retry_routing_field(source, checkpoint_routing_payload, :command_source)
    )
    |> maybe_put_retry_metadata(
      :codex_model,
      retry_routing_field(source, checkpoint_routing_payload, :codex_model)
    )
    |> maybe_put_retry_metadata(
      :codex_effort,
      retry_routing_field(source, checkpoint_routing_payload, :codex_effort)
    )
    |> maybe_put_retry_metadata(
      :observed_model,
      retry_routing_field(source, checkpoint_routing_payload, :observed_model)
    )
    |> maybe_put_retry_metadata(
      :observed_effort,
      retry_routing_field(source, checkpoint_routing_payload, :observed_effort)
    )
    |> maybe_put_retry_metadata(
      :observed_signal_source,
      retry_routing_field(source, checkpoint_routing_payload, :observed_signal_source)
    )
    |> maybe_put_retry_metadata(
      :routing_parity_status,
      retry_routing_field(source, checkpoint_routing_payload, :routing_parity_status)
    )
    |> maybe_put_retry_metadata(
      :routing_parity_reason,
      retry_routing_field(source, checkpoint_routing_payload, :routing_parity_reason)
    )
    |> maybe_put_retry_metadata(:session_id, retry_session_id(source))
    |> maybe_put_retry_metadata(:thread_id, retry_thread_id(source))
    |> maybe_put_retry_metadata(:turn_id, retry_turn_id(source))
    |> maybe_put_retry_metadata(
      :replacement_of_session_id,
      retry_replacement_of_session_id(source)
    )
    |> maybe_put_retry_metadata(:replacement_session_id, retry_replacement_session_id(source))
    |> maybe_put_retry_metadata(:continuation_reason, retry_continuation_reason(source, resume_checkpoint))
    |> maybe_put_retry_metadata(:resume_mode, retry_resume_mode(source, resume_checkpoint))
    |> maybe_put_retry_metadata(
      :resume_fallback_reason,
      retry_resume_fallback_reason(source, resume_checkpoint)
    )
    |> maybe_put_retry_metadata(:runtime_head_sha, retry_runtime_head_sha(source, resume_checkpoint))
    |> maybe_put_retry_metadata(:expected_head_sha, Map.get(source, :expected_head_sha))
    |> maybe_put_retry_metadata(:execution_branch, Map.get(source, :execution_branch))
    |> maybe_put_retry_metadata(:feedback_digest, retry_feedback_digest(source, resume_checkpoint))
    |> maybe_put_retry_metadata(:failure_class, Map.get(source, :failure_class))
    |> maybe_put_retry_metadata(
      :validation_bundle_fingerprint,
      retry_validation_bundle_fingerprint(source, resume_checkpoint)
    )
    |> maybe_put_retry_metadata(
      :workspace_diff_fingerprint,
      retry_workspace_diff_fingerprint(source, resume_checkpoint)
    )
  end

  defp retry_execution_metadata(_source, _resume_checkpoint), do: %{}

  defp retry_routing_field(source, checkpoint_routing_payload, key)
       when is_map(source) and is_map(checkpoint_routing_payload) and is_atom(key) do
    key_string = Atom.to_string(key)

    normalize_optional_string(map_any(source, [key, key_string])) ||
      normalize_optional_string(Map.get(checkpoint_routing_payload, key_string))
  end

  defp retry_routing_field(source, _checkpoint_routing_payload, key)
       when is_map(source) and is_atom(key) do
    normalize_optional_string(map_any(source, [key, Atom.to_string(key)]))
  end

  defp retry_runtime_head_sha(source, resume_checkpoint) when is_map(source) do
    case Map.get(source, :runtime_head_sha) do
      "unknown" -> checkpoint_head(resume_checkpoint) || "unknown"
      value when is_binary(value) and value != "" -> value
      _ -> checkpoint_head(resume_checkpoint)
    end
  end

  defp retry_session_id(source) when is_map(source) do
    source
    |> map_any([:session_id, "session_id"])
    |> normalize_optional_string()
  end

  defp retry_thread_id(source) when is_map(source) do
    source
    |> map_any([:thread_id, "thread_id"])
    |> normalize_optional_string()
  end

  defp retry_turn_id(source) when is_map(source) do
    case map_any(source, [:turn_id, "turn_id"]) do
      turn_id when is_binary(turn_id) -> normalize_optional_string(turn_id)
      turn_id when is_integer(turn_id) -> Integer.to_string(turn_id)
      _ -> nil
    end
  end

  defp retry_replacement_of_session_id(source) when is_map(source) do
    source
    |> map_any([:replacement_of_session_id, "replacement_of_session_id"])
    |> normalize_optional_string()
    |> Kernel.||(retry_session_id(source))
  end

  defp retry_replacement_session_id(source) when is_map(source) do
    source
    |> map_any([:replacement_session_id, "replacement_session_id"])
    |> normalize_optional_string()
  end

  defp retry_continuation_reason(source, resume_checkpoint) when is_map(source) do
    normalize_optional_string(map_any(source, [:continuation_reason, "continuation_reason"])) ||
      checkpoint_continuation_reason(resume_checkpoint)
  end

  defp retry_resume_mode(source, resume_checkpoint) when is_map(source) do
    normalize_optional_string(map_any(source, [:resume_mode, "resume_mode"])) ||
      checkpoint_resume_mode(resume_checkpoint)
  end

  defp retry_resume_fallback_reason(source, resume_checkpoint) when is_map(source) do
    normalize_optional_string(map_any(source, [:resume_fallback_reason, "resume_fallback_reason"])) ||
      checkpoint_resume_fallback_reason(resume_checkpoint)
  end

  defp maybe_put_retry_metadata(metadata, _key, value)
       when not is_binary(value) or value == "",
       do: metadata

  defp maybe_put_retry_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp checkpoint_head(%{"head" => head}) when is_binary(head) and head != "", do: head
  defp checkpoint_head(_resume_checkpoint), do: nil

  defp checkpoint_workpad_digest(%{"workpad_digest" => workpad_digest})
       when is_binary(workpad_digest) and workpad_digest != "",
       do: workpad_digest

  defp checkpoint_workpad_digest(_resume_checkpoint), do: nil

  defp checkpoint_feedback_digest(%{"feedback_digest" => feedback_digest})
       when is_binary(feedback_digest) and feedback_digest != "",
       do: feedback_digest

  defp checkpoint_feedback_digest(_resume_checkpoint), do: nil

  defp retry_feedback_digest(source, resume_checkpoint) when is_map(source) do
    case Map.get(source, :feedback_digest) do
      value when is_binary(value) and value != "" -> value
      _ -> checkpoint_feedback_digest(resume_checkpoint)
    end
  end

  defp retry_validation_bundle_fingerprint(source, resume_checkpoint)
       when is_map(source) and (is_map(resume_checkpoint) or is_nil(resume_checkpoint)) do
    case Map.get(source, :validation_bundle_fingerprint) || Map.get(source, "validation_bundle_fingerprint") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        active_validation_bundle_fingerprint(source) ||
          source
          |> Map.get(:current_command)
          |> validation_bundle_fingerprint_from_command() ||
          checkpoint_active_validation_bundle_fingerprint(resume_checkpoint)
    end
  end

  defp retry_workspace_diff_fingerprint(source, resume_checkpoint) when is_map(source) do
    case Map.get(source, :workspace_diff_fingerprint) || Map.get(source, "workspace_diff_fingerprint") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        checkpoint_workspace_diff_fingerprint(resume_checkpoint)
    end
  end

  defp normalize_error_signature(value) when is_binary(value) do
    downcased = String.downcase(value)

    normalized =
      if Regex.match?(~r/stalled\s+for\s+\d+ms\s+without\s+codex\s+activity/u, downcased) do
        "stalled_without_codex_activity"
      else
        downcased
        |> String.replace(~r/[^a-z0-9]+/u, "_")
        |> String.trim("_")
      end

    case normalized do
      "" -> nil
      normalized -> String.slice(normalized, 0, 120)
    end
  end

  defp normalize_error_signature(_value), do: nil

  defp retry_dedupe_key(metadata) when is_map(metadata) do
    if metadata[:delay_type] == :continuation,
      do: continuation_retry_dedupe_key(metadata),
      else: validation_retry_dedupe_key(metadata) || generic_retry_dedupe_key(metadata)
  end

  defp retry_dedupe_reason(metadata) when is_map(metadata) do
    if metadata[:delay_type] == :continuation,
      do: continuation_retry_dedupe_reason(metadata),
      else: failure_retry_dedupe_reason(metadata)
  end

  defp continuation_retry_dedupe_key(metadata) when is_map(metadata) do
    metadata
    |> continuation_retry_surface()
    |> continuation_retry_surface_key()
  end

  defp continuation_retry_dedupe_reason(metadata) when is_map(metadata) do
    surface = continuation_retry_surface(metadata)

    "retry_dedupe_hit: identical continuation retry surface repeated after one queued retry (continuation_reason=#{surface.continuation_reason} runtime_head_sha=#{surface.runtime_head_sha} workspace_diff_fingerprint=#{surface.workspace_diff_fingerprint || "none"} workpad_digest=#{surface.workpad_digest || "none"} validation_bundle_fingerprint=#{surface.validation_bundle_fingerprint} feedback_digest=#{surface.feedback_digest})"
  end

  defp failure_retry_dedupe_reason(metadata) when is_map(metadata) do
    error_signature = metadata[:error_signature] || normalize_error_signature(metadata[:error]) || "unknown"
    failure_class = normalize_optional_string(metadata[:failure_class]) || "unknown"
    validation_bundle_fingerprint = normalize_optional_string(metadata[:validation_bundle_fingerprint])
    workspace_diff_fingerprint = normalize_optional_string(metadata[:workspace_diff_fingerprint])
    runtime_head_sha = metadata[:runtime_head_sha] || "unknown"
    feedback_digest = metadata[:feedback_digest] || "unknown"

    if validation_bundle_fingerprint && workspace_diff_fingerprint do
      "retry_dedupe_hit: identical validation retry surface repeated after one queued retry (error_signature=#{error_signature} failure_class=#{failure_class} validation_bundle_fingerprint=#{validation_bundle_fingerprint} workspace_diff_fingerprint=#{workspace_diff_fingerprint} feedback_digest=#{feedback_digest})"
    else
      "retry_dedupe_hit: identical failure surface repeated after one queued retry (error_signature=#{error_signature} runtime_head_sha=#{runtime_head_sha} feedback_digest=#{feedback_digest})"
    end
  end

  defp continuation_retry_surface(metadata) when is_map(metadata) do
    %{
      continuation_reason:
        normalize_optional_string(metadata[:continuation_reason]) ||
          checkpoint_continuation_reason(metadata[:resume_checkpoint]) ||
          "normal_exit",
      runtime_head_sha:
        normalize_optional_string(metadata[:runtime_head_sha]) ||
          checkpoint_head(metadata[:resume_checkpoint]),
      workspace_diff_fingerprint:
        normalize_optional_string(metadata[:workspace_diff_fingerprint]) ||
          checkpoint_workspace_diff_fingerprint(metadata[:resume_checkpoint]),
      workpad_digest: checkpoint_workpad_digest(metadata[:resume_checkpoint]),
      validation_bundle_fingerprint:
        normalize_optional_string(metadata[:validation_bundle_fingerprint]) ||
          checkpoint_active_validation_bundle_fingerprint(metadata[:resume_checkpoint]) ||
          "none",
      feedback_digest:
        normalize_optional_string(metadata[:feedback_digest]) ||
          checkpoint_feedback_digest(metadata[:resume_checkpoint]) ||
          "none"
    }
  end

  defp continuation_retry_surface_key(%{
         continuation_reason: continuation_reason,
         runtime_head_sha: runtime_head_sha,
         workspace_diff_fingerprint: workspace_diff_fingerprint,
         workpad_digest: workpad_digest,
         validation_bundle_fingerprint: validation_bundle_fingerprint,
         feedback_digest: feedback_digest
       })
       when is_binary(runtime_head_sha) and
              (is_binary(workspace_diff_fingerprint) or is_binary(workpad_digest)) do
    [
      "continuation",
      continuation_reason,
      runtime_head_sha,
      workspace_diff_fingerprint || "none",
      workpad_digest || "none",
      validation_bundle_fingerprint,
      feedback_digest
    ]
    |> Enum.join("::")
  end

  defp continuation_retry_surface_key(_surface), do: nil

  defp validation_retry_dedupe_key(metadata) when is_map(metadata) do
    with error_signature when is_binary(error_signature) and error_signature != "" <-
           metadata[:error_signature] || normalize_error_signature(metadata[:error]),
         validation_bundle_fingerprint
         when is_binary(validation_bundle_fingerprint) and validation_bundle_fingerprint != "" <-
           metadata[:validation_bundle_fingerprint],
         workspace_diff_fingerprint
         when is_binary(workspace_diff_fingerprint) and workspace_diff_fingerprint != "" <-
           metadata[:workspace_diff_fingerprint] do
      failure_class = normalize_optional_string(metadata[:failure_class])
      feedback_digest = normalize_optional_string(metadata[:feedback_digest])

      [
        "validation",
        error_signature,
        failure_class || "unknown",
        validation_bundle_fingerprint,
        workspace_diff_fingerprint,
        feedback_digest || "none"
      ]
      |> Enum.join("::")
    else
      _ -> nil
    end
  end

  defp generic_retry_dedupe_key(metadata) when is_map(metadata) do
    with error_signature when is_binary(error_signature) and error_signature != "" <-
           metadata[:error_signature] || normalize_error_signature(metadata[:error]),
         runtime_head_sha when is_binary(runtime_head_sha) and runtime_head_sha != "" <-
           metadata[:runtime_head_sha],
         feedback_digest when is_binary(feedback_digest) and feedback_digest != "" <-
           metadata[:feedback_digest] do
      Enum.join(["generic", error_signature, runtime_head_sha, feedback_digest], "::")
    else
      _ -> nil
    end
  end

  defp validation_bundle_fingerprint_from_command(command) when is_binary(command) do
    normalized =
      command
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\s+/, " ")

    if normalized == "" do
      nil
    else
      [
        {~r/^mix test(\s|$)/, "validation:test"},
        {~r/^make test(\s|$)/, "validation:test"},
        {~r/^make symphony-validate(\s|$)/, "validation:repo-validate"},
        {~r/^make symphony-preflight(\s|$)/, "validation:preflight"},
        {~r/^make symphony-handoff-check(\s|$)/, "validation:handoff-check"},
        {~r/^mix specs\.check(\s|$)/, "validation:specs-check"},
        {~r/^mix dialyzer(\s|$)/, "validation:dialyzer"}
      ]
      |> Enum.find_value(fn {pattern, fingerprint} ->
        Regex.match?(pattern, normalized) && fingerprint
      end)
    end
  end

  defp validation_bundle_fingerprint_from_command(_command), do: nil

  defp active_validation_bundle_fingerprint(%{} = source) do
    source
    |> Map.get(:active_validation_snapshot, Map.get(source, "active_validation_snapshot"))
    |> active_validation_snapshot_bundle()
  end

  defp checkpoint_active_validation_bundle_fingerprint(%{} = resume_checkpoint) do
    resume_checkpoint
    |> Map.get("active_validation_snapshot", Map.get(resume_checkpoint, :active_validation_snapshot))
    |> active_validation_snapshot_bundle()
  end

  defp checkpoint_active_validation_bundle_fingerprint(_resume_checkpoint), do: nil

  defp active_validation_snapshot_bundle(%{} = snapshot) do
    case Map.get(snapshot, "validation_bundle_fingerprint") || Map.get(snapshot, :validation_bundle_fingerprint) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp active_validation_snapshot_bundle(_snapshot), do: nil

  defp checkpoint_workspace_diff_fingerprint(%{} = resume_checkpoint) do
    case Map.get(resume_checkpoint, "workspace_diff_fingerprint") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        checkpoint_workspace_diff_fallback_fingerprint(resume_checkpoint)
    end
  end

  defp checkpoint_workspace_diff_fingerprint(_resume_checkpoint), do: nil

  defp checkpoint_workspace_diff_fallback_fingerprint(%{} = resume_checkpoint) do
    head = normalize_optional_string(Map.get(resume_checkpoint, "head"))
    workpad_digest = normalize_optional_string(Map.get(resume_checkpoint, "workpad_digest"))
    changed_files = normalize_checkpoint_changed_files(Map.get(resume_checkpoint, "changed_files"))

    if is_binary(head) or is_binary(workpad_digest) or changed_files != [] do
      digest_source =
        ["head=#{head || "none"}", "workpad_digest=#{workpad_digest || "none"}"] ++
          Enum.map(changed_files, &"changed_file=#{&1}")

      digest_source
      |> Enum.join("\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defp normalize_checkpoint_changed_files(files) when is_list(files) do
    files
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_checkpoint_changed_files(_files), do: []

  defp remember_retry_dedupe_key(%State{} = state, issue_id, key)
       when is_binary(issue_id) and is_binary(key) do
    %{state | retry_dedupe_keys: Map.put(state.retry_dedupe_keys, issue_id, key)}
  end

  defp capture_execution_head(issue, retry_delay_type, resume_checkpoint) do
    workspace = issue_workspace_path(issue)
    runtime_head_sha = resolve_runtime_head_sha(workspace) || "unknown"
    execution_branch = resolve_execution_branch(workspace)

    expected_head_sha =
      dispatch_expected_head_sha(workspace, execution_branch, retry_delay_type, resume_checkpoint) ||
        "unknown"

    %{
      workspace: workspace,
      runtime_head_sha: runtime_head_sha,
      expected_head_sha: expected_head_sha,
      execution_branch: execution_branch
    }
  end

  defp dispatch_expected_head_sha(workspace, execution_branch, _retry_delay_type, resume_checkpoint) do
    resolve_expected_head_sha(workspace, execution_branch) || checkpoint_head(resume_checkpoint)
  end

  defp block_stale_workspace_head(
         %State{} = state,
         %Issue{} = issue,
         attempt,
         trace_id,
         resume_checkpoint,
         execution_head,
         stale_reason
       ) do
    reason = stale_workspace_head_reason(execution_head, stale_reason)
    failure_attempt = dispatch_failure_attempt(attempt)

    decision =
      RetryFailoverDecision.decide(%{
        stale_workspace_head: %{
          reason: reason,
          checkpoint_type: "human-action",
          risk_level: "high",
          log_fields: %{
            runtime_head_sha: Map.get(execution_head, :runtime_head_sha),
            expected_head_sha: Map.get(execution_head, :expected_head_sha),
            execution_branch: Map.get(execution_head, :execution_branch)
          }
        }
      })

    with_log_metadata(issue_log_metadata(issue.id, issue.identifier, nil, trace_id), fn ->
      Logger.warning("Blocking stale workspace head before dispatch for #{issue_context(issue)}: #{reason}")
    end)

    log_retry_failover_decision(issue.id, issue.identifier, nil, trace_id, decision)

    escalate_issue_for_retry_failover_handoff(
      state,
      issue,
      decision,
      failure_attempt,
      %{
        issue_id: issue.id,
        identifier: issue.identifier,
        trace_id: trace_id,
        codex_account_id: nil,
        error_class: ErrorClassifier.to_string(:permanent),
        failure_class: "stale_workspace_head",
        retry_action: :stop,
        resume_checkpoint: resume_checkpoint
      }
      |> Map.merge(retry_execution_metadata(execution_head, resume_checkpoint))
    )
  end

  defp stale_execution_head_reason(%{
         workspace: workspace,
         runtime_head_sha: runtime_head_sha,
         expected_head_sha: expected_head_sha
       }) do
    cond do
      not known_git_sha?(runtime_head_sha) or not known_git_sha?(expected_head_sha) ->
        nil

      runtime_head_sha == expected_head_sha ->
        nil

      git_status_success?(workspace, ["merge-base", "--is-ancestor", runtime_head_sha, expected_head_sha]) ->
        :behind

      true ->
        :known_mismatch_non_behind
    end
  end

  defp stale_workspace_head_reason(execution_head, stale_reason) do
    branch_suffix =
      case Map.get(execution_head, :execution_branch) do
        branch when is_binary(branch) and branch != "" -> " on #{branch}"
        _ -> ""
      end

    case stale_reason do
      :behind ->
        "stale_workspace_head: reason=behind runtime #{Map.get(execution_head, :runtime_head_sha)} is behind expected #{Map.get(execution_head, :expected_head_sha)}#{branch_suffix}"

      :known_mismatch_non_behind ->
        "stale_workspace_head: reason=known_mismatch_non_behind runtime #{Map.get(execution_head, :runtime_head_sha)} mismatches expected #{Map.get(execution_head, :expected_head_sha)}#{branch_suffix}"
    end
  end

  defp dispatch_failure_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp dispatch_failure_attempt(_attempt), do: 1

  defp issue_workspace_path(%Issue{identifier: identifier}), do: issue_workspace_path(%{identifier: identifier})

  defp issue_workspace_path(%{identifier: identifier}) when is_binary(identifier) and identifier != "" do
    safe_identifier = String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
    Path.expand(Path.join(Config.settings!().workspace.root, safe_identifier))
  end

  defp issue_workspace_path(_issue), do: nil

  defp resolve_runtime_head_sha(workspace), do: git_trimmed(workspace, ["rev-parse", "HEAD"])

  defp resolve_execution_branch(workspace) when is_binary(workspace) do
    read_trimmed(Path.join(workspace, ".symphony-working-branch")) ||
      read_trimmed(Path.join(workspace, ".symphony-base-branch"))
  end

  defp resolve_execution_branch(_workspace), do: nil

  defp resolve_expected_head_sha(workspace, execution_branch)
       when is_binary(workspace) and is_binary(execution_branch) and execution_branch != "" do
    [
      "refs/remotes/origin/#{execution_branch}",
      "origin/#{execution_branch}",
      "refs/heads/#{execution_branch}",
      execution_branch
    ]
    |> Enum.find_value(&git_trimmed(workspace, ["rev-parse", &1]))
  end

  defp resolve_expected_head_sha(_workspace, _execution_branch), do: nil

  defp git_trimmed(workspace, args) when is_binary(workspace) and is_list(args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp git_trimmed(_workspace, _args), do: nil

  defp git_status_success?(workspace, args) when is_binary(workspace) and is_list(args) do
    match?({_output, 0}, System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true))
  end

  defp git_status_success?(_workspace, _args), do: false

  defp read_trimmed(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        case String.trim(body) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp known_git_sha?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{7,40}$/)
  end

  defp known_git_sha?(_value), do: false

  defp capture_resume_checkpoint(%Issue{} = issue, running_entry) when is_map(running_entry) do
    ResumeCheckpoint.capture(issue, running_entry)
  rescue
    error ->
      ResumeCheckpoint.for_prompt(%{
        "fallback_reasons" => ["resume checkpoint capture failed: #{Exception.message(error)}"]
      })
  end

  defp capture_resume_checkpoint(_issue, _running_entry), do: ResumeCheckpoint.for_prompt(nil)

  defp resolve_resume_checkpoint(%Issue{} = issue, checkpoint) when is_map(checkpoint) do
    checkpoint
    |> ResumeCheckpoint.for_prompt()
    |> merge_loaded_resume_checkpoint(issue)
  end

  defp resolve_resume_checkpoint(%Issue{} = issue, _checkpoint) do
    issue
    |> ResumeCheckpoint.load()
    |> ResumeCheckpoint.for_prompt()
  end

  defp merge_loaded_resume_checkpoint(%{} = provided, %Issue{} = issue) do
    provided = ResumeCheckpoint.for_prompt(provided)
    loaded = issue |> ResumeCheckpoint.load() |> ResumeCheckpoint.for_prompt()
    loaded_reasons = if loaded["available"] == true, do: Map.get(loaded, "fallback_reasons", []), else: []

    cond do
      loaded["resume_ready"] == true and provided["resume_ready"] != true ->
        loaded

      loaded_reasons == [] ->
        provided

      true ->
        provided
        |> Map.update("fallback_reasons", loaded_reasons, fn reasons ->
          (reasons || []) ++ loaded_reasons
        end)
        |> ResumeCheckpoint.for_prompt()
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

  defp running_entry_worker_kind(%{worker_kind: worker_kind}) when worker_kind in [:agent, :controller_finalizer],
    do: worker_kind

  defp running_entry_worker_kind(_running_entry), do: :agent

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
  def handle_call({:issue_cleanup_busy?, issue_id}, _from, state) when is_binary(issue_id) do
    {:reply, issue_cleanup_busy?(state, issue_id), state}
  end

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
          thread_id: Map.get(metadata, :thread_id),
          turn_id: Map.get(metadata, :turn_id),
          replacement_of_session_id: Map.get(metadata, :replacement_of_session_id),
          replacement_session_id: Map.get(metadata, :replacement_session_id),
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          verification_profile: Map.get(metadata, :verification_profile),
          verification_result: Map.get(metadata, :verification_result),
          verification_summary: Map.get(metadata, :verification_summary),
          verification_missing_items: Map.get(metadata, :verification_missing_items, []),
          verification_checked_at: Map.get(metadata, :verification_checked_at),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
        |> Map.merge(runtime_fields)
        |> TelemetrySchema.put_runtime_payload(metadata)
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
          session_id: Map.get(retry, :session_id),
          thread_id: Map.get(retry, :thread_id),
          turn_id: Map.get(retry, :turn_id),
          replacement_of_session_id: Map.get(retry, :replacement_of_session_id),
          replacement_session_id: Map.get(retry, :replacement_session_id),
          error: Map.get(retry, :error),
          error_class: Map.get(retry, :error_class)
        }
        |> TelemetrySchema.put_runtime_payload(retry)
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       active_codex_account_id: state.active_codex_account_id,
       codex_accounts: snapshot_codex_accounts(state),
       codex_totals: state.codex_totals,
       token_reason_totals: normalize_token_reason_totals(state.codex_token_reason_totals),
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

    state =
      state
      |> Map.put(:last_codex_account_probe_at_ms, nil)
      |> Map.put(:last_full_codex_account_probe_at_ms, nil)
      |> then(fn state ->
        if coalesced, do: state, else: schedule_tick(state, 0)
      end)

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
        thread_id: thread_id_for_update(Map.get(running_entry, :thread_id), update),
        turn_id: turn_id_for_update(Map.get(running_entry, :turn_id), update),
        replacement_of_session_id:
          replacement_of_session_id_for_update(
            Map.get(running_entry, :replacement_of_session_id),
            running_entry.session_id,
            update
          ),
        replacement_session_id:
          replacement_session_id_for_update(
            Map.get(running_entry, :replacement_session_id),
            update
          ),
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
      |> apply_routing_update(update)
      |> apply_verification_update(update)
      |> apply_pr_context_update(update)
      |> RunPhase.apply_update(update)

    {updated_running_entry, token_delta}
  end

  defp apply_routing_update(running_entry, update) when is_map(running_entry) and is_map(update) do
    running_entry
    |> merge_present_metadata(routing_intended_fields(update))
    |> merge_present_metadata(routing_observed_fields(update))
    |> apply_routing_parity()
  end

  defp apply_routing_update(running_entry, _update), do: running_entry

  defp routing_intended_fields(update) when is_map(update) do
    %{
      cost_profile_key: normalize_optional_string(map_any(update, [:cost_profile_key, "cost_profile_key"])),
      cost_profile_reason: normalize_optional_string(map_any(update, [:cost_profile_reason, "cost_profile_reason"])),
      cost_stage: normalize_optional_string(map_any(update, [:cost_stage, "cost_stage"])),
      cost_signals: normalize_cost_signals(map_any(update, [:cost_signals, "cost_signals"])),
      codex_model: normalize_optional_string(map_any(update, [:codex_model, "codex_model"])),
      codex_effort: normalize_optional_string(map_any(update, [:codex_effort, "codex_effort"])),
      command_source: normalize_optional_string(map_any(update, [:command_source, "command_source"]))
    }
  end

  defp routing_observed_fields(update) when is_map(update) do
    explicit_fields = explicit_observed_fields(update)

    if explicit_fields == %{} do
      observed_fields_from_sources([
        {"payload", map_any(update, [:payload, "payload"])},
        {"usage", map_any(update, [:usage, "usage"])},
        {"update", update}
      ])
    else
      explicit_fields
    end
  end

  defp explicit_observed_fields(update) when is_map(update) do
    explicit_model = normalize_optional_string(map_any(update, [:observed_model, "observed_model"]))
    explicit_effort = normalize_optional_string(map_any(update, [:observed_effort, "observed_effort"]))

    explicit_source =
      normalize_optional_string(map_any(update, [:observed_signal_source, "observed_signal_source"]))

    case {explicit_model, explicit_effort} do
      {nil, nil} ->
        %{}

      _ ->
        %{
          observed_model: explicit_model,
          observed_effort: explicit_effort,
          observed_signal_source: explicit_source || "update"
        }
    end
  end

  defp observed_fields_from_sources(sources) when is_list(sources) do
    Enum.find_value(sources, %{}, &observed_fields_from_source/1)
  end

  defp observed_fields_from_source({source, value}) when is_binary(source) and is_map(value) do
    model = observed_model_from_source(value)
    effort = observed_effort_from_source(value)

    case {model, effort} do
      {nil, nil} ->
        nil

      _ ->
        %{
          observed_model: model,
          observed_effort: effort,
          observed_signal_source: source
        }
    end
  end

  defp observed_fields_from_source(_source), do: nil

  defp observed_model_from_source(source) when is_map(source) do
    observed_value_at_paths(source, [
      ["model"],
      [:model],
      ["model_slug"],
      [:model_slug],
      ["modelName"],
      [:modelName],
      ["params", "model"],
      [:params, :model],
      ["params", "msg", "model"],
      [:params, :msg, :model],
      ["params", "msg", "info", "model"],
      [:params, :msg, :info, :model],
      ["params", "usage", "model"],
      [:params, :usage, :model],
      ["usage", "model"],
      [:usage, :model]
    ])
  end

  defp observed_effort_from_source(source) when is_map(source) do
    observed_value_at_paths(source, [
      ["effort"],
      [:effort],
      ["reasoning_effort"],
      [:reasoning_effort],
      ["model_reasoning_effort"],
      [:model_reasoning_effort],
      ["reasoningEffort"],
      [:reasoningEffort],
      ["params", "effort"],
      [:params, :effort],
      ["params", "reasoning_effort"],
      [:params, :reasoning_effort],
      ["params", "model_reasoning_effort"],
      [:params, :model_reasoning_effort],
      ["params", "usage", "reasoning_effort"],
      [:params, :usage, :reasoning_effort],
      ["params", "usage", "model_reasoning_effort"],
      [:params, :usage, :model_reasoning_effort],
      ["usage", "reasoning_effort"],
      [:usage, :reasoning_effort],
      ["usage", "model_reasoning_effort"],
      [:usage, :model_reasoning_effort]
    ])
  end

  defp observed_value_at_paths(source, paths) when is_map(source) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      source
      |> map_at_path(path)
      |> normalize_optional_string()
    end)
  end

  defp observed_value_at_paths(_source, _paths), do: nil

  defp merge_present_metadata(map, values) when is_map(map) and is_map(values) do
    Enum.reduce(values, map, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp merge_present_metadata(map, _values), do: map

  defp normalize_cost_signals(values) when is_list(values) do
    Enum.reduce(values, [], fn
      value, acc when is_binary(value) ->
        case String.trim(value) do
          "" -> acc
          normalized -> [normalized | acc]
        end

      value, acc when is_atom(value) ->
        [Atom.to_string(value) | acc]

      _value, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp normalize_cost_signals(_values), do: nil

  defp apply_routing_parity(running_entry) when is_map(running_entry) do
    intended_model = normalize_optional_string(Map.get(running_entry, :codex_model))
    intended_effort = normalize_optional_string(Map.get(running_entry, :codex_effort))
    observed_model = normalize_optional_string(Map.get(running_entry, :observed_model))
    observed_effort = normalize_optional_string(Map.get(running_entry, :observed_effort))

    {status, reason} =
      routing_parity_status_and_reason(
        intended_model,
        intended_effort,
        observed_model,
        observed_effort
      )

    running_entry
    |> maybe_put_optional_metadata(:routing_parity_status, status)
    |> maybe_put_optional_metadata(:routing_parity_reason, reason)
  end

  defp apply_routing_parity(running_entry), do: running_entry

  defp routing_parity_status_and_reason(nil, nil, _observed_model, _observed_effort), do: {nil, nil}

  defp routing_parity_status_and_reason(
         intended_model,
         intended_effort,
         nil,
         nil
       )
       when is_binary(intended_model) or is_binary(intended_effort) do
    {"observed_unavailable", "observed routing metadata unavailable"}
  end

  defp routing_parity_status_and_reason(
         intended_model,
         intended_effort,
         observed_model,
         observed_effort
       ) do
    mismatches =
      []
      |> maybe_add_routing_mismatch(:model, intended_model, observed_model)
      |> maybe_add_routing_mismatch(:effort, intended_effort, observed_effort)

    case mismatches do
      [] ->
        {"ok", "observed routing matches intended model/effort"}

      _ ->
        {"mismatch", Enum.join(mismatches, "; ")}
    end
  end

  defp maybe_add_routing_mismatch(messages, _label, nil, _observed), do: messages

  defp maybe_add_routing_mismatch(messages, label, intended, observed)
       when is_binary(intended) and intended != observed do
    messages ++ ["#{label} expected=#{intended} observed=#{observed || "unknown"}"]
  end

  defp maybe_add_routing_mismatch(messages, _label, _intended, _observed), do: messages

  defp maybe_put_optional_metadata(map, _key, nil), do: map
  defp maybe_put_optional_metadata(map, key, value), do: Map.put(map, key, value)

  defp apply_verification_update(running_entry, update) when is_map(running_entry) and is_map(update) do
    case verification_manifest_from_update(update) do
      {:ok, manifest} ->
        verification_result = if(manifest["passed"] == true, do: "passed", else: "failed")
        verification_summary = manifest["summary"]
        verification_profile = manifest["profile"]

        Map.merge(running_entry, %{
          verification_profile: verification_profile,
          verification_result: verification_result,
          verification_summary: verification_summary,
          verification_missing_items: normalize_manifest_missing_items(manifest["missing_items"]),
          verification_checked_at: parse_manifest_checked_at(manifest["checked_at"]),
          validation_guard_name: verification_profile,
          validation_guard_result: verification_result,
          validation_guard_reason: verification_summary
        })

      :error ->
        running_entry
    end
  end

  defp apply_pr_context_update(running_entry, update) when is_map(running_entry) and is_map(update) do
    running_entry
    |> maybe_put_pr_snapshot(update)
    |> maybe_put_ci_wait_result(update)
  end

  defp verification_manifest_from_update(update) when is_map(update) do
    with {:ok, @symphony_handoff_check_tool, _result} <- dynamic_tool_result(update),
         {:ok, payload} <- parse_dynamic_tool_result_payload(update),
         manifest when is_map(manifest) <- extract_manifest_payload(payload) do
      {:ok, manifest}
    else
      _ -> :error
    end
  end

  defp maybe_put_pr_snapshot(running_entry, update) when is_map(running_entry) and is_map(update) do
    with {:ok, @github_pr_snapshot_tool, _result} <- dynamic_tool_result(update),
         {:ok, payload} <- parse_dynamic_tool_result_payload(update),
         normalized when is_map(normalized) <- normalize_pr_snapshot_payload(payload) do
      Map.put(running_entry, :latest_pr_snapshot, normalized)
    else
      _ -> running_entry
    end
  end

  defp maybe_put_ci_wait_result(running_entry, update) when is_map(running_entry) and is_map(update) do
    with {:ok, @github_wait_for_checks_tool, _result} <- dynamic_tool_result(update),
         {:ok, payload} <- parse_dynamic_tool_result_payload(update),
         normalized when is_map(normalized) <- normalize_ci_wait_payload(payload) do
      Map.put(running_entry, :latest_ci_wait_result, normalized)
    else
      _ -> running_entry
    end
  end

  defp maybe_put_ci_wait_result(running_entry, _update), do: running_entry

  defp extract_manifest_payload(%{"manifest" => manifest}) when is_map(manifest), do: manifest
  defp extract_manifest_payload(manifest) when is_map(manifest), do: manifest
  defp extract_manifest_payload(_payload), do: nil

  defp normalize_manifest_missing_items(items) when is_list(items), do: items
  defp normalize_manifest_missing_items(_items), do: []

  defp normalize_pr_snapshot_payload(payload) when is_map(payload) do
    url = payload["url"]
    state = payload["state"]
    has_pending_checks = payload["has_pending_checks"]
    has_actionable_feedback = payload["has_actionable_feedback"]
    feedback_digest = payload["feedback_digest"]

    if is_binary(url) and String.trim(url) != "" do
      %{
        "url" => url,
        "state" => state,
        "number" => extract_pr_number(url),
        "has_pending_checks" => normalize_optional_boolean(has_pending_checks),
        "has_actionable_feedback" => normalize_optional_boolean(has_actionable_feedback),
        "feedback_digest" => normalize_optional_string(feedback_digest)
      }
    end
  end

  defp normalize_pr_snapshot_payload(_payload), do: nil

  defp normalize_ci_wait_payload(payload) when is_map(payload) do
    all_green = normalize_optional_boolean(payload["all_green"])
    pending_checks = payload["pending_checks"]
    failed_checks = payload["failed_checks"]
    checks = payload["checks"]

    %{
      "all_green" => all_green,
      "pending_checks" => if(is_list(pending_checks), do: pending_checks, else: []),
      "failed_checks" => if(is_list(failed_checks), do: failed_checks, else: []),
      "checks" => if(is_list(checks), do: checks, else: [])
    }
  end

  defp normalize_ci_wait_payload(_payload), do: nil

  defp dynamic_tool_result(%{event: event, payload: payload} = update)
       when event in [:tool_call_completed, :tool_call_failed, :unsupported_tool_call] and
              is_map(payload) do
    tool_name =
      get_in(payload, ["params", "tool"]) ||
        get_in(payload, ["params", "name"])

    result =
      Map.get(update, :result) ||
        Map.get(update, "result")

    if is_binary(tool_name), do: {:ok, tool_name, result}, else: :error
  end

  defp dynamic_tool_result(_update), do: :error

  defp parse_dynamic_tool_result_payload(update) when is_map(update) do
    with {:ok, _tool_name, result} <- dynamic_tool_result(update),
         text when is_binary(text) <- result_payload_text(result),
         {:ok, payload} <- Jason.decode(text),
         true <- is_map(payload) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  defp result_payload_text(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp result_payload_text(%{contentItems: [%{text: text} | _]}) when is_binary(text), do: text
  defp result_payload_text(_result), do: nil

  defp extract_pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url, capture: :all_but_first) do
      [value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp extract_pr_number(_url), do: nil

  defp normalize_optional_boolean(value) when is_boolean(value), do: value
  defp normalize_optional_boolean(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp parse_manifest_checked_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_manifest_checked_at(_value), do: nil

  defp maybe_publish_run_milestones(
         issue_id,
         previous_running_entry,
         current_running_entry,
         update
       ) do
    pending =
      current_running_entry
      |> Map.get(:pending_milestones, MapSet.new())
      |> normalize_milestone_set()

    transition_milestones = RunPhase.transition_milestones(previous_running_entry, current_running_entry)
    tool_milestones = tool_update_milestones(update)

    milestones_to_publish =
      pending
      |> MapSet.union(MapSet.new(transition_milestones))
      |> MapSet.union(MapSet.new(tool_milestones))
      |> MapSet.to_list()
      |> RunPhase.sort_milestones()

    Enum.reduce(milestones_to_publish, current_running_entry, fn milestone, entry ->
      publish_single_milestone(issue_id, entry, milestone)
    end)
  end

  defp publish_single_milestone(issue_id, running_entry, milestone) do
    if RunPhase.milestone_reported?(running_entry, milestone) do
      RunPhase.clear_pending_milestone(running_entry, milestone)
    else
      comment = RunPhase.milestone_comment(milestone, running_entry)

      case Tracker.create_comment(issue_id, comment) do
        :ok ->
          running_entry
          |> RunPhase.clear_pending_milestone(milestone)
          |> RunPhase.mark_milestone_reported(milestone)

        {:error, reason} ->
          Logger.warning("Failed to publish run milestone #{RunPhase.milestone_label(milestone)} for issue_id=#{issue_id}: #{inspect(reason)}")
          RunPhase.mark_milestone_pending(running_entry, milestone)
      end
    end
  end

  defp tool_update_milestones(update) when is_map(update) do
    []
    |> maybe_add_ci_failed_milestone(update)
    |> maybe_add_handoff_ready_milestone(update)
    |> Enum.uniq()
  end

  defp maybe_add_ci_failed_milestone(milestones, update) do
    case dynamic_tool_result(update) do
      {:ok, @github_wait_for_checks_tool, _result} ->
        if ci_failed_milestone?(update), do: milestones ++ [:ci_failed], else: milestones

      _ ->
        milestones
    end
  end

  defp ci_failed_milestone?(%{event: :tool_call_failed}), do: true

  defp ci_failed_milestone?(update) do
    case parse_dynamic_tool_result_payload(update) do
      {:ok, %{"all_green" => false}} -> true
      _ -> false
    end
  end

  defp maybe_add_handoff_ready_milestone(milestones, update) do
    with {:ok, @symphony_handoff_check_tool, _result} <- dynamic_tool_result(update),
         :tool_call_completed <- Map.get(update, :event),
         {:ok, payload} <- parse_dynamic_tool_result_payload(update),
         manifest when is_map(manifest) <- extract_manifest_payload(payload),
         true <- manifest["passed"] == true do
      milestones ++ [:handoff_ready]
    else
      _ -> milestones
    end
  end

  defp normalize_milestone_set(%MapSet{} = milestones), do: milestones
  defp normalize_milestone_set(milestones) when is_list(milestones), do: MapSet.new(milestones)
  defp normalize_milestone_set(_milestones), do: MapSet.new()

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

  defp thread_id_for_update(_existing, %{thread_id: thread_id}) when is_binary(thread_id),
    do: thread_id

  defp thread_id_for_update(existing, _update), do: existing

  defp turn_id_for_update(_existing, %{turn_id: turn_id}) when is_binary(turn_id),
    do: turn_id

  defp turn_id_for_update(_existing, %{turn_id: turn_id}) when is_integer(turn_id),
    do: Integer.to_string(turn_id)

  defp turn_id_for_update(existing, _update), do: existing

  defp replacement_of_session_id_for_update(existing_replacement_of_session_id, _existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_binary(existing_replacement_of_session_id) and is_binary(session_id) do
    existing_replacement_of_session_id
  end

  defp replacement_of_session_id_for_update(_existing_replacement_of_session_id, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_binary(existing_session_id) and is_binary(session_id) and
              existing_session_id != session_id do
    existing_session_id
  end

  defp replacement_of_session_id_for_update(existing_replacement_of_session_id, _existing_session_id, update)
       when is_map(update) do
    update_replacement =
      Map.get(update, :replacement_of_session_id) ||
        Map.get(update, "replacement_of_session_id")

    normalize_optional_string(update_replacement) || existing_replacement_of_session_id
  end

  defp replacement_session_id_for_update(_existing_replacement_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_binary(session_id) do
    session_id
  end

  defp replacement_session_id_for_update(existing_replacement_session_id, update) when is_map(update) do
    update_replacement =
      Map.get(update, :replacement_session_id) ||
        Map.get(update, "replacement_session_id")

    normalize_optional_string(update_replacement) || existing_replacement_session_id
  end

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
    refresh_selected_codex_accounts(state, accounts, replace_all?: true, full_reconcile?: true)
  end

  defp refresh_active_codex_account(%State{} = state) do
    case active_codex_account_config(state) do
      nil ->
        refresh_codex_accounts(state)

      account ->
        state
        |> refresh_selected_codex_accounts([account], probe_mode: :account_only)
        |> maybe_refresh_all_codex_accounts_after_active_probe(account.id)
    end
  end

  defp maybe_refresh_all_codex_accounts_after_active_probe(%State{} = state, account_id)
       when is_binary(account_id) do
    case Map.get(state.codex_accounts, account_id) do
      %{probe_healthy: true} -> state
      _ -> refresh_codex_accounts(state)
    end
  end

  defp maybe_refresh_all_codex_accounts_after_active_probe(%State{} = state, _account_id),
    do: refresh_codex_accounts(state)

  defp refresh_selected_codex_accounts(%State{} = state, accounts, opts)
       when is_list(accounts) do
    now_ms = System.monotonic_time(:millisecond)
    probed_accounts = probe_codex_accounts(state, accounts, opts)

    codex_accounts =
      Enum.reduce(
        probed_accounts,
        base_codex_accounts_after_refresh(state, opts),
        fn account_status, acc ->
          existing =
            Map.get(
              state.codex_accounts,
              account_status.id,
              default_codex_account_status(account_status.id)
            )

          incoming =
            build_codex_account_probe_update(existing, account_status)

          Map.put(acc, account_status.id, merge_codex_account_status(existing, incoming, :probe))
        end
      )

    state
    |> Map.put(:codex_accounts, codex_accounts)
    |> reselect_active_codex_account()
    |> Map.put(:last_codex_account_probe_at_ms, now_ms)
    |> maybe_mark_full_codex_account_probe(now_ms, opts)
  end

  defp base_codex_accounts_after_refresh(%State{} = state, opts) do
    if Keyword.get(opts, :replace_all?, false) do
      %{}
    else
      state.codex_accounts
    end
  end

  defp maybe_mark_full_codex_account_probe(%State{} = state, now_ms, opts)
       when is_integer(now_ms) do
    if Keyword.get(opts, :full_reconcile?, false) do
      Map.put(state, :last_full_codex_account_probe_at_ms, now_ms)
    else
      state
    end
  end

  defp active_codex_account_config(%State{active_codex_account_id: account_id})
       when is_binary(account_id) do
    Enum.find(Config.codex_accounts(), &(Map.get(&1, :id) == account_id))
  end

  defp active_codex_account_config(_state), do: nil

  defp probe_codex_accounts(%State{codex_account_probe_fun: probe_fun}, accounts, opts)
       when is_list(accounts) do
    probe_fun = if is_function(probe_fun, 2), do: probe_fun, else: &AccountProbe.probe_accounts/2

    probe_fun.(accounts,
      cwd: System.tmp_dir!(),
      monitored_windows_mins: Config.codex_monitored_windows_mins(),
      minimum_remaining_percent: Config.codex_minimum_remaining_percent(),
      timeout_ms: max(Config.settings!().codex.read_timeout_ms * 2, 2_000),
      probe_mode: Keyword.get(opts, :probe_mode, :full)
    )
  end

  defp build_codex_account_probe_update(existing, %{probe_scope: :account_only} = account_status)
       when is_map(existing) do
    logged_in? = Map.get(account_status, :healthy, false)

    account_status
    |> Map.drop([
      :probe_scope,
      :healthy,
      :health_reason,
      :rate_limits,
      :missing_windows_mins,
      :insufficient_windows_mins
    ])
    |> Map.put(:probe_healthy, account_only_probe_healthy(existing, logged_in?))
    |> Map.put(
      :probe_health_reason,
      account_only_probe_health_reason(existing, account_status, logged_in?)
    )
    |> Map.put(:rate_limits, Map.get(existing, :rate_limits))
    |> Map.put(:missing_windows_mins, Map.get(existing, :missing_windows_mins, []))
    |> Map.put(:insufficient_windows_mins, Map.get(existing, :insufficient_windows_mins, []))
  end

  defp build_codex_account_probe_update(_existing, account_status) when is_map(account_status) do
    account_status
    |> Map.drop([:probe_scope])
    |> Map.put(:probe_healthy, Map.get(account_status, :healthy, false))
    |> Map.put(:probe_health_reason, Map.get(account_status, :health_reason))
  end

  defp account_only_probe_healthy(existing, true) when is_map(existing) do
    Map.get(existing, :probe_healthy, Map.get(existing, :healthy, false))
  end

  defp account_only_probe_healthy(_existing, _logged_in?), do: false

  defp account_only_probe_health_reason(existing, _account_status, true) when is_map(existing) do
    Map.get(existing, :probe_health_reason, Map.get(existing, :health_reason))
  end

  defp account_only_probe_health_reason(_existing, account_status, _logged_in?)
       when is_map(account_status) do
    Map.get(account_status, :health_reason)
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

  defp apply_codex_reason_delta(
         %State{} = state,
         running_entry,
         update,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) and total > 0 do
    category = token_reason_category(running_entry, update)
    totals = normalize_token_reason_totals(state.codex_token_reason_totals)

    category_totals = Map.get(totals, category, %{input_tokens: 0, output_tokens: 0, total_tokens: 0})

    updated_category_totals = %{
      input_tokens: max(0, Map.get(category_totals, :input_tokens, 0) + token_delta.input_tokens),
      output_tokens: max(0, Map.get(category_totals, :output_tokens, 0) + token_delta.output_tokens),
      total_tokens: max(0, Map.get(category_totals, :total_tokens, 0) + token_delta.total_tokens)
    }

    %{state | codex_token_reason_totals: Map.put(totals, category, updated_category_totals)}
  end

  defp apply_codex_reason_delta(state, _running_entry, _update, _token_delta), do: state

  defp normalize_token_reason_totals(totals) when is_map(totals) do
    Enum.reduce(@token_reason_categories, %{}, fn category, acc ->
      source = Map.get(totals, category) || Map.get(totals, Atom.to_string(category)) || %{}

      Map.put(acc, category, %{
        input_tokens: normalize_non_negative_integer(Map.get(source, :input_tokens) || Map.get(source, "input_tokens")),
        output_tokens: normalize_non_negative_integer(Map.get(source, :output_tokens) || Map.get(source, "output_tokens")),
        total_tokens: normalize_non_negative_integer(Map.get(source, :total_tokens) || Map.get(source, "total_tokens"))
      })
    end)
  end

  defp normalize_token_reason_totals(_totals), do: @empty_token_reason_totals

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_integer(_value), do: 0

  defp token_reason_category(running_entry, update) do
    current_command = normalize_optional_string(map_any(running_entry, [:current_command]))
    run_phase = map_any(running_entry, [:run_phase])
    external_step = normalize_optional_string(map_any(running_entry, [:external_step]))

    cond do
      linear_mutation_update?(update) ->
        :linear_mutation

      git_gh_status_command?(current_command) ->
        :git_gh_status

      validation_command?(current_command) ->
        :validation

      polling_wait_update?(run_phase, external_step, current_command) ->
        :polling

      true ->
        :other
    end
  end

  defp polling_wait_update?(run_phase, external_step, current_command) do
    run_phase in [:waiting_external, "waiting external"] and external_step == "exec_wait" and
      current_command in [nil, "", "exec_wait"]
  end

  defp git_gh_status_command?(command) do
    if is_binary(command) do
      normalized =
        command
        |> String.trim()
        |> String.downcase()

      String.starts_with?(normalized, "git status") or
        String.starts_with?(normalized, "gh pr status") or
        String.starts_with?(normalized, "gh pr checks") or
        String.starts_with?(normalized, "gh pr view") or
        String.starts_with?(normalized, "gh run list") or
        String.starts_with?(normalized, "gh run view") or
        String.starts_with?(normalized, "gh run watch")
    else
      false
    end
  end

  defp validation_command?(command) do
    if is_binary(command) do
      normalized =
        command
        |> String.trim()
        |> String.downcase()

      String.contains?(normalized, "make symphony-preflight") or
        String.contains?(normalized, "make symphony-validate") or
        String.contains?(normalized, "make test") or
        String.contains?(normalized, "mix test") or
        String.contains?(normalized, "pytest") or
        String.contains?(normalized, "mix dialyzer") or
        String.contains?(normalized, "make all")
    else
      false
    end
  end

  defp linear_mutation_update?(%{payload: payload}) when is_map(payload) do
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}
    tool_name = linear_mutation_tool_name(params)
    linear_mutation_tool?(tool_name, params)
  end

  defp linear_mutation_update?(_update), do: false

  defp linear_mutation_tool_name(params) when is_map(params) do
    Map.get(params, "tool") ||
      Map.get(params, :tool) ||
      Map.get(params, "name") ||
      Map.get(params, :name)
  end

  defp linear_mutation_tool_name(_params), do: nil

  defp linear_mutation_tool?(tool_name, _params)
       when tool_name in ["sync_workpad", "linear_upload_issue_attachment"],
       do: true

  defp linear_mutation_tool?("linear_graphql", params) do
    arguments = Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
    linear_mutation_query?(arguments)
  end

  defp linear_mutation_tool?(_tool_name, _params), do: false

  defp linear_mutation_query?(arguments) when is_map(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        query
        |> String.trim_leading()
        |> String.downcase()
        |> String.starts_with?("mutation")

      _ ->
        false
    end
  end

  defp linear_mutation_query?(_arguments), do: false

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
    Map.get(account, :requires_openai_auth) == false and Map.get(account, :probe_healthy) == true
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
