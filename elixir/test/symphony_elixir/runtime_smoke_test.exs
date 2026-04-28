defmodule SymphonyElixir.RuntimeSmokeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentRunner, Config, Orchestrator, ResumeCheckpoint, Workflow, WorkflowStore}
  alias SymphonyElixir.RuntimeSmokeSupport

  @moduletag :runtime_smoke
  @moduletag timeout: 30_000

  @primary_account %{id: "primary", codex_home: "/tmp/codex-primary"}

  defmodule Let539LinearClient do
    alias SymphonyElixir.Linear.Issue

    def fetch_candidate_issues do
      send_event(:fetch_candidate_issues)
      {:ok, configured_issues()}
    end

    def fetch_issues_by_states(states) when is_list(states) do
      normalized_states =
        states
        |> Enum.map(&normalize_state/1)
        |> MapSet.new()

      {:ok,
       Enum.filter(configured_issues(), fn %Issue{state: state} ->
         MapSet.member?(normalized_states, normalize_state(state))
       end)}
    end

    def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
      send_event({:fetch_issue_states_by_ids, issue_ids})
      wanted_ids = MapSet.new(issue_ids)

      {:ok,
       Enum.filter(configured_issues(), fn %Issue{id: id} ->
         MapSet.member?(wanted_ids, id)
       end)}
    end

    def graphql(_query, _variables), do: {:ok, %{"data" => %{}}}

    defp configured_issues do
      Application.get_env(:symphony_elixir, :let_539_runtime_linear_issues, [])
    end

    defp send_event(event) do
      case Application.get_env(:symphony_elixir, :let_539_runtime_linear_recipient) do
        pid when is_pid(pid) -> send(pid, event)
        _ -> :ok
      end
    end

    defp normalize_state(state) when is_binary(state) do
      state
      |> String.trim()
      |> String.downcase()
    end

    defp normalize_state(_state), do: ""
  end

  @tag :hooks_stall_guard
  test "hooks_stall_guard runs a long before_run hook on a low stall budget" do
    test_root = RuntimeSmokeSupport.unique_test_root("symphony-runtime-smoke-hooks")
    workspace_root = Path.join(test_root, "workspaces")
    hook_marker = Path.join(test_root, "before-run.marker")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        tracker_active_states: ["In Progress"],
        codex_approval_policy: "never",
        codex_stall_timeout_ms: 100,
        max_turns: 1,
        hook_before_run: """
        sleep 0.2
        printf 'before_run_ok' > "#{hook_marker}"
        """
      )

      issue =
        RuntimeSmokeSupport.issue_fixture(%{
          id: "issue-hooks-stall-guard",
          identifier: "RT-HOOKS-STALL",
          title: "Hook stall guard smoke"
        })

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [RuntimeSmokeSupport.snapshot_issue(issue, "Done")]}
      end

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 max_turns: 1,
                 trace_id: "trace-runtime-smoke-hooks",
                 issue_state_fetcher: issue_state_fetcher
               )

      assert File.read!(hook_marker) == "before_run_ok"
    after
      File.rm_rf(test_root)
    end
  end

  @tag :retry_reconcile
  test "retry_reconcile surfaces retry lifecycle after a stalled worker restart" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-runtime-smoke-retry"
    orchestrator_name = Module.concat(__MODULE__, :RetryReconcileOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      RuntimeSmokeSupport.stop_orchestrator(pid)
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "RT-RETRY",
      issue:
        RuntimeSmokeSupport.issue_fixture(%{
          id: issue_id,
          identifier: "RT-RETRY",
          title: "Retry reconcile smoke"
        }),
      trace_id: "trace-runtime-smoke-retry",
      session_id: "thread-runtime-smoke-retry",
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
      RuntimeSmokeSupport.wait_for_orchestrator_state(pid, fn state ->
        not Process.alive?(worker_pid) and
          not Map.has_key?(state.running, issue_id) and
          match?(
            %{
              attempt: 1,
              identifier: "RT-RETRY",
              trace_id: "trace-runtime-smoke-retry",
              error: "stalled for " <> _,
              error_class: "transient"
            },
            state.retry_attempts[issue_id]
          )
      end)

    assert %{
             attempt: 1,
             identifier: "RT-RETRY",
             trace_id: "trace-runtime-smoke-retry",
             error_class: "transient"
           } = state.retry_attempts[issue_id]

    snapshot = GenServer.call(pid, :snapshot, 15_000)

    assert [%{issue_id: ^issue_id, attempt: 1, error_class: "transient"}] = snapshot.retrying
    assert snapshot.running == []
    refute Process.alive?(worker_pid)
  end

  @tag :let_539
  test "let_539 retry timer runtime refreshes only the targeted issue state" do
    issue_id = "issue-runtime-smoke-let-539"

    issue =
      RuntimeSmokeSupport.issue_fixture(%{
        id: issue_id,
        identifier: "RT-LET-539",
        title: "Targeted retry refresh runtime smoke",
        state: "In Progress"
      })

    previous_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_issues = Application.get_env(:symphony_elixir, :let_539_runtime_linear_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :let_539_runtime_linear_recipient)

    try do
      Application.put_env(:symphony_elixir, :linear_client_module, Let539LinearClient)
      Application.put_env(:symphony_elixir, :let_539_runtime_linear_issues, [issue])
      Application.put_env(:symphony_elixir, :let_539_runtime_linear_recipient, self())

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
        max_retry_backoff_ms: 10
      )

      orchestrator_name = Module.concat(__MODULE__, :Let539TargetedRetryOrchestrator)

      {:ok, pid} =
        Orchestrator.start_link(
          name: orchestrator_name,
          start_immediately?: false,
          run_startup_housekeeping?: false
        )

      on_exit(fn ->
        RuntimeSmokeSupport.stop_orchestrator(pid)
      end)

      retry_token = make_ref()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | claimed: MapSet.put(state.claimed, issue_id),
            retry_attempts: %{
              issue_id => %{
                attempt: 1,
                retry_token: retry_token,
                timer_ref: nil,
                due_at_ms: 0,
                identifier: issue.identifier,
                trace_id: "trace-runtime-smoke-let-539",
                error: nil,
                error_class: nil,
                delay_type: :continuation
              }
            }
        }
      end)

      send(pid, {:retry_issue, issue_id, retry_token})

      assert_receive {:fetch_issue_states_by_ids, [^issue_id]}, 1_000
      refute_receive :fetch_candidate_issues, 100

      state =
        RuntimeSmokeSupport.wait_for_orchestrator_state(pid, fn state ->
          retry = state.retry_attempts[issue_id]

          is_map(retry) and retry.identifier == issue.identifier and
            retry.error == "no healthy codex account available" and
            retry.error_class == "transient"
        end)

      assert MapSet.member?(state.claimed, issue_id)
    after
      RuntimeSmokeSupport.restore_app_env!(:linear_client_module, previous_client_module)
      RuntimeSmokeSupport.restore_app_env!(:let_539_runtime_linear_issues, previous_issues)
      RuntimeSmokeSupport.restore_app_env!(:let_539_runtime_linear_recipient, previous_recipient)
    end
  end

  @tag :resume_checkpoint
  test "resume_checkpoint reload prefers a loaded checkpoint over queued fallback data" do
    retry_token = make_ref()
    task_supervisor = RuntimeSmokeSupport.install_failing_task_supervisor_for_test()
    test_root = RuntimeSmokeSupport.unique_test_root("symphony-runtime-smoke-resume")
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
        id: "issue-runtime-smoke-resume",
        identifier: "RT-RESUME",
        title: "Resume checkpoint smoke"
      })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    workspace = RuntimeSmokeSupport.init_workspace_repo!(workspace_root, issue.identifier)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nReloaded state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-runtime-smoke")

    loaded_checkpoint =
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
          trace_id: "trace-runtime-smoke-resume",
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

    assert %{
             attempt: 2,
             error_class: "transient",
             delay_type: nil,
             resume_mode: "resume_checkpoint",
             resume_fallback_reason: nil,
             resume_checkpoint: reloaded_checkpoint
           } = updated_state.retry_attempts[issue.id]

    assert reloaded_checkpoint["head"] == loaded_checkpoint["head"]
    assert reloaded_checkpoint["branch"] == loaded_checkpoint["branch"]
    assert reloaded_checkpoint["resume_ready"] == true
    assert reloaded_checkpoint["resume_mode"] == "resume_checkpoint"
    assert reloaded_checkpoint["resume_fallback_reason"] == nil
    assert reloaded_checkpoint["workpad_ref"] == "comment-runtime-smoke"
    assert reloaded_checkpoint["open_pr"]["number"] == 78
  end

  @tag :workflow_contract
  test "workflow_contract reload applies updated before_run hook and codex settings to future runs" do
    test_root = RuntimeSmokeSupport.unique_test_root("symphony-runtime-smoke-workflow")
    workspace_root = Path.join(test_root, "workspaces")

    issue =
      RuntimeSmokeSupport.issue_fixture(%{
        id: "issue-runtime-smoke-workflow",
        identifier: "RT-WORKFLOW",
        title: "Workflow contract smoke"
      })

    issue_state_fetcher = fn [_issue_id] ->
      {:ok, [RuntimeSmokeSupport.snapshot_issue(issue, "Done")]}
    end

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        tracker_active_states: ["In Progress"],
        codex_approval_policy: "never",
        codex_stall_timeout_ms: 111,
        max_turns: 1,
        hook_before_run: "printf 'v1' > workflow-contract.txt",
        prompt: "Workflow contract prompt v1"
      )

      assert Config.settings!().codex.stall_timeout_ms == 111

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 max_turns: 1,
                 trace_id: "trace-runtime-smoke-workflow-v1",
                 issue_state_fetcher: issue_state_fetcher
               )

      workspace = Path.join(workspace_root, issue.identifier)
      assert File.read!(Path.join(workspace, "workflow-contract.txt")) == "v1"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        tracker_active_states: ["In Progress"],
        codex_approval_policy: "never",
        codex_stall_timeout_ms: 222,
        max_turns: 1,
        hook_before_run: "printf 'v2' > workflow-contract.txt",
        prompt: "Workflow contract prompt v2"
      )

      assert :ok = WorkflowStore.force_reload()
      assert Config.settings!().codex.stall_timeout_ms == 222
      assert {:ok, %{prompt: "Workflow contract prompt v2"}} = Workflow.current()

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 max_turns: 1,
                 trace_id: "trace-runtime-smoke-workflow-v2",
                 issue_state_fetcher: issue_state_fetcher
               )

      assert File.read!(Path.join(workspace, "workflow-contract.txt")) == "v2"
    after
      File.rm_rf(test_root)
    end
  end
end
