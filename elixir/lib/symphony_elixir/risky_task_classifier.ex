defmodule SymphonyElixir.RiskyTaskClassifier do
  @moduledoc """
  Deterministic, machine-executable risk classifier used by routing and cost policy.
  """

  @risk_class_standard "standard"
  @risk_class_risky "risky"
  @signal_persistence "persistence_migration_or_identifier"
  @signal_rollout "backward_compatibility_or_staged_rollout"
  @signal_ordering "retry_state_machine_or_ordering_sensitive_logic"
  @signal_adjacent "adjacent_ticket_ambiguity_or_neighboring_active_work"
  @signal_security "security_or_destructive_change"

  @stateful_capability "stateful_db"
  @risky_capabilities MapSet.new([@stateful_capability, "vps_ssh"])
  @stateful_label_fragments ["migration", "stateful", "schema", "database", "db", "identifier"]
  @rollout_label_fragments ["rollout", "backward-compat", "backward_compat", "compatibility", "canary", "feature-flag"]
  @ordering_label_fragments ["retry", "state-machine", "state_machine", "ordering", "idempotency", "at-least-once"]
  @adjacent_label_fragments ["adjacent", "neighbor", "ambiguity", "parallel-work", "related-ticket"]
  @risky_label_fragments ["migration", "stateful", "security", "auth", "destructive", "data-risk", "risk:high"]
  @stateful_description_pattern ~r/\b(?:stateful|migration|migrate|schema|database|alembic|backfill|ddl|identifier|stored\s+id)\b/i
  @rollout_description_pattern ~r/\b(?:backward[\s-]?compat(?:ibility)?|staged\s+rollout|rollout|dual[\s-]?(?:read|write)|canary|feature\s+flag)\b/i
  @ordering_description_pattern ~r/\b(?:retry|retries|state\s+machine|ordering[\s-]?sensitive|order[\s-]?sensitive|idempotency|at[\s-]?least[\s-]?once)\b/i
  @adjacent_description_pattern ~r/\b(?:adjacent(?:\s+ticket)?|neighbor(?:ing)?\s+active\s+work|cross[\s-]?ticket|ambiguity)\b/i
  @risky_description_pattern ~r/\b(?:destructive|irreversible|drop\s+table|truncate|data\s+loss|security|auth)\b/i

  @spec classify(map() | keyword()) :: map()
  def classify(input) when is_list(input), do: input |> Map.new() |> classify()

  def classify(input) when is_map(input) do
    description = input |> map_get_any([:description, "description"]) |> normalize_text()
    labels = input |> map_get_any([:labels, "labels"]) |> normalize_labels()
    blocked_by = input |> map_get_any([:blocked_by, "blocked_by"]) |> normalize_blockers()
    required_capabilities = input |> map_get_any([:required_capabilities, "required_capabilities"]) |> normalize_capabilities()

    signal_flags = risk_signal_flags(description, labels, blocked_by, required_capabilities)
    risk_signals = risk_signals(signal_flags)
    risky_task = risk_signals != []
    risk_class = if(risky_task, do: @risk_class_risky, else: @risk_class_standard)
    required_validation_families = required_validation_families(risk_signals)
    required_spec_sections = required_spec_sections(risk_signals)
    reasons = risk_reasons(signal_flags)

    %{
      "risk_class" => risk_class,
      "risk_signals" => risk_signals,
      "required_validation_families" => required_validation_families,
      "required_spec_sections" => required_spec_sections,
      "risky_task" => risky_task,
      "stateful_migration" => Map.get(signal_flags, @signal_persistence, false),
      "cost_signals" => if(risky_task, do: ["risky_task"], else: []),
      "reasons" => reasons
    }
  end

  def classify(_input) do
    %{
      "risk_class" => @risk_class_standard,
      "risk_signals" => [],
      "required_validation_families" => [],
      "required_spec_sections" => [],
      "risky_task" => false,
      "stateful_migration" => false,
      "cost_signals" => [],
      "reasons" => []
    }
  end

  @spec risky_task?(map()) :: boolean()
  def risky_task?(%{} = classification) do
    risk_class = map_get_any(classification, ["risk_class", :risk_class])
    explicit_risky_flag = map_get_any(classification, ["risky_task", :risky_task])

    risk_class == @risk_class_risky or truthy?(explicit_risky_flag)
  end

  def risky_task?(_classification), do: false

  @spec stateful_migration?(map()) :: boolean()
  def stateful_migration?(%{} = classification) do
    explicit_flag =
      classification
      |> map_get_any(["stateful_migration", :stateful_migration])
      |> truthy?()

    risk_signals = map_get_any(classification, ["risk_signals", :risk_signals]) || []

    explicit_flag or @signal_persistence in risk_signals
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

  defp normalize_blockers(blockers) when is_list(blockers) do
    Enum.flat_map(blockers, fn
      %{} = blocker ->
        state = blocker["state"] || blocker[:state]
        [%{"state" => state}]

      _ ->
        []
    end)
  end

  defp normalize_blockers(_blockers), do: []

  defp non_terminal_blockers?(blocked_by) when is_list(blocked_by) do
    Enum.any?(blocked_by, fn blocker ->
      blocker
      |> map_get_any(["state", :state])
      |> normalize_state()
      |> non_terminal_state?()
    end)
  end

  defp non_terminal_state?(state), do: state not in ["", "closed", "cancelled", "canceled", "duplicate", "done"]

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp stateful_capability?(capabilities) when is_list(capabilities), do: @stateful_capability in capabilities

  defp risky_capability?(capabilities) when is_list(capabilities) do
    Enum.any?(capabilities, &MapSet.member?(@risky_capabilities, &1))
  end

  defp label_match?(labels, fragments) when is_list(labels) and is_list(fragments) do
    Enum.any?(labels, fn label ->
      Enum.any?(fragments, fn fragment ->
        String.contains?(label, fragment)
      end)
    end)
  end

  defp map_get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp required_validation_families(risk_signals) when is_list(risk_signals) do
    risk_signals
    |> Enum.flat_map(fn
      @signal_persistence -> ["targeted_tests", "stateful_proof", "repo_validation"]
      @signal_rollout -> ["targeted_tests", "runtime_smoke", "repo_validation"]
      @signal_ordering -> ["targeted_tests", "runtime_smoke", "repo_validation"]
      @signal_adjacent -> ["targeted_tests", "runtime_smoke", "repo_validation"]
      @signal_security -> ["targeted_tests", "runtime_smoke", "repo_validation"]
    end)
    |> Enum.uniq()
  end

  defp required_spec_sections(risk_signals) when is_list(risk_signals) do
    base =
      if risk_signals == [] do
        []
      else
        ["Acceptance Matrix", "Risks", "Validation Plan"]
      end

    if Enum.any?(risk_signals, &(&1 in [@signal_rollout, @signal_adjacent])) do
      Enum.uniq(base ++ ["Dependencies"])
    else
      base
    end
  end

  defp truthy?(value), do: value in [true, "true", "yes", "1", 1]

  defp risk_signal_flags(description, labels, blocked_by, required_capabilities) do
    %{
      @signal_persistence =>
        stateful_capability?(required_capabilities) or
          label_match?(labels, @stateful_label_fragments) or
          Regex.match?(@stateful_description_pattern, description),
      @signal_rollout =>
        label_match?(labels, @rollout_label_fragments) or
          Regex.match?(@rollout_description_pattern, description),
      @signal_ordering =>
        label_match?(labels, @ordering_label_fragments) or
          Regex.match?(@ordering_description_pattern, description),
      @signal_adjacent =>
        label_match?(labels, @adjacent_label_fragments) or
          Regex.match?(@adjacent_description_pattern, description) or
          non_terminal_blockers?(blocked_by),
      @signal_security =>
        risky_capability?(required_capabilities) or
          label_match?(labels, @risky_label_fragments) or
          Regex.match?(@risky_description_pattern, description)
    }
  end

  defp risk_signals(signal_flags) when is_map(signal_flags) do
    signal_flags
    |> Enum.flat_map(fn
      {signal, true} -> [signal]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp risk_reasons(signal_flags) when is_map(signal_flags) do
    []
    |> maybe_add_reason(Map.get(signal_flags, @signal_persistence, false), "stateful/migration/identifier signal")
    |> maybe_add_reason(Map.get(signal_flags, @signal_rollout, false), "backward-compat/rollout signal")
    |> maybe_add_reason(Map.get(signal_flags, @signal_ordering, false), "retry/state-machine/ordering signal")
    |> maybe_add_reason(Map.get(signal_flags, @signal_adjacent, false), "adjacent-work ambiguity signal")
    |> maybe_add_reason(Map.get(signal_flags, @signal_security, false), "high-risk security/destructive signal")
    |> Enum.uniq()
  end

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons
end
