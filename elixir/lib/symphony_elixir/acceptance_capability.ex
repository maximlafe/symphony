defmodule SymphonyElixir.AcceptanceCapability do
  @moduledoc """
  Evaluates explicit per-issue capabilities needed before an execution run can
  credibly complete its acceptance contract.

  The gate is intentionally driven by the task-spec `## Symphony` block instead
  of hard-coding verification labels. Labels select handoff profiles; explicit
  capabilities describe external resources that must exist before execution.
  """

  alias SymphonyElixir.WorkspaceCapability

  @supported_capabilities [
    "artifact_upload",
    "pr_body_contract",
    "pr_publication",
    "repo_validation",
    "runtime_smoke",
    "stateful_db",
    "ui_runtime",
    "vps_ssh"
  ]

  @capability_aliases %{
    "artifact" => "artifact_upload",
    "artifact_upload" => "artifact_upload",
    "db" => "stateful_db",
    "database" => "stateful_db",
    "database_url" => "stateful_db",
    "pr" => "pr_publication",
    "pr_body" => "pr_body_contract",
    "pr_body_contract" => "pr_body_contract",
    "pr_publication" => "pr_publication",
    "repo_validation" => "repo_validation",
    "runtime" => "runtime_smoke",
    "runtime_smoke" => "runtime_smoke",
    "stateful" => "stateful_db",
    "stateful_db" => "stateful_db",
    "ui" => "ui_runtime",
    "ui_runtime" => "ui_runtime",
    "vps" => "vps_ssh",
    "vps_ssh" => "vps_ssh"
  }

  @type result :: {:ok, map()} | {:error, map()}

  @spec supported_capabilities() :: [String.t()]
  def supported_capabilities, do: @supported_capabilities

  @spec evaluate(Path.t(), map() | struct(), keyword()) :: result()
  def evaluate(workspace, issue, opts \\ []) when is_binary(workspace) do
    description = issue_description(issue)
    {capabilities, parse_errors} = required_capabilities(description)

    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    tcp_connect = Keyword.get(opts, :tcp_connect, &tcp_connect/2)
    manifest_result = Keyword.get_lazy(opts, :manifest_result, fn -> WorkspaceCapability.load_or_probe(workspace) end)

    case manifest_result do
      {:ok, manifest} ->
        missing =
          capabilities
          |> Enum.flat_map(&missing_for_capability(&1, env, manifest, tcp_connect))
          |> Enum.concat(parse_errors)
          |> Enum.uniq()

        report = report(workspace, capabilities, manifest, missing)

        if missing == [] do
          {:ok, report}
        else
          {:error, report}
        end

      {:error, reason} ->
        {:error,
         %{
           "passed" => false,
           "workspace" => workspace,
           "required_capabilities" => capabilities,
           "missing" => ["workspace capability manifest unavailable: #{inspect(reason)}"]
         }}
    end
  end

  @spec required_capabilities(String.t() | nil) :: {[String.t()], [String.t()]}
  def required_capabilities(description) when is_binary(description) do
    description
    |> required_capability_lines()
    |> Enum.flat_map(&capability_values_from_line/1)
    |> normalize_capability_values()
  end

  def required_capabilities(_description), do: {[], []}

  @spec summarize_failure(map()) :: String.t()
  def summarize_failure(%{"required_capabilities" => capabilities, "missing" => missing}) do
    required =
      case capabilities do
        [] -> "none"
        values -> Enum.join(values, ", ")
      end

    missing_text =
      case missing do
        [] -> "none"
        values -> Enum.join(values, "; ")
      end

    "acceptance capability preflight failed; required=#{required}; missing=#{missing_text}"
  end

  defp report(workspace, capabilities, manifest, missing) do
    %{
      "passed" => missing == [],
      "workspace" => workspace,
      "required_capabilities" => capabilities,
      "missing" => missing,
      "make_targets" => get_in(manifest, ["makefile", "targets"]) || []
    }
  end

  defp required_capability_lines(description) do
    Regex.scan(~r/^\s*Required capabilities\s*:\s*(.+)$/im, description)
    |> Enum.map(fn [_match, value] -> value end)
  end

  defp capability_values_from_line(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp normalize_capability_values(values) do
    Enum.reduce(values, {[], []}, fn value, {capabilities, errors} ->
      normalized =
        value
        |> String.downcase()
        |> String.replace(~r/[\s-]+/, "_")
        |> String.trim("_")

      case Map.get(@capability_aliases, normalized) do
        capability when is_binary(capability) ->
          {[capability | capabilities], errors}

        _ ->
          {capabilities, ["unsupported required capability `#{value}`"]}
      end
    end)
    |> then(fn {capabilities, errors} ->
      {capabilities |> Enum.reverse() |> Enum.uniq(), errors |> Enum.reverse() |> Enum.uniq()}
    end)
  end

  defp missing_for_capability("artifact_upload", env, _manifest, _tcp_connect) do
    require_envs(env, "artifact_upload", ["LINEAR_API_KEY"])
  end

  defp missing_for_capability("pr_body_contract", _env, manifest, _tcp_connect) do
    require_make_target(manifest, "pr_body_contract", ["symphony-pr-body-check", "pr-body-check"])
  end

  defp missing_for_capability("pr_publication", env, manifest, _tcp_connect) do
    require_tools(manifest, "pr_publication", ["git", "gh"]) ++
      require_one_env(env, "pr_publication", ["GH_TOKEN", "GITHUB_TOKEN"])
  end

  defp missing_for_capability("repo_validation", _env, manifest, _tcp_connect) do
    require_make_target(manifest, "repo_validation", ["symphony-validate"])
  end

  defp missing_for_capability("runtime_smoke", _env, manifest, _tcp_connect) do
    require_make_target(manifest, "runtime_smoke", ["symphony-runtime-smoke"])
  end

  defp missing_for_capability("stateful_db", env, _manifest, tcp_connect) do
    case env_value(env, "DATABASE_URL") do
      nil ->
        ["stateful_db requires env `DATABASE_URL`"]

      database_url ->
        database_url_reachability_errors(database_url, tcp_connect)
    end
  end

  defp missing_for_capability("ui_runtime", _env, manifest, _tcp_connect) do
    require_make_target(manifest, "ui_runtime", [
      "team-master-ui-e2e",
      "symphony-live-e2e",
      "symphony-runtime-smoke"
    ])
  end

  defp missing_for_capability("vps_ssh", env, _manifest, _tcp_connect) do
    require_envs(env, "vps_ssh", ["PROD_VPS_HOST", "PROD_VPS_USER", "PROD_VPS_KNOWN_HOSTS"]) ++
      require_one_env(env, "vps_ssh", ["PROD_VPS_SSH_KEY", "PROD_VPS_SSH_KEY_PATH"])
  end

  defp require_tools(manifest, capability, tools) do
    Enum.flat_map(tools, fn tool ->
      if get_in(manifest, ["tools", tool, "available"]) == true do
        []
      else
        ["#{capability} requires tool `#{tool}`"]
      end
    end)
  end

  defp require_make_target(manifest, capability, targets) do
    available_targets = MapSet.new(get_in(manifest, ["makefile", "targets"]) || [])

    if Enum.any?(targets, &MapSet.member?(available_targets, &1)) do
      []
    else
      ["#{capability} requires one Makefile target: #{Enum.map_join(targets, ", ", &"`#{&1}`")}"]
    end
  end

  defp require_envs(env, capability, keys) do
    Enum.flat_map(keys, fn key ->
      case env_value(env, key) do
        nil -> ["#{capability} requires env `#{key}`"]
        _value -> []
      end
    end)
  end

  defp require_one_env(env, capability, keys) do
    if Enum.any?(keys, &env_value(env, &1)) do
      []
    else
      ["#{capability} requires one env: #{Enum.map_join(keys, ", ", &"`#{&1}`")}"]
    end
  end

  defp env_value(env, key) when is_map(env) do
    case Map.get(env, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp database_url_reachability_errors(database_url, tcp_connect) do
    uri = URI.parse(database_url)

    cond do
      not postgres_database_scheme?(uri.scheme) ->
        ["stateful_db requires postgres DATABASE_URL"]

      is_nil(uri.host) or uri.host == "" ->
        []

      true ->
        port = uri.port || 5432

        case tcp_connect.(uri.host, port) do
          :ok -> []
          {:error, reason} -> ["stateful_db DATABASE_URL is not reachable at #{uri.host}:#{port}: #{inspect(reason)}"]
        end
    end
  end

  defp postgres_database_scheme?(scheme) when is_binary(scheme) do
    normalized =
      scheme
      |> String.downcase()
      |> String.trim()

    normalized in ["postgres", "postgresql"] or
      String.starts_with?(normalized, "postgres+") or
      String.starts_with?(normalized, "postgresql+")
  end

  defp postgres_database_scheme?(_), do: false

  defp tcp_connect(host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_description(%{description: description}) when is_binary(description), do: description
  defp issue_description(%{"description" => description}) when is_binary(description), do: description
  defp issue_description(_issue), do: ""
end
