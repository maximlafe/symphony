defmodule SymphonyElixir.Orchestrator.RoutingMetadata do
  @moduledoc false

  @spec apply(map(), map()) :: map()
  def apply(running_entry, update) when is_map(running_entry) and is_map(update) do
    running_entry
    |> merge_present_metadata(routing_intended_fields(update))
    |> merge_present_metadata(routing_observed_fields(update))
    |> apply_routing_parity()
  end

  def apply(running_entry, _update), do: running_entry

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

  defp merge_present_metadata(map, values) when is_map(map) and is_map(values) do
    Enum.reduce(values, map, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

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

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp map_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn segment, acc ->
      case acc do
        map when is_map(map) -> {:cont, Map.get(map, segment)}
        _other -> {:halt, nil}
      end
    end)
  end
end
