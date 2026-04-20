defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup context do
        :global.set_lock({SymphonyElixir.TestSupport, :workflow_test_lock})

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        previous_path = System.get_env("PATH")
        previous_linear_api_key = System.get_env("LINEAR_API_KEY")
        previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")

        File.mkdir_p!(workflow_root)
        SymphonyElixir.TestSupport.install_test_codex!(workflow_root)

        unless Map.get(context, :live_e2e, false) do
          System.delete_env("LINEAR_API_KEY")
          System.delete_env("LINEAR_ASSIGNEE")
        end

        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        SymphonyElixir.TestSupport.ensure_application_started()
        SymphonyElixir.TestSupport.ensure_workflow_store_running()
        SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          :global.del_lock({SymphonyElixir.TestSupport, :workflow_test_lock})
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          restore_env("LINEAR_API_KEY", previous_linear_api_key)
          restore_env("LINEAR_ASSIGNEE", previous_linear_assignee)
          restore_env("PATH", previous_path)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def ensure_application_started do
    case Application.ensure_all_started(:symphony_elixir) do
      {:ok, _started} -> :ok
      {:error, {:already_started, _app}} -> :ok
      other -> raise "failed to start :symphony_elixir for test setup: #{inspect(other)}"
    end
  end

  def ensure_workflow_store_running do
    case Process.whereis(SymphonyElixir.WorkflowStore) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> raise "failed to restart WorkflowStore for test setup: #{inspect(other)}"
        end
    end
  end

  def stop_default_http_server do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        stop_http_server_child(find_default_http_server_child())

      _ ->
        :ok
    end
  end

  defp find_default_http_server_child do
    Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
      {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
      _child -> false
    end)
  end

  defp stop_http_server_child({SymphonyElixir.HttpServer, child_pid, _type, _modules})
       when is_pid(child_pid) do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

    if Process.alive?(child_pid) do
      Process.exit(child_pid, :normal)
    end

    :ok
  end

  defp stop_http_server_child(_child), do: :ok

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_team_key: nil,
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_manual_intervention_state: "Blocked",
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          workspace_cleanup_keep_recent: 5,
          workspace_warning_threshold_bytes: 10 * 1024 * 1024 * 1024,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_command_template: nil,
          codex_cost_profiles: nil,
          codex_cost_policy: nil,
          codex_planning_command: nil,
          codex_implementation_command: nil,
          codex_handoff_command: nil,
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          codex_enforce_token_budgets: true,
          codex_max_total_tokens: 300_000,
          codex_max_tokens_per_attempt: 120_000,
          codex_max_continuation_attempts: 3,
          codex_accounts: [],
          codex_minimum_remaining_percent: 5,
          codex_monitored_windows_mins: [300, 10_080],
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          server_path: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_team_key = Keyword.get(config, :tracker_team_key)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_manual_intervention_state = Keyword.get(config, :tracker_manual_intervention_state)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    workspace_cleanup_keep_recent = Keyword.get(config, :workspace_cleanup_keep_recent)
    workspace_warning_threshold_bytes = Keyword.get(config, :workspace_warning_threshold_bytes)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_command_template = Keyword.get(config, :codex_command_template)
    codex_cost_profiles = Keyword.get(config, :codex_cost_profiles)
    codex_cost_policy = Keyword.get(config, :codex_cost_policy)
    codex_planning_command = Keyword.get(config, :codex_planning_command)
    codex_implementation_command = Keyword.get(config, :codex_implementation_command)
    codex_handoff_command = Keyword.get(config, :codex_handoff_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    codex_enforce_token_budgets = Keyword.get(config, :codex_enforce_token_budgets)
    codex_max_total_tokens = Keyword.get(config, :codex_max_total_tokens)
    codex_max_tokens_per_attempt = Keyword.get(config, :codex_max_tokens_per_attempt)
    codex_max_continuation_attempts = Keyword.get(config, :codex_max_continuation_attempts)
    codex_accounts = Keyword.get(config, :codex_accounts)
    codex_minimum_remaining_percent = Keyword.get(config, :codex_minimum_remaining_percent)
    codex_monitored_windows_mins = Keyword.get(config, :codex_monitored_windows_mins)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    server_path = Keyword.get(config, :server_path)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  team_key: #{yaml_value(tracker_team_key)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  manual_intervention_state: #{yaml_value(tracker_manual_intervention_state)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        "  cleanup_keep_recent: #{yaml_value(workspace_cleanup_keep_recent)}",
        "  warning_threshold_bytes: #{yaml_value(workspace_warning_threshold_bytes)}",
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  command_template: #{yaml_value(codex_command_template)}",
        "  cost_profiles: #{yaml_value(codex_cost_profiles)}",
        "  cost_policy: #{yaml_value(codex_cost_policy)}",
        "  planning_command: #{yaml_value(codex_planning_command)}",
        "  implementation_command: #{yaml_value(codex_implementation_command)}",
        "  handoff_command: #{yaml_value(codex_handoff_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        "  enforce_token_budgets: #{yaml_value(codex_enforce_token_budgets)}",
        "  max_total_tokens: #{yaml_value(codex_max_total_tokens)}",
        "  max_tokens_per_attempt: #{yaml_value(codex_max_tokens_per_attempt)}",
        "  max_continuation_attempts: #{yaml_value(codex_max_continuation_attempts)}",
        "  accounts: #{yaml_value(codex_accounts)}",
        "  minimum_remaining_percent: #{yaml_value(codex_minimum_remaining_percent)}",
        "  monitored_windows_mins: #{yaml_value(codex_monitored_windows_mins)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host, server_path),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  def install_test_codex!(workflow_root) do
    bin_dir = Path.join(workflow_root, "bin")
    codex_path = Path.join(bin_dir, "codex")

    File.mkdir_p!(bin_dir)

    File.write!(codex_path, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"account/read"'*)
          printf '%s\\n' '{"id":1001,"result":{"requiresOpenaiAuth":true}}'
          ;;
        *'"method":"account/rateLimits/read"'*)
          printf '%s\\n' '{"id":1002,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex"}}}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-test"}}}'
          ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-test"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
        *)
          ;;
      esac
    done
    """)

    File.chmod!(codex_path, 0o755)

    updated_path =
      [bin_dir, System.get_env("PATH")]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(":")

    System.put_env("PATH", updated_path)
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil, nil), do: nil

  defp server_yaml(port, host, path) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}",
      path && "  path: #{yaml_value(path)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
