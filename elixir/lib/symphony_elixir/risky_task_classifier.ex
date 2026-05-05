defmodule SymphonyElixir.RiskyTaskClassifier do
  @moduledoc """
  Deterministic, machine-executable risk classifier used by routing and cost policy.
  """

  @stateful_capability "stateful_db"
  @risky_capabilities MapSet.new([@stateful_capability, "vps_ssh"])
  @stateful_label_fragments ["migration", "stateful", "schema", "database", "db"]
  @risky_label_fragments ["migration", "stateful", "security", "auth", "destructive", "data-risk", "risk:high"]
  @stateful_description_pattern ~r/\b(?:stateful|migration|migrate|schema|database|alembic|backfill|ddl)\b/i
  @risky_description_pattern ~r/\b(?:destructive|irreversible|drop\s+table|truncate|data\s+loss|security|auth)\b/i

  @spec classify(map() | keyword()) :: map()
  def classify(input) when is_list(input), do: input |> Map.new() |> classify()

  def classify(input) when is_map(input) do
    description = input |> map_get_any([:description, "description"]) |> normalize_text()
    labels = input |> map_get_any([:labels, "labels"]) |> normalize_labels()
    required_capabilities = input |> map_get_any([:required_capabilities, "required_capabilities"]) |> normalize_capabilities()

    stateful_migration =
      stateful_capability?(required_capabilities) or
        label_match?(labels, @stateful_label_fragments) or
        Regex.match?(@stateful_description_pattern, description)

    risky_task =
      stateful_migration or
        risky_capability?(required_capabilities) or
        label_match?(labels, @risky_label_fragments) or
        Regex.match?(@risky_description_pattern, description)

    reasons =
      []
      |> maybe_add_reason(stateful_capability?(required_capabilities), "required capability `stateful_db`")
      |> maybe_add_reason(label_match?(labels, @stateful_label_fragments), "stateful/migration label")
      |> maybe_add_reason(Regex.match?(@stateful_description_pattern, description), "stateful/migration keyword in spec")
      |> maybe_add_reason(risky_capability?(required_capabilities), "high-risk required capability")
      |> maybe_add_reason(label_match?(labels, @risky_label_fragments), "high-risk label")
      |> maybe_add_reason(Regex.match?(@risky_description_pattern, description), "high-risk keyword in spec")
      |> Enum.uniq()

    %{
      "risky_task" => risky_task,
      "stateful_migration" => stateful_migration,
      "cost_signals" => if(risky_task, do: ["risky_task"], else: []),
      "reasons" => reasons
    }
  end

  def classify(_input) do
    %{
      "risky_task" => false,
      "stateful_migration" => false,
      "cost_signals" => [],
      "reasons" => []
    }
  end

  @spec risky_task?(map()) :: boolean()
  def risky_task?(%{} = classification) do
    classification
    |> map_get_any(["risky_task", :risky_task])
    |> truthy?()
  end

  def risky_task?(_classification), do: false

  @spec stateful_migration?(map()) :: boolean()
  def stateful_migration?(%{} = classification) do
    classification
    |> map_get_any(["stateful_migration", :stateful_migration])
    |> truthy?()
  end

  def stateful_migration?(_classification), do: false

  defp normalize_text(value) when is_binary(value), do: value
  defp normalize_text(_value), do: ""

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> ""
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_labels(_labels), do: []

  defp normalize_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(fn
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> ""
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp normalize_capabilities(_capabilities), do: []

  defp stateful_capability?(capabilities) when is_list(capabilities), do: @stateful_capability in capabilities
  defp stateful_capability?(_capabilities), do: false

  defp risky_capability?(capabilities) when is_list(capabilities) do
    Enum.any?(capabilities, &MapSet.member?(@risky_capabilities, &1))
  end

  defp risky_capability?(_capabilities), do: false

  defp label_match?(labels, fragments) when is_list(labels) and is_list(fragments) do
    Enum.any?(labels, fn label ->
      Enum.any?(fragments, fn fragment ->
        String.contains?(label, fragment)
      end)
    end)
  end

  defp label_match?(_labels, _fragments), do: false

  defp map_get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_get_any(_map, _keys), do: nil

  defp truthy?(value), do: value in [true, "true", "yes", "1", 1]

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons
end
