defmodule SymphonyElixir.DeliveryContract do
  @moduledoc """
  Parses and validates the machine-readable rollout/delivery contract embedded in issue descriptions.
  """

  @delivery_classes ["code_only", "stateful_schema", "runtime_repair", "operator_flow"]
  @sensitive_delivery_classes ["stateful_schema", "runtime_repair", "operator_flow"]
  @obligation_types [
    "migration_applied",
    "real_case_canary",
    "post_merge_runtime_smoke",
    "operator_cutover_verified"
  ]
  @required_capabilities ["none", "stateful_db", "runtime_smoke", "ui_runtime", "vps_ssh", "artifact_upload"]
  @proof_types ["test", "artifact", "runtime_smoke"]
  @required_before ["review", "done"]

  @stateful_patterns [
    ~r/\b(?:stateful|state\s+lifecycle|migration|migrate|schema|database|alembic|backfill|ddl)\b/i
  ]
  @runtime_repair_patterns [
    ~r/\b(?:runtime[-\s_]?repair|repair\s+runtime|post[-\s_]?merge\s+runtime|runtime\s+smoke|real[-\s_]?case\s+canary|canary|production\s+smoke)\b/i
  ]
  @operator_flow_patterns [
    ~r/\b(?:operator[-\s_]?flow|operator\s+cutover|operator|ops\s+cutover|cutover|runbook)\b/i
  ]

  @type contract_result :: {map(), [String.t()]}

  @spec delivery_classes() :: [String.t()]
  def delivery_classes, do: @delivery_classes

  @spec sensitive_delivery_classes() :: [String.t()]
  def sensitive_delivery_classes, do: @sensitive_delivery_classes

  @spec required_capabilities() :: [String.t()]
  def required_capabilities, do: @required_capabilities

  @spec parse(any()) :: contract_result()
  def parse(issue_description) when is_binary(issue_description) do
    case rollout_section(issue_description) do
      nil ->
        {empty_contract(nil), []}

      section ->
        parse_section(section)
    end
  end

  def parse(_issue_description), do: {empty_contract(nil), []}

  @spec evaluate(any(), keyword()) :: map()
  def evaluate(issue_description, opts \\ []) do
    labels = normalize_list(Keyword.get(opts, :labels, []))
    declared_capabilities = normalize_list(Keyword.get(opts, :required_capabilities, []))
    {contract, parse_errors} = parse(issue_description)

    classification =
      classify(%{
        description: issue_description,
        labels: labels,
        required_capabilities: declared_capabilities,
        contract: contract
      })

    validation_errors = validation_errors(contract, classification, declared_capabilities)

    %{
      "contract" => contract,
      "classification" => classification,
      "missing_items" => Enum.uniq(parse_errors ++ validation_errors)
    }
  end

  @spec classify(any()) :: map()
  def classify(input) when is_list(input), do: input |> Map.new() |> classify()

  def classify(input) when is_map(input) do
    context = classification_context(input)
    signals = delivery_signals(context)
    detected_classes = signals |> Enum.map(& &1["delivery_class"]) |> Enum.uniq()
    delivery_class = resolved_delivery_class(context.contract_class, detected_classes)
    source = delivery_class_source(context.contract_class, detected_classes)

    %{
      "delivery_class" => delivery_class,
      "delivery_sensitive" => delivery_class in @sensitive_delivery_classes,
      "source" => source,
      "detected_classes" => detected_classes,
      "signals" => signals
    }
  end

  def classify(_input), do: classify(%{})

  defp classification_context(input) do
    contract =
      input
      |> map_get_any([:contract, "contract"])
      |> normalize_contract()

    %{
      description: input |> map_get_any([:description, "description"]) |> normalize_text(),
      labels: input |> map_get_any([:labels, "labels"]) |> normalize_list(),
      capabilities: input |> map_get_any([:required_capabilities, "required_capabilities"]) |> normalize_list(),
      contract_class: if(contract["present"] == true, do: contract["delivery_class"])
    }
  end

  defp delivery_signals(context) do
    [
      class_signals(
        "stateful_schema",
        context,
        @stateful_patterns,
        ["stateful", "schema", "migration", "database", "db"],
        ["stateful_db"]
      ),
      class_signals(
        "runtime_repair",
        context,
        @runtime_repair_patterns,
        ["runtime-repair", "runtime_repair", "runtime", "canary"],
        ["runtime_smoke", "vps_ssh"]
      ),
      class_signals(
        "operator_flow",
        context,
        @operator_flow_patterns,
        ["operator-flow", "operator_flow", "operator", "cutover", "ops"],
        []
      )
    ]
    |> List.flatten()
  end

  defp resolved_delivery_class(contract_class, detected_classes) do
    cond do
      contract_class in @delivery_classes -> contract_class
      "stateful_schema" in detected_classes -> "stateful_schema"
      "runtime_repair" in detected_classes -> "runtime_repair"
      "operator_flow" in detected_classes -> "operator_flow"
      true -> "code_only"
    end
  end

  defp delivery_class_source(contract_class, detected_classes) do
    cond do
      contract_class in @delivery_classes -> "contract"
      detected_classes == [] -> "default"
      length(detected_classes) == 1 -> "classifier"
      true -> "classifier_ambiguous"
    end
  end

  @spec delivery_sensitive?(any()) :: boolean()
  def delivery_sensitive?(classification) when is_map(classification) do
    classification["delivery_class"] in @sensitive_delivery_classes or classification[:delivery_class] in @sensitive_delivery_classes
  end

  def delivery_sensitive?(_classification), do: false

  @spec done_obligations(any()) :: [map()]
  def done_obligations(contract) when is_map(contract) do
    contract
    |> Map.get("obligations", [])
    |> Enum.filter(&(Map.get(&1, "required_before") == "done"))
  end

  def done_obligations(_contract), do: []

  @spec has_done_obligations?(any()) :: boolean()
  def has_done_obligations?(contract), do: done_obligations(contract) != []

  defp parse_section(section) do
    case table_rows(section) do
      [] -> parse_key_value_section(section)
      rows -> parse_table_rows(rows)
    end
  end

  defp parse_table_rows(rows) do
    {obligations, errors} =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {row, index} -> normalize_obligation(row, index) end)
      |> Enum.reduce({[], []}, fn
        {:ok, obligation}, {items, errors} -> {items ++ [obligation], errors}
        {:error, row_errors}, {items, errors} -> {items, errors ++ row_errors}
      end)

    delivery_classes = obligations |> Enum.map(& &1["delivery_class"]) |> Enum.uniq()
    delivery_class = List.first(delivery_classes) || "code_only"

    class_errors =
      if length(delivery_classes) > 1 do
        ["rollout contract has multiple delivery_class values; use exactly one delivery_class per issue"]
      else
        []
      end

    {
      %{
        "present" => true,
        "delivery_class" => delivery_class,
        "obligations" => obligations
      },
      errors ++ class_errors
    }
  end

  defp parse_key_value_section(section) do
    fields =
      section
      |> String.split(~r/\R/u, trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] -> Map.put(acc, normalize_key(key), String.trim(value))
          _ -> acc
        end
      end)

    if Map.has_key?(fields, "delivery_class") and not Map.has_key?(fields, "obligation_type") do
      {empty_contract(normalize_value(fields["delivery_class"])), []}
    else
      case normalize_obligation(fields, 1) do
        {:ok, obligation} ->
          {%{"present" => true, "delivery_class" => obligation["delivery_class"], "obligations" => [obligation]}, []}

        {:error, errors} ->
          {empty_contract(normalize_value(fields["delivery_class"])), errors}
      end
    end
  end

  defp normalize_obligation(row, index) do
    delivery_class = row |> Map.get("delivery_class", "") |> normalize_value()
    obligation_type = row |> Map.get("obligation_type", "") |> normalize_value()
    required_capability = row |> Map.get("required_capability", "none") |> normalize_value()
    proof_type = row |> Map.get("proof_type", "") |> normalize_value()
    proof_target = row |> Map.get("proof_target", "") |> String.trim()
    required_before = row |> Map.get("required_before", "done") |> normalize_value()
    unblock_action = row |> Map.get("unblock_action", "") |> String.trim()
    id = row |> Map.get("id", "RO-#{index}") |> String.trim()

    errors =
      []
      |> validate_allowed(delivery_class, @delivery_classes, "delivery_class")
      |> validate_allowed(obligation_type, @obligation_types, "obligation_type")
      |> validate_allowed(required_capability, @required_capabilities, "required_capability")
      |> validate_allowed(proof_type, @proof_types, "proof_type")
      |> validate_allowed(required_before, @required_before, "required_before")
      |> maybe_require_non_empty(proof_target, "proof_target")
      |> maybe_require_non_empty(unblock_action, "unblock_action")

    if errors == [] do
      {:ok,
       %{
         "id" => id,
         "delivery_class" => delivery_class,
         "obligation_type" => obligation_type,
         "required_capability" => required_capability,
         "proof_type" => proof_type,
         "proof_target" => proof_target,
         "proof_semantic" => proof_semantic(proof_type),
         "required_before" => required_before,
         "unblock_action" => unblock_action
       }}
    else
      {:error, Enum.map(errors, &"rollout contract row #{index} #{&1}")}
    end
  end

  defp validation_errors(contract, classification, declared_capabilities) do
    cond do
      classification["delivery_sensitive"] == true and contract["present"] != true ->
        ["delivery-sensitive task requires a `Rollout Contract` section with explicit obligations"]

      classification["delivery_class"] in @sensitive_delivery_classes and contract["present"] == true and contract["obligations"] == [] ->
        ["delivery_class=#{classification["delivery_class"]} requires at least one rollout obligation"]

      true ->
        []
    end
    |> Kernel.++(capability_reference_errors(contract, declared_capabilities))
  end

  defp capability_reference_errors(contract, declared_capabilities) do
    contract
    |> Map.get("obligations", [])
    |> Enum.flat_map(fn obligation ->
      capability = obligation["required_capability"]

      cond do
        capability in [nil, "", "none"] ->
          []

        capability in declared_capabilities ->
          []

        true ->
          [
            "rollout obligation `#{obligation["id"]}` requires capability `#{capability}` but `Required capabilities` does not declare it"
          ]
      end
    end)
  end

  defp rollout_section(markdown) do
    case Regex.run(~r/(?:^|\n)##\s+(?:Rollout Contract|Delivery Contract)\s*\n(?<body>.*?)(?=\n##\s+|\z)/msu, markdown, capture: :all_names) do
      [body] -> String.trim(body)
      _ -> nil
    end
  end

  defp table_rows(section) do
    lines =
      section
      |> String.split(~r/\R/u)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "|"))

    with [header_line, separator_line | row_lines] <- lines,
         true <- separator_line?(separator_line) do
      headers = split_table_row(header_line) |> Enum.map(&normalize_key/1)

      row_lines
      |> Enum.reject(&separator_line?/1)
      |> Enum.map(fn line ->
        values = split_table_row(line)
        headers |> Enum.zip(values) |> Map.new()
      end)
    else
      _ -> []
    end
  end

  defp separator_line?(line) when is_binary(line), do: Regex.match?(~r/^\|\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)+\|?$/, line)

  defp split_table_row(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp class_signals(class, context, patterns, label_fragments, capability_names) do
    description_signals =
      Enum.flat_map(patterns, fn pattern ->
        if Regex.match?(pattern, context.description), do: [%{"delivery_class" => class, "source" => "description"}], else: []
      end)

    label_signals =
      if Enum.any?(context.labels, &label_matches?(&1, label_fragments)) do
        [%{"delivery_class" => class, "source" => "label"}]
      else
        []
      end

    capability_signals =
      if Enum.any?(context.capabilities, &(&1 in capability_names)) do
        [%{"delivery_class" => class, "source" => "required_capability"}]
      else
        []
      end

    description_signals ++ label_signals ++ capability_signals
  end

  defp label_matches?(label, fragments) do
    Enum.any?(fragments, &String.contains?(label, &1))
  end

  defp validate_allowed(errors, value, allowed, field) do
    if value in allowed do
      errors
    else
      errors ++ ["has unsupported #{field} `#{value}`; expected one of: #{Enum.join(allowed, ", ")}"]
    end
  end

  defp maybe_require_non_empty(errors, "", field), do: errors ++ ["is missing required #{field}"]
  defp maybe_require_non_empty(errors, value, _field) when is_binary(value), do: errors

  defp proof_semantic("runtime_smoke"), do: "runtime_smoke"
  defp proof_semantic(_proof_type), do: "run_executed"

  defp empty_contract(delivery_class) do
    normalized_delivery_class =
      case delivery_class do
        value when is_binary(value) and value != "" -> value
        _ -> "code_only"
      end

    %{
      "present" => not is_nil(delivery_class),
      "delivery_class" => normalized_delivery_class,
      "obligations" => []
    }
  end

  defp normalize_contract(contract) when is_map(contract), do: contract
  defp normalize_contract(_contract), do: empty_contract(nil)

  defp normalize_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
  end

  defp normalize_value(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_value(_value), do: ""

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
    |> Enum.uniq()
  end

  defp normalize_list(_values), do: []

  defp map_get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end
end
