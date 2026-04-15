defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @planning_issue_states MapSet.new(["spec prep", "spec review"])
  @implementation_issue_states MapSet.new(["in progress"])
  @rework_issue_states MapSet.new(["rework"])
  @handoff_issue_states MapSet.new(["merging"])
  @cost_signal_priority [
    :rework,
    :repeated_auto_fix_failure,
    :security_data_risk,
    :unresolvable_ambiguity
  ]

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type codex_account :: %{
          id: String.t(),
          codex_home: Path.t(),
          explicit?: boolean()
        }

  @type release_metadata :: %{
          git_sha: String.t() | nil,
          image_tag: String.t() | nil,
          image_digest: String.t() | nil
        }

  @type linear_polling_scope :: {:project, String.t()} | {:team, String.t()} | nil
  @type codex_stage :: :planning | :implementation | :rework | :handoff

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_command(map() | String.t() | atom() | nil) :: String.t()
  def codex_command(issue_or_state \\ nil) do
    issue_or_state
    |> codex_cost_decision()
    |> Map.fetch!(:command)
  end

  @spec codex_cost_decision(map() | String.t() | atom() | nil) :: map()
  def codex_cost_decision(issue_or_state \\ nil) do
    settings = settings!()
    stage = codex_stage(issue_or_state)
    signals = cost_signals(issue_or_state, stage, settings.codex.cost_policy)

    with template when is_binary(template) <- present_codex_command(Map.get(settings.codex, :command_template)),
         {:ok, profile_key, profile, reason} <- resolve_cost_profile(settings.codex, stage, signals),
         {:ok, model, effort} <- profile_model_effort(profile) do
      %{
        stage: stage,
        signals: signals,
        profile_key: profile_key,
        model: model,
        effort: effort,
        reason: reason,
        command_source: "cost_profile",
        command: render_codex_command_template(template, model, effort)
      }
    else
      _ ->
        legacy_or_fallback_cost_decision(settings.codex, stage, signals)
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec linear_polling_scope() :: linear_polling_scope()
  def linear_polling_scope do
    linear_polling_scope(settings!())
  end

  @spec linear_polling_scope(Schema.t()) :: linear_polling_scope()
  def linear_polling_scope(%Schema{} = settings) do
    cond do
      is_binary(settings.tracker.project_slug) and settings.tracker.project_slug != "" ->
        {:project, settings.tracker.project_slug}

      is_binary(settings.tracker.team_key) and settings.tracker.team_key != "" ->
        {:team, settings.tracker.team_key}

      true ->
        nil
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil) :: {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @spec codex_accounts() :: [codex_account()]
  def codex_accounts do
    settings = settings!()

    case settings.codex.accounts do
      [] ->
        [
          %{
            id: "default",
            codex_home: ambient_codex_home(),
            explicit?: false
          }
        ]

      accounts ->
        Enum.map(accounts, fn account ->
          %{
            id: account.id,
            codex_home: account.codex_home,
            explicit?: true
          }
        end)
    end
  end

  @spec release_metadata() :: release_metadata()
  def release_metadata do
    %{
      git_sha: present_env("SYMPHONY_RELEASE_SHA"),
      image_tag: present_env("SYMPHONY_IMAGE_TAG"),
      image_digest: present_env("SYMPHONY_IMAGE_DIGEST")
    }
  end

  @spec codex_minimum_remaining_percent() :: non_neg_integer()
  def codex_minimum_remaining_percent do
    settings!().codex.minimum_remaining_percent
  end

  @spec codex_monitored_windows_mins() :: [pos_integer()]
  def codex_monitored_windows_mins do
    settings!().codex.monitored_windows_mins
  end

  @spec ambient_codex_home() :: Path.t()
  def ambient_codex_home do
    System.get_env("CODEX_HOME")
    |> case do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.join(System.user_home!(), ".codex")
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and is_nil(linear_polling_scope(settings)) ->
        {:error, :missing_linear_polling_scope}

      true ->
        :ok
    end
  end

  defp codex_stage(%{phase: phase}), do: normalize_codex_stage(phase)
  defp codex_stage(%{"phase" => phase}), do: normalize_codex_stage(phase)
  defp codex_stage(%{state: state}), do: stage_from_state(state)
  defp codex_stage(%{"state" => state}), do: stage_from_state(state)

  defp codex_stage(stage_or_state) do
    stage_or_state
    |> normalize_codex_stage()
    |> case do
      nil -> stage_from_state(stage_or_state)
      stage -> stage
    end
  end

  defp stage_from_state(state) when is_binary(state) do
    normalized_state =
      state
      |> String.trim()
      |> String.downcase()

    cond do
      MapSet.member?(@planning_issue_states, normalized_state) ->
        :planning

      MapSet.member?(@implementation_issue_states, normalized_state) ->
        :implementation

      MapSet.member?(@rework_issue_states, normalized_state) ->
        :rework

      MapSet.member?(@handoff_issue_states, normalized_state) ->
        :handoff

      true ->
        nil
    end
  end

  defp stage_from_state(_state), do: nil

  defp normalize_codex_stage(stage) when stage in [:planning, :implementation, :rework, :handoff], do: stage

  defp normalize_codex_stage(stage) when is_binary(stage) do
    case stage |> String.trim() |> String.downcase() do
      "planning" -> :planning
      "implementation" -> :implementation
      "rework" -> :rework
      "handoff" -> :handoff
      _ -> nil
    end
  end

  defp normalize_codex_stage(_stage), do: nil

  defp resolve_cost_profile(codex_config, stage, signals) do
    signal_escalations = nested_map(codex_config.cost_policy, "signal_escalations")
    stage_defaults = nested_map(codex_config.cost_policy, "stage_defaults")

    with {signal, profile_key} <- first_signal_profile(signals, signal_escalations),
         {:ok, profile} <- fetch_cost_profile(codex_config.cost_profiles, profile_key) do
      {:ok, profile_key, profile, "signal:#{signal}"}
    else
      _ ->
        with profile_key when is_binary(profile_key) <- map_get(stage_defaults, stage),
             {:ok, profile} <- fetch_cost_profile(codex_config.cost_profiles, profile_key) do
          {:ok, profile_key, profile, "stage_default:#{stage}"}
        else
          _ -> :error
        end
    end
  end

  defp first_signal_profile(signals, signal_escalations) do
    Enum.find_value(signals, fn signal ->
      case map_get(signal_escalations, signal) do
        profile_key when is_binary(profile_key) -> {signal, profile_key}
        _ -> nil
      end
    end)
  end

  defp fetch_cost_profile(profiles, profile_key) when is_binary(profile_key) do
    case map_get(profiles, profile_key) do
      profile when is_map(profile) -> {:ok, profile}
      _ -> :error
    end
  end

  defp profile_model_effort(profile) when is_map(profile) do
    case {map_get(profile, "model"), map_get(profile, "effort")} do
      {model, effort} when is_binary(model) and is_binary(effort) -> {:ok, model, effort}
      _ -> :error
    end
  end

  defp render_codex_command_template(template, model, effort) do
    template
    |> String.replace("{{model}}", model)
    |> String.replace("{{effort}}", effort)
  end

  defp legacy_or_fallback_cost_decision(codex_config, stage, signals) do
    case legacy_command(codex_config, stage) do
      {field, command} ->
        %{
          stage: stage,
          signals: signals,
          profile_key: nil,
          model: nil,
          effort: nil,
          reason: "legacy_direct_command:#{stage}",
          command_source: "legacy_direct_command:#{field}",
          command: command
        }

      nil ->
        %{
          stage: stage,
          signals: signals,
          profile_key: nil,
          model: nil,
          effort: nil,
          reason: "fallback:codex.command",
          command_source: "codex.command",
          command: codex_config.command
        }
    end
  end

  defp legacy_command(_codex_config, nil), do: nil

  defp legacy_command(codex_config, stage) do
    field =
      case stage do
        :planning -> :planning_command
        :implementation -> :implementation_command
        :rework -> :implementation_command
        :handoff -> :handoff_command
      end

    case present_codex_command(Map.get(codex_config, field)) do
      command when is_binary(command) -> {field, command}
      _ -> nil
    end
  end

  defp cost_signals(context, stage, cost_policy) do
    explicit_signals = extract_cost_signals(context)
    label_signals = signals_from_labels(extract_labels(context), cost_policy)
    stage_signals = if stage == :rework, do: [:rework], else: []

    (stage_signals ++ explicit_signals ++ label_signals)
    |> Enum.map(&normalize_signal/1)
    |> Enum.reject(&is_nil/1)
    |> prioritize_signals()
  end

  defp extract_cost_signals(%{cost_signals: signals}) when is_list(signals), do: signals
  defp extract_cost_signals(%{"cost_signals" => signals}) when is_list(signals), do: signals
  defp extract_cost_signals(%{signals: signals}) when is_list(signals), do: signals
  defp extract_cost_signals(%{"signals" => signals}) when is_list(signals), do: signals
  defp extract_cost_signals(_context), do: []

  defp signals_from_labels(labels, cost_policy) when is_list(labels) do
    label_signals = nested_map(cost_policy, "label_signals")

    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.flat_map(fn
      nil ->
        []

      label ->
        case map_get(label_signals, label) do
          signal when is_binary(signal) or is_atom(signal) -> [signal]
          signals when is_list(signals) -> signals
          _ -> []
        end
    end)
  end

  defp signals_from_labels(_labels, _cost_policy), do: []

  defp prioritize_signals(signals) do
    unique_signals = Enum.uniq(signals)
    priority = Enum.filter(@cost_signal_priority, &(&1 in unique_signals))
    rest = Enum.reject(unique_signals, &(&1 in priority))
    priority ++ rest
  end

  defp normalize_signal(signal) when is_atom(signal), do: signal

  defp normalize_signal(signal) when is_binary(signal) do
    signal
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "rework" -> :rework
      "repeated_auto_fix_failure" -> :repeated_auto_fix_failure
      "security_data_risk" -> :security_data_risk
      "unresolvable_ambiguity" -> :unresolvable_ambiguity
      _ -> nil
    end
  end

  defp normalize_signal(_signal), do: nil

  defp nested_map(map, key) do
    case map_get(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> map_get_atom_string_key(map, key)
    end
  end

  defp map_get(_map, _key), do: nil

  defp map_get_atom_string_key(map, key) do
    Enum.find_value(map, fn
      {map_key, value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: value

      _ ->
        nil
    end)
  end

  defp extract_labels(%{labels: labels}) when is_list(labels), do: labels
  defp extract_labels(%{"labels" => labels}) when is_list(labels), do: labels
  defp extract_labels(_context), do: []

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp normalize_label(_label), do: nil

  defp present_codex_command(command) when is_binary(command) do
    if String.trim(command) == "", do: nil, else: command
  end

  defp present_codex_command(_command), do: nil

  defp present_env(key) do
    key
    |> System.get_env()
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      :missing_linear_polling_scope ->
        "Invalid WORKFLOW.md config: tracker.project_slug or tracker.team_key is required when tracker.kind=linear"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
