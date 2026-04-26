defmodule SymphonyElixir.RuntimeRecoveryParityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Orchestrator, ResumeCheckpoint, RuntimeSmokeSupport}

  @matrix_fixture Path.expand("../fixtures/parity/parity_07_runtime_recovery_matrix.json", __DIR__)
  @live_fixture Path.expand("../fixtures/parity/parity_07_runtime_recovery_live_sanitized.json", __DIR__)
  @contract_doc Path.expand("../../../docs/symphony-next/contracts/PARITY-07_RUNTIME_RECOVERY_CONTRACT.md", __DIR__)

  @required_acceptance_ids [
    "PARITY-07-AM-01",
    "PARITY-07-AM-02",
    "PARITY-07-AM-03",
    "PARITY-07-AM-04",
    "PARITY-07-AM-05",
    "PARITY-07-AM-06",
    "PARITY-07-AM-07",
    "PARITY-07-AM-08",
    "PARITY-07-AM-09",
    "PARITY-07-AM-10"
  ]

  @primary_account %{id: "primary", codex_home: "/tmp/codex-primary"}

  test "PARITY-07 deterministic runtime recovery matrix cases pass" do
    payload = load_fixture!(@matrix_fixture)

    assert payload["ticket"] == "PARITY-07"
    assert payload["source"]["kind"] == "deterministic_matrix"

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    Enum.each(cases, fn case_entry ->
      case case_entry["kind"] do
        "stall_retry" -> assert_stall_retry_case!(case_entry)
        "pre_run_hook_guard" -> assert_pre_run_hook_guard_case!(case_entry)
        "retry_terminal_reconcile" -> assert_retry_terminal_case!(case_entry)
        "resume_reload" -> assert_resume_reload_case!(case_entry)
        "orphaned_claim_reconcile" -> assert_orphaned_claim_case!(case_entry)
        "replay_stability" -> assert_replay_stability_case!(case_entry)
        kind -> flunk("unsupported deterministic case kind: #{inspect(kind)}")
      end
    end)
  end

  test "PARITY-07 live-sanitized runtime recovery traces map to canonical classes" do
    payload = load_fixture!(@live_fixture)

    assert payload["ticket"] == "PARITY-07"
    assert is_binary(payload["generated_at"])

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    recovery_classes =
      cases
      |> Enum.map(&get_in(&1, ["expected", "recovery_class"]))
      |> MapSet.new()

    assert MapSet.member?(recovery_classes, "classified_handoff_stop")

    assert Enum.any?(recovery_classes, fn value ->
             value in ["resume_checkpoint_recovery", "fallback_reread_recovery"]
           end)

    Enum.each(cases, fn case_entry ->
      case_id = case_entry["case_id"] || "UNKNOWN"
      observed = Map.get(case_entry, "observed", %{})
      expected_class = get_in(case_entry, ["expected", "recovery_class"])

      assert expected_class != "unknown", "case #{case_id}: replacement-scope unknown is not allowed"
      assert classify_live_recovery_case(observed) == expected_class, "case #{case_id}: recovery class mismatch"
    end)
  end

  test "PARITY-07 contract doc maps AM ids to executable suite" do
    body = File.read!(@contract_doc)

    Enum.each(@required_acceptance_ids, fn id ->
      assert String.contains?(body, id), "missing acceptance id #{id} in contract doc"
    end)

    Enum.each(
      [
        "resume_checkpoint_recovery",
        "fallback_reread_recovery",
        "classified_handoff_stop",
        "Replay stability"
      ],
      fn marker ->
        assert String.contains?(body, marker), "missing contract marker #{marker}"
      end
    )
  end

  defp assert_stall_retry_case!(case_entry) do
    expected = Map.get(case_entry, "expected", %{})
    issue_id = "issue-parity07-stall"
    orchestrator_name = Module.concat(__MODULE__, :"StallOrchestrator#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000
    )

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        send(worker_pid, :done)
      end

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: expected["identifier"],
      issue: %Issue{id: issue_id, identifier: expected["identifier"], state: "In Progress"},
      trace_id: "trace-parity07-stall",
      session_id: "thread-parity07-stall-turn-1",
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)

    state =
      RuntimeSmokeSupport.wait_for_orchestrator_state(
        pid,
        fn state ->
          not Process.alive?(worker_pid) and
            not Map.has_key?(state.running, issue_id) and
            match?(
              %{
                attempt: _,
                identifier: _,
                error: "stalled for " <> _,
                error_class: _
              },
              state.retry_attempts[issue_id]
            )
        end,
        5_000
      )

    retry_entry = state.retry_attempts[issue_id]
    assert retry_entry.attempt == expected["attempt"]
    assert retry_entry.identifier == expected["identifier"]
    assert retry_entry.error_class == expected["error_class"]
    assert is_binary(retry_entry.error)
    assert String.starts_with?(retry_entry.error, expected["error_prefix"])
  end

  defp assert_pre_run_hook_guard_case!(case_entry) do
    expected = Map.get(case_entry, "expected", %{})
    issue_id = "issue-parity07-pre-hook"
    orchestrator_name = Module.concat(__MODULE__, :"PreHookOrchestrator#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000,
      hook_timeout_ms: 10_000
    )

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        send(worker_pid, :done)
      end

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    started_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "PARITY07-PRE-HOOK",
      issue: %Issue{id: issue_id, identifier: "PARITY07-PRE-HOOK", state: "In Progress"},
      trace_id: "trace-parity07-pre-hook",
      session_id: "thread-parity07-pre-hook",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at,
      pre_run_hook_active: true,
      pre_run_hook_started_at: started_at,
      pre_run_hook_timeout_ms: 10_000
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)

    state =
      RuntimeSmokeSupport.wait_for_orchestrator_state(
        pid,
        fn state ->
          Map.has_key?(state.running, issue_id) and
            Map.has_key?(state.retry_attempts, issue_id) == expected["retry_scheduled"]
        end,
        5_000
      )

    assert Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  defp assert_retry_terminal_case!(case_entry) do
    expected = Map.get(case_entry, "expected", %{})
    issue_id = "issue-parity07-retry-terminal"
    retry_token = make_ref()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      poll_interval_ms: 30_000
    )

    active_issue =
      RuntimeSmokeSupport.issue_fixture(%{
        id: issue_id,
        identifier: "PARITY07-RETRY-TERMINAL",
        state: "In Progress",
        title: "PARITY-07 retry terminal reconcile"
      })

    terminal_issue = %{active_issue | state: "Done"}
    memory_tracker_state = RuntimeSmokeSupport.put_memory_tracker!([terminal_issue])

    on_exit(fn ->
      RuntimeSmokeSupport.restore_memory_tracker!(memory_tracker_state)
    end)

    state =
      fresh_orchestrator_state()
      |> Map.put(:claimed, MapSet.put(MapSet.new(), issue_id))
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 1,
          retry_token: retry_token,
          timer_ref: nil,
          due_at_ms: 0,
          identifier: active_issue.identifier,
          trace_id: nil,
          error: nil,
          error_class: nil,
          delay_type: :continuation
        }
      })

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:retry_issue, issue_id, retry_token}, state)

    if expected["claim_released"] do
      refute MapSet.member?(updated_state.claimed, issue_id)
    end

    if expected["retry_cleared"] do
      refute Map.has_key?(updated_state.retry_attempts, issue_id)
    end
  end

  defp assert_resume_reload_case!(case_entry) do
    expected = Map.get(case_entry, "expected", %{})
    retry_token = make_ref()
    task_supervisor = RuntimeSmokeSupport.install_failing_task_supervisor_for_test()
    test_root = RuntimeSmokeSupport.unique_test_root("symphony-parity07-resume")
    workspace_root = Path.join(test_root, "workspaces")
    memory_tracker_state = RuntimeSmokeSupport.put_memory_tracker!([])

    on_exit(fn ->
      RuntimeSmokeSupport.restore_task_supervisor_for_test(task_supervisor)
      RuntimeSmokeSupport.restore_memory_tracker!(memory_tracker_state)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      codex_accounts: [@primary_account]
    )

    issue =
      RuntimeSmokeSupport.issue_fixture(%{
        id: "issue-parity07-resume",
        identifier: "PARITY07-RESUME",
        title: "PARITY-07 resume reload"
      })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    workspace = RuntimeSmokeSupport.init_workspace_repo!(workspace_root, issue.identifier)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nPARITY-07 checkpoint")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-parity07-resume")

    _loaded_checkpoint =
      ResumeCheckpoint.capture(
        issue,
        %{
          latest_pr_snapshot: %{
            "url" => "https://github.com/maximlafe/symphony/pull/78",
            "state" => "OPEN",
            "has_pending_checks" => false,
            "has_actionable_feedback" => false
          }
        },
        workspace_root: workspace_root
      )

    queued_fallback =
      ResumeCheckpoint.for_prompt(%{
        "fallback_reasons" => ["resume checkpoint capture failed: boom"]
      })

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{
        issue.id => %{
          attempt: 1,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: issue.identifier,
          trace_id: "trace-parity07-resume",
          error: "account failover: threshold exceeded",
          error_class: "transient",
          delay_type: :failover,
          resume_checkpoint: queued_fallback
        }
      },
      codex_accounts: %{
        "primary" => %{
          id: "primary",
          explicit?: true,
          healthy: true,
          probe_healthy: true,
          probe_health_reason: nil,
          health_reason: nil,
          auth_mode: "chatgpt",
          requires_openai_auth: false,
          missing_windows_mins: [],
          insufficient_windows_mins: [],
          rate_limits: %{"limitId" => "codex"}
        }
      },
      active_codex_account_id: "primary",
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: %{"limitId" => "codex"},
      codex_dispatch_reason: nil
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:retry_issue, issue.id, retry_token}, state)

    retry_entry = updated_state.retry_attempts[issue.id]
    reloaded_checkpoint = retry_entry.resume_checkpoint

    assert retry_entry.resume_mode == expected["resume_mode"]
    assert retry_entry.resume_fallback_reason == expected["resume_fallback_reason"]
    assert reloaded_checkpoint["resume_ready"] == expected["resume_ready"]
  end

  defp assert_orphaned_claim_case!(case_entry) do
    expected = Map.get(case_entry, "expected", %{})
    issue_id = "issue-parity07-orphan-claim"

    state =
      fresh_orchestrator_state()
      |> Map.put(:running, %{})
      |> Map.put(:retry_attempts, %{})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_dedupe_keys, %{issue_id => "stale-key"})

    assert {:noreply, updated_state} = Orchestrator.handle_info({:retry_issue, issue_id}, state)

    if expected["claim_released"] do
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Map.has_key?(updated_state.retry_dedupe_keys, issue_id)
    end
  end

  defp assert_replay_stability_case!(case_entry) do
    expected = Map.get(case_entry, "expected", %{})
    events = Map.get(case_entry, "event_log", [])
    issue_id = "issue-parity07-replay"
    issue_identifier = "PARITY07-REPLAY"

    base_running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue_identifier,
      issue:
        RuntimeSmokeSupport.issue_fixture(%{
          id: issue_id,
          identifier: issue_identifier,
          title: "PARITY-07 replay stability"
        }),
      trace_id: "trace-parity07",
      session_id: nil,
      thread_id: nil,
      turn_id: nil,
      replacement_of_session_id: nil,
      replacement_session_id: nil,
      turn_count: 0,
      started_at: parse_iso8601!("2026-04-26T10:59:00Z"),
      last_codex_timestamp: nil,
      last_codex_message: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0
    }

    state0 =
      fresh_orchestrator_state()
      |> Map.put(:running, %{issue_id => base_running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})

    state_once = replay_events(state0, issue_id, events)
    state_twice = replay_events(state_once, issue_id, events)
    state_fresh = replay_events(state0, issue_id, events)

    fields = Map.get(expected, "stable_fields", [])

    assert normalized_running_fields(state_once.running[issue_id], fields) ==
             normalized_running_fields(state_twice.running[issue_id], fields)

    assert normalized_running_fields(state_once.running[issue_id], fields) ==
             normalized_running_fields(state_fresh.running[issue_id], fields)

    running_once = Map.fetch!(state_once.running, issue_id)

    assert Map.get(running_once, :session_id) == expected["session_id"]
    assert Map.get(running_once, :turn_count) == expected["turn_count"]
    assert Map.get(running_once, :codex_total_tokens) == expected["codex_total_tokens"]
  end

  defp replay_events(state, issue_id, events) do
    Enum.reduce(events, state, fn event_entry, acc_state ->
      update = event_update_from_fixture(event_entry)
      {:noreply, next_state} = Orchestrator.handle_info({:codex_worker_update, issue_id, update}, acc_state)
      next_state
    end)
  end

  defp event_update_from_fixture(entry) when is_map(entry) do
    update = %{
      event: event_atom(entry["event"]),
      timestamp: parse_iso8601!(entry["timestamp"])
    }

    update
    |> maybe_put(:session_id, normalize_optional_string(entry["session_id"]))
    |> maybe_put(:thread_id, normalize_optional_string(entry["thread_id"]))
    |> maybe_put(:turn_id, normalize_optional_string(entry["turn_id"]))
    |> maybe_put(:trace_id, normalize_optional_string(entry["trace_id"]))
    |> maybe_put(:payload, entry["payload"])
    |> maybe_put(:usage, entry["usage"])
    |> maybe_put(:codex_model, normalize_optional_string(entry["codex_model"]))
    |> maybe_put(:codex_effort, normalize_optional_string(entry["codex_effort"]))
    |> maybe_put(:command_source, "cost_profile")
  end

  defp normalized_running_fields(entry, fields) when is_map(entry) and is_list(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      Map.put(acc, field, running_field(entry, field))
    end)
  end

  defp running_field(entry, "session_id"), do: Map.get(entry, :session_id)
  defp running_field(entry, "thread_id"), do: Map.get(entry, :thread_id)
  defp running_field(entry, "turn_id"), do: Map.get(entry, :turn_id)
  defp running_field(entry, "trace_id"), do: Map.get(entry, :trace_id)
  defp running_field(entry, "turn_count"), do: Map.get(entry, :turn_count)
  defp running_field(entry, "codex_input_tokens"), do: Map.get(entry, :codex_input_tokens)
  defp running_field(entry, "codex_output_tokens"), do: Map.get(entry, :codex_output_tokens)
  defp running_field(entry, "codex_total_tokens"), do: Map.get(entry, :codex_total_tokens)
  defp running_field(entry, "codex_last_reported_input_tokens"), do: Map.get(entry, :codex_last_reported_input_tokens)
  defp running_field(entry, "codex_last_reported_output_tokens"), do: Map.get(entry, :codex_last_reported_output_tokens)
  defp running_field(entry, "codex_last_reported_total_tokens"), do: Map.get(entry, :codex_last_reported_total_tokens)
  defp running_field(entry, "routing_parity_status"), do: Map.get(entry, :routing_parity_status)
  defp running_field(entry, "routing_parity_reason"), do: Map.get(entry, :routing_parity_reason)
  defp running_field(_entry, _field), do: nil

  defp classify_live_recovery_case(observed) when is_map(observed) do
    selected_action = normalize_optional_string(observed["selected_action"])
    resume_mode = normalize_optional_string(observed["resume_mode"])

    cond do
      selected_action == "stop_with_classified_handoff" ->
        "classified_handoff_stop"

      resume_mode == "resume_checkpoint" ->
        "resume_checkpoint_recovery"

      resume_mode == "fallback_reread" ->
        "fallback_reread_recovery"

      true ->
        "unknown"
    end
  end

  defp classify_live_recovery_case(_observed), do: "unknown"

  defp event_atom("session_started"), do: :session_started
  defp event_atom("notification"), do: :notification
  defp event_atom("tool_call_completed"), do: :tool_call_completed
  defp event_atom("tool_call_failed"), do: :tool_call_failed
  defp event_atom("unsupported_tool_call"), do: :unsupported_tool_call
  defp event_atom(other), do: raise("unsupported event #{inspect(other)}")

  defp parse_iso8601!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> raise("invalid iso8601 timestamp #{inspect(value)}")
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fresh_orchestrator_state do
    orchestrator_name =
      Module.concat(__MODULE__, :"TemplateOrchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        start_immediately?: false,
        run_startup_housekeeping?: false
      )

    state = :sys.get_state(pid)

    if Process.alive?(pid) do
      Process.exit(pid, :normal)
    end

    state
  end

  defp load_fixture!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
