defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.manual_intervention_state == "Blocked"
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.tracker.team_key == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_team_key: nil
    )

    assert {:error, :missing_linear_polling_scope} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: "LET"
    )

    assert :ok = Config.validate!()
    assert Config.settings!().tracker.team_key == "LET"
    assert Config.linear_polling_scope() == {:team, "LET"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "   ",
      tracker_team_key: "   "
    )

    assert {:error, :missing_linear_polling_scope} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      tracker_team_key: "LET"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.team_key"
    assert message =~ "Linear polling scope"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      tracker_team_key: nil,
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert Map.get(tracker, "project_slug") == "symphony-bd5bc5b51675"
    assert is_list(Map.get(tracker, "active_states"))
    assert Map.get(tracker, "manual_intervention_state") == "Blocked"
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "export GIT_TERMINAL_PROMPT=0"
    assert Map.get(hooks, "after_create") =~ "git clone --depth 1"
    assert Map.get(hooks, "after_create") =~ "SYMPHONY_SOURCE_REPO_URL"
    assert Map.get(hooks, "after_create") =~ "https://github.com/maximlafe/symphony.git"
    assert Map.get(hooks, "after_create") =~ "make symphony-bootstrap"
    assert Map.get(hooks, "before_remove") =~ "gh pr list --head \"$branch\" --state open --json number"
    assert Map.get(hooks, "before_remove") =~ "gh pr close \"$pr\" --comment"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "repository root exposes the symphony-bootstrap contract" do
    repo_root = Path.expand("../../..", __DIR__)
    makefile_path = Path.join(repo_root, "Makefile")

    assert File.exists?(makefile_path)

    makefile = File.read!(makefile_path)

    assert makefile =~ ".PHONY:"
    assert makefile =~ "test: symphony-validate symphony-dashboard-checks symphony-nginx-proxy-contract"
    assert makefile =~ "symphony-preflight:"
    assert makefile =~ "symphony-bootstrap:"
    assert makefile =~ "symphony-dashboard-checks:"
    assert makefile =~ "symphony-runtime-smoke:"
    assert makefile =~ "symphony-handoff-check:"
    assert makefile =~ "symphony-nginx-proxy-contract:"
    assert makefile =~ "symphony-nginx-proxy-smoke:"
    assert makefile =~ "symphony-validate:"
    assert makefile =~ "symphony-live-e2e:"
    assert makefile =~ "gh auth setup-git"
    assert makefile =~ "$(MISE) install"
    assert makefile =~ "$(MISE) exec -- mix setup"
    assert makefile =~ "$(MISE) exec -- $(MAKE) dashboard"
    assert makefile =~ "$(MISE) exec -- $(MAKE) runtime-smoke SCENARIO=\"$(SCENARIO)\""
    assert makefile =~ "python3 scripts/symphony_nginx_proxy_smoke.py --contract-only"
    assert makefile =~ "python3 scripts/symphony_nginx_proxy_smoke.py"
    assert makefile =~ "$(MISE) exec -- $(MAKE) validate"
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and schedules cleanup for non-retained artifacts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)
    issue_tmp_dir = Path.join("/tmp", "symphony-#{issue_identifier}-#{System.unique_integer([:positive])}")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        workspace_cleanup_keep_recent: 0
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)
      File.mkdir_p!(issue_tmp_dir)
      File.write!(Path.join(issue_tmp_dir, "marker.txt"), issue_identifier)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)

      Enum.each(1..20, fn _attempt ->
        if File.exists?(workspace) or File.exists?(issue_tmp_dir) do
          Process.sleep(50)
        end
      end)

      refute File.exists?(workspace)
      refute File.exists?(issue_tmp_dir)
    after
      if is_nil(previous_memory_issues) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)
      end

      File.rm_rf(test_root)
      File.rm_rf(issue_tmp_dir)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)

      state =
        wait_for_orchestrator_state(pid, fn state ->
          not Map.has_key?(state.running, issue_id) and not MapSet.member?(state.claimed, issue_id)
        end)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    state =
      wait_for_orchestrator_state(pid, fn state ->
        not Map.has_key?(state.running, issue_id) and
          MapSet.member?(state.completed, issue_id) and
          is_map(state.retry_attempts[issue_id])
      end)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert_due_in_range(due_at_ms, 2_000, 5_500)
  end

  test "normal worker exit resets continuation backoff after failure-driven retry" do
    issue_id = "issue-resume-after-failure"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationResetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558A",
      retry_attempt: 3,
      retry_delay_type: nil,
      issue: %Issue{id: issue_id, identifier: "MT-558A", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    state =
      wait_for_orchestrator_state(pid, fn state ->
        match?(%{attempt: 1}, state.retry_attempts[issue_id])
      end)

    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert_due_in_range(due_at_ms, 2_000, 5_500)
  end

  test "normal worker exit over continuation ceiling blocks with controlled handoff" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-continuation-ceiling-normal"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_max_continuation_attempts: 2
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :ContinuationCeilingNormalOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-558-limit",
        retry_attempt: 2,
        retry_delay_type: :continuation,
        issue: %Issue{id: issue_id, identifier: "MT-558-limit", state: "In Progress"},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 1_500
      assert blocker_body =~ "selected_rule: `continuation_attempt_limit_exceeded`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "reason: `continuation_attempt_limit_exceeded`"
      assert blocker_body =~ "failed_attempt: `3`"
      assert blocker_body =~ "failure_class: `continuation_attempt_limit_exceeded`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      state =
        wait_for_orchestrator_state(pid, fn state ->
          not Map.has_key?(state.retry_attempts, issue_id) and not MapSet.member?(state.claimed, issue_id)
        end)

      refute Map.has_key?(state.retry_attempts, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "identical continuation surface after one queued retry blocks repeated continuation" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-continuation-dedupe-block"
    issue_identifier = "MT-CONTINUATION-DEDUPE-BLOCK"
    trace_id = "trace-continuation-dedupe-block"
    runtime_head_sha = "runtime-head-continuation-dedupe"
    workspace_diff_fingerprint = "workspace-diff-continuation-stable"
    validation_bundle_fingerprint = "validation-bundle-continuation-stable"
    feedback_digest = "feedback-continuation-stable"
    continuation_reason = "normal_exit"
    first_ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :ContinuationDedupeBlockOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue = %Issue{id: issue_id, identifier: issue_identifier, state: "In Progress"}
      initial_state = :sys.get_state(pid)

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            continuation_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              workspace_diff_fingerprint: workspace_diff_fingerprint,
              validation_bundle_fingerprint: validation_bundle_fingerprint,
              feedback_digest: feedback_digest,
              continuation_reason: continuation_reason
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, first_ref, :process, self(), :normal})

      first_state =
        wait_for_orchestrator_state(pid, fn state ->
          match?(
            %{
              attempt: 1,
              delay_type: :continuation,
              runtime_head_sha: ^runtime_head_sha,
              workspace_diff_fingerprint: ^workspace_diff_fingerprint,
              validation_bundle_fingerprint: ^validation_bundle_fingerprint,
              feedback_digest: ^feedback_digest,
              continuation_reason: ^continuation_reason
            },
            state.retry_attempts[issue_id]
          ) and is_binary(state.retry_dedupe_keys[issue_id])
        end)

      cancel_retry_timer(first_state.retry_attempts[issue_id])
      second_ref = make_ref()

      replace_orchestrator_state!(pid, fn current_state ->
        current_state
        |> Map.put(:running, %{
          issue_id =>
            continuation_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              workspace_diff_fingerprint: workspace_diff_fingerprint,
              validation_bundle_fingerprint: validation_bundle_fingerprint,
              feedback_digest: feedback_digest,
              continuation_reason: continuation_reason,
              retry_attempt: 1,
              retry_delay_type: :continuation
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, second_ref, :process, self(), :normal})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 1_500
      assert blocker_body =~ "selected_rule: `retry_dedupe_hit`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "failure_class: `retry_dedupe_hit`"
      assert blocker_body =~ "retry_action: `stop`"
      assert blocker_body =~ "continuation_reason=normal_exit"
      assert blocker_body =~ runtime_head_sha
      assert blocker_body =~ workspace_diff_fingerprint
      assert blocker_body =~ validation_bundle_fingerprint
      assert blocker_body =~ feedback_digest
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      final_state =
        wait_for_orchestrator_state(pid, fn state ->
          state.running == %{} and
            not Map.has_key?(state.retry_attempts, issue_id) and
            not MapSet.member?(state.claimed, issue_id)
        end)

      refute Map.has_key?(final_state.retry_dedupe_keys, issue_id)
      refute Map.has_key?(final_state.retry_attempts, issue_id)
      refute MapSet.member?(final_state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "changed continuation surface does not dedupe and keeps continuation allowed" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-continuation-dedupe-progress"
    issue_identifier = "MT-CONTINUATION-DEDUPE-PROGRESS"
    trace_id = "trace-continuation-dedupe-progress"
    runtime_head_sha = "runtime-head-continuation-progress"
    validation_bundle_fingerprint = "validation-bundle-continuation-progress"
    feedback_digest = "feedback-continuation-progress"
    continuation_reason = "normal_exit"
    first_workspace_diff_fingerprint = "workspace-diff-continuation-first"
    second_workspace_diff_fingerprint = "workspace-diff-continuation-second"
    first_ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :ContinuationDedupeProgressOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue = %Issue{id: issue_id, identifier: issue_identifier, state: "In Progress"}
      initial_state = :sys.get_state(pid)

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            continuation_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              workspace_diff_fingerprint: first_workspace_diff_fingerprint,
              validation_bundle_fingerprint: validation_bundle_fingerprint,
              feedback_digest: feedback_digest,
              continuation_reason: continuation_reason
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, first_ref, :process, self(), :normal})

      first_state =
        wait_for_orchestrator_state(pid, fn state ->
          match?(
            %{
              attempt: 1,
              delay_type: :continuation,
              workspace_diff_fingerprint: ^first_workspace_diff_fingerprint
            },
            state.retry_attempts[issue_id]
          ) and is_binary(state.retry_dedupe_keys[issue_id])
        end)

      cancel_retry_timer(first_state.retry_attempts[issue_id])
      first_retry_key = first_state.retry_dedupe_keys[issue_id]
      second_ref = make_ref()

      replace_orchestrator_state!(pid, fn current_state ->
        current_state
        |> Map.put(:running, %{
          issue_id =>
            continuation_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              workspace_diff_fingerprint: second_workspace_diff_fingerprint,
              validation_bundle_fingerprint: validation_bundle_fingerprint,
              feedback_digest: feedback_digest,
              continuation_reason: continuation_reason,
              retry_attempt: 1,
              retry_delay_type: :continuation
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, second_ref, :process, self(), :normal})

      second_state =
        wait_for_orchestrator_state(pid, fn state ->
          match?(
            %{
              attempt: 2,
              delay_type: :continuation,
              workspace_diff_fingerprint: ^second_workspace_diff_fingerprint
            },
            state.retry_attempts[issue_id]
          ) and is_binary(state.retry_dedupe_keys[issue_id]) and state.retry_dedupe_keys[issue_id] != first_retry_key
        end)

      cancel_retry_timer(second_state.retry_attempts[issue_id])
      refute_received {:memory_tracker_comment, ^issue_id, _comment}
      refute_received {:memory_tracker_state_update, ^issue_id, "Blocked"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "failure after continuation retry starts failure backoff from attempt 1" do
    issue_id = "issue-continuation-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationCrashOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(), codex_max_continuation_attempts: 1)

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558B",
      retry_attempt: 2,
      retry_delay_type: :continuation,
      issue: %Issue{id: issue_id, identifier: "MT-558B", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})

    state =
      wait_for_orchestrator_state(pid, fn state ->
        match?(%{attempt: 1}, state.retry_attempts[issue_id])
      end)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-558B",
             error: "agent exited: :boom",
             error_class: "transient"
           } = state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 7_000, 10_500)
  end

  test "spawn failure after continuation retry uses normal failure backoff" do
    issue_id = "issue-continuation-spawn-failure"
    retry_token = make_ref()
    task_supervisor = install_failing_task_supervisor_for_test()

    on_exit(fn ->
      restore_task_supervisor_for_test(task_supervisor)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_accounts: [%{id: "primary", codex_home: "/tmp/codex-primary"}]
    )

    issue = %Issue{
      id: issue_id,
      identifier: "MT-558C",
      title: "Continuation spawn failure",
      state: "In Progress"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{
        issue_id => %{
          attempt: 1,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: issue.identifier,
          trace_id: "trace-continuation-spawn",
          error: nil,
          error_class: nil,
          delay_type: :continuation
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
             Orchestrator.handle_info({:retry_issue, issue_id, retry_token}, state)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             error: error,
             error_class: "transient",
             delay_type: nil,
             resume_mode: "fallback_reread",
             resume_fallback_reason: "resume_checkpoint_unavailable",
             resume_checkpoint: resume_checkpoint
           } = updated_state.retry_attempts[issue_id]

    assert error =~ "failed to spawn agent:"
    assert resume_checkpoint["resume_mode"] == "fallback_reread"
    assert resume_checkpoint["resume_fallback_reason"] == "resume_checkpoint_unavailable"
    assert_due_in_range(due_at_ms, 7_000, 10_500)
  end

  test "spawn failure after failover retry uses normal failure backoff" do
    issue_id = "issue-failover-spawn-failure"
    retry_token = make_ref()
    task_supervisor = install_failing_task_supervisor_for_test()

    on_exit(fn ->
      restore_task_supervisor_for_test(task_supervisor)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_accounts: [%{id: "primary", codex_home: "/tmp/codex-primary"}]
    )

    issue = %Issue{
      id: issue_id,
      identifier: "MT-558D",
      title: "Failover spawn failure",
      state: "In Progress"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{
        issue_id => %{
          attempt: 1,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: issue.identifier,
          trace_id: "trace-failover-spawn",
          error: "account failover: threshold exceeded",
          error_class: "transient",
          delay_type: :failover
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
             Orchestrator.handle_info({:retry_issue, issue_id, retry_token}, state)

    assert %{
             attempt: 2,
             due_at_ms: due_at_ms,
             error: error,
             error_class: "transient",
             delay_type: nil
           } = updated_state.retry_attempts[issue_id]

    assert error =~ "failed to spawn agent:"
    assert_due_in_range(due_at_ms, 17_000, 20_500)
  end

  test "failover retry prefers a loaded ready checkpoint over a queued fallback checkpoint" do
    issue_id = "issue-failover-spawn-reload-checkpoint"
    retry_token = make_ref()
    task_supervisor = install_failing_task_supervisor_for_test()
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-failover-reload-checkpoint-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")

    on_exit(fn ->
      restore_task_supervisor_for_test(task_supervisor)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      codex_accounts: [%{id: "primary", codex_home: "/tmp/codex-primary"}]
    )

    issue = %Issue{
      id: issue_id,
      identifier: "MT-558E",
      title: "Failover spawn reload checkpoint",
      state: "In Progress"
    }

    workspace = init_workspace_repo!(workspace_root, issue.identifier)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nReloaded state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-789")

    loaded_checkpoint =
      SymphonyElixir.ResumeCheckpoint.capture(
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

    assert loaded_checkpoint["resume_ready"] == true
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    queued_fallback =
      SymphonyElixir.ResumeCheckpoint.for_prompt(%{
        "fallback_reasons" => ["resume checkpoint capture failed: boom"]
      })

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{
        issue_id => %{
          attempt: 1,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: issue.identifier,
          trace_id: "trace-failover-spawn-reload",
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
             Orchestrator.handle_info({:retry_issue, issue_id, retry_token}, state)

    assert %{
             attempt: 2,
             due_at_ms: due_at_ms,
             error: error,
             error_class: "transient",
             delay_type: nil,
             resume_mode: "resume_checkpoint",
             resume_fallback_reason: nil,
             resume_checkpoint: reloaded_checkpoint
           } = updated_state.retry_attempts[issue_id]

    assert error =~ "failed to spawn agent:"
    assert_due_in_range(due_at_ms, 17_000, 20_500)
    assert reloaded_checkpoint["resume_ready"] == true
    assert reloaded_checkpoint["resume_mode"] == "resume_checkpoint"
    assert reloaded_checkpoint["resume_fallback_reason"] == nil
    assert reloaded_checkpoint["workpad_ref"] == "comment-789"
    assert reloaded_checkpoint["open_pr"]["number"] == 78

    refute Enum.any?(
             reloaded_checkpoint["fallback_reasons"],
             &String.contains?(&1, "capture failed")
           )
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})

    state =
      wait_for_orchestrator_state(pid, fn state ->
        match?(%{attempt: 3}, state.retry_attempts[issue_id])
      end)

    assert %{
             attempt: 3,
             due_at_ms: due_at_ms,
             identifier: "MT-559",
             error: "agent exited: :boom",
             error_class: "transient"
           } = state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 37_000, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})

    state =
      wait_for_orchestrator_state(pid, fn state ->
        match?(%{attempt: 1}, state.retry_attempts[issue_id])
      end)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-560",
             error: "agent exited: :boom",
             error_class: "transient"
           } = state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 7_000, 10_500)
  end

  test "permanent worker failure moves issue to Blocked without retrying" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-compile"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :PermanentFailureOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-562",
        issue: %Issue{id: issue_id, identifier: "MT-562", state: "In Progress"},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(
        pid,
        {:DOWN, ref, :process, self(), {:agent_run_failed, {:workspace_hook_failed, "before_run", 1, "CompileError: undefined function"}}}
      )

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "error_class: `permanent`"
      assert blocker_body =~ "CompileError"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      state =
        wait_for_orchestrator_state(pid, fn state ->
          not MapSet.member?(state.claimed, issue_id) and not Map.has_key?(state.retry_attempts, issue_id)
        end)

      refute Map.has_key?(state.retry_attempts, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "semi-permanent failures retry up to the configured limit then escalate" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-semi"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :SemiPermanentFailureOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-563",
        retry_attempt: 1,
        issue: %Issue{id: issue_id, identifier: "MT-563", state: "In Progress"},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state =
        wait_for_orchestrator_state(pid, fn state ->
          match?(%{attempt: 2, error_class: "semi_permanent"}, state.retry_attempts[issue_id])
        end)

      assert %{attempt: 2, error_class: "semi_permanent"} = state.retry_attempts[issue_id]

      retry_ref = make_ref()

      :sys.replace_state(pid, fn current_state ->
        current_running_entry = %{running_entry | ref: retry_ref, retry_attempt: 3}

        current_state
        |> Map.put(:running, %{issue_id => current_running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
      end)

      send(pid, {:DOWN, retry_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "error_class: `semi_permanent`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      final_state =
        wait_for_orchestrator_state(pid, fn state ->
          not MapSet.member?(state.claimed, issue_id) and not Map.has_key?(state.retry_attempts, issue_id)
        end)

      refute Map.has_key?(final_state.retry_attempts, issue_id)
      refute MapSet.member?(final_state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "quota exhaustion cools down the failing account and switches future retries to another healthy account" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-quota-account-switch"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_accounts: [
          %{id: "primary", codex_home: "/tmp/codex-primary"},
          %{id: "secondary", codex_home: "/tmp/codex-secondary"}
        ]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :QuotaSwitchOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-564",
        issue: %Issue{id: issue_id, identifier: "MT-564", state: "In Progress"},
        trace_id: "trace-quota-switch",
        codex_account_id: "primary",
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:codex_accounts, %{
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
          },
          "secondary" => %{
            id: "secondary",
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
        })
        |> Map.put(:active_codex_account_id, "primary")
      end)

      send(
        pid,
        {:DOWN, ref, :process, self(),
         {:agent_run_failed,
          {:turn_failed,
           %{
             "error" => %{
               "message" => "RESOURCE_EXHAUSTED: requests per day limit reached for this account"
             }
           }}}}
      )

      state =
        wait_for_orchestrator_state(pid, fn state ->
          primary = Map.get(state.codex_accounts, "primary")

          match?(%{attempt: 1, error_class: "semi_permanent"}, state.retry_attempts[issue_id]) and
            state.active_codex_account_id == "secondary" and
            is_map(primary) and primary.runtime_state == :cooldown and primary.healthy == false
        end)

      assert %{attempt: 1, error_class: "semi_permanent"} = state.retry_attempts[issue_id]
      assert state.active_codex_account_id == "secondary"

      assert %{
               runtime_state: :cooldown,
               healthy: false,
               runtime_health_reason: runtime_health_reason,
               runtime_cooldown_until: %DateTime{}
             } = state.codex_accounts["primary"]

      assert runtime_health_reason =~ "quota_exhausted"
      refute_received {:memory_tracker_comment, ^issue_id, _body}
      refute_received {:memory_tracker_state_update, ^issue_id, _state_name}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "quota exhaustion on the last account blocks the issue instead of waiting in the internal retry queue" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-quota-single-account"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_accounts: [%{id: "primary", codex_home: "/tmp/codex-primary"}]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :QuotaSingleAccountOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-564A",
        issue: %Issue{id: issue_id, identifier: "MT-564A", state: "In Progress"},
        trace_id: "trace-quota-single-account",
        codex_account_id: "primary",
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:codex_accounts, %{
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
        })
        |> Map.put(:active_codex_account_id, "primary")
      end)

      send(
        pid,
        {:DOWN, ref, :process, self(),
         {:agent_run_failed,
          {:turn_failed,
           %{
             "error" => %{
               "message" => "RESOURCE_EXHAUSTED: requests per day limit reached for this account"
             }
           }}}}
      )

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "error_class: `semi_permanent`"
      assert blocker_body =~ "failure_class: `quota_exhausted`"
      assert blocker_body =~ "codex_account_id: `primary`"
      assert blocker_body =~ "retry_action: `switch_account`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      state =
        wait_for_orchestrator_state(pid, fn state ->
          primary = Map.get(state.codex_accounts, "primary")

          not MapSet.member?(state.claimed, issue_id) and
            not Map.has_key?(state.retry_attempts, issue_id) and
            state.active_codex_account_id == nil and
            is_map(primary) and primary.runtime_state == :cooldown and primary.healthy == false
        end)

      refute Map.has_key?(state.retry_attempts, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      assert state.active_codex_account_id == nil
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "switch_account failures ignore the semi-permanent retry limit while a healthy account remains" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-auth-account-switch-after-limit"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_accounts: [
          %{id: "primary", codex_home: "/tmp/codex-primary"},
          %{id: "secondary", codex_home: "/tmp/codex-secondary"}
        ]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :AuthSwitchAfterLimitOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-564B",
        issue: %Issue{id: issue_id, identifier: "MT-564B", state: "In Progress"},
        trace_id: "trace-auth-switch-after-limit",
        codex_account_id: "primary",
        retry_attempt: 3,
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:codex_accounts, %{
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
          },
          "secondary" => %{
            id: "secondary",
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
        })
        |> Map.put(:active_codex_account_id, "primary")
      end)

      send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, "invalid api key for this account"}})

      state =
        wait_for_orchestrator_state(pid, fn state ->
          primary = Map.get(state.codex_accounts, "primary")

          match?(%{attempt: 4, error_class: "semi_permanent"}, state.retry_attempts[issue_id]) and
            state.active_codex_account_id == "secondary" and
            is_map(primary) and primary.runtime_state == :broken and primary.healthy == false
        end)

      assert %{attempt: 4, error_class: "semi_permanent"} = state.retry_attempts[issue_id]
      assert state.active_codex_account_id == "secondary"
      assert %{runtime_state: :broken, healthy: false} = state.codex_accounts["primary"]
      refute_received {:memory_tracker_comment, ^issue_id, _body}
      refute_received {:memory_tracker_state_update, ^issue_id, _state_name}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "auth failure blocks the issue when it leaves no healthy codex accounts" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-auth-account-blocked"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_accounts: [%{id: "primary", codex_home: "/tmp/codex-primary"}]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :AuthBlockedOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-565",
        issue: %Issue{id: issue_id, identifier: "MT-565", state: "In Progress"},
        trace_id: "trace-auth-blocked",
        codex_account_id: "primary",
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:codex_accounts, %{
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
        })
        |> Map.put(:active_codex_account_id, "primary")
      end)

      send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, "invalid api key for this account"}})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "error_class: `semi_permanent`"
      assert blocker_body =~ "failure_class: `auth_failure`"
      assert blocker_body =~ "codex_account_id: `primary`"
      assert blocker_body =~ "retry_action: `switch_account`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      state =
        wait_for_orchestrator_state(pid, fn state ->
          primary = Map.get(state.codex_accounts, "primary")

          not MapSet.member?(state.claimed, issue_id) and
            not Map.has_key?(state.retry_attempts, issue_id) and
            state.active_codex_account_id == nil and
            is_map(primary) and primary.runtime_state == :broken and primary.healthy == false
        end)

      assert %{runtime_state: :broken, healthy: false} = state.codex_accounts["primary"]
      assert state.active_codex_account_id == nil
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "same failure key after one queued retry blocks the issue" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-feedback-dedupe-block"
    issue_identifier = "MT-FEEDBACK-DEDUPE-BLOCK"
    trace_id = "trace-feedback-dedupe-block"
    runtime_head_sha = "runtime-head-feedback-dedupe"
    feedback_digest = "feedback-digest-stable"
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-feedback-dedupe-block-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      issue = prepare_feedback_dedupe_issue!(issue_id, issue_identifier, workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :FeedbackDedupeBlockOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      first_ref = make_ref()

      replace_orchestrator_state!(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            feedback_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              feedback_digest: feedback_digest
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, first_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state_after_first_failure =
        wait_for_orchestrator_state(pid, fn state ->
          match?(
            %{
              attempt: 1,
              feedback_digest: ^feedback_digest,
              runtime_head_sha: ^runtime_head_sha
            },
            state.retry_attempts[issue_id]
          )
        end)

      assert %{
               attempt: 1,
               feedback_digest: ^feedback_digest,
               runtime_head_sha: ^runtime_head_sha,
               error_signature: first_error_signature
             } = state_after_first_failure.retry_attempts[issue_id]

      cancel_retry_timer(state_after_first_failure.retry_attempts[issue_id])
      wait_for_orchestrator_state(pid, fn state -> state.poll_check_in_progress == false end)

      second_ref = make_ref()

      replace_orchestrator_state!(pid, fn current_state ->
        current_state
        |> Map.put(:running, %{
          issue_id =>
            feedback_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              feedback_digest: feedback_digest,
              retry_attempt: 1
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, second_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "selected_rule: `retry_dedupe_hit`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "failure_class: `retry_dedupe_hit`"
      assert blocker_body =~ "retry_action: `stop`"
      assert blocker_body =~ first_error_signature
      assert blocker_body =~ runtime_head_sha
      assert blocker_body =~ feedback_digest
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      final_state =
        wait_for_orchestrator_state(pid, fn state ->
          state.running == %{} and
            not Map.has_key?(state.retry_attempts, issue_id) and
            not MapSet.member?(state.claimed, issue_id)
        end)

      assert final_state.running == %{}
      refute Map.has_key?(final_state.retry_attempts, issue_id)
      refute MapSet.member?(final_state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "same validation bundle and workspace diff without feedback digest blocks repeated reruns" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-validation-dedupe-without-feedback"
    issue_identifier = "MT-VALIDATION-DEDUPE-NO-FEEDBACK"
    trace_id = "trace-validation-dedupe-without-feedback"

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-validation-dedupe-no-feedback-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")

    try do
      workspace = init_workspace_repo!(workspace_root, issue_identifier)
      File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nValidation dedupe state")
      File.write!(Path.join(workspace, ".workpad-id"), "comment-validation-dedupe")

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Validation retry dedupe without feedback",
        description: "Track validation retry dedupe when feedback digest is missing",
        state: "In Progress",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      runtime_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :ValidationDedupeNoFeedbackOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      first_ref = make_ref()

      replace_orchestrator_state!(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            validation_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              current_command: "mix test elixir/test/symphony_elixir/retry_failover_decision_test.exs"
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, first_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state_after_first_failure =
        wait_for_orchestrator_state(pid, fn state ->
          match?(
            %{
              attempt: 1,
              validation_bundle_fingerprint: "validation:test",
              workspace_diff_fingerprint: workspace_diff_fingerprint
            }
            when is_binary(workspace_diff_fingerprint),
            state.retry_attempts[issue_id]
          )
        end)
        |> then(fn state ->
          cancel_retry_timer(state.retry_attempts[issue_id])
          state
        end)

      first_retry = state_after_first_failure.retry_attempts[issue_id]
      first_retry_key = state_after_first_failure.retry_dedupe_keys[issue_id]

      assert is_binary(first_retry_key)
      assert first_retry.validation_bundle_fingerprint == "validation:test"
      assert is_binary(first_retry.workspace_diff_fingerprint)
      stop_orchestrator(pid)

      second_ref = make_ref()
      retry_orchestrator_name = Module.concat(__MODULE__, :ValidationDedupeNoFeedbackRetryOrchestrator)
      {:ok, retry_pid} = Orchestrator.start_link(name: retry_orchestrator_name)

      on_exit(fn ->
        stop_orchestrator(retry_pid)
      end)

      retry_initial_state = :sys.get_state(retry_pid)

      replace_orchestrator_state!(retry_pid, fn _ ->
        retry_initial_state
        |> Map.put(:running, %{
          issue_id =>
            validation_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              current_command: "make test",
              retry_attempt: 1
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:retry_dedupe_keys, %{issue_id => first_retry_key})
      end)

      send(retry_pid, {:DOWN, second_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "selected_rule: `retry_dedupe_hit`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "validation_bundle_fingerprint=validation:test"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "repeated stall failures with different elapsed times are deduped for the same validation wait snapshot" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-validation-stall-dedupe"
    issue_identifier = "MT-VALIDATION-STALL-DEDUPE"
    trace_id = "trace-validation-stall-dedupe"

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-validation-stall-dedupe-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")

    try do
      workspace = init_workspace_repo!(workspace_root, issue_identifier)
      File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nValidation stall dedupe state")
      File.write!(Path.join(workspace, ".workpad-id"), "comment-validation-stall-dedupe")

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Validation stall dedupe",
        description: "Track dedupe when stalled validation restarts with unchanged state",
        state: "In Progress",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      runtime_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :ValidationStallDedupeOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      first_ref = make_ref()

      replace_orchestrator_state!(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            validation_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              current_command: "make symphony-validate",
              external_step: "exec_wait"
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(
        pid,
        {:DOWN, first_ref, :process, self(), {:agent_run_failed, "stalled for 312655ms without codex activity"}}
      )

      state_after_first_failure =
        wait_for_orchestrator_state(pid, fn state ->
          match?(%{attempt: 1, validation_bundle_fingerprint: "validation:repo-validate"}, state.retry_attempts[issue_id])
        end)
        |> then(fn state ->
          cancel_retry_timer(state.retry_attempts[issue_id])
          state
        end)

      first_retry_key = state_after_first_failure.retry_dedupe_keys[issue_id]
      assert is_binary(first_retry_key)
      stop_orchestrator(pid)

      second_ref = make_ref()
      retry_orchestrator_name = Module.concat(__MODULE__, :ValidationStallDedupeRetryOrchestrator)
      {:ok, retry_pid} = Orchestrator.start_link(name: retry_orchestrator_name)

      on_exit(fn ->
        stop_orchestrator(retry_pid)
      end)

      retry_initial_state = :sys.get_state(retry_pid)

      replace_orchestrator_state!(retry_pid, fn _ ->
        retry_initial_state
        |> Map.put(:running, %{
          issue_id =>
            validation_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              current_command: "make symphony-validate",
              external_step: "exec_wait",
              retry_attempt: 1
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:retry_dedupe_keys, %{issue_id => first_retry_key})
      end)

      send(
        retry_pid,
        {:DOWN, second_ref, :process, self(), {:agent_run_failed, "stalled for 305994ms without codex activity"}}
      )

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "selected_rule: `retry_dedupe_hit`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "validation_bundle_fingerprint=validation:repo-validate"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "repeated stall failures are deduped for dialyzer validation wait snapshot" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-dialyzer-stall-dedupe"
    issue_identifier = "MT-DIALYZER-STALL-DEDUPE"
    trace_id = "trace-dialyzer-stall-dedupe"

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dialyzer-stall-dedupe-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")

    try do
      workspace = init_workspace_repo!(workspace_root, issue_identifier)
      File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nDialyzer stall dedupe state")
      File.write!(Path.join(workspace, ".workpad-id"), "comment-dialyzer-stall-dedupe")

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Dialyzer validation stall dedupe",
        description: "Track dedupe when stalled dialyzer validation restarts with unchanged state",
        state: "In Progress",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      runtime_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :DialyzerStallDedupeOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      first_ref = make_ref()

      replace_orchestrator_state!(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            validation_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              current_command: "mix dialyzer --format short",
              external_step: "exec_wait"
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(
        pid,
        {:DOWN, first_ref, :process, self(), {:agent_run_failed, "stalled for 312655ms without codex activity"}}
      )

      state_after_first_failure =
        wait_for_orchestrator_state(pid, fn state ->
          match?(%{attempt: 1, validation_bundle_fingerprint: "validation:dialyzer"}, state.retry_attempts[issue_id])
        end)
        |> then(fn state ->
          cancel_retry_timer(state.retry_attempts[issue_id])
          state
        end)

      first_retry_key = state_after_first_failure.retry_dedupe_keys[issue_id]
      assert is_binary(first_retry_key)
      stop_orchestrator(pid)

      second_ref = make_ref()
      retry_orchestrator_name = Module.concat(__MODULE__, :DialyzerStallDedupeRetryOrchestrator)
      {:ok, retry_pid} = Orchestrator.start_link(name: retry_orchestrator_name)

      on_exit(fn ->
        stop_orchestrator(retry_pid)
      end)

      retry_initial_state = :sys.get_state(retry_pid)

      replace_orchestrator_state!(retry_pid, fn _ ->
        retry_initial_state
        |> Map.put(:running, %{
          issue_id =>
            validation_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              current_command: "mix dialyzer --format short",
              external_step: "exec_wait",
              retry_attempt: 1
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:retry_dedupe_keys, %{issue_id => first_retry_key})
      end)

      send(
        retry_pid,
        {:DOWN, second_ref, :process, self(), {:agent_run_failed, "stalled for 305994ms without codex activity"}}
      )

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "selected_rule: `retry_dedupe_hit`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "validation_bundle_fingerprint=validation:dialyzer"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "changed workspace diff allows another validation retry without feedback digest" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-validation-dedupe-workspace-change"
    issue_identifier = "MT-VALIDATION-DEDUPE-DIFF-CHANGE"
    trace_id = "trace-validation-dedupe-workspace-change"

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-validation-dedupe-diff-change-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")

    try do
      workspace = init_workspace_repo!(workspace_root, issue_identifier)
      File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nValidation dedupe state")
      File.write!(Path.join(workspace, ".workpad-id"), "comment-validation-dedupe")

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Validation retry dedupe with workspace diff change",
        description: "Track validation retry dedupe when workspace diff changes",
        state: "In Progress",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      runtime_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :ValidationDedupeWorkspaceChangeOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      first_ref = make_ref()

      replace_orchestrator_state!(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            validation_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              current_command: "mix test elixir/test/symphony_elixir/retry_failover_decision_test.exs"
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, first_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state_after_first_failure =
        wait_for_orchestrator_state(pid, fn state ->
          match?(%{attempt: 1, validation_bundle_fingerprint: "validation:test"}, state.retry_attempts[issue_id])
        end)
        |> then(fn state ->
          cancel_retry_timer(state.retry_attempts[issue_id])
          state
        end)

      first_retry = state_after_first_failure.retry_attempts[issue_id]
      first_retry_key = state_after_first_failure.retry_dedupe_keys[issue_id]

      assert is_binary(first_retry_key)
      assert is_binary(first_retry.workspace_diff_fingerprint)
      stop_orchestrator(pid)

      File.write!(Path.join(workspace, "tracked.txt"), "runtime head updated\n")

      second_ref = make_ref()
      retry_orchestrator_name = Module.concat(__MODULE__, :ValidationDedupeWorkspaceChangeRetryOrchestrator)
      {:ok, retry_pid} = Orchestrator.start_link(name: retry_orchestrator_name)

      on_exit(fn ->
        stop_orchestrator(retry_pid)
      end)

      retry_initial_state = :sys.get_state(retry_pid)

      replace_orchestrator_state!(retry_pid, fn _ ->
        retry_initial_state
        |> Map.put(:running, %{
          issue_id =>
            validation_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              current_command: "mix test --cover elixir/test/symphony_elixir/retry_failover_decision_test.exs",
              retry_attempt: 1
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:retry_dedupe_keys, %{issue_id => first_retry_key})
      end)

      send(retry_pid, {:DOWN, second_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state_after_second_failure =
        wait_for_orchestrator_state(retry_pid, fn state ->
          match?(%{attempt: 2, validation_bundle_fingerprint: "validation:test"}, state.retry_attempts[issue_id])
        end)

      assert %{attempt: 2} = state_after_second_failure.retry_attempts[issue_id]

      refute first_retry.workspace_diff_fingerprint ==
               state_after_second_failure.retry_attempts[issue_id].workspace_diff_fingerprint

      refute_received {:memory_tracker_comment, ^issue_id, _body}
      refute_received {:memory_tracker_state_update, ^issue_id, _state_name}
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "changed feedback digest allows another failure-driven retry" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-feedback-dedupe-feedback-change"
    issue_identifier = "MT-FEEDBACK-DEDUPE-FEEDBACK"
    trace_id = "trace-feedback-dedupe-feedback-change"
    runtime_head_sha = "runtime-head-feedback-change"
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-feedback-dedupe-feedback-change-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      issue = prepare_feedback_dedupe_issue!(issue_id, issue_identifier, workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :FeedbackDedupeFeedbackChangeOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      first_ref = make_ref()

      replace_orchestrator_state!(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            feedback_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              feedback_digest: "feedback-digest-a"
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, first_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state_after_first_failure =
        wait_for_orchestrator_state(pid, fn state ->
          match?(%{attempt: 1, feedback_digest: "feedback-digest-a"}, state.retry_attempts[issue_id])
        end)
        |> then(fn state ->
          cancel_retry_timer(state.retry_attempts[issue_id])
          state
        end)

      first_retry_key = state_after_first_failure.retry_dedupe_keys[issue_id]
      assert is_binary(first_retry_key)
      stop_orchestrator(pid)

      second_ref = make_ref()
      retry_orchestrator_name = Module.concat(__MODULE__, :FeedbackDedupeFeedbackChangeRetryOrchestrator)
      {:ok, retry_pid} = Orchestrator.start_link(name: retry_orchestrator_name)

      on_exit(fn ->
        stop_orchestrator(retry_pid)
      end)

      retry_initial_state = :sys.get_state(retry_pid)

      replace_orchestrator_state!(retry_pid, fn _ ->
        retry_initial_state
        |> Map.put(:running, %{
          issue_id =>
            feedback_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              feedback_digest: "feedback-digest-b",
              retry_attempt: 1
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:retry_dedupe_keys, %{issue_id => first_retry_key})
      end)

      send(retry_pid, {:DOWN, second_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state_after_second_failure =
        wait_for_orchestrator_state(retry_pid, fn state ->
          match?(%{attempt: 2, feedback_digest: "feedback-digest-b"}, state.retry_attempts[issue_id])
        end)

      assert %{attempt: 2, feedback_digest: "feedback-digest-b"} =
               state_after_second_failure.retry_attempts[issue_id]

      refute_received {:memory_tracker_comment, ^issue_id, _body}
      refute_received {:memory_tracker_state_update, ^issue_id, _state_name}
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "changed runtime head allows another failure-driven retry" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-feedback-dedupe-head-change"
    issue_identifier = "MT-FEEDBACK-DEDUPE-HEAD"
    trace_id = "trace-feedback-dedupe-head-change"
    feedback_digest = "feedback-digest-stable"
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-feedback-dedupe-head-change-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      issue = prepare_feedback_dedupe_issue!(issue_id, issue_identifier, workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :FeedbackDedupeHeadChangeOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      first_ref = make_ref()

      replace_orchestrator_state!(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            feedback_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: "runtime-head-a",
              feedback_digest: feedback_digest
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, first_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state_after_first_failure =
        wait_for_orchestrator_state(pid, fn state ->
          match?(%{attempt: 1, runtime_head_sha: "runtime-head-a"}, state.retry_attempts[issue_id])
        end)
        |> then(fn state ->
          cancel_retry_timer(state.retry_attempts[issue_id])
          state
        end)

      first_retry_key = state_after_first_failure.retry_dedupe_keys[issue_id]
      assert is_binary(first_retry_key)
      stop_orchestrator(pid)

      second_ref = make_ref()
      retry_orchestrator_name = Module.concat(__MODULE__, :FeedbackDedupeHeadChangeRetryOrchestrator)
      {:ok, retry_pid} = Orchestrator.start_link(name: retry_orchestrator_name)

      on_exit(fn ->
        stop_orchestrator(retry_pid)
      end)

      retry_initial_state = :sys.get_state(retry_pid)

      replace_orchestrator_state!(retry_pid, fn _ ->
        retry_initial_state
        |> Map.put(:running, %{
          issue_id =>
            feedback_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: "runtime-head-b",
              feedback_digest: feedback_digest,
              retry_attempt: 1
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:retry_dedupe_keys, %{issue_id => first_retry_key})
      end)

      send(retry_pid, {:DOWN, second_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state_after_second_failure =
        wait_for_orchestrator_state(retry_pid, fn state ->
          match?(%{attempt: 2, runtime_head_sha: "runtime-head-b"}, state.retry_attempts[issue_id])
        end)

      assert %{attempt: 2, runtime_head_sha: "runtime-head-b"} =
               state_after_second_failure.retry_attempts[issue_id]

      refute_received {:memory_tracker_comment, ^issue_id, _body}
      refute_received {:memory_tracker_state_update, ^issue_id, _state_name}
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "changed error signature allows another failure-driven retry" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-feedback-dedupe-error-change"
    issue_identifier = "MT-FEEDBACK-DEDUPE-ERROR"
    trace_id = "trace-feedback-dedupe-error-change"
    runtime_head_sha = "runtime-head-error-change"
    feedback_digest = "feedback-digest-error-change"
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-feedback-dedupe-error-change-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      issue = prepare_feedback_dedupe_issue!(issue_id, issue_identifier, workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :FeedbackDedupeErrorChangeOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      first_ref = make_ref()

      replace_orchestrator_state!(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{
          issue_id =>
            feedback_dedupe_running_entry(issue, first_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              feedback_digest: feedback_digest
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, first_ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

      state_after_first_failure =
        wait_for_orchestrator_state(pid, fn state ->
          match?(%{attempt: 1}, state.retry_attempts[issue_id])
        end)
        |> then(fn state ->
          cancel_retry_timer(state.retry_attempts[issue_id])
          state
        end)

      assert %{error_signature: first_error_signature} = state_after_first_failure.retry_attempts[issue_id]
      first_retry_key = state_after_first_failure.retry_dedupe_keys[issue_id]
      assert is_binary(first_retry_key)
      stop_orchestrator(pid)

      second_ref = make_ref()
      retry_orchestrator_name = Module.concat(__MODULE__, :FeedbackDedupeErrorChangeRetryOrchestrator)
      {:ok, retry_pid} = Orchestrator.start_link(name: retry_orchestrator_name)

      on_exit(fn ->
        stop_orchestrator(retry_pid)
      end)

      retry_initial_state = :sys.get_state(retry_pid)

      replace_orchestrator_state!(retry_pid, fn _ ->
        retry_initial_state
        |> Map.put(:running, %{
          issue_id =>
            feedback_dedupe_running_entry(issue, second_ref,
              trace_id: trace_id,
              runtime_head_sha: runtime_head_sha,
              feedback_digest: feedback_digest,
              retry_attempt: 1
            )
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:retry_dedupe_keys, %{issue_id => first_retry_key})
      end)

      send(retry_pid, {:DOWN, second_ref, :process, self(), {:agent_run_failed, "connection reset by peer"}})

      state_after_second_failure =
        wait_for_orchestrator_state(retry_pid, fn state ->
          match?(%{attempt: 2}, state.retry_attempts[issue_id])
        end)

      assert %{attempt: 2, error_signature: second_error_signature} =
               state_after_second_failure.retry_attempts[issue_id]

      refute first_error_signature == second_error_signature
      refute_received {:memory_tracker_comment, ^issue_id, _body}
      refute_received {:memory_tracker_state_update, ^issue_id, _state_name}
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "untrusted turn_failed text does not mark the codex account unhealthy" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-turn-failed-untrusted-auth-text"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_accounts: [%{id: "primary", codex_home: "/tmp/codex-primary"}]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :TurnFailedUntrustedAuthTextOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-565A",
        issue: %Issue{id: issue_id, identifier: "MT-565A", state: "In Progress"},
        trace_id: "trace-turn-failed-untrusted-auth-text",
        codex_account_id: "primary",
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:codex_accounts, %{
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
        })
        |> Map.put(:active_codex_account_id, "primary")
      end)

      send(
        pid,
        {:DOWN, ref, :process, self(), {:agent_run_failed, {:turn_failed, %{"error" => %{"message" => "invalid api key returned by a downstream API"}}}}}
      )

      state =
        wait_for_orchestrator_state(pid, fn state ->
          primary = Map.get(state.codex_accounts, "primary")

          match?(%{attempt: 1, error_class: "semi_permanent"}, state.retry_attempts[issue_id]) and
            MapSet.member?(state.claimed, issue_id) and
            state.active_codex_account_id == "primary" and
            is_map(primary) and primary.healthy == true and is_nil(Map.get(primary, :runtime_state))
        end)

      assert %{attempt: 1, error_class: "semi_permanent"} = state.retry_attempts[issue_id]
      assert state.active_codex_account_id == "primary"
      assert %{healthy: true} = state.codex_accounts["primary"]
      assert is_nil(Map.get(state.codex_accounts["primary"], :runtime_state))
      refute_received {:memory_tracker_comment, ^issue_id, _body}
      refute_received {:memory_tracker_state_update, ^issue_id, _state_name}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "live rate-limit exhaustion fails over a running issue to a healthy replacement account" do
    issue_id = "issue-live-rate-limit-failover"
    issue = %Issue{id: issue_id, identifier: "MT-LIVE-FAILOVER", state: "In Progress"}
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_accounts: [
        %{id: "primary", codex_home: "/tmp/codex-primary"},
        %{id: "secondary", codex_home: "/tmp/codex-secondary"}
      ],
      codex_minimum_remaining_percent: 5,
      codex_monitored_windows_mins: [300, 10_080]
    )

    healthy_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 20},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    exhausted_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 96},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{
        issue_id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          trace_id: "trace-live-failover",
          session_id: "thread-live-failover-turn-1",
          codex_account_id: "primary",
          run_phase: :editing,
          reported_milestones: MapSet.new([:validation_running]),
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          started_at: DateTime.utc_now()
        }
      },
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
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
          rate_limits: healthy_rate_limits
        },
        "secondary" => %{
          id: "secondary",
          explicit?: true,
          healthy: true,
          probe_healthy: true,
          probe_health_reason: nil,
          health_reason: nil,
          auth_mode: "chatgpt",
          requires_openai_auth: false,
          missing_windows_mins: [],
          insufficient_windows_mins: [],
          rate_limits: healthy_rate_limits
        }
      },
      active_codex_account_id: "primary",
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: healthy_rate_limits,
      codex_dispatch_reason: nil
    }

    update = %{
      event: :notification,
      codex_account_id: "primary",
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "type" => "event_msg",
            "payload" => %{
              "type" => "token_count",
              "rate_limits" => exhausted_rate_limits
            }
          }
        }
      },
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

    assert_receive {:retry_issue, ^issue_id, retry_token}, 200
    Process.sleep(10)

    assert updated_state.active_codex_account_id == "secondary"
    refute Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(worker_pid)

    assert %{
             attempt: 1,
             retry_token: ^retry_token,
             error: error,
             error_class: "transient",
             delay_type: :failover,
             retry_failover_decision: %{
               selected_rule: "account_unhealthy_no_checkpoint",
               selected_action: "immediate_preemption"
             }
           } = updated_state.retry_attempts[issue_id]

    assert error =~ "account failover forced_preemption=no_safe_drain_signal:"
    assert %{healthy: false, health_reason: health_reason} = updated_state.codex_accounts["primary"]
    assert health_reason =~ "threshold exceeded"

    assert {:noreply, late_down_state} =
             Orchestrator.handle_info(
               {:DOWN, make_ref(), :process, worker_pid, :shutdown},
               updated_state
             )

    assert late_down_state == updated_state
    refute_received {:retry_issue, ^issue_id, _another_retry_token}
  end

  test "live rate-limit exhaustion preempts when CI wait result reports failed checks" do
    issue_id = "issue-live-rate-limit-ci-failed"
    issue = %Issue{id: issue_id, identifier: "MT-LIVE-CI-FAILED", state: "In Progress"}
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_accounts: [
        %{id: "primary", codex_home: "/tmp/codex-primary"},
        %{id: "secondary", codex_home: "/tmp/codex-secondary"}
      ],
      codex_minimum_remaining_percent: 5,
      codex_monitored_windows_mins: [300, 10_080]
    )

    healthy_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 20},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    exhausted_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 96},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{
        issue_id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          trace_id: "trace-live-ci-failed",
          session_id: "thread-live-ci-failed-turn-1",
          codex_account_id: "primary",
          run_phase: :editing,
          latest_ci_wait_result: %{
            "all_green" => false,
            "failed_checks" => [],
            "pending_checks" => [],
            "checks" => []
          },
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          started_at: DateTime.utc_now()
        }
      },
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
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
          rate_limits: healthy_rate_limits
        },
        "secondary" => %{
          id: "secondary",
          explicit?: true,
          healthy: true,
          probe_healthy: true,
          probe_health_reason: nil,
          health_reason: nil,
          auth_mode: "chatgpt",
          requires_openai_auth: false,
          missing_windows_mins: [],
          insufficient_windows_mins: [],
          rate_limits: healthy_rate_limits
        }
      },
      active_codex_account_id: "primary",
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: healthy_rate_limits,
      codex_dispatch_reason: nil
    }

    update = %{
      event: :notification,
      codex_account_id: "primary",
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "type" => "event_msg",
            "payload" => %{
              "type" => "token_count",
              "rate_limits" => exhausted_rate_limits
            }
          }
        }
      },
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

    assert_receive {:retry_issue, ^issue_id, retry_token}, 200
    Process.sleep(10)

    assert updated_state.active_codex_account_id == "secondary"
    refute Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(worker_pid)

    assert %{
             attempt: 1,
             retry_token: ^retry_token,
             error: error,
             error_class: "transient",
             delay_type: :failover
           } = updated_state.retry_attempts[issue_id]

    assert error =~ "account failover forced_preemption=no_safe_drain_signal:"
  end

  test "live rate-limit exhaustion also fails over sibling runs already on the exhausted account" do
    issue_a = %Issue{id: "issue-live-rate-limit-failover-a", identifier: "MT-LIVE-FAILOVER-A", state: "In Progress"}
    issue_b = %Issue{id: "issue-live-rate-limit-failover-b", identifier: "MT-LIVE-FAILOVER-B", state: "In Progress"}
    issue_a_id = issue_a.id
    issue_b_id = issue_b.id
    worker_a = spawn(fn -> Process.sleep(:infinity) end)
    worker_b = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Enum.each([worker_a, worker_b], fn pid ->
        if Process.alive?(pid) do
          Process.exit(pid, :kill)
        end
      end)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_accounts: [
        %{id: "primary", codex_home: "/tmp/codex-primary"},
        %{id: "secondary", codex_home: "/tmp/codex-secondary"}
      ],
      codex_minimum_remaining_percent: 5,
      codex_monitored_windows_mins: [300, 10_080]
    )

    healthy_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 20},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    exhausted_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 96},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    running_entry = fn issue, worker_pid, trace_id ->
      %{
        pid: worker_pid,
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        trace_id: trace_id,
        session_id: "#{trace_id}-turn-1",
        codex_account_id: "primary",
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        started_at: DateTime.utc_now()
      }
    end

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 2,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{
        issue_a_id => running_entry.(issue_a, worker_a, "trace-live-failover-a"),
        issue_b_id => running_entry.(issue_b, worker_b, "trace-live-failover-b")
      },
      completed: MapSet.new(),
      claimed: MapSet.new([issue_a_id, issue_b_id]),
      retry_attempts: %{},
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
          rate_limits: healthy_rate_limits
        },
        "secondary" => %{
          id: "secondary",
          explicit?: true,
          healthy: true,
          probe_healthy: true,
          probe_health_reason: nil,
          health_reason: nil,
          auth_mode: "chatgpt",
          requires_openai_auth: false,
          missing_windows_mins: [],
          insufficient_windows_mins: [],
          rate_limits: healthy_rate_limits
        }
      },
      active_codex_account_id: "primary",
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: healthy_rate_limits,
      codex_dispatch_reason: nil
    }

    update = %{
      event: :notification,
      codex_account_id: "primary",
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "type" => "event_msg",
            "payload" => %{
              "type" => "token_count",
              "rate_limits" => exhausted_rate_limits
            }
          }
        }
      },
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, after_first_failover} =
             Orchestrator.handle_info({:codex_worker_update, issue_a_id, update}, state)

    assert_receive {:retry_issue, ^issue_a_id, _retry_token_a}, 200
    Process.sleep(10)

    assert after_first_failover.active_codex_account_id == "secondary"
    refute Map.has_key?(after_first_failover.running, issue_a_id)
    assert %{codex_account_id: "primary"} = after_first_failover.running[issue_b_id]
    refute Process.alive?(worker_a)
    assert Process.alive?(worker_b)

    assert {:noreply, after_second_failover} =
             Orchestrator.handle_info({:codex_worker_update, issue_b_id, update}, after_first_failover)

    assert_receive {:retry_issue, ^issue_b_id, _retry_token_b}, 200
    Process.sleep(10)

    assert after_second_failover.active_codex_account_id == "secondary"
    refute Map.has_key?(after_second_failover.running, issue_b_id)
    refute Process.alive?(worker_b)

    assert %{attempt: 1, delay_type: :failover, error_class: "transient"} =
             after_second_failover.retry_attempts[issue_a_id]

    assert %{attempt: 1, delay_type: :failover, error_class: "transient"} =
             after_second_failover.retry_attempts[issue_b_id]
  end

  test "live rate-limit exhaustion drains a run with safe handoff signals instead of failover retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-failover-resume-ready-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue_id = "issue-live-rate-limit-resume-ready"
    issue = %Issue{id: issue_id, identifier: "MT-LIVE-RESUME", state: "In Progress"}
    workspace = init_workspace_repo!(workspace_root, issue.identifier)
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)
    verification_checked_at = DateTime.utc_now()

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end

      File.rm_rf(test_root)
    end)

    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nResume state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-123")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      codex_accounts: [
        %{id: "primary", codex_home: "/tmp/codex-primary"},
        %{id: "secondary", codex_home: "/tmp/codex-secondary"}
      ],
      codex_minimum_remaining_percent: 5,
      codex_monitored_windows_mins: [300, 10_080]
    )

    healthy_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 20},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    exhausted_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 96},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{
        issue_id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          trace_id: "trace-failover-resume",
          session_id: "thread-failover-resume",
          codex_account_id: "primary",
          latest_pr_snapshot: %{
            "url" => "https://github.com/maximlafe/symphony/pull/77",
            "state" => "OPEN",
            "has_pending_checks" => false,
            "has_actionable_feedback" => false
          },
          latest_ci_wait_result: %{"pending_checks" => []},
          verification_result: "passed",
          verification_summary: "handoff check passed",
          verification_checked_at: verification_checked_at,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          started_at: DateTime.utc_now()
        }
      },
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
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
          rate_limits: healthy_rate_limits
        },
        "secondary" => %{
          id: "secondary",
          explicit?: true,
          healthy: true,
          probe_healthy: true,
          probe_health_reason: nil,
          health_reason: nil,
          auth_mode: "chatgpt",
          requires_openai_auth: false,
          missing_windows_mins: [],
          insufficient_windows_mins: [],
          rate_limits: healthy_rate_limits
        }
      },
      active_codex_account_id: "primary",
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: healthy_rate_limits,
      codex_dispatch_reason: nil
    }

    update = %{
      event: :notification,
      codex_account_id: "primary",
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "type" => "event_msg",
            "payload" => %{
              "type" => "token_count",
              "rate_limits" => exhausted_rate_limits
            }
          }
        }
      },
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

    assert updated_state.active_codex_account_id == "secondary"
    assert %{healthy: false, health_reason: health_reason} = updated_state.codex_accounts["primary"]
    assert health_reason =~ "threshold exceeded"

    assert %{
             codex_account_id: "primary",
             failover_drain_decision: %{
               disposition: :drain,
               reason: :safe_boundary_reached,
               safe_signal: safe_signal,
               from_account_id: "primary",
               to_account_id: "secondary"
             }
           } = updated_state.running[issue_id]

    assert safe_signal in [
             "verification_result:passed",
             "latest_pr_snapshot:open",
             "latest_ci_wait_result:available"
           ]

    assert updated_state.retry_attempts == %{}
    assert Process.alive?(worker_pid)
    refute_received {:retry_issue, ^issue_id, _retry_token}
  end

  test "live rate-limit exhaustion drains when active validation wait snapshot is present" do
    issue_id = "issue-live-rate-limit-active-validation"
    issue = %Issue{id: issue_id, identifier: "MT-LIVE-ACTIVE-VALIDATION", state: "In Progress"}
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_accounts: [
        %{id: "primary", codex_home: "/tmp/codex-primary"},
        %{id: "secondary", codex_home: "/tmp/codex-secondary"}
      ],
      codex_minimum_remaining_percent: 5,
      codex_monitored_windows_mins: [300, 10_080]
    )

    healthy_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 20},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    exhausted_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 96},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{
        issue_id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          trace_id: "trace-live-active-validation",
          session_id: "thread-live-active-validation",
          codex_account_id: "primary",
          run_phase: :editing,
          current_command: "mix dialyzer --format short",
          external_step: "exec_wait",
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          started_at: DateTime.utc_now()
        }
      },
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
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
          rate_limits: healthy_rate_limits
        },
        "secondary" => %{
          id: "secondary",
          explicit?: true,
          healthy: true,
          probe_healthy: true,
          probe_health_reason: nil,
          health_reason: nil,
          auth_mode: "chatgpt",
          requires_openai_auth: false,
          missing_windows_mins: [],
          insufficient_windows_mins: [],
          rate_limits: healthy_rate_limits
        }
      },
      active_codex_account_id: "primary",
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: healthy_rate_limits,
      codex_dispatch_reason: nil
    }

    update = %{
      event: :notification,
      codex_account_id: "primary",
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "type" => "event_msg",
            "payload" => %{
              "type" => "token_count",
              "rate_limits" => exhausted_rate_limits
            }
          }
        }
      },
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

    assert updated_state.active_codex_account_id == "secondary"
    assert %{healthy: false, health_reason: health_reason} = updated_state.codex_accounts["primary"]
    assert health_reason =~ "threshold exceeded"

    assert %{
             codex_account_id: "primary",
             failover_drain_decision: %{
               disposition: :drain,
               reason: :safe_boundary_reached,
               safe_signal: "active_validation_snapshot:validation:dialyzer",
               from_account_id: "primary",
               to_account_id: "secondary"
             }
           } = updated_state.running[issue_id]

    assert Process.alive?(worker_pid)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    refute_received {:retry_issue, ^issue_id, _retry_token}
  end

  test "live rate-limit exhaustion keeps fallback checkpoint when workspace is unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-failover-resume-fallback-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue_id = "issue-live-rate-limit-resume-fallback"
    issue = %Issue{id: issue_id, identifier: "MT-LIVE-RESUME-FALLBACK", state: "In Progress"}
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end

      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      codex_accounts: [
        %{id: "primary", codex_home: "/tmp/codex-primary"},
        %{id: "secondary", codex_home: "/tmp/codex-secondary"}
      ],
      codex_minimum_remaining_percent: 5,
      codex_monitored_windows_mins: [300, 10_080]
    )

    healthy_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 20},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    exhausted_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 96},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{
        issue_id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          trace_id: "trace-failover-resume-fallback",
          session_id: "thread-failover-resume-fallback",
          codex_account_id: "primary",
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          started_at: DateTime.utc_now()
        }
      },
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
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
          rate_limits: healthy_rate_limits
        },
        "secondary" => %{
          id: "secondary",
          explicit?: true,
          healthy: true,
          probe_healthy: true,
          probe_health_reason: nil,
          health_reason: nil,
          auth_mode: "chatgpt",
          requires_openai_auth: false,
          missing_windows_mins: [],
          insufficient_windows_mins: [],
          rate_limits: healthy_rate_limits
        }
      },
      active_codex_account_id: "primary",
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: healthy_rate_limits,
      codex_dispatch_reason: nil
    }

    update = %{
      event: :notification,
      codex_account_id: "primary",
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "type" => "event_msg",
            "payload" => %{
              "type" => "token_count",
              "rate_limits" => exhausted_rate_limits
            }
          }
        }
      },
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

    assert_receive {:retry_issue, ^issue_id, _retry_token}, 200

    assert %{
             attempt: 1,
             delay_type: :failover,
             error_class: "transient",
             resume_checkpoint: checkpoint
           } = updated_state.retry_attempts[issue_id]

    assert checkpoint["available"] == false
    assert checkpoint["resume_ready"] == false

    assert Enum.any?(
             checkpoint["fallback_reasons"],
             &String.contains?(&1, "workspace is unavailable for retry checkpoint capture")
           )
  end

  test "live rate-limit exhaustion does not preempt the run when no healthy replacement exists" do
    issue_id = "issue-live-rate-limit-no-failover"
    issue = %Issue{id: issue_id, identifier: "MT-LIVE-STAY", state: "In Progress"}
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_accounts: [%{id: "primary", codex_home: "/tmp/codex-primary"}],
      codex_minimum_remaining_percent: 5,
      codex_monitored_windows_mins: [300, 10_080]
    )

    healthy_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 20},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    exhausted_rate_limits = %{
      "limitId" => "codex",
      "primary" => %{"windowDurationMins" => 300, "usedPercent" => 96},
      "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 30},
      "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => nil}
    }

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{
        issue_id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          trace_id: "trace-live-stay",
          session_id: "thread-live-stay-turn-1",
          codex_account_id: "primary",
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          started_at: DateTime.utc_now()
        }
      },
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
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
          rate_limits: healthy_rate_limits
        }
      },
      active_codex_account_id: "primary",
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: healthy_rate_limits,
      codex_dispatch_reason: nil
    }

    update = %{
      event: :notification,
      codex_account_id: "primary",
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "type" => "event_msg",
            "payload" => %{
              "type" => "token_count",
              "rate_limits" => exhausted_rate_limits
            }
          }
        }
      },
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

    assert %{codex_account_id: "primary"} = updated_state.running[issue_id]
    assert updated_state.active_codex_account_id == nil
    assert %{healthy: false, health_reason: health_reason} = updated_state.codex_accounts["primary"]
    assert health_reason =~ "threshold exceeded"
    assert updated_state.retry_attempts == %{}
    assert Process.alive?(worker_pid)
    refute_received {:retry_issue, ^issue_id, _retry_token}
  end

  test "probe failure does not clear broken runtime state without a successful auth check" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-broken-probe-failure-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      codex_home = Path.join(test_root, "primary-home")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(codex_home)

      File.write!(codex_binary, """
      #!/bin/sh
      exit 1
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_accounts: [%{id: "primary", codex_home: codex_home}]
      )

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 1,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        tick_timer_ref: nil,
        tick_token: nil,
        workspace_usage_bytes: 0,
        workspace_cleanup_ref: nil,
        workspace_usage_refresh_ref: nil,
        workspace_threshold_exceeded?: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        retry_attempts: %{},
        codex_accounts: %{
          "primary" => %{
            id: "primary",
            explicit?: true,
            healthy: false,
            probe_healthy: false,
            probe_health_reason: "auth failure",
            health_reason: "auth_failure: invalid api key",
            auth_mode: "chatgpt",
            requires_openai_auth: false,
            missing_windows_mins: [],
            insufficient_windows_mins: [],
            rate_limits: %{"limitId" => "codex"},
            account: nil,
            runtime_state: :broken,
            runtime_health_reason: "auth_failure: invalid api key",
            runtime_marked_at: DateTime.utc_now(),
            runtime_cooldown_until: nil
          }
        },
        active_codex_account_id: nil,
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        codex_rate_limits: nil,
        codex_dispatch_reason: nil
      }

      assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

      assert %{
               runtime_state: :broken,
               healthy: false,
               runtime_health_reason: "auth_failure: invalid api key",
               health_reason: "auth_failure: invalid api key",
               probe_health_reason: probe_health_reason
             } = updated_state.codex_accounts["primary"]

      assert probe_health_reason =~ "startup failed"
    after
      File.rm_rf(test_root)
    end
  end

  test "successful auth probe clears broken runtime state even when rate limits are unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-broken-probe-rate-limit-auth-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      codex_home = Path.join(test_root, "primary-home")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(codex_home)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":1001,"result":{"account":{"type":"chatgpt","email":"primary@example.com","planType":"pro"},"requiresOpenaiAuth":false}}'
            ;;
          3)
            printf '%s\\n' '{"id":1002,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_accounts: [%{id: "primary", codex_home: codex_home}]
      )

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 1,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        tick_timer_ref: nil,
        tick_token: nil,
        workspace_usage_bytes: 0,
        workspace_cleanup_ref: nil,
        workspace_usage_refresh_ref: nil,
        workspace_threshold_exceeded?: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        retry_attempts: %{},
        codex_accounts: %{
          "primary" => %{
            id: "primary",
            explicit?: true,
            healthy: false,
            probe_healthy: false,
            probe_health_reason: "auth failure",
            health_reason: "auth_failure: invalid api key",
            auth_mode: "chatgpt",
            requires_openai_auth: false,
            missing_windows_mins: [],
            insufficient_windows_mins: [],
            rate_limits: nil,
            account: nil,
            runtime_state: :broken,
            runtime_health_reason: "auth_failure: invalid api key",
            runtime_marked_at: DateTime.utc_now(),
            runtime_cooldown_until: nil
          }
        },
        active_codex_account_id: nil,
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        codex_rate_limits: nil,
        codex_dispatch_reason: nil
      }

      assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

      assert %{
               runtime_state: nil,
               healthy: true,
               probe_healthy: true,
               health_reason: nil,
               runtime_health_reason: nil,
               auth_mode: "chatgpt",
               email: "primary@example.com",
               plan_type: "pro",
               rate_limits: nil
             } = updated_state.codex_accounts["primary"]

      assert updated_state.active_codex_account_id == "primary"
    after
      File.rm_rf(test_root)
    end
  end

  test "healthy probe does not clear an active runtime cooldown before its deadline" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cooldown-probe-regression-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      codex_home = Path.join(test_root, "primary-home")
      workspace_root = Path.join(test_root, "workspaces")
      cooldown_until = DateTime.add(DateTime.utc_now(), 60, :second)

      File.mkdir_p!(codex_home)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":1001,"result":{"account":{"type":"chatgpt","email":"primary@example.com","planType":"pro"},"requiresOpenaiAuth":false}}'
            ;;
          3)
            printf '%s\\n' '{"id":1002,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"windowDurationMins":300,"usedPercent":20},"secondary":{"windowDurationMins":10080,"usedPercent":35},"credits":{"hasCredits":false,"unlimited":false,"balance":null}}}}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_accounts: [%{id: "primary", codex_home: codex_home}]
      )

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 1,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        tick_timer_ref: nil,
        tick_token: nil,
        workspace_usage_bytes: 0,
        workspace_cleanup_ref: nil,
        workspace_usage_refresh_ref: nil,
        workspace_threshold_exceeded?: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        retry_attempts: %{},
        codex_accounts: %{
          "primary" => %{
            id: "primary",
            explicit?: true,
            healthy: false,
            probe_healthy: false,
            probe_health_reason: "quota exhausted",
            health_reason: "quota_exhausted: requests per day limit reached",
            auth_mode: "chatgpt",
            requires_openai_auth: false,
            missing_windows_mins: [],
            insufficient_windows_mins: [],
            rate_limits: %{"limitId" => "codex"},
            account: nil,
            runtime_state: :cooldown,
            runtime_health_reason: "quota_exhausted: requests per day limit reached",
            runtime_marked_at: DateTime.utc_now(),
            runtime_cooldown_until: cooldown_until
          }
        },
        active_codex_account_id: nil,
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        codex_rate_limits: nil,
        codex_dispatch_reason: nil
      }

      assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

      assert %{
               runtime_state: :cooldown,
               healthy: false,
               probe_healthy: true,
               auth_mode: "chatgpt",
               email: "primary@example.com",
               plan_type: "pro",
               runtime_health_reason: "quota_exhausted: requests per day limit reached",
               runtime_cooldown_until: ^cooldown_until
             } = updated_state.codex_accounts["primary"]

      assert updated_state.active_codex_account_id == nil
    after
      File.rm_rf(test_root)
    end
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})

    state =
      wait_for_orchestrator_state(pid, fn state ->
        match?(%{retry_token: ^current_retry_token}, state.retry_attempts[issue_id])
      end)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = state.retry_attempts[issue_id]
  end

  test "stale retry outcome without retry entry releases orphaned claim" do
    issue_id = "issue-stale-retry-orphan"
    retry_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      codex_accounts: %{},
      active_codex_account_id: nil,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil,
      codex_dispatch_reason: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info({:retry_issue, issue_id, retry_token}, state)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "tokenless retry outcome releases orphaned claim when no active retry context remains" do
    issue_id = "issue-tokenless-retry-orphan"

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      codex_accounts: %{},
      active_codex_account_id: nil,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil,
      codex_dispatch_reason: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info({:retry_issue, issue_id}, state)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "stale retry outcome does not release claim for an actively running issue" do
    issue_id = "issue-stale-retry-running"
    retry_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      running: %{
        issue_id => %{
          pid: self(),
          ref: make_ref(),
          identifier: "MT-561-RUN",
          issue: %Issue{id: issue_id, identifier: "MT-561-RUN", title: "Running retry", state: "In Progress"},
          trace_id: "trace-running-retry",
          codex_account_id: "primary",
          started_at: DateTime.utc_now()
        }
      },
      completed: MapSet.new(),
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      codex_accounts: %{},
      active_codex_account_id: nil,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil,
      codex_dispatch_reason: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info({:retry_issue, issue_id, retry_token}, state)
    assert MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry dispatch preserves trace_id from retry metadata" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-retry-trace-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-retry-trace"
    issue_identifier = "MT-562"
    trace_id = "trace-retry-preserved"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{
          id: issue_id,
          identifier: issue_identifier,
          title: "Retry trace preservation",
          description: "Keep the same trace_id across retry dispatch",
          state: "In Progress",
          url: "https://example.org/issues/#{issue_identifier}",
          labels: []
        }
      ])

      orchestrator_name = Module.concat(__MODULE__, :RetryTraceOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      retry_token = make_ref()

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:codex_accounts, %{
          "primary" => %{id: "primary", codex_home: System.tmp_dir!(), healthy: true}
        })
        |> Map.put(:active_codex_account_id, "primary")
        |> Map.put(:retry_attempts, %{
          issue_id => %{
            attempt: 1,
            timer_ref: nil,
            retry_token: retry_token,
            due_at_ms: System.monotonic_time(:millisecond) + 30_000,
            identifier: issue_identifier,
            trace_id: trace_id,
            error: "agent exited: :boom"
          }
        })
      end)

      send(pid, {:retry_issue, issue_id, retry_token})

      state =
        wait_for_orchestrator_state(
          pid,
          fn state ->
            match?(%{trace_id: ^trace_id}, Map.get(state.running, issue_id))
          end,
          80
        )

      assert %{identifier: ^issue_identifier, trace_id: ^trace_id, pid: worker_pid} =
               state.running[issue_id]

      Process.exit(worker_pid, :kill)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "stale workspace head blocks dispatch before the worker starts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stale-head-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-stale-head"
    issue_identifier = "MT-STALE-HEAD"
    trace_id = "trace-stale-head"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{
          id: issue_id,
          identifier: issue_identifier,
          title: "Block stale workspace head",
          description: "Do not dispatch stale runtime workspaces",
          state: "In Progress",
          url: "https://example.org/issues/#{issue_identifier}",
          labels: []
        }
      ])

      {runtime_head_sha, expected_head_sha} =
        create_stale_workspace!(workspace_root, issue_identifier, "merge/stale-01")

      orchestrator_name = Module.concat(__MODULE__, :StaleHeadOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      retry_token = make_ref()

      :sys.replace_state(pid, fn _ ->
        base_dispatch_state("primary")
        |> Map.put(:poll_interval_ms, initial_state.poll_interval_ms)
        |> Map.put(:retry_attempts, %{
          issue_id => %{
            attempt: 1,
            timer_ref: nil,
            retry_token: retry_token,
            due_at_ms: System.monotonic_time(:millisecond) + 30_000,
            identifier: issue_identifier,
            trace_id: trace_id,
            error: "retry stale workspace head"
          }
        })
      end)

      send(pid, {:retry_issue, issue_id, retry_token})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "selected_rule: `stale_workspace_head`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "reason=behind"
      assert blocker_body =~ "stale_workspace_head"
      assert blocker_body =~ runtime_head_sha
      assert blocker_body =~ expected_head_sha
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      final_state =
        wait_for_orchestrator_state(pid, fn state ->
          state.running == %{} and
            not Map.has_key?(state.retry_attempts, issue_id) and
            not MapSet.member?(state.claimed, issue_id)
        end)

      assert final_state.running == %{}
      refute Map.has_key?(final_state.retry_attempts, issue_id)
      refute MapSet.member?(final_state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "known non-behind workspace head mismatch blocks dispatch before the worker starts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-mismatch-head-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-mismatch-head"
    issue_identifier = "MT-MISMATCH-HEAD"
    trace_id = "trace-mismatch-head"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{
          id: issue_id,
          identifier: issue_identifier,
          title: "Block known non-behind head mismatch",
          description: "Do not dispatch known mismatched runtime workspaces",
          state: "In Progress",
          url: "https://example.org/issues/#{issue_identifier}",
          labels: []
        }
      ])

      {runtime_head_sha, expected_head_sha} =
        create_non_behind_mismatch_workspace!(workspace_root, issue_identifier, "merge/diverged-01")

      orchestrator_name = Module.concat(__MODULE__, :MismatchHeadOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      retry_token = make_ref()

      :sys.replace_state(pid, fn _ ->
        base_dispatch_state("primary")
        |> Map.put(:poll_interval_ms, initial_state.poll_interval_ms)
        |> Map.put(:retry_attempts, %{
          issue_id => %{
            attempt: 1,
            timer_ref: nil,
            retry_token: retry_token,
            due_at_ms: System.monotonic_time(:millisecond) + 30_000,
            identifier: issue_identifier,
            trace_id: trace_id,
            error: "retry mismatch workspace head"
          }
        })
      end)

      send(pid, {:retry_issue, issue_id, retry_token})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "selected_rule: `stale_workspace_head`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "known_mismatch_non_behind"
      assert blocker_body =~ runtime_head_sha
      assert blocker_body =~ expected_head_sha
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      final_state =
        wait_for_orchestrator_state(pid, fn state ->
          state.running == %{} and
            not Map.has_key?(state.retry_attempts, issue_id) and
            not MapSet.member?(state.claimed, issue_id)
        end)

      assert final_state.running == %{}
      refute Map.has_key?(final_state.retry_attempts, issue_id)
      refute MapSet.member?(final_state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "rework stale workspace head reconciles before dispatch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-rework-stale-head-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue_id = "issue-rework-stale-head"
    issue_identifier = "MT-REWORK-STALE-HEAD"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Reconcile stale rework workspace head",
        description: "Rework stale head should reconcile before dispatch",
        state: "Rework",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      {runtime_head_sha, expected_head_sha} =
        create_rework_reconcilable_workspace!(workspace_root, issue_identifier, "main")

      assert runtime_head_sha != expected_head_sha
      workspace = Path.join(workspace_root, issue_identifier)

      execution_head = %{
        workspace: workspace,
        runtime_head_sha: runtime_head_sha,
        expected_head_sha: expected_head_sha,
        execution_branch: "main"
      }

      assert {:ok, reconciled_head} =
               Orchestrator.reconcile_rework_stale_workspace_for_test(
                 issue,
                 execution_head,
                 :behind,
                 "trace-rework-stale-head"
               )

      assert reconciled_head.runtime_head_sha == expected_head_sha
      assert reconciled_head.expected_head_sha == expected_head_sha
      assert git_output!(workspace, ["rev-parse", "HEAD"]) == expected_head_sha
    after
      File.rm_rf(test_root)
    end
  end

  test "rework stale workspace reconciliation failure escalates with reconcile reason" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-rework-stale-failure-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue_id = "issue-rework-stale-failure"
    issue_identifier = "MT-REWORK-STALE-FAILURE"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Fail closed when rework reconciliation fails",
        description: "Missing origin fetch should classify as reconcile failure",
        state: "Rework",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      {runtime_head_sha, expected_head_sha} =
        create_stale_workspace!(workspace_root, issue_identifier, "merge/stale-01")

      execution_head = %{
        workspace: Path.join(workspace_root, issue_identifier),
        runtime_head_sha: runtime_head_sha,
        expected_head_sha: expected_head_sha,
        execution_branch: "merge/stale-01"
      }

      assert {:error, {:reconcile_failure, :behind, reconcile_reason}, failed_head} =
               Orchestrator.reconcile_rework_stale_workspace_for_test(
                 issue,
                 execution_head,
                 :behind,
                 "trace-rework-stale-failure"
               )

      assert reconcile_reason =~ "fetch_origin_base_branch"
      assert reconcile_reason =~ "base_branch=main"
      assert failed_head.runtime_head_sha == runtime_head_sha
      assert failed_head.expected_head_sha == expected_head_sha
    after
      File.rm_rf(test_root)
    end
  end

  test "matching workspace head does not block dispatch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-match-head-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-match-head"
    issue_identifier = "MT-MATCH-HEAD"
    trace_id = "trace-match-head"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{
          id: issue_id,
          identifier: issue_identifier,
          title: "Allow matching workspace head",
          description: "Matching runtime and expected head should dispatch",
          state: "In Progress",
          url: "https://example.org/issues/#{issue_identifier}",
          labels: []
        }
      ])

      matching_head_sha =
        create_matching_workspace!(workspace_root, issue_identifier, "merge/match-01")

      orchestrator_name = Module.concat(__MODULE__, :MatchHeadOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      retry_token = make_ref()

      :sys.replace_state(pid, fn _ ->
        base_dispatch_state("primary")
        |> Map.put(:retry_attempts, %{
          issue_id => %{
            attempt: 1,
            timer_ref: nil,
            retry_token: retry_token,
            due_at_ms: System.monotonic_time(:millisecond) + 30_000,
            identifier: issue_identifier,
            trace_id: trace_id,
            error: "retry match workspace head"
          }
        })
      end)

      send(pid, {:retry_issue, issue_id, retry_token})

      state =
        wait_for_orchestrator_state(pid, fn state ->
          match?(
            %{
              runtime_head_sha: ^matching_head_sha,
              expected_head_sha: ^matching_head_sha
            },
            Map.get(state.running, issue_id)
          )
        end)

      assert %{
               ^issue_id => %{
                 pid: worker_pid,
                 runtime_head_sha: ^matching_head_sha,
                 expected_head_sha: ^matching_head_sha
               }
             } = state.running

      refute_received {:memory_tracker_state_update, ^issue_id, "Blocked"}
      refute_received {:memory_tracker_comment, ^issue_id, _comment}

      Process.exit(worker_pid, :kill)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "dispatch keeps runtime head metadata when expected head cannot be resolved" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-unknown-expected-head-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-unknown-expected-head"
    issue_identifier = "MT-UNKNOWN-HEAD"
    trace_id = "trace-unknown-expected-head"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        workspace_root: workspace_root,
        codex_command: "sleep 60",
        codex_read_timeout_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{
          id: issue_id,
          identifier: issue_identifier,
          title: "Keep runtime head metadata",
          description: "Expected head resolution may be unavailable",
          state: "In Progress",
          url: "https://example.org/issues/#{issue_identifier}",
          labels: []
        }
      ])

      runtime_head_sha =
        create_workspace_with_unknown_expected_head!(
          workspace_root,
          issue_identifier,
          "merge/missing-head"
        )

      orchestrator_name = Module.concat(__MODULE__, :UnknownExpectedHeadOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      retry_token = make_ref()

      :sys.replace_state(pid, fn _ ->
        base_dispatch_state("primary")
        |> Map.put(:retry_attempts, %{
          issue_id => %{
            attempt: 1,
            timer_ref: nil,
            retry_token: retry_token,
            due_at_ms: System.monotonic_time(:millisecond) + 30_000,
            identifier: issue_identifier,
            trace_id: trace_id,
            error: "retry unknown expected head"
          }
        })
      end)

      send(pid, {:retry_issue, issue_id, retry_token})

      state =
        wait_for_orchestrator_state(pid, fn state ->
          match?(
            %{
              runtime_head_sha: ^runtime_head_sha,
              expected_head_sha: "unknown"
            },
            Map.get(state.running, issue_id)
          )
        end)

      assert %{
               ^issue_id => %{
                 pid: worker_pid,
                 runtime_head_sha: ^runtime_head_sha,
                 expected_head_sha: "unknown"
               }
             } = state.running

      refute_received {:memory_tracker_state_update, ^issue_id, _state_name}
      Process.exit(worker_pid, :kill)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "worker failure preserves execution head metadata in retry context" do
    issue_id = "issue-retry-head-metadata"
    ref = make_ref()
    runtime_head_sha = "7384c2d49d893f544cda4ffa38f61bf06bcb0e9d"
    expected_head_sha = "4d93431c93186898f429f090f0054b7f3a1cb5a9"
    execution_branch = "merge/retry-head"

    orchestrator_name = Module.concat(__MODULE__, :RetryHeadMetadataOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-RETRY-HEADS",
      issue: %Issue{id: issue_id, identifier: "MT-RETRY-HEADS", state: "In Progress"},
      trace_id: "trace-retry-heads",
      runtime_head_sha: runtime_head_sha,
      expected_head_sha: expected_head_sha,
      execution_branch: execution_branch,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, "mix test failed in CI"}})

    state =
      wait_for_orchestrator_state(pid, fn state ->
        match?(
          %{
            runtime_head_sha: ^runtime_head_sha,
            expected_head_sha: ^expected_head_sha,
            execution_branch: ^execution_branch
          },
          state.retry_attempts[issue_id]
        )
      end)

    assert %{
             attempt: 1,
             error_class: "semi_permanent",
             runtime_head_sha: ^runtime_head_sha,
             expected_head_sha: ^expected_head_sha,
             execution_branch: ^execution_branch
           } = state.retry_attempts[issue_id]
  end

  test "failed symphony_handoff_check manifest fail-closes active run as human-action blocker" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-verification-fail-close"
    issue = %Issue{id: issue_id, identifier: "LET-523", state: "In Progress"}
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        base_dispatch_state("primary")
        |> Map.put(:running, %{
          issue_id => %{
            pid: worker_pid,
            ref: make_ref(),
            identifier: issue.identifier,
            issue: issue,
            trace_id: "trace-verification-failed",
            session_id: "thread-verification-failed",
            codex_account_id: "primary",
            run_phase: :editing,
            started_at: DateTime.utc_now()
          }
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))

      update =
        handoff_check_tool_update(%{
          "profile" => "runtime",
          "passed" => false,
          "summary" => "proof mapping reference 'validation:targeted tests' is reused by multiple acceptance matrix items",
          "missing_items" => ["validation:targeted tests"],
          "checked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })

      assert {:noreply, updated_state} =
               Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 500
      assert blocker_body =~ "selected_rule: `validation_env_mismatch`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "failure_class: `verification_guard_failed`"
      assert blocker_body =~ "verification guard failed"
      assert blocker_body =~ "validation:targeted tests"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      refute Map.has_key?(updated_state.running, issue_id)
      refute Map.has_key?(updated_state.retry_attempts, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(worker_pid)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end
  end

  test "passed symphony_handoff_check manifest updates metadata without stopping active run" do
    issue_id = "issue-verification-pass-through"
    issue = %Issue{id: issue_id, identifier: "LET-523", state: "In Progress"}
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)
    checked_at = DateTime.utc_now() |> DateTime.truncate(:second)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    state =
      base_dispatch_state("primary")
      |> Map.put(:running, %{
        issue_id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          trace_id: "trace-verification-passed",
          session_id: "thread-verification-passed",
          codex_account_id: "primary",
          run_phase: :editing,
          started_at: DateTime.utc_now()
        }
      })
      |> Map.put(:claimed, MapSet.new([issue_id]))

    update =
      handoff_check_tool_update(%{
        "profile" => "runtime",
        "passed" => true,
        "summary" => "all checks green",
        "missing_items" => [],
        "checked_at" => DateTime.to_iso8601(checked_at)
      })

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

    assert %{^issue_id => running_entry} = updated_state.running
    assert running_entry.verification_profile == "runtime"
    assert running_entry.verification_result == "passed"
    assert running_entry.verification_summary == "all checks green"
    assert running_entry.verification_missing_items == []
    assert running_entry.verification_checked_at == checked_at
    assert running_entry.validation_guard_reason == "all checks green"
    assert updated_state.retry_attempts == %{}
    assert Process.alive?(worker_pid)
    refute_received {:memory_tracker_state_update, ^issue_id, "Blocked"}
  end

  test "tool updates without verification manifest do not stop active run" do
    issue_id = "issue-no-verification-update"
    issue = %Issue{id: issue_id, identifier: "LET-523", state: "In Progress"}
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :kill)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    state =
      base_dispatch_state("primary")
      |> Map.put(:running, %{
        issue_id => %{
          pid: worker_pid,
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          trace_id: "trace-no-verification-update",
          session_id: "thread-no-verification-update",
          codex_account_id: "primary",
          run_phase: :editing,
          started_at: DateTime.utc_now()
        }
      })
      |> Map.put(:claimed, MapSet.new([issue_id]))

    update = %{
      event: :tool_call_completed,
      payload: %{"params" => %{"tool" => "github_pr_snapshot"}},
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

    assert %{^issue_id => running_entry} = updated_state.running
    assert Map.get(running_entry, :verification_result) == nil
    assert updated_state.retry_attempts == %{}
    assert Process.alive?(worker_pid)
    refute_received {:memory_tracker_state_update, ^issue_id, "Blocked"}
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()
    stale_probe_at_ms = now_ms - 60_000
    stale_full_probe_at_ms = now_ms - 300_000

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      last_codex_account_probe_at_ms: stale_probe_at_ms,
      last_full_codex_account_probe_at_ms: stale_full_probe_at_ms,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)
    assert refreshed_state.last_codex_account_probe_at_ms == nil
    assert refreshed_state.last_full_codex_account_probe_at_ms == nil

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert coalesced_state.last_codex_account_probe_at_ms == nil
    assert coalesced_state.last_full_codex_account_probe_at_ms == nil
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp handoff_check_tool_update(manifest) when is_map(manifest) do
    %{
      event: :tool_call_completed,
      payload: %{"params" => %{"tool" => "symphony_handoff_check"}},
      result: %{contentItems: [%{text: Jason.encode!(%{"manifest" => manifest})}]},
      timestamp: DateTime.utc_now()
    }
  end

  defp base_dispatch_state(account_id) do
    %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: nil,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_cleanup_ref: nil,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_accounts: %{
        account_id => %{id: account_id, codex_home: System.tmp_dir!(), healthy: true}
      },
      active_codex_account_id: account_id,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil,
      codex_dispatch_reason: nil
    }
  end

  defp create_stale_workspace!(workspace_root, issue_identifier, execution_branch) do
    workspace = init_workspace_repo!(workspace_root, issue_identifier)

    runtime_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

    git_ok!(workspace, ["checkout", "-b", execution_branch])
    File.write!(Path.join(workspace, "tracked.txt"), "expected head\n")
    git_ok!(workspace, ["add", "tracked.txt"])
    git_ok!(workspace, ["commit", "-m", "expected head"])

    expected_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

    git_ok!(workspace, ["checkout", runtime_head_sha])
    File.write!(Path.join(workspace, ".symphony-working-branch"), execution_branch <> "\n")

    {runtime_head_sha, expected_head_sha}
  end

  defp create_non_behind_mismatch_workspace!(workspace_root, issue_identifier, execution_branch) do
    workspace = init_workspace_repo!(workspace_root, issue_identifier)

    git_ok!(workspace, ["checkout", "-b", execution_branch])
    File.write!(Path.join(workspace, "tracked.txt"), "expected head\n")
    git_ok!(workspace, ["add", "tracked.txt"])
    git_ok!(workspace, ["commit", "-m", "expected head"])
    expected_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

    git_ok!(workspace, ["checkout", "main"])
    File.write!(Path.join(workspace, "tracked.txt"), "runtime diverged head\n")
    git_ok!(workspace, ["add", "tracked.txt"])
    git_ok!(workspace, ["commit", "-m", "runtime diverged head"])
    runtime_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

    File.write!(Path.join(workspace, ".symphony-working-branch"), execution_branch <> "\n")

    {runtime_head_sha, expected_head_sha}
  end

  defp create_matching_workspace!(workspace_root, issue_identifier, execution_branch) do
    workspace = init_workspace_repo!(workspace_root, issue_identifier)
    runtime_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])
    git_ok!(workspace, ["branch", execution_branch, runtime_head_sha])
    File.write!(Path.join(workspace, ".symphony-working-branch"), execution_branch <> "\n")
    runtime_head_sha
  end

  defp create_workspace_with_unknown_expected_head!(
         workspace_root,
         issue_identifier,
         execution_branch
       ) do
    workspace = init_workspace_repo!(workspace_root, issue_identifier)
    File.write!(Path.join(workspace, ".symphony-working-branch"), execution_branch <> "\n")
    git_output!(workspace, ["rev-parse", "HEAD"])
  end

  defp create_rework_reconcilable_workspace!(workspace_root, issue_identifier, base_branch) do
    sandbox_root = Path.join(workspace_root, "#{issue_identifier}-reconcile")
    origin_repo = Path.join(sandbox_root, "origin.git")
    seed_repo = Path.join(sandbox_root, "seed")
    workspace = Path.join(workspace_root, issue_identifier)

    File.mkdir_p!(sandbox_root)
    File.mkdir_p!(seed_repo)

    assert {_, 0} = System.cmd("git", ["init", "--bare", origin_repo], stderr_to_stdout: true)

    git_ok!(seed_repo, ["init", "-b", base_branch])
    git_ok!(seed_repo, ["config", "user.name", "Symphony Tests"])
    git_ok!(seed_repo, ["config", "user.email", "symphony-tests@example.com"])

    File.write!(Path.join(seed_repo, "tracked.txt"), "runtime head\n")
    git_ok!(seed_repo, ["add", "tracked.txt"])
    git_ok!(seed_repo, ["commit", "-m", "runtime head"])
    git_ok!(seed_repo, ["remote", "add", "origin", origin_repo])
    git_ok!(seed_repo, ["push", "-u", "origin", base_branch])

    assert {_, 0} = System.cmd("git", ["clone", origin_repo, workspace], stderr_to_stdout: true)
    git_ok!(workspace, ["config", "user.name", "Symphony Tests"])
    git_ok!(workspace, ["config", "user.email", "symphony-tests@example.com"])
    git_ok!(workspace, ["checkout", "-B", base_branch, "origin/#{base_branch}"])

    runtime_head_sha = git_output!(workspace, ["rev-parse", "HEAD"])

    File.write!(Path.join(seed_repo, "tracked.txt"), "expected head\n")
    git_ok!(seed_repo, ["add", "tracked.txt"])
    git_ok!(seed_repo, ["commit", "-m", "expected head"])
    git_ok!(seed_repo, ["push", "origin", base_branch])

    git_ok!(workspace, ["fetch", "origin", base_branch])
    expected_head_sha = git_output!(workspace, ["rev-parse", "origin/#{base_branch}"])

    File.write!(Path.join(workspace, ".symphony-base-branch"), base_branch <> "\n")
    File.write!(Path.join(workspace, ".symphony-working-branch"), base_branch <> "\n")

    {runtime_head_sha, expected_head_sha}
  end

  defp init_workspace_repo!(workspace_root, issue_identifier) do
    workspace = Path.join(workspace_root, issue_identifier)
    File.mkdir_p!(workspace)

    git_ok!(workspace, ["init", "-b", "main"])
    git_ok!(workspace, ["config", "user.name", "Symphony Tests"])
    git_ok!(workspace, ["config", "user.email", "symphony-tests@example.com"])

    File.write!(Path.join(workspace, "tracked.txt"), "runtime head\n")
    git_ok!(workspace, ["add", "tracked.txt"])
    git_ok!(workspace, ["commit", "-m", "runtime head"])

    workspace
  end

  defp git_ok!(workspace, args) do
    assert {_, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
  end

  defp git_output!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder preserves valid UTF-8 for Russian workflow and issue text" do
    workflow_prompt = "Задача {{ issue.identifier }} {{ issue.title }} статус={{ issue.state }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "LET-182",
      title: "Создать phase1-smoke.md",
      description: "Русский smoke test",
      state: "Spec Prep",
      url: "https://example.org/issues/LET-182",
      labels: ["smoke"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert String.valid?(prompt)
    assert prompt == "Задача LET-182 Создать phase1-smoke.md статус=Spec Prep"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker or an explicitly classified handoff"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "use the `land` skill and do not call `gh pr merge` directly"
    assert prompt =~ "`delivery:tdd`"
    assert prompt =~ "`red`"
    assert prompt =~ "`green`"
    assert prompt =~ "never delete, rewrite away, or relocate them when updating issue text"
    assert prompt =~ "`github_pr_snapshot`"
    assert prompt =~ "`github_wait_for_checks`"
    assert prompt =~ "`exec_background`"
    assert prompt =~ "`exec_wait`"
    assert prompt =~ "background_required"
    assert prompt =~ "do not retry the same command in foreground"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
    assert prompt =~ "making a classified `decision`/`human-action` handoff"
    assert prompt =~ "`checkpoint_type`"
    assert prompt =~ "`risk_level`"
    assert prompt =~ "`human-verify`"
    assert prompt =~ "`decision`"
    assert prompt =~ "`human-action`"
    assert prompt =~ "every bullet must be an actionable blocker in three parts"
    assert prompt =~ "why it blocks execution or acceptance"
    assert prompt =~ "`low-context`"
    assert prompt =~ "Limit yourself to 2 auto-fix attempts"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "prompt builder includes explicit resume mode and fallback reason fields" do
    workflow_prompt = "{{ resume_checkpoint.resume_mode }}|{{ resume_checkpoint.resume_fallback_reason }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-202",
      title: "Resume metadata is explicit",
      description: "Fallback flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-202",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        resume_checkpoint: %{"fallback_reasons" => ["resume checkpoint is unavailable"]}
      )

    assert prompt == "fallback_reread|resume_checkpoint_unavailable"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner raises RunError with classified metadata on hook failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-error-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: "echo 'CompileError: undefined function' >&2; exit 1"
      )

      issue = %Issue{
        id: "issue-run-error",
        identifier: "MT-ERR",
        title: "Raise classified error",
        description: "before_run fails",
        state: "In Progress",
        url: "https://example.org/issues/MT-ERR",
        labels: []
      }

      error =
        assert_raise AgentRunner.RunError, fn ->
          AgentRunner.run(issue)
        end

      assert error.issue_id == "issue-run-error"
      assert error.issue_identifier == "MT-ERR"
      assert error.error_class == :permanent
      assert error.reason == {:workspace_hook_failed, "before_run", 1, "CompileError: undefined function\n"}
      assert error.message =~ "error_class=permanent"
      assert error.message =~ "MT-ERR"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()
      trace_id = "trace-live-updates"

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 trace_id: trace_id
               )

      assert_receive {:worker_phase_update, "issue-live-updates",
                      %{
                        phase: :pre_run_hook_enter,
                        timestamp: %DateTime{},
                        trace_id: ^trace_id
                      }},
                     500

      assert_receive {:worker_phase_update, "issue-live-updates",
                      %{
                        phase: :pre_run_hook_exit,
                        timestamp: %DateTime{},
                        trace_id: ^trace_id
                      }},
                     500

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        trace_id: ^trace_id,
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file=#{inspect(trace_file)}
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_payloads =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))

      assert length(turn_payloads) == 2
      assert Enum.uniq(Enum.map(turn_payloads, &get_in(&1, ["params", "threadId"]))) == ["thread-cont"]

      turn_texts =
        Enum.map(turn_payloads, fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops after consecutive empty turns and backs off between them" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-empty-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-empty"}}}'
            ;;
          *)
            turn_number=$((count - 3))
            printf '{"id":3,"result":{"turn":{"id":"turn-empty-%s"}}}\\n' "$turn_number"
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 6
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_empty_turn_fetch_count, 0) + 1
        Process.put(:agent_empty_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch_empty, attempt})

        {:ok,
         [
           %Issue{
             id: "issue-empty-turns",
             identifier: "MT-249",
             title: "Break empty turn loop",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-empty-turns",
        identifier: "MT-249",
        title: "Break empty turn loop",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-249",
        labels: []
      }

      started_at = System.monotonic_time(:millisecond)
      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert_receive {:issue_state_fetch_empty, 1}
      assert_receive {:issue_state_fetch_empty, 2}
      assert_receive {:issue_state_fetch_empty, 3}

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 3
      assert elapsed_ms >= 5_500
      assert elapsed_ms < 15_000
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"turn/start\""))) == 2
    after
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --model gpt-5.3-codex app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--model gpt-5.3-codex app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp stop_task_supervisor_for_test do
    task_supervisor_pid = Process.whereis(SymphonyElixir.TaskSupervisor)

    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {_child_id, pid, _type, _modules} -> pid == task_supervisor_pid
           _child -> false
         end) do
      {child_id, _pid, _type, _modules} ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, child_id)
        child_id

      nil ->
        raise "TaskSupervisor child not found"
    end
  end

  defp install_failing_task_supervisor_for_test do
    child_id = stop_task_supervisor_for_test()
    {:ok, pid} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor, max_children: 0)
    {child_id, pid}
  end

  defp restore_task_supervisor_for_test({child_id, pid}) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, {:noproc, _details} -> :ok
        :exit, :noproc -> :ok
      end
    end

    restart_task_supervisor_for_test(child_id)
  end

  defp restart_task_supervisor_for_test(child_id) do
    case Supervisor.restart_child(SymphonyElixir.Supervisor, child_id) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "failed to restart TaskSupervisor: #{inspect(other)}"
    end
  end

  defp prepare_feedback_dedupe_issue!(issue_id, issue_identifier, workspace_root) do
    workspace = Path.join(workspace_root, issue_identifier)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nFeedback dedupe state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-#{issue_id}")

    %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Feedback retry dedupe",
      description: "Track retry dedupe for identical feedback",
      state: "In Progress",
      url: "https://example.org/issues/#{issue_identifier}",
      labels: []
    }
  end

  defp feedback_dedupe_running_entry(issue, ref, opts) do
    %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      trace_id: Keyword.get(opts, :trace_id),
      retry_attempt: Keyword.get(opts, :retry_attempt),
      runtime_head_sha: Keyword.fetch!(opts, :runtime_head_sha),
      latest_pr_snapshot: %{
        "url" => "https://github.com/acme/symphony/pull/480",
        "state" => "OPEN",
        "has_pending_checks" => false,
        "has_actionable_feedback" => true,
        "feedback_digest" => Keyword.fetch!(opts, :feedback_digest)
      },
      started_at: DateTime.utc_now()
    }
  end

  defp validation_dedupe_running_entry(issue, ref, opts) do
    latest_pr_snapshot =
      %{
        "url" => "https://github.com/acme/symphony/pull/497",
        "state" => "OPEN",
        "has_pending_checks" => false,
        "has_actionable_feedback" => false
      }
      |> maybe_put_feedback_digest(Keyword.get(opts, :feedback_digest))

    %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      trace_id: Keyword.get(opts, :trace_id),
      retry_attempt: Keyword.get(opts, :retry_attempt),
      runtime_head_sha: Keyword.fetch!(opts, :runtime_head_sha),
      current_command: Keyword.fetch!(opts, :current_command),
      external_step: Keyword.get(opts, :external_step),
      latest_pr_snapshot: latest_pr_snapshot,
      started_at: DateTime.utc_now()
    }
  end

  defp continuation_dedupe_running_entry(issue, ref, opts) do
    continuation_reason = Keyword.get(opts, :continuation_reason, "normal_exit")
    validation_bundle_fingerprint = Keyword.fetch!(opts, :validation_bundle_fingerprint)
    feedback_digest = Keyword.fetch!(opts, :feedback_digest)

    %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      trace_id: Keyword.get(opts, :trace_id),
      retry_attempt: Keyword.get(opts, :retry_attempt),
      retry_delay_type: Keyword.get(opts, :retry_delay_type),
      runtime_head_sha: Keyword.fetch!(opts, :runtime_head_sha),
      workspace_diff_fingerprint: Keyword.fetch!(opts, :workspace_diff_fingerprint),
      validation_bundle_fingerprint: validation_bundle_fingerprint,
      feedback_digest: feedback_digest,
      continuation_reason: continuation_reason,
      active_validation_snapshot: %{
        "validation_bundle_fingerprint" => validation_bundle_fingerprint
      },
      latest_pr_snapshot: %{
        "url" => "https://github.com/acme/symphony/pull/539",
        "state" => "OPEN",
        "has_pending_checks" => false,
        "has_actionable_feedback" => true,
        "feedback_digest" => feedback_digest
      },
      started_at: DateTime.utc_now()
    }
  end

  defp maybe_put_feedback_digest(snapshot, digest) when is_binary(digest) and digest != "" do
    snapshot
    |> Map.put("feedback_digest", digest)
    |> Map.put("has_actionable_feedback", true)
  end

  defp maybe_put_feedback_digest(snapshot, _digest), do: snapshot

  defp replace_orchestrator_state!(pid, fun, timeout \\ 30_000)
       when is_pid(pid) and is_function(fun, 1) and is_integer(timeout) and timeout > 0 do
    :sys.replace_state(pid, fun, timeout)
  end

  defp cancel_retry_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_retry_timer(_retry_entry), do: :ok

  defp stop_orchestrator(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :normal)
    end

    :ok
  end

  defp stop_orchestrator(_pid), do: :ok

  defp wait_for_orchestrator_state(pid, predicate, attempts \\ 40)

  defp wait_for_orchestrator_state(pid, predicate, attempts)
       when is_pid(pid) and is_function(predicate, 1) and attempts > 0 do
    state =
      try do
        :sys.get_state(pid)
      catch
        :exit, _reason -> nil
      end

    if is_map(state) and predicate.(state) do
      state
    else
      Process.sleep(25)
      wait_for_orchestrator_state(pid, predicate, attempts - 1)
    end
  end

  defp wait_for_orchestrator_state(pid, _predicate, 0), do: :sys.get_state(pid)
end
