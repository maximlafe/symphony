defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])
  @fresh_attempt_states MapSet.new(["Rework"])
  @stale_bootstrap_markers [".symphony-base-branch-error"]
  @default_issue_cleanup_external_roots ["/tmp", "/var/tmp"]
  @issue_cleanup_prefix "symphony-"
  @issue_cleanup_lock_dir ".symphony-cleanup-locks"
  @issue_cleanup_lock_retry_ms 10
  @issue_cleanup_lock_max_attempts 500

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id),
           :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace, issue_context),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, issue_context) do
    cond do
      File.dir?(workspace) and recreate_workspace?(workspace, issue_context) ->
        create_workspace(workspace)

      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  defp recreate_workspace?(workspace, issue_context) do
    fresh_attempt_state?(Map.get(issue_context, :issue_state)) or stale_failed_bootstrap?(workspace)
  end

  defp fresh_attempt_state?(state) when is_atom(state), do: fresh_attempt_state?(Atom.to_string(state))

  defp fresh_attempt_state?(state) when is_binary(state) do
    MapSet.member?(@fresh_attempt_states, String.trim(state))
  end

  defp fresh_attempt_state?(_state), do: false

  defp stale_failed_bootstrap?(workspace) do
    Enum.any?(@stale_bootstrap_markers, fn marker ->
      File.exists?(Path.join(workspace, marker))
    end)
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    with_issue_cleanup_lock(safe_id, fn ->
      remove_issue_workspace(safe_id)
      :ok
    end)

    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec cleanup_issue_artifacts(term(), keyword()) :: :ok
  def cleanup_issue_artifacts(identifier, opts \\ []) when is_list(opts) do
    case identifier do
      identifier when is_binary(identifier) ->
        safe_id = safe_identifier(identifier)

        with_issue_cleanup_lock(safe_id, fn ->
          remove_issue_workspace(safe_id)

          safe_id
          |> issue_cleanup_patterns(opts)
          |> Enum.each(&remove_issue_external_pattern(&1, safe_id, opts))

          :ok
        end)

        :ok

      _ ->
        :ok
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, keyword()) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier, opts)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier, opts)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  @spec total_usage_bytes(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def total_usage_bytes(workspace_root) when is_binary(workspace_root) do
    usage_for_path(Path.expand(workspace_root))
  end

  def total_usage_bytes(_workspace_root), do: {:error, :invalid_workspace_root}

  @spec root_usage_bytes() :: {:ok, non_neg_integer()} | {:error, term()}
  def root_usage_bytes do
    total_usage_bytes(Config.settings!().workspace.root)
  end

  @spec cleanup_completed_issue_workspaces([map()], keyword()) ::
          {:ok, %{kept: [String.t()], removed: [String.t()]}}
  def cleanup_completed_issue_workspaces(issues, opts \\ []) when is_list(issues) and is_list(opts) do
    keep_recent = keep_recent_option(opts)

    {kept, removed} =
      issues
      |> completed_issue_identifiers_sorted()
      |> Enum.split(keep_recent)

    removed = Enum.filter(removed, &remove_retained_issue_workspace/1)

    {:ok, %{kept: kept, removed: removed}}
  end

  defp keep_recent_option(opts) when is_list(opts) do
    case Keyword.get(opts, :keep_recent, Config.settings!().workspace.cleanup_keep_recent) do
      keep_recent when is_integer(keep_recent) and keep_recent >= 0 -> keep_recent
      _ -> 5
    end
  end

  defp remove_issue_workspace(safe_id) when is_binary(safe_id) do
    case workspace_path_for_issue(safe_id) do
      {:ok, workspace} ->
        removed? = File.exists?(workspace)
        _ = remove(workspace)
        removed?

      {:error, _reason} ->
        false
    end
  end

  defp remove_retained_issue_workspace(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    with_issue_cleanup_lock(safe_id, fn -> remove_issue_workspace(safe_id) end)
  end

  defp issue_cleanup_patterns(safe_id, opts) when is_binary(safe_id) and is_list(opts) do
    default_patterns =
      Enum.map(@default_issue_cleanup_external_roots, fn root ->
        Path.join(root, "#{@issue_cleanup_prefix}#{safe_id}-*")
      end)

    extra_patterns =
      case Keyword.get(opts, :external_paths, []) do
        patterns when is_list(patterns) -> Enum.filter(patterns, &is_binary/1)
        _ -> []
      end

    default_patterns ++ extra_patterns
  end

  defp remove_issue_external_pattern(pattern, safe_id, opts)
       when is_binary(pattern) and is_binary(safe_id) and is_list(opts) do
    case validate_issue_cleanup_pattern(pattern, safe_id, opts) do
      {:ok, expanded_pattern, allowed_roots} ->
        expanded_pattern
        |> Path.wildcard(match_dot: true)
        |> Enum.each(&remove_issue_cleanup_match(&1, safe_id, allowed_roots))

      {:error, reason} ->
        Logger.warning("Skipping unsafe issue cleanup pattern issue_identifier=#{safe_id} pattern=#{inspect(pattern)} reason=#{inspect(reason)}")
    end
  end

  defp remove_issue_cleanup_match(path, safe_id, allowed_roots)
       when is_binary(path) and is_binary(safe_id) and is_list(allowed_roots) do
    case validate_issue_cleanup_match(path, safe_id, allowed_roots) do
      :ok ->
        File.rm_rf(path)

      {:error, reason} ->
        Logger.warning("Skipping unsafe issue cleanup match issue_identifier=#{safe_id} path=#{inspect(path)} reason=#{inspect(reason)}")
    end
  end

  defp validate_issue_cleanup_pattern(pattern, safe_id, opts)
       when is_binary(pattern) and is_binary(safe_id) and is_list(opts) do
    expanded_pattern = Path.expand(pattern)
    dirname = Path.dirname(expanded_pattern)
    basename = Path.basename(expanded_pattern)
    allowed_roots = allowed_issue_cleanup_roots(opts)

    with :ok <- validate_issue_cleanup_absolute_path(expanded_pattern),
         :ok <- validate_issue_cleanup_basename(basename, safe_id),
         :ok <- validate_issue_cleanup_pattern_prefix(dirname, expanded_pattern),
         :ok <- validate_issue_cleanup_directory(dirname, allowed_roots) do
      {:ok, expanded_pattern, allowed_roots}
    end
  end

  defp validate_issue_cleanup_absolute_path(expanded_pattern)
       when is_binary(expanded_pattern) do
    if Path.type(expanded_pattern) == :absolute do
      :ok
    else
      {:error, {:issue_cleanup_path_not_absolute, expanded_pattern}}
    end
  end

  defp validate_issue_cleanup_basename(basename, safe_id)
       when is_binary(basename) and is_binary(safe_id) do
    cond do
      basename in [".", "..", ""] ->
        {:error, {:issue_cleanup_invalid_basename, basename}}

      issue_cleanup_basename?(basename, safe_id) ->
        :ok

      true ->
        {:error, {:issue_cleanup_unscoped_basename, basename, safe_id}}
    end
  end

  defp validate_issue_cleanup_pattern_prefix(dirname, expanded_pattern)
       when is_binary(dirname) and is_binary(expanded_pattern) do
    if glob_in_path_prefix?(dirname) do
      {:error, {:issue_cleanup_glob_outside_basename, expanded_pattern}}
    else
      :ok
    end
  end

  defp validate_issue_cleanup_match(path, safe_id, allowed_roots)
       when is_binary(path) and is_binary(safe_id) and is_list(allowed_roots) do
    expanded_path = Path.expand(path)
    basename = Path.basename(expanded_path)

    cond do
      basename in [".", "..", ""] ->
        {:error, {:issue_cleanup_invalid_basename, basename}}

      not issue_cleanup_basename?(basename, safe_id) ->
        {:error, {:issue_cleanup_unscoped_basename, basename, safe_id}}

      true ->
        validate_issue_cleanup_directory(Path.dirname(expanded_path), allowed_roots)
    end
  end

  defp validate_issue_cleanup_directory(path, allowed_roots)
       when is_binary(path) and is_list(allowed_roots) do
    expanded_path = Path.expand(path)

    Enum.find_value(
      allowed_roots,
      {:error, {:issue_cleanup_outside_allowed_roots, expanded_path, allowed_roots}},
      fn root ->
        case validate_issue_cleanup_root(expanded_path, root) do
          :ok -> :ok
          {:error, _reason} -> nil
        end
      end
    )
  end

  defp validate_issue_cleanup_root(path, root) when is_binary(path) and is_binary(root) do
    expanded_root = Path.expand(root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_path} <- PathSafety.canonicalize(path),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_path == canonical_root ->
          :ok

        String.starts_with?(canonical_path <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(path <> "/", expanded_root_prefix) ->
          {:error, {:issue_cleanup_symlink_escape, path, canonical_root}}

        true ->
          {:error, {:issue_cleanup_outside_allowed_root, canonical_path, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, unreadable_path, reason}} ->
        {:error, {:issue_cleanup_path_unreadable, unreadable_path, reason}}
    end
  end

  defp allowed_issue_cleanup_roots(opts) when is_list(opts) do
    case Keyword.get(opts, :allowed_external_roots, []) do
      roots when is_list(roots) ->
        (@default_issue_cleanup_external_roots ++ roots)
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&Path.expand/1)
        |> Enum.uniq()

      _ ->
        @default_issue_cleanup_external_roots
    end
  end

  defp issue_cleanup_basename?(basename, safe_id)
       when is_binary(basename) and is_binary(safe_id) do
    String.starts_with?(basename, "#{@issue_cleanup_prefix}#{safe_id}-")
  end

  defp glob_in_path_prefix?(path) when is_binary(path) do
    String.contains?(path, ["*", "?", "["])
  end

  defp with_issue_cleanup_lock(safe_id, fun)
       when is_binary(safe_id) and is_function(fun, 0) do
    lock_path = issue_cleanup_lock_path(safe_id)

    case acquire_issue_cleanup_lock(lock_path, @issue_cleanup_lock_max_attempts) do
      :ok ->
        try do
          fun.()
        after
          release_issue_cleanup_lock(lock_path)
        end

      {:error, reason} ->
        Logger.warning("Skipping issue cleanup lock acquisition issue_identifier=#{safe_id} reason=#{inspect(reason)}")

        false
    end
  end

  defp issue_cleanup_lock_path(safe_id) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.expand()
    |> Path.join(@issue_cleanup_lock_dir)
    |> Path.join(safe_id)
  end

  defp acquire_issue_cleanup_lock(lock_path, attempts_left)
       when is_binary(lock_path) and is_integer(attempts_left) and attempts_left > 0 do
    lock_root = Path.dirname(lock_path)

    case File.mkdir(lock_path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        File.mkdir_p!(lock_root)
        acquire_issue_cleanup_lock(lock_path, attempts_left)

      {:error, :eexist} ->
        Process.sleep(@issue_cleanup_lock_retry_ms)
        acquire_issue_cleanup_lock(lock_path, attempts_left - 1)

      {:error, reason} ->
        {:error, {:issue_cleanup_lock_failed, lock_path, reason}}
    end
  end

  defp acquire_issue_cleanup_lock(lock_path, 0) when is_binary(lock_path) do
    {:error, {:issue_cleanup_lock_timeout, lock_path}}
  end

  defp release_issue_cleanup_lock(lock_path) when is_binary(lock_path) do
    case File.rmdir(lock_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, :enotempty} -> File.rm_rf(lock_path)
      {:error, _reason} -> :ok
    end
  end

  defp completed_issue_identifiers_sorted(issues) do
    issues
    |> Enum.flat_map(fn issue ->
      case completed_issue_identifier(issue) do
        identifier when is_binary(identifier) -> [{identifier, completed_issue_sort_key(issue)}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_identifier, sort_key} -> sort_key end, :desc)
    |> Enum.uniq_by(fn {identifier, _sort_key} -> identifier end)
    |> Enum.map(fn {identifier, _sort_key} -> identifier end)
  end

  defp completed_issue_identifier(%{identifier: identifier})
       when is_binary(identifier) and identifier != "" do
    identifier
  end

  defp completed_issue_identifier(%{"identifier" => identifier})
       when is_binary(identifier) and identifier != "" do
    identifier
  end

  defp completed_issue_identifier(_issue), do: nil

  defp completed_issue_sort_key(%{updated_at: %DateTime{} = updated_at}) do
    DateTime.to_unix(updated_at, :millisecond)
  end

  defp completed_issue_sort_key(%{"updated_at" => %DateTime{} = updated_at}) do
    DateTime.to_unix(updated_at, :millisecond)
  end

  defp completed_issue_sort_key(%{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :millisecond)
  end

  defp completed_issue_sort_key(%{"created_at" => %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :millisecond)
  end

  defp completed_issue_sort_key(_issue), do: 0

  defp usage_for_path(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        usage_for_directory(path)

      {:ok, %File.Stat{type: :regular, size: size}} when is_integer(size) and size > 0 ->
        {:ok, size}

      {:ok, %File.Stat{}} ->
        {:ok, 0}

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, {:workspace_usage_scan_failed, path, reason}}
    end
  end

  defp usage_for_directory(path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, 0}, &accumulate_directory_usage(path, &1, &2))

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, {:workspace_usage_scan_failed, path, reason}}
    end
  end

  defp accumulate_directory_usage(path, entry, {:ok, acc}) do
    case usage_for_path(Path.join(path, entry)) do
      {:ok, size} -> {:cont, {:ok, acc + size}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace), trace_id: nil},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    env = hook_env(issue_context)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, env: env, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp issue_context(issue_or_identifier, opts \\ [])

  defp issue_context(%{id: issue_id, identifier: identifier} = issue, opts) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_title: Map.get(issue, :title),
      issue_description: Map.get(issue, :description),
      issue_project_slug: Map.get(issue, :project_slug),
      issue_project_name: Map.get(issue, :project_name),
      issue_labels: Map.get(issue, :labels) || [],
      issue_state: Map.get(issue, :state),
      issue_branch_name: Map.get(issue, :branch_name),
      issue_url: Map.get(issue, :url),
      trace_id: Keyword.get(opts, :trace_id) || issue_trace_id(issue)
    }
  end

  defp issue_context(identifier, opts) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_title: nil,
      issue_description: nil,
      issue_project_slug: nil,
      issue_project_name: nil,
      issue_labels: [],
      issue_state: nil,
      issue_branch_name: nil,
      issue_url: nil,
      trace_id: Keyword.get(opts, :trace_id)
    }
  end

  defp issue_context(_identifier, opts) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_title: nil,
      issue_description: nil,
      issue_project_slug: nil,
      issue_project_name: nil,
      issue_labels: [],
      issue_state: nil,
      issue_branch_name: nil,
      issue_url: nil,
      trace_id: Keyword.get(opts, :trace_id)
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier, trace_id: trace_id}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"} trace_id=#{trace_id || "n/a"}"
  end

  defp hook_env(issue_context) when is_map(issue_context) do
    [
      {"SYMPHONY_ISSUE_ID", env_value(Map.get(issue_context, :issue_id))},
      {"SYMPHONY_ISSUE_IDENTIFIER", env_value(Map.get(issue_context, :issue_identifier))},
      {"SYMPHONY_ISSUE_TITLE", env_value(Map.get(issue_context, :issue_title))},
      {"SYMPHONY_ISSUE_DESCRIPTION", env_value(Map.get(issue_context, :issue_description))},
      {"SYMPHONY_ISSUE_PROJECT_SLUG", env_value(Map.get(issue_context, :issue_project_slug))},
      {"SYMPHONY_ISSUE_PROJECT_NAME", env_value(Map.get(issue_context, :issue_project_name))},
      {"SYMPHONY_ISSUE_LABELS", issue_labels_env(Map.get(issue_context, :issue_labels))},
      {"SYMPHONY_ISSUE_STATE", env_value(Map.get(issue_context, :issue_state))},
      {"SYMPHONY_ISSUE_BRANCH_NAME", env_value(Map.get(issue_context, :issue_branch_name))},
      {"SYMPHONY_ISSUE_URL", env_value(Map.get(issue_context, :issue_url))},
      {"SYMPHONY_TRACE_ID", env_value(Map.get(issue_context, :trace_id))}
    ]
  end

  defp issue_trace_id(%{trace_id: trace_id}) when is_binary(trace_id) and trace_id != "", do: trace_id
  defp issue_trace_id(_issue), do: nil

  defp issue_labels_env(labels) when is_list(labels) do
    Enum.map_join(labels, "\n", fn
      label when is_binary(label) -> label
      other -> to_string(other)
    end)
  end

  defp issue_labels_env(_labels), do: ""

  defp env_value(nil), do: ""
  defp env_value(value) when is_binary(value), do: value
  defp env_value(value), do: to_string(value)
end
