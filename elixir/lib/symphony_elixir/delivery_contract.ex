defmodule SymphonyElixir.DeliveryContract do
  @moduledoc """
  Parses and classifies delivery rollout obligations from issue task-specs.
  """

  @delivery_classes ["code_only", "stateful_schema", "runtime_repair", "operator_flow"]
  @sensitive_delivery_classes ["stateful_schema", "runtime_repair", "operator_flow"]
  @obligation_types [
    "migration_applied",
    "real_case_canary",
    "post_merge_runtime_smoke",
    "operator_cutover_verified"
  ]
  @required_capabilities ["stateful_db", "runtime_smoke", "ui_runtime", "vps_ssh", "artifact_upload", "none"]
  @proof_types ["test", "artifact", "runtime_smoke"]
  @required_before_values ["review", "done"]

  @stateful_pattern ~r/\b(?:stateful|state\s+lifecycle|migration|migrate|schema|database|alembic|backfill|ddl)\b/i
  @runtime_pattern ~r/\b(?:runtime\s+repair|runtime-repair|runtime|canary|post-merge|post\s+merge|runtime\s+smoke|health\s+check|restart|deploy|production)\b/i
  @operator_pattern ~r/\b(?:operator|operator-flow|operator\s+flow|cutover|runbook|ops|manual\s+action)\b/i

  @stateful_label_fragments ["migration", "stateful", "schema", "database", "db"]
  @runtime_label_fragments ["runtime", "runtime-repair", "canary", "deploy", "smoke"]
  @operator_label_fragments ["operator", "operator-flow", "ops", "cutover"]

  @spec delivery_classes() :: [String.t()]
  def delivery_classes, do: @delivery_classes

  @spec sensitive_delivery_classes() :: [String.t()]
  def sensitive_delivery_classes, do: @sensitive_delivery_classes

  @spec parse(String.t() | nil) :: {map(), [String.t()]}
  def parse(description) when is_binary(description) do
    case markdown_h2_section_body(description, "Rollout Contract") ||
           markdown_h2_section_body(description, "Delivery Contract") do
      nil ->
        {empty_contract(), []}

      section_body ->
        parse_section(section_body)
    end
  end

  def parse(_description), do: {empty_contract(), []}

  @spec classify(map() | keyword()) :: map()
  def classify(input) when is_list(input), do: input |> Map.new() |> classify()

  def classify(input) when is_map(input) do
    description = input |> map_get_any([:description, "description"]) |> normalize_text()
    labels = input |> map_get_any([:labels, "labels"]) |> normalize_list()
    required_capabilities = input |> map_get_any([:required_capabilities, "required_capabilities"]) |> normalize_list()

    {contract, _errors} = parse(description)
    explicit_class = contract["delivery_class"]

    signals =
      []
      |> maybe_add_signal(stateful_signal?(description, labels, required_capabilities), "stateful_schema")
      |> maybe_add_signal(runtime_signal?(description, labels, required_capabilities), "runtime_repair")
      |> maybe_add_signal(operator_signal?(description, labels, required_capabilities), "operator_flow")
      |> Enum.uniq()

    inferred_class = infer_delivery_class(explicit_class, signals)
    ambiguous = length(signals) > 1 and explicit_class in [nil, "code_only"]

    %{
      "delivery_class" => inferred_class,
      "delivery_sensitive" => inferred_class in @sensitive_delivery_classes,
      "delivery_ambiguous" => ambiguous,
      "explicit_contract" => contract["present"],
      "signals" => signals,
      "reasons" => delivery_reasons(signals, explicit_class)
    }
  end

  def classify(_input), do: code_only_classification()

  @spec sensitive_class?(String.t() | nil) :: boolean()
  def sensitive_class?(delivery_class), do: delivery_class in @sensitive_delivery_classes

  @spec done_closure_required?(String.t() | nil) :: boolean()
  def done_closure_required?(description) do
    {contract, _errors} = parse(description)

    Enum.any?(contract["obligations"] || [], fn obligation ->
      obligation["required_before"] == "done"
    end)
  end

  @spec spec_check_errors(map(), map(), [String.t()]) :: [String.t()]
  def spec_check_errors(contract, classification, required_capabilities)
      when is_map(contract) and is_map(classification) and is_list(required_capabilities) do
    required_capabilities = Enum.map(required_capabilities, &String.downcase/1)
    delivery_class = classification["delivery_class"]

    []
    |> Kernel.++(Map.get(contract, "errors", []))
    |> Kernel.++(missing_rollout_contract_errors(contract, delivery_class))
    |> Kernel.++(missing_required_capability_errors(contract, required_capabilities))
    |> Enum.uniq()
  end

  def spec_check_errors(_contract, _classification, _required_capabilities), do: []

  defp parse_section(section_body) do
    fields = key_value_fields(section_body)
    delivery_class = normalize_field(fields["delivery_class"])

    obligations =
      case table_obligations(section_body) do
        [] -> single_obligation(fields)
        rows -> rows
      end
      |> Enum.with_index(1)
      |> Enum.map(fn {obligation, index} -> normalize_obligation(obligation, index) end)

    contract = %{
      "present" => true,
      "delivery_class" => delivery_class,
      "obligations" => obligations
    }

    errors =
      []
      |> Kernel.++(delivery_class_errors(delivery_class))
      |> Kernel.++(code_only_obligation_errors(delivery_class, obligations))
      |> Kernel.++(Enum.flat_map(obligations, &obligation_errors/1))

    {Map.put(contract, "errors", errors), errors}
  end

  defp empty_contract do
    %{
      "present" => false,
      "delivery_class" => nil,
      "obligations" => [],
      "errors" => []
    }
  end

  defp key_value_fields(section_body) do
    section_body
    |> String.split(~r/\R/u)
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^\s*([a-zA-Z_]+)\s*:\s*(.+?)\s*$/, line) do
        [_, key, value] -> Map.put(acc, String.downcase(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp table_obligations(section_body) do
    lines =
      section_body
      |> String.split(~r/\R/u)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "|"))

    case lines do
      [header, _separator | rows] ->
        headers = table_cells(header) |> Enum.map(&String.downcase/1)

        rows
        |> Enum.reject(&table_separator_row?/1)
        |> Enum.map(fn row ->
          headers
          |> Enum.zip(table_cells(row))
          |> Map.new()
        end)

      _ ->
        []
    end
  end

  defp single_obligation(fields) do
    if Map.has_key?(fields, "obligation_type") do
      [fields]
    else
      []
    end
  end

  defp normalize_obligation(fields, index) when is_map(fields) do
    id = normalize_text_field(fields["id"]) || "RO-#{index}"
    proof_type = normalize_field(fields["proof_type"])

    %{
      "id" => id,
      "obligation_type" => normalize_field(fields["obligation_type"]),
      "required_capability" => normalize_field(fields["required_capability"]) || "none",
      "proof_type" => proof_type,
      "proof_target" => normalize_text_field(fields["proof_target"]),
      "proof_semantic" => proof_semantic_for_type(proof_type),
      "required_before" => normalize_field(fields["required_before"]) || "done",
      "unblock_action" => normalize_text_field(fields["unblock_action"])
    }
  end

  defp delivery_class_errors(delivery_class) do
    cond do
      is_nil(delivery_class) ->
        ["rollout contract is missing `delivery_class`"]

      delivery_class not in @delivery_classes ->
        ["rollout contract has unsupported delivery_class `#{delivery_class}`"]

      true ->
        []
    end
  end

  defp code_only_obligation_errors("code_only", [_ | _]) do
    ["delivery_class `code_only` must not declare rollout obligations"]
  end

  defp code_only_obligation_errors(_delivery_class, _obligations), do: []

  defp obligation_errors(obligation) do
    id = obligation["id"]

    []
    |> require_allowed(obligation, "obligation_type", @obligation_types, id)
    |> require_allowed(obligation, "required_capability", @required_capabilities, id)
    |> require_allowed(obligation, "proof_type", @proof_types, id)
    |> require_allowed(obligation, "required_before", @required_before_values, id)
    |> require_present(obligation, "proof_target", id)
    |> require_present(obligation, "unblock_action", id)
  end

  defp require_allowed(errors, obligation, key, allowed, id) do
    value = obligation[key]

    cond do
      is_nil(value) or value == "" ->
        errors ++ ["rollout obligation `#{id}` is missing `#{key}`"]

      value not in allowed ->
        errors ++ ["rollout obligation `#{id}` has unsupported #{key} `#{value}`"]

      true ->
        errors
    end
  end

  defp require_present(errors, obligation, key, id) do
    case obligation[key] do
      value when is_binary(value) and value != "" -> errors
      _ -> errors ++ ["rollout obligation `#{id}` is missing `#{key}`"]
    end
  end

  defp missing_rollout_contract_errors(%{"present" => false}, delivery_class)
       when delivery_class in @sensitive_delivery_classes do
    ["rollout contract is required for delivery-sensitive class `#{delivery_class}`"]
  end

  defp missing_rollout_contract_errors(_contract, _delivery_class), do: []

  defp missing_required_capability_errors(contract, required_capabilities) do
    contract
    |> Map.get("obligations", [])
    |> Enum.flat_map(fn obligation ->
      capability = obligation["required_capability"]

      if capability in [nil, "", "none"] or capability in required_capabilities do
        []
      else
        [
          "rollout obligation `#{obligation["id"]}` requires capability `#{capability}`, but `Required capabilities` does not declare it"
        ]
      end
    end)
  end

  defp markdown_h2_section_body(markdown, wanted_heading) do
    pattern = ~r/^##\s+#{Regex.escape(wanted_heading)}\s*$(?<body>.*?)(?=^##\s+|\z)/ims

    case Regex.named_captures(pattern, markdown) do
      %{"body" => body} -> String.trim(body)
      _ -> nil
    end
  end

  defp table_cells(row) do
    row
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp table_separator_row?(row) do
    row
    |> table_cells()
    |> Enum.all?(&Regex.match?(~r/^:?-{2,}:?$/, &1))
  end

  defp normalize_field(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim("`")
    |> String.downcase()
    |> String.replace("-", "_")
    |> blank_to_nil()
  end

  defp normalize_field(_value), do: nil

  defp normalize_text_field(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp normalize_text_field(_value), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp proof_semantic_for_type("runtime_smoke"), do: "runtime_smoke"
  defp proof_semantic_for_type(_proof_type), do: "run_executed"

  defp infer_delivery_class(explicit_class, _signals) when explicit_class in @delivery_classes, do: explicit_class
  defp infer_delivery_class(_explicit_class, ["stateful_schema" | _]), do: "stateful_schema"
  defp infer_delivery_class(_explicit_class, ["runtime_repair" | _]), do: "runtime_repair"
  defp infer_delivery_class(_explicit_class, ["operator_flow" | _]), do: "operator_flow"
  defp infer_delivery_class(_explicit_class, _signals), do: "code_only"

  defp delivery_reasons(signals, explicit_class) do
    []
    |> maybe_add_reason(explicit_class in @delivery_classes, "explicit rollout delivery_class `#{explicit_class}`")
    |> Kernel.++(Enum.map(signals, &"#{&1} signal"))
  end

  defp stateful_signal?(description, labels, required_capabilities) do
    "stateful_db" in required_capabilities or label_match?(labels, @stateful_label_fragments) or
      Regex.match?(@stateful_pattern, description)
  end

  defp runtime_signal?(description, labels, required_capabilities) do
    Enum.any?(required_capabilities, &(&1 in ["runtime_smoke", "ui_runtime", "vps_ssh"])) or
      label_match?(labels, @runtime_label_fragments) or Regex.match?(@runtime_pattern, description)
  end

  defp operator_signal?(description, labels, _required_capabilities) do
    label_match?(labels, @operator_label_fragments) or Regex.match?(@operator_pattern, description)
  end

  defp label_match?(labels, fragments) do
    Enum.any?(labels, fn label ->
      Enum.any?(fragments, &String.contains?(label, &1))
    end)
  end

  defp normalize_text(value) when is_binary(value), do: value
  defp normalize_text(_value), do: ""

  defp normalize_list(values) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> ""
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_list(_values), do: []

  defp map_get_any(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp maybe_add_signal(signals, true, signal), do: signals ++ [signal]
  defp maybe_add_signal(signals, false, _signal), do: signals

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons

  defp code_only_classification do
    %{
      "delivery_class" => "code_only",
      "delivery_sensitive" => false,
      "delivery_ambiguous" => false,
      "explicit_contract" => false,
      "signals" => [],
      "reasons" => []
    }
  end
end
