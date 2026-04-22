defmodule SymphonyElixir.RuntimeSmokeSupport do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator

  def unique_test_root(prefix) when is_binary(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end

  def issue_fixture(attrs \\ %{}) do
    defaults = %{
      id: "runtime-smoke-issue",
      identifier: "RT-SMOKE",
      title: "Runtime smoke issue",
      description: "Runtime smoke validation",
      state: "In Progress",
      url: "https://example.org/issues/runtime-smoke",
      updated_at: DateTime.utc_now(),
      labels: []
    }

    struct(Issue, Map.merge(defaults, Map.new(attrs)))
  end

  def snapshot_issue(issue, state_name) when is_map(issue) and is_binary(state_name) do
    %{issue | state: state_name, updated_at: DateTime.utc_now()}
  end

  def put_memory_tracker!(issues, recipient \\ self()) when is_list(issues) do
    previous_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

    %{issues: previous_issues, recipient: previous_recipient}
  end

  def restore_memory_tracker!(%{issues: previous_issues, recipient: previous_recipient}) do
    restore_app_env!(:memory_tracker_issues, previous_issues)
    restore_app_env!(:memory_tracker_recipient, previous_recipient)
  end

  def restore_memory_tracker!(_state), do: :ok

  def restore_app_env!(key, nil), do: Application.delete_env(:symphony_elixir, key)
  def restore_app_env!(key, value), do: Application.put_env(:symphony_elixir, key, value)

  def wait_for_orchestrator_state(pid, predicate, timeout_ms \\ 2_000)
      when is_pid(pid) and is_function(predicate, 1) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
  end

  def init_workspace_repo!(workspace_root, issue_identifier)
      when is_binary(workspace_root) and is_binary(issue_identifier) do
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

  def git_output!(workspace, args) when is_binary(workspace) and is_list(args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    String.trim(output)
  end

  def write_delayed_codex!(test_root, opts \\ []) when is_binary(test_root) and is_list(opts) do
    script_path = Path.join(test_root, "runtime-smoke-codex")
    turn_started_marker = Keyword.get(opts, :turn_started_marker)
    turn_completed_delay_s = Keyword.get(opts, :turn_completed_delay_s, "0.6")

    marker_command =
      case turn_started_marker do
        path when is_binary(path) and path != "" ->
          escaped_path = String.replace(path, "\"", "\\\"")
          "printf 'turn_started\\n' > \"#{escaped_path}\""

        _ ->
          ":"
      end

    File.write!(script_path, """
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
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-smoke"}}}'
          ;;
        *'"method":"turn/start"'*)
          #{marker_command}
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-smoke"}}}'
          sleep #{turn_completed_delay_s}
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
        *)
          ;;
      esac
    done
    """)

    File.chmod!(script_path, 0o755)
    script_path
  end

  def healthy_probe_statuses(accounts) when is_list(accounts) do
    Enum.map(accounts, fn account ->
      %{
        id: account.id,
        codex_home: account.codex_home,
        explicit?: Map.get(account, :explicit?, true),
        checked_at: DateTime.utc_now(),
        healthy: true,
        health_reason: nil,
        auth_mode: "chatgpt",
        email: "#{account.id}@example.com",
        plan_type: "pro",
        requires_openai_auth: false,
        rate_limits: %{
          "limitId" => "codex",
          "primary" => %{"windowDurationMins" => 300, "usedPercent" => 20},
          "secondary" => %{"windowDurationMins" => 10_080, "usedPercent" => 35}
        },
        account: %{"email" => "#{account.id}@example.com"},
        missing_windows_mins: [],
        insufficient_windows_mins: []
      }
    end)
  end

  def install_failing_task_supervisor_for_test do
    child_id = stop_task_supervisor_for_test()
    {:ok, pid} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor, max_children: 0)
    {child_id, pid}
  end

  def restore_task_supervisor_for_test({child_id, pid}) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, {:noproc, _details} -> :ok
        :exit, :noproc -> :ok
      end
    end

    case Supervisor.restart_child(SymphonyElixir.Supervisor, child_id) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "failed to restart TaskSupervisor: #{inspect(other)}"
    end
  end

  def stop_orchestrator(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :normal)
    end

    :ok
  end

  def request_refresh!(server) do
    case Orchestrator.request_refresh(server) do
      :unavailable -> raise "orchestrator is unavailable"
      reply -> reply
    end
  end

  defp do_wait_for_orchestrator_state(pid, predicate, deadline_ms) do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      now_ms = System.monotonic_time(:millisecond)

      if now_ms >= deadline_ms do
        state
      else
        Process.sleep(25)
        do_wait_for_orchestrator_state(pid, predicate, deadline_ms)
      end
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

  defp git_ok!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end
