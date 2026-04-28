defmodule SymphonyElixir.WorkspaceCapability do
  @moduledoc """
  Builds and caches a cheap workspace/repo capability manifest for pre-launch gating.
  """

  alias SymphonyElixir.PathSafety

  @manifest_version 1
  @cache_dir ".symphony/cache"
  @cache_file "workspace-capability-manifest.json"

  @runtime_required_tools ["rg"]
  @pr_tail_required_tools ["git", "gh"]
  @supported_approval_policies ["untrusted", "on-failure", "on-request", "never"]
  @validation_entrypoints [
    {"preflight", "symphony-preflight"},
    {"repo_validation", "symphony-validate"},
    {"handoff_check", "symphony-handoff-check"}
  ]

  @tool_inventory Enum.sort(Enum.uniq(["make" | @runtime_required_tools ++ @pr_tail_required_tools]))

  @type manifest :: map()
  @type rejection_reason :: map()

  @spec prelaunch_gate(Path.t(), keyword()) ::
          {:ok, manifest()} | {:error, {:workspace_capability_rejected, rejection_reason()} | term()}
  def prelaunch_gate(workspace, opts \\ []) do
    with {:ok, manifest} <- load_or_probe(workspace, opts),
         :ok <- validate_command_classes(manifest, opts) do
      {:ok, manifest}
    end
  end

  @spec load_or_probe(Path.t()) :: {:ok, manifest()} | {:error, term()}
  def load_or_probe(workspace), do: load_or_probe(workspace, [])

  @spec load_or_probe(Path.t(), keyword()) :: {:ok, manifest()} | {:error, term()}
  def load_or_probe(workspace, opts) when is_binary(workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace) do
      case resolve_repo_root(canonical_workspace) do
        {:ok, repo_root} ->
          build_repo_manifest(canonical_workspace, repo_root, opts)

        :error ->
          {:ok, non_repo_manifest(canonical_workspace)}
      end
    end
  end

  def load_or_probe(workspace, _opts), do: {:error, {:invalid_workspace, workspace}}

  defp build_repo_manifest(canonical_workspace, repo_root, opts) do
    tool_paths = probe_tools(opts)
    {makefile_path, makefile_body, makefile_digest} = read_makefile(repo_root)
    cache_path = manifest_path(canonical_workspace)
    cache_key = cache_key(canonical_workspace, repo_root, makefile_digest, tool_paths)

    case read_cached_manifest(cache_path, cache_key) do
      {:ok, manifest} ->
        {:ok, manifest}

      :miss ->
        make_targets = parse_make_targets(makefile_body)

        manifest =
          %{
            "version" => @manifest_version,
            "mode" => "repo_workspace",
            "captured_at" => captured_at(opts),
            "cache_key" => cache_key,
            "manifest_path" => cache_path,
            "workspace" => %{
              "cwd" => canonical_workspace,
              "repo_root" => repo_root
            },
            "tools" => tool_statuses(tool_paths),
            "makefile" => %{
              "path" => makefile_path,
              "exists" => is_binary(makefile_body),
              "targets" => make_targets |> MapSet.to_list() |> Enum.sort()
            },
            "validation_entrypoints" => validation_entrypoints(make_targets, tool_paths)
          }

        _ = write_cached_manifest(cache_path, manifest)
        {:ok, manifest}
    end
  end

  defp validate_command_classes(%{"mode" => "non_repo_workspace"} = manifest, opts) do
    ensure_approval_policy(manifest, opts)
  end

  defp validate_command_classes(%{} = manifest, opts) do
    manifest
    |> ensure_runtime_class()
    |> continue_gate(fn -> ensure_validation_class(manifest) end)
    |> continue_gate(fn -> ensure_pr_tail_class(manifest) end)
    |> continue_gate(fn -> ensure_approval_policy(manifest, opts) end)
  end

  defp continue_gate(:ok, next_fun) when is_function(next_fun, 0), do: next_fun.()
  defp continue_gate(error, _next_fun), do: error

  defp ensure_runtime_class(manifest) do
    case first_missing_tool(manifest, @runtime_required_tools) do
      nil ->
        :ok

      tool ->
        {:error, rejection(manifest, :runtime, :missing_tool, %{tool: tool})}
    end
  end

  defp ensure_validation_class(manifest) do
    case first_missing_tool(manifest, ["make"]) do
      nil ->
        case missing_validation_entrypoint(manifest) do
          nil ->
            :ok

          %{id: id, target: target} ->
            {:error,
             rejection(manifest, :validation, :missing_make_target, %{
               entrypoint: id,
               target: target
             })}
        end

      missing_tool ->
        {:error, rejection(manifest, :validation, :missing_tool, %{tool: missing_tool})}
    end
  end

  defp ensure_pr_tail_class(manifest) do
    case first_missing_tool(manifest, @pr_tail_required_tools) do
      nil ->
        :ok

      tool ->
        {:error, rejection(manifest, :pr_tail, :missing_tool, %{tool: tool})}
    end
  end

  defp ensure_approval_policy(manifest, opts) when is_map(manifest) and is_list(opts) do
    case Keyword.get(opts, :approval_policy) do
      nil ->
        :ok

      approval_policy ->
        case normalize_approval_policy(approval_policy) do
          {:ok, _normalized} ->
            :ok

          {:error, value} ->
            {:error,
             rejection(manifest, :runtime, :unsupported_approval_policy, %{
               approval_policy: value,
               supported_approval_policies: @supported_approval_policies
             })}
        end
    end
  end

  defp ensure_approval_policy(_manifest, _opts), do: :ok

  defp normalize_approval_policy(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    cond do
      normalized == "" ->
        {:error, "(empty)"}

      normalized in @supported_approval_policies ->
        {:ok, normalized}

      true ->
        {:error, normalized}
    end
  end

  defp normalize_approval_policy(%{} = value) do
    if Map.has_key?(value, "reject") or Map.has_key?(value, :reject) do
      {:error, "reject"}
    else
      {:error, inspect(value)}
    end
  end

  defp normalize_approval_policy(value), do: {:error, inspect(value)}

  defp first_missing_tool(manifest, required_tools) do
    Enum.find(required_tools, fn tool -> not tool_available?(manifest, tool) end)
  end

  defp tool_available?(manifest, tool) when is_binary(tool) do
    get_in(manifest, ["tools", tool, "available"]) == true
  end

  defp missing_validation_entrypoint(manifest) do
    manifest
    |> Map.get("validation_entrypoints", [])
    |> Enum.find_value(fn
      %{"available" => true} ->
        nil

      %{"id" => id, "required_target" => target} when is_binary(id) and is_binary(target) ->
        %{id: id, target: target}

      _entry ->
        nil
    end)
  end

  defp rejection(manifest, command_class, reason, details) when is_map(details) do
    %{workspace: workspace, repo_root: repo_root, manifest_path: manifest_path, cache_key: cache_key} =
      manifest_context(manifest)

    base = %{
      reason: reason,
      command_class: command_class,
      workspace_cwd: workspace,
      repo_root: repo_root,
      manifest_path: manifest_path,
      manifest_cache_key: cache_key
    }

    base
    |> Map.merge(details)
    |> Map.put(:summary, rejection_summary(command_class, reason, details))
    |> then(&{:workspace_capability_rejected, &1})
  end

  defp rejection_summary(command_class, :missing_tool, %{tool: tool}) do
    "workspace capability rejected #{command_class}: missing required tool `#{tool}`"
  end

  defp rejection_summary(command_class, :missing_make_target, %{target: target}) do
    "workspace capability rejected #{command_class}: missing required make target `#{target}`"
  end

  defp rejection_summary(
         command_class,
         :unsupported_approval_policy,
         %{approval_policy: approval_policy, supported_approval_policies: supported}
       ) do
    "workspace capability rejected #{command_class}: unsupported approval policy `#{approval_policy}`; supported values: #{Enum.join(supported, ", ")}"
  end

  defp manifest_context(manifest) do
    %{
      workspace: get_in(manifest, ["workspace", "cwd"]),
      repo_root: get_in(manifest, ["workspace", "repo_root"]),
      manifest_path: Map.get(manifest, "manifest_path"),
      cache_key: Map.get(manifest, "cache_key")
    }
  end

  defp non_repo_manifest(canonical_workspace) do
    %{
      "version" => @manifest_version,
      "mode" => "non_repo_workspace",
      "workspace" => %{
        "cwd" => canonical_workspace,
        "repo_root" => nil
      },
      "reason" => "repo_root_not_found"
    }
  end

  defp resolve_repo_root(canonical_workspace) when is_binary(canonical_workspace) do
    canonical_workspace
    |> path_ancestors()
    |> Enum.find(&git_marker_exists?/1)
    |> case do
      nil -> :error
      repo_root -> PathSafety.canonicalize(repo_root)
    end
  end

  defp path_ancestors(path) when is_binary(path) do
    build_path_ancestors(path, [])
  end

  defp build_path_ancestors(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      Enum.reverse([path | acc])
    else
      build_path_ancestors(parent, [path | acc])
    end
  end

  defp git_marker_exists?(path) when is_binary(path) do
    case File.stat(Path.join(path, ".git")) do
      {:ok, %File.Stat{}} -> true
      _ -> false
    end
  end

  defp probe_tools(opts) do
    probe = Keyword.get(opts, :tool_probe, &System.find_executable/1)

    Enum.into(@tool_inventory, %{}, fn tool ->
      {tool, normalize_tool_path(probe.(tool))}
    end)
  end

  defp normalize_tool_path(path) when is_binary(path) do
    trimmed = String.trim(path)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_tool_path(_path), do: nil

  defp read_makefile(repo_root) when is_binary(repo_root) do
    makefile_path = Path.join(repo_root, "Makefile")

    case File.read(makefile_path) do
      {:ok, body} ->
        digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
        {makefile_path, body, digest}

      {:error, :enoent} ->
        {makefile_path, nil, "missing"}

      {:error, reason} ->
        {makefile_path, nil, "error:#{reason}"}
    end
  end

  defp parse_make_targets(nil), do: MapSet.new()

  defp parse_make_targets(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reduce(MapSet.new(), fn line, acc ->
      parse_make_targets_line(line, acc)
    end)
  end

  defp parse_make_targets_line(line, acc) when is_binary(line) do
    trimmed = String.trim(line)

    if ignorable_make_line?(line, trimmed) do
      acc
    else
      trimmed
      |> make_targets_from_line()
      |> Enum.reduce(acc, &maybe_add_make_target/2)
    end
  end

  defp ignorable_make_line?(line, trimmed) when is_binary(line) and is_binary(trimmed) do
    trimmed == "" or
      String.starts_with?(line, "\t") or
      String.starts_with?(trimmed, "#") or
      String.contains?(trimmed, ":=") or
      String.contains?(trimmed, "?=") or
      String.contains?(trimmed, "+=")
  end

  defp make_targets_from_line(trimmed) when is_binary(trimmed) do
    case String.split(trimmed, ":", parts: 2) do
      [lhs, _rhs] -> String.split(lhs, ~r/\s+/, trim: true)
      _ -> []
    end
  end

  defp maybe_add_make_target(target, acc) when is_binary(target) and is_map(acc) do
    if target != "" and
         not String.starts_with?(target, ".") and
         not String.contains?(target, "%") and
         not String.starts_with?(target, "$") do
      MapSet.put(acc, target)
    else
      acc
    end
  end

  defp validation_entrypoints(make_targets, tool_paths) do
    make_available = is_binary(Map.get(tool_paths, "make"))

    Enum.map(@validation_entrypoints, fn {id, target} ->
      target_available = MapSet.member?(make_targets, target)
      available = make_available and target_available

      %{
        "id" => id,
        "command" => "make #{target}",
        "required_tool" => "make",
        "required_target" => target,
        "available" => available,
        "missing_reason" =>
          cond do
            available -> nil
            not make_available -> "missing_tool"
            true -> "missing_make_target"
          end
      }
    end)
  end

  defp tool_statuses(tool_paths) when is_map(tool_paths) do
    Enum.into(tool_paths, %{}, fn {tool, path} ->
      {tool, %{"available" => is_binary(path), "path" => path}}
    end)
  end

  defp manifest_path(workspace) when is_binary(workspace) do
    Path.join([workspace, @cache_dir, @cache_file])
  end

  defp cache_key(canonical_workspace, repo_root, makefile_digest, tool_paths) do
    digest_source = %{
      version: @manifest_version,
      workspace: canonical_workspace,
      repo_root: repo_root,
      makefile_digest: makefile_digest,
      tools: tool_paths
    }

    digest_source
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp read_cached_manifest(cache_path, cache_key) do
    with {:ok, body} <- File.read(cache_path),
         {:ok, decoded} <- Jason.decode(body),
         true <- decoded["version"] == @manifest_version,
         true <- decoded["cache_key"] == cache_key do
      {:ok, decoded}
    else
      _ -> :miss
    end
  end

  defp write_cached_manifest(cache_path, manifest) when is_binary(cache_path) and is_map(manifest) do
    with :ok <- File.mkdir_p(Path.dirname(cache_path)),
         encoded <- Jason.encode_to_iodata!(manifest),
         :ok <- File.write(cache_path, encoded) do
      :ok
    else
      _ -> :error
    end
  end

  defp captured_at(opts) do
    case Keyword.get(opts, :time_source, fn -> DateTime.utc_now() end).() do
      %DateTime{} = timestamp -> DateTime.to_iso8601(timestamp)
      _other -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end
end
