defmodule SymphonyElixir.HandoffCheck do
  @moduledoc """
  Evaluates the review-ready handoff contract and writes a machine-readable manifest.
  """

  alias SymphonyElixir.{TelemetrySchema, ValidationGate}

  @allowed_checkpoint_types ["human-verify", "decision", "human-action"]
  @allowed_risk_levels ["low", "medium", "high"]
  @plan_mode_label "mode:plan"
  @supported_profiles ["ui", "data-extraction", "runtime", "generic"]
  @default_profile_labels %{
    "ui" => "verification:ui",
    "data-extraction" => "verification:data-extraction",
    "runtime" => "verification:runtime",
    "generic" => "verification:generic"
  }
  @default_review_ready_states ["In Review", "Human Review"]
  @default_manifest_path ".symphony/verification/handoff-manifest.json"
  @visual_extensions MapSet.new([".gif", ".jpeg", ".jpg", ".mov", ".mp4", ".png", ".webm", ".webp"])
  @machine_readable_extensions MapSet.new([".csv", ".json", ".jsonl", ".md", ".ndjson", ".tsv"])
  @runtime_extensions MapSet.new([".json", ".log", ".md", ".txt"])
  @matrix_proof_types MapSet.new(["test", "artifact", "runtime_smoke"])
  @matrix_semantics MapSet.new(["surface_exists", "run_executed", "runtime_smoke"])
  @default_handoff_phase "review"
  @supported_handoff_phases ["review", "done"]
  @default_matrix_required_before "review"
  @matrix_required_before MapSet.new(["review", "done"])

  @type result :: {:ok, map()} | {:error, map()}

  @spec supported_profiles() :: [String.t()]
  def supported_profiles, do: @supported_profiles

  @spec default_profile_labels() :: map()
  def default_profile_labels, do: @default_profile_labels

  @spec default_review_ready_states() :: [String.t()]
  def default_review_ready_states, do: @default_review_ready_states

  @spec default_manifest_path() :: String.t()
  def default_manifest_path, do: @default_manifest_path

  @spec evaluate(String.t(), keyword()) :: result()
  def evaluate(workpad_body, opts \\ []) when is_binary(workpad_body) do
    checked_at = Keyword.get(opts, :checked_at, DateTime.utc_now())
    workpad_path = Keyword.get(opts, :workpad_path)
    repo = Keyword.get(opts, :repo)
    pr_number = Keyword.get(opts, :pr_number)
    issue_id = Keyword.get(opts, :issue_id)
    issue_identifier = Keyword.get(opts, :issue_identifier)
    issue_description = Keyword.get(opts, :issue_description)
    issue_labels = normalize_labels(Keyword.get(opts, :labels, []))
    attachments = normalize_attachments(Keyword.get(opts, :attachments, []))
    pr_snapshot = normalize_pr_snapshot(Keyword.get(opts, :pr_snapshot))
    profile_labels = normalize_profile_labels(Keyword.get(opts, :profile_labels, @default_profile_labels))
    {phase, phase_errors} = normalize_handoff_phase(Keyword.get(opts, :phase))

    {profile, profile_source, profile_errors} =
      select_profile(
        Keyword.get(opts, :profile),
        issue_labels,
        profile_labels,
        Keyword.get(opts, :default_profile, "generic")
      )

    parsed_workpad = parse_workpad(workpad_body)
    {acceptance_matrix_items, acceptance_matrix_errors} = parse_acceptance_matrix(issue_description)

    {validation_gate, git_metadata, validation_gate_errors} =
      resolve_validation_gate(parsed_workpad, opts)

    validation_context = %{
      "gate" => validation_gate,
      "git" => git_metadata,
      "errors" => validation_gate_errors
    }

    {proof_signals, acceptance_matrix_missing_items, deferred_proofs} =
      acceptance_matrix_missing_items(
        acceptance_matrix_items,
        parsed_workpad,
        issue_labels,
        attachments,
        acceptance_matrix_errors,
        phase
      )

    missing_items =
      collect_missing_items(
        parsed_workpad,
        issue_labels,
        attachments,
        pr_snapshot,
        profile,
        profile_errors,
        validation_context,
        phase_errors ++ acceptance_matrix_missing_items
      )

    passed = missing_items == []

    manifest =
      %{
        "contract_version" => 2,
        "checked_at" => DateTime.to_iso8601(checked_at),
        "passed" => passed,
        "phase" => phase,
        "profile" => profile,
        "profile_source" => profile_source,
        "validation_gate" => validation_gate,
        "git" => git_metadata,
        "summary" => summary_for_manifest(passed, profile, missing_items),
        "proof_signals" => proof_signals,
        "deferred_proofs" => deferred_proofs,
        "issue" => %{
          "id" => issue_id,
          "identifier" => issue_identifier,
          "labels" => issue_labels,
          "attachment_titles" => Enum.map(attachments, & &1["title"]),
          "acceptance_matrix" => acceptance_matrix_items
        },
        "pull_request" => %{
          "repo" => repo,
          "number" => pr_number,
          "all_checks_green" => Map.get(pr_snapshot, "all_checks_green"),
          "has_pending_checks" => Map.get(pr_snapshot, "has_pending_checks"),
          "has_actionable_feedback" => Map.get(pr_snapshot, "has_actionable_feedback"),
          "merge_state_status" => Map.get(pr_snapshot, "merge_state_status"),
          "url" => Map.get(pr_snapshot, "url")
        },
        "workpad" => %{
          "file_path" => workpad_path,
          "sha256" => sha256(workpad_body),
          "sections" => parsed_workpad["sections"],
          "validation" => parsed_workpad["validation"],
          "artifacts" => parsed_workpad["artifacts"],
          "proof_mapping" => parsed_workpad["proof_mapping"],
          "checkpoint" => parsed_workpad["checkpoint"]
        },
        "missing_items" => missing_items
      }
      |> Map.merge(
        TelemetrySchema.validation_guard_payload(%{
          validation_guard_name: profile,
          validation_guard_result: if(passed, do: "passed", else: "failed"),
          validation_guard_reason: summary_for_manifest(passed, profile, missing_items)
        })
      )

    if passed, do: {:ok, manifest}, else: {:error, manifest}
  end

  @spec write_manifest(map(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_manifest(manifest, path) when is_map(manifest) and is_binary(path) do
    expanded_path = Path.expand(path)
    sanitized_manifest = sanitize_manifest_utf8(manifest)

    with :ok <- File.mkdir_p(Path.dirname(expanded_path)),
         :ok <- File.write(expanded_path, Jason.encode!(sanitized_manifest, pretty: true)) do
      {:ok, expanded_path}
    end
  end

  @spec review_ready_transition_allowed?(Path.t(), String.t(), String.t() | nil) ::
          :ok | {:error, atom(), map()}
  def review_ready_transition_allowed?(manifest_path, issue_id, state_name) do
    review_ready_transition_allowed?(manifest_path, issue_id, state_name, nil)
  end

  @spec review_ready_transition_allowed?(Path.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, atom(), map()}
  def review_ready_transition_allowed?(manifest_path, issue_id, state_name, expected_workpad_path)
      when is_binary(manifest_path) and is_binary(issue_id) do
    review_ready_transition_allowed?(manifest_path, issue_id, state_name, expected_workpad_path, [])
  end

  def review_ready_transition_allowed?(_manifest_path, _issue_id, _state_name, _expected_workpad_path) do
    {:error, :handoff_manifest_invalid, %{"reason" => "issue_id is required"}}
  end

  @spec review_ready_transition_allowed?(Path.t(), String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          :ok | {:error, atom(), map()}
  def review_ready_transition_allowed?(manifest_path, issue_id, state_name, expected_workpad_path, opts)
      when is_binary(manifest_path) and is_binary(issue_id) and is_list(opts) do
    with {:ok, manifest} <- load_manifest(manifest_path),
         :ok <- validate_manifest_identity(manifest, issue_id, state_name),
         :ok <- validate_manifest_validation_gate(manifest, opts) do
      validate_manifest_workpad(manifest, expected_workpad_path)
    end
  end

  defp load_manifest(path) do
    expanded_path = Path.expand(path)

    with {:ok, body} <- File.read(expanded_path),
         {:ok, manifest} <- Jason.decode(body) do
      {:ok, manifest}
    else
      {:error, :enoent} ->
        {:error, :handoff_manifest_missing, %{"reason" => "manifest file is missing", "manifest_path" => expanded_path}}

      {:error, reason} when is_atom(reason) ->
        {:error, :handoff_manifest_invalid, %{"reason" => "cannot read manifest file", "manifest_path" => expanded_path, "details" => inspect(reason)}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, :handoff_manifest_invalid, %{"reason" => "manifest file is not valid JSON", "manifest_path" => expanded_path, "details" => Exception.message(error)}}
    end
  end

  defp validate_manifest_identity(manifest, issue_id, state_name) do
    manifest_issue_id = get_in(manifest, ["issue", "id"])
    manifest_target_state = manifest["target_state"]

    cond do
      manifest["passed"] != true ->
        {:error, :handoff_manifest_failed, %{"reason" => "manifest does not record a successful handoff check", "manifest" => manifest}}

      manifest_issue_id not in [issue_id, nil] ->
        {:error, :handoff_manifest_invalid, %{"reason" => "manifest belongs to a different issue", "manifest" => manifest}}

      (is_binary(state_name) and state_name != "" and state_name != manifest_target_state) &&
          manifest_target_state not in [nil, state_name] ->
        {:error, :handoff_manifest_invalid, %{"reason" => "manifest target state does not match the requested review-ready state", "manifest" => manifest}}

      true ->
        :ok
    end
  end

  defp validate_manifest_workpad(manifest, expected_workpad_path) do
    manifest_workpad_path = get_in(manifest, ["workpad", "file_path"])
    manifest_workpad_sha = get_in(manifest, ["workpad", "sha256"])

    workpad_path =
      cond do
        is_binary(expected_workpad_path) and expected_workpad_path != "" -> expected_workpad_path
        is_binary(manifest_workpad_path) and manifest_workpad_path != "" -> manifest_workpad_path
        true -> nil
      end

    with path when is_binary(path) <- workpad_path,
         {:ok, body} <- File.read(path),
         true <- sha256(body) == manifest_workpad_sha do
      :ok
    else
      nil ->
        {:error, :handoff_manifest_invalid, %{"reason" => "manifest does not point to a workpad file", "manifest" => manifest}}

      {:error, reason} ->
        {:error, :handoff_manifest_invalid, %{"reason" => "cannot read workpad referenced by manifest", "details" => inspect(reason), "manifest" => manifest}}

      false ->
        {:error, :handoff_manifest_stale, %{"reason" => "workpad changed after the last successful handoff check", "manifest" => manifest}}
    end
  end

  defp validate_manifest_validation_gate(manifest, opts) do
    manifest =
      if Map.has_key?(manifest, "validation_gate") do
        manifest
      else
        Map.put(manifest, "validation_gate", %{})
      end

    with {:ok, current_git} <- current_git_metadata(opts),
         :ok <- ValidationGate.validate_final_proof(manifest, current_git) do
      :ok
    else
      {:error, reasons} when is_list(reasons) ->
        {:error, :handoff_manifest_stale,
         %{
           "reason" => "validation gate final proof is stale or incomplete",
           "details" => reasons,
           "manifest" => manifest
         }}

      {:error, reason} ->
        {:error, :handoff_manifest_invalid,
         %{
           "reason" => "cannot read current git metadata",
           "details" => inspect(reason),
           "manifest" => manifest
         }}
    end
  end

  defp normalize_handoff_phase(nil), do: {@default_handoff_phase, []}

  defp normalize_handoff_phase(value) when is_binary(value) do
    normalized =
      value
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/[\s-]+/, "_")

    if normalized in @supported_handoff_phases do
      {normalized, []}
    else
      {@default_handoff_phase, ["handoff phase `#{value}` is unsupported; expected one of: #{Enum.join(@supported_handoff_phases, ", ")}"]}
    end
  end

  defp normalize_handoff_phase(value) do
    {@default_handoff_phase, ["handoff phase must be a string, got: #{inspect(value)}"]}
  end

  defp select_profile(explicit_profile, issue_labels, profile_labels, default_profile) do
    normalized_explicit = normalize_profile(explicit_profile)
    normalized_default = normalize_profile(default_profile) || "generic"
    matched_profiles = profiles_for_issue_labels(issue_labels, profile_labels)

    cond do
      is_binary(normalized_explicit) and normalized_explicit in @supported_profiles ->
        {normalized_explicit, "config", []}

      is_binary(normalized_explicit) ->
        {"generic", "fallback", ["explicit profile `#{explicit_profile}` is not supported"]}

      true ->
        case matched_profiles do
          [profile] ->
            {profile, "label", []}

          [] ->
            {normalized_default, "fallback", []}

          profiles ->
            {"generic", "fallback", ["conflicting verification labels matched multiple profiles: #{Enum.join(profiles, ", ")}"]}
        end
    end
  end

  defp profiles_for_issue_labels(issue_labels, profile_labels) do
    label_to_profile =
      Enum.reduce(@supported_profiles, %{}, fn profile, acc ->
        case Map.get(profile_labels, profile) do
          label when is_binary(label) and label != "" -> Map.put(acc, label, profile)
          _ -> acc
        end
      end)

    issue_labels
    |> Enum.map(&Map.get(label_to_profile, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parse_workpad(body) do
    sections = split_sections(body)
    validation_items = parse_checkbox_items(section_body(sections, ["Validation", "Проверка"]))
    artifact_items = parse_artifact_items(section_body(sections, ["Artifacts", "Артефакты"]))
    proof_mapping_items = parse_proof_mapping_items(section_body(sections, ["Proof Mapping", "Маппинг доказательств"]))
    checkpoint = parse_checkpoint(Map.get(sections, "Checkpoint", ""))

    %{
      "sections" => Map.keys(sections),
      "validation" => validation_items,
      "artifacts" => artifact_items,
      "proof_mapping" => proof_mapping_items,
      "checkpoint" => checkpoint
    }
  end

  defp section_body(sections, titles) when is_map(sections) and is_list(titles) do
    Enum.find_value(titles, "", &Map.get(sections, &1))
  end

  defp split_sections(body) do
    {sections, current_title, current_lines} =
      Enum.reduce(String.split(body, ~r/\R/, trim: false), {%{}, nil, []}, fn line, {sections, current_title, current_lines} ->
        case Regex.run(~r/^###\s+(.+?)\s*$/, line) do
          [_, title] ->
            sections =
              commit_section(sections, current_title, current_lines)

            {sections, String.trim(title), []}

          _ ->
            {sections, current_title, [line | current_lines]}
        end
      end)

    commit_section(sections, current_title, current_lines)
  end

  defp commit_section(sections, nil, _lines), do: sections

  defp commit_section(sections, title, lines) do
    Map.put(sections, title, lines |> Enum.reverse() |> Enum.join("\n") |> String.trim())
  end

  defp parse_checkbox_items(section_body) when is_binary(section_body) do
    section_body
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&Regex.run(~r/^- \[([ xX])\]\s+(.*)$/, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn [_, checked, text] ->
      %{
        "checked" => String.downcase(checked) == "x",
        "text" => String.trim(text),
        "label" => checkbox_label(text),
        "command" => checkbox_command(text)
      }
    end)
  end

  defp parse_artifact_items(section_body) when is_binary(section_body) do
    parse_checkbox_items(section_body)
    |> Enum.map(fn item ->
      title = artifact_title(item["text"])
      claim = artifact_claim(item["text"])

      Map.merge(item, %{
        "kind" => artifact_kind(item["text"], title, claim),
        "title" => title,
        "claim" => claim
      })
    end)
  end

  defp parse_proof_mapping_items(section_body) when is_binary(section_body) do
    parse_checkbox_items(section_body)
    |> Enum.map(fn item ->
      matrix_item_id = mapping_matrix_item_id(item["text"])
      reference = mapping_reference(item["text"])

      {reference_type, reference_value} =
        if is_binary(reference), do: mapping_reference_parts(reference), else: {nil, nil}

      Map.merge(item, %{
        "matrix_item_id" => matrix_item_id,
        "reference" => reference,
        "reference_type" => reference_type,
        "reference_value" => reference_value
      })
    end)
  end

  defp parse_checkpoint(section_body) when is_binary(section_body) do
    section_body
    |> String.split(~r/\R/, trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^- `([^`]+)`: (.+)$/, line) do
        [_, key, value] -> Map.put(acc, key, normalize_checkpoint_value(value))
        _ -> acc
      end
    end)
  end

  defp parse_acceptance_matrix(nil), do: {[], []}

  defp parse_acceptance_matrix(issue_description) when is_binary(issue_description) do
    section_body = markdown_h2_section_body(issue_description, "Acceptance Matrix")

    rows =
      section_body
      |> String.split(~r/\R/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.starts_with?(&1, "|") and String.ends_with?(&1, "|")))

    data_rows =
      rows
      |> Enum.drop(2)
      |> Enum.reject(&table_separator_row?/1)

    parsed_rows =
      Enum.map(data_rows, &parse_acceptance_matrix_row/1)

    items =
      parsed_rows
      |> Enum.flat_map(fn
        {:ok, item} -> [item]
        _ -> []
      end)

    row_errors =
      parsed_rows
      |> Enum.flat_map(fn
        {:error, reason} -> [reason]
        _ -> []
      end)

    unique_errors =
      items
      |> Enum.group_by(& &1["id"])
      |> Enum.flat_map(fn
        {_id, [_single]} -> []
        {id, _dupes} -> ["acceptance matrix contains duplicate id `#{id}`"]
      end)

    {items, Enum.uniq(row_errors ++ unique_errors)}
  end

  defp parse_acceptance_matrix(_issue_description), do: {[], []}

  defp markdown_h2_section_body(markdown, heading) when is_binary(markdown) and is_binary(heading) do
    escaped_heading = Regex.escape(heading)
    section_regex = ~r/(?:^|\n)##\s+#{escaped_heading}\s*\n(?<body>.*?)(?=\n##\s+|\z)/ms

    case Regex.named_captures(section_regex, markdown) do
      %{"body" => body} -> String.trim(body)
      _ -> ""
    end
  end

  defp table_separator_row?(row) do
    row
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.all?(fn cell -> Regex.match?(~r/^:?-{3,}:?$/, cell) end)
  end

  defp parse_acceptance_matrix_row(row) do
    cells =
      row
      |> String.trim("|")
      |> String.split("|")
      |> Enum.map(&String.trim/1)

    case cells do
      [id, scenario, expected_outcome, proof_type, proof_target, proof_semantic | rest] ->
        required_before =
          case rest do
            [] -> @default_matrix_required_before
            [value | _rest] -> value
          end

        with true <- not placeholder_value?(id),
             {:proof_type, canonical_type} when is_binary(canonical_type) <-
               {:proof_type, normalize_matrix_proof_type(proof_type)},
             {:proof_semantic, canonical_semantic} when is_binary(canonical_semantic) <-
               {:proof_semantic, normalize_matrix_semantic(proof_semantic)},
             {:required_before, canonical_required_before} when is_binary(canonical_required_before) <-
               {:required_before, normalize_matrix_required_before(required_before)},
             true <- not placeholder_value?(proof_target) do
          {:ok,
           %{
             "id" => strip_wrapping_backticks(id),
             "scenario" => scenario,
             "expected_outcome" => expected_outcome,
             "proof_type" => canonical_type,
             "proof_target" => strip_wrapping_backticks(proof_target),
             "proof_semantic" => canonical_semantic,
             "required_before" => canonical_required_before
           }}
        else
          false ->
            {:error, "acceptance matrix row is missing required id or proof_target: #{row}"}

          {:proof_type, nil} ->
            {:error, "acceptance matrix row has unsupported proof_type/proof_semantic: #{row}"}

          {:proof_semantic, nil} ->
            {:error, "acceptance matrix row has unsupported proof_type/proof_semantic: #{row}"}

          {:required_before, nil} ->
            {:error, "acceptance matrix row has unsupported required_before: #{row}"}
        end

      _ ->
        {:error, "acceptance matrix row has invalid column count: #{row}"}
    end
  end

  defp normalize_matrix_proof_type(value) when is_binary(value) do
    normalized =
      value
      |> strip_wrapping_backticks()
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/[\s-]+/, "_")

    if MapSet.member?(@matrix_proof_types, normalized), do: normalized
  end

  defp normalize_matrix_semantic(value) when is_binary(value) do
    normalized =
      value
      |> strip_wrapping_backticks()
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/[\s-]+/, "_")

    cond do
      normalized in ["", "default"] ->
        "run_executed"

      MapSet.member?(@matrix_semantics, normalized) ->
        normalized

      true ->
        nil
    end
  end

  defp normalize_matrix_required_before(value) when is_binary(value) do
    normalized =
      value
      |> strip_wrapping_backticks()
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/[\s-]+/, "_")

    cond do
      normalized in ["", "default"] ->
        @default_matrix_required_before

      MapSet.member?(@matrix_required_before, normalized) ->
        normalized

      true ->
        nil
    end
  end

  defp mapping_matrix_item_id(text) when is_binary(text) do
    case Regex.run(~r/`([^`]+)`/, text) do
      [_, id] -> String.trim(id)
      _ -> nil
    end
  end

  defp mapping_reference(text) when is_binary(text) do
    case String.split(text, "->", parts: 2) do
      [_, reference] -> reference |> String.trim() |> strip_wrapping_backticks()
      _ -> nil
    end
  end

  defp mapping_reference_parts(reference) when is_binary(reference) do
    case Regex.run(~r/^(validation|artifact|runtime)\s*:\s*(.+)$/i, reference) do
      [_, type, value] ->
        {String.downcase(String.trim(type)), value |> String.trim() |> strip_wrapping_backticks()}

      _ ->
        {nil, nil}
    end
  end

  defp acceptance_matrix_missing_items(acceptance_matrix_items, parsed_workpad, issue_labels, attachments, parse_errors, phase) do
    validation_items = parsed_workpad["validation"] || []
    proof_mapping_items = parsed_workpad["proof_mapping"] || []
    artifact_items = parsed_workpad["artifacts"] || []
    runtime_smoke_checked? = runtime_smoke_checked?(validation_items)

    case requires_acceptance_matrix?(issue_labels, acceptance_matrix_items) do
      false ->
        {skipped_matrix_proof_signals(runtime_smoke_checked?), [], []}

      true ->
        evaluate_acceptance_matrix(
          acceptance_matrix_items,
          validation_items,
          artifact_items,
          proof_mapping_items,
          attachments,
          parse_errors,
          runtime_smoke_checked?,
          phase
        )
    end
  end

  defp evaluate_acceptance_matrix(
         acceptance_matrix_items,
         validation_items,
         artifact_items,
         proof_mapping_items,
         attachments,
         parse_errors,
         runtime_smoke_checked?,
         phase
       ) do
    required_items = Enum.filter(acceptance_matrix_items, &matrix_item_required_for_phase?(&1, phase))
    deferred_proofs = deferred_proofs_for_phase(acceptance_matrix_items, phase)
    checked_mappings = checked_proof_mapping_items(proof_mapping_items)
    mapping_groups = Enum.group_by(checked_mappings, & &1["matrix_item_id"])
    matrix_ids = MapSet.new(Enum.map(acceptance_matrix_items, & &1["id"]))

    base_errors =
      []
      |> Kernel.++(missing_matrix_section_errors(acceptance_matrix_items))
      |> Kernel.++(parse_errors)
      |> Kernel.++(proof_mapping_format_errors(proof_mapping_items))
      |> Kernel.++(unknown_matrix_mapping_errors(checked_mappings, matrix_ids))
      |> Kernel.++(duplicate_reference_errors(checked_mappings))

    {item_errors, signals} =
      Enum.reduce(required_items, {base_errors, initial_proof_signals(runtime_smoke_checked?)}, fn matrix_item, {errors, signals} ->
        validate_single_matrix_item(
          matrix_item,
          Map.get(mapping_groups, matrix_item["id"], []),
          validation_items,
          artifact_items,
          attachments,
          errors,
          signals
        )
      end)

    finalized_signals =
      signals
      |> Map.put("acceptance_matrix_covered", item_errors == [])
      |> Map.put("acceptance_matrix_required_items", length(required_items))
      |> Map.put("acceptance_matrix_deferred_items", length(deferred_proofs))

    {finalized_signals, Enum.uniq(item_errors), deferred_proofs}
  end

  defp matrix_item_required_for_phase?(matrix_item, "done") do
    matrix_item["required_before"] in ["review", "done"]
  end

  defp matrix_item_required_for_phase?(matrix_item, _phase) do
    Map.get(matrix_item, "required_before", @default_matrix_required_before) == "review"
  end

  defp deferred_proofs_for_phase(acceptance_matrix_items, phase) do
    acceptance_matrix_items
    |> Enum.reject(&matrix_item_required_for_phase?(&1, phase))
    |> Enum.map(&Map.take(&1, ["id", "scenario", "proof_type", "proof_target", "proof_semantic", "required_before"]))
  end

  defp validate_single_matrix_item(matrix_item, [], _validation_items, _artifact_items, _attachments, errors, signals) do
    {errors ++ ["acceptance matrix item `#{matrix_item["id"]}` is missing a checked proof mapping entry"], signals}
  end

  defp validate_single_matrix_item(matrix_item, [_mapping, _second | _rest], _validation_items, _artifact_items, _attachments, errors, signals) do
    {errors ++ ["acceptance matrix item `#{matrix_item["id"]}` has multiple proof mapping entries; exactly one is required"], signals}
  end

  defp validate_single_matrix_item(matrix_item, [mapping], validation_items, artifact_items, attachments, errors, signals) do
    validate_matrix_mapping(
      matrix_item,
      mapping,
      validation_items,
      artifact_items,
      attachments,
      errors,
      signals
    )
  end

  defp requires_acceptance_matrix?(issue_labels, acceptance_matrix_items) do
    @plan_mode_label in issue_labels or acceptance_matrix_items != []
  end

  defp runtime_smoke_checked?(validation_items) do
    Enum.any?(validation_items, fn item ->
      item["checked"] == true and item["label"] == "runtime smoke" and not placeholder_value?(item["command"])
    end)
  end

  defp skipped_matrix_proof_signals(runtime_smoke_checked?) do
    %{
      "proof_surface_exists" => false,
      "proof_run_executed" => false,
      "runtime_smoke" => runtime_smoke_checked?,
      "acceptance_matrix_covered" => true
    }
  end

  defp checked_proof_mapping_items(proof_mapping_items) do
    proof_mapping_items
    |> Enum.filter(&(&1["checked"] == true))
    |> Enum.reject(&(placeholder_value?(&1["matrix_item_id"]) or placeholder_value?(&1["reference_value"])))
  end

  defp missing_matrix_section_errors(acceptance_matrix_items) do
    case acceptance_matrix_items do
      [] -> ["acceptance matrix section is missing or empty in issue description for `mode:plan` handoff"]
      _ -> []
    end
  end

  defp validate_matrix_mapping(matrix_item, mapping, validation_items, artifact_items, attachments, errors, signals) do
    matrix_item_id = matrix_item["id"]
    matrix_type = matrix_item["proof_type"]
    matrix_semantic = matrix_item["proof_semantic"]
    reference_type = mapping["reference_type"]
    reference_value = mapping["reference_value"]

    if matrix_type == "artifact" do
      validate_artifact_matrix_mapping(
        matrix_item_id,
        reference_type,
        reference_value,
        artifact_items,
        attachments,
        errors,
        signals,
        matrix_semantic
      )
    else
      validate_validation_matrix_mapping(
        matrix_item_id,
        matrix_type,
        matrix_semantic,
        reference_type,
        reference_value,
        validation_items,
        errors,
        signals
      )
    end
  end

  defp validate_artifact_matrix_mapping(matrix_item_id, reference_type, reference_value, artifact_items, attachments, errors, signals, matrix_semantic) do
    if reference_type != "artifact" do
      {errors ++ ["acceptance matrix item `#{matrix_item_id}` expects artifact mapping `artifact:<title>`"], signals}
    else
      artifact_match =
        Enum.find(artifact_items, fn item ->
          item["checked"] == true and item["kind"] == "uploaded_attachment" and item["title"] == reference_value
        end)

      cond do
        is_nil(artifact_match) ->
          {errors ++ ["acceptance matrix item `#{matrix_item_id}` maps to artifact `#{reference_value}` that is not checked in `Artifacts`"], signals}

        not attachment_present?(attachments, reference_value) ->
          {errors ++ ["acceptance matrix item `#{matrix_item_id}` maps to artifact `#{reference_value}` that is not uploaded in Linear attachments"], signals}

        true ->
          updated_signals =
            signals
            |> mark_matrix_semantic(matrix_semantic)
            |> mark_runtime_smoke_signal(matrix_semantic)

          {errors, updated_signals}
      end
    end
  end

  defp validate_validation_matrix_mapping(
         matrix_item_id,
         matrix_type,
         matrix_semantic,
         reference_type,
         reference_value,
         validation_items,
         errors,
         signals
       ) do
    case reference_type do
      type when type in ["validation", "runtime"] ->
        validation_match = find_checked_validation_item(validation_items, reference_value)

        validate_validation_match(
          validation_match,
          reference_value,
          matrix_item_id,
          matrix_type,
          matrix_semantic,
          errors,
          signals
        )

      _ ->
        {errors ++ ["acceptance matrix item `#{matrix_item_id}` expects validation mapping `validation:<label>`"], signals}
    end
  end

  defp find_checked_validation_item(validation_items, reference_value) do
    Enum.find(validation_items, fn item ->
      item["checked"] == true and String.downcase(to_string(item["label"])) == String.downcase(to_string(reference_value))
    end)
  end

  defp validate_validation_match(nil, reference_value, matrix_item_id, _matrix_type, _matrix_semantic, errors, signals) do
    {errors ++ ["acceptance matrix item `#{matrix_item_id}` maps to validation `#{reference_value}` that is not checked"], signals}
  end

  defp validate_validation_match(validation_match, _reference_value, matrix_item_id, "runtime_smoke", matrix_semantic, errors, signals) do
    cond do
      validation_match["label"] != "runtime smoke" ->
        {errors ++ ["acceptance matrix item `#{matrix_item_id}` with proof_type `runtime_smoke` must map to `runtime smoke` validation entry"], signals}

      matrix_semantic == "run_executed" and surface_only_command?(validation_match["command"]) ->
        {errors ++ ["acceptance matrix item `#{matrix_item_id}` requires executed proof; mapped validation command looks surface-only (`--help`)"], signals}

      true ->
        updated_signals =
          signals
          |> mark_matrix_semantic(matrix_semantic)
          |> mark_runtime_smoke_signal("runtime_smoke")

        {errors, updated_signals}
    end
  end

  defp validate_validation_match(validation_match, _reference_value, matrix_item_id, _matrix_type, "run_executed", errors, signals)
       when is_map(validation_match) do
    if surface_only_command?(validation_match["command"]) do
      {errors ++ ["acceptance matrix item `#{matrix_item_id}` requires executed proof; mapped validation command looks surface-only (`--help`)"], signals}
    else
      {errors, signals |> mark_matrix_semantic("run_executed")}
    end
  end

  defp validate_validation_match(_validation_match, _reference_value, _matrix_item_id, matrix_type, matrix_semantic, errors, signals) do
    updated_signals =
      signals
      |> mark_matrix_semantic(matrix_semantic)
      |> mark_runtime_smoke_signal(matrix_type)

    {errors, updated_signals}
  end

  defp proof_mapping_format_errors(proof_mapping_items) do
    Enum.flat_map(proof_mapping_items, fn item ->
      checked? = item["checked"] == true
      matrix_item_id = item["matrix_item_id"]
      reference_type = item["reference_type"]
      reference_value = item["reference_value"]

      cond do
        not checked? ->
          []

        placeholder_value?(matrix_item_id) ->
          ["proof mapping entry is missing matrix item id in backticks"]

        reference_type not in ["validation", "artifact", "runtime"] or placeholder_value?(reference_value) ->
          ["proof mapping entry for `#{matrix_item_id}` must use `validation:<label>`, `artifact:<title>`, or `runtime:<label>`"]

        true ->
          []
      end
    end)
  end

  defp unknown_matrix_mapping_errors(checked_mappings, matrix_ids) do
    checked_mappings
    |> Enum.flat_map(fn mapping ->
      matrix_item_id = mapping["matrix_item_id"]

      if MapSet.member?(matrix_ids, matrix_item_id) do
        []
      else
        ["proof mapping references unknown acceptance matrix item `#{matrix_item_id}`"]
      end
    end)
  end

  defp duplicate_reference_errors(checked_mappings) do
    checked_mappings
    |> Enum.group_by(fn mapping ->
      "#{mapping["reference_type"]}:#{String.downcase(to_string(mapping["reference_value"]))}"
    end)
    |> Enum.flat_map(fn {reference, mappings} ->
      matrix_ids =
        mappings
        |> Enum.map(& &1["matrix_item_id"])
        |> Enum.uniq()

      if length(matrix_ids) > 1 do
        ["proof mapping reference `#{reference}` is reused by multiple acceptance matrix items: #{Enum.join(matrix_ids, ", ")}"]
      else
        []
      end
    end)
  end

  defp mark_matrix_semantic(signals, "surface_exists"), do: Map.put(signals, "proof_surface_exists", true)
  defp mark_matrix_semantic(signals, "run_executed"), do: Map.put(signals, "proof_run_executed", true)
  defp mark_matrix_semantic(signals, "runtime_smoke"), do: Map.put(signals, "runtime_smoke", true)

  defp mark_runtime_smoke_signal(signals, "runtime_smoke"), do: Map.put(signals, "runtime_smoke", true)
  defp mark_runtime_smoke_signal(signals, _), do: signals

  defp initial_proof_signals(runtime_smoke_checked?) do
    %{
      "proof_surface_exists" => false,
      "proof_run_executed" => false,
      "runtime_smoke" => runtime_smoke_checked?,
      "acceptance_matrix_covered" => false
    }
  end

  defp normalize_checkpoint_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> strip_wrapping_backticks()
  end

  defp strip_wrapping_backticks("`" <> rest) do
    rest
    |> String.trim_trailing("`")
    |> String.trim()
  end

  defp strip_wrapping_backticks(value), do: value

  defp collect_missing_items(
         parsed_workpad,
         issue_labels,
         attachments,
         pr_snapshot,
         profile,
         profile_errors,
         validation_context,
         acceptance_matrix_missing_items
       ) do
    []
    |> Kernel.++(profile_errors)
    |> Kernel.++(validation_context["errors"])
    |> Kernel.++(validation_missing_items(parsed_workpad["validation"], issue_labels, validation_context["gate"]))
    |> Kernel.++(validation_gate_missing_items(validation_context["gate"], validation_context["git"]))
    |> Kernel.++(checkpoint_missing_items(parsed_workpad["checkpoint"]))
    |> Kernel.++(artifact_manifest_missing_items(parsed_workpad["artifacts"], attachments))
    |> Kernel.++(acceptance_matrix_missing_items)
    |> Kernel.++(profile_missing_items(profile, parsed_workpad["artifacts"], attachments))
    |> Kernel.++(pr_snapshot_missing_items(pr_snapshot))
    |> Enum.uniq()
  end

  defp validation_missing_items(validation_items, issue_labels, validation_gate) do
    checked_checks = ValidationGate.checked_validation_checks(validation_items)

    required_core_checks =
      ["preflight", "targeted tests", "repo validation"]
      |> ValidationGate.normalize_checks()
      |> Enum.reject(&(&1 in checked_checks))
      |> Enum.map(&"validation checklist is missing a checked `#{human_check_label(&1)}` item")

    proof_check_diagnostic =
      ValidationGate.missing_required_proof_checks(
        validation_items,
        issue_labels,
        validation_gate_change_classes(validation_gate)
      )

    required_proof_checks =
      proof_check_diagnostic["missing_checks"]
      |> Enum.map(fn requirement ->
        "validation checklist is missing a checked `#{requirement["label"]}` item"
      end)

    required_core_checks ++ required_proof_checks
  end

  defp validation_gate_missing_items(validation_gate, git_metadata) do
    case ValidationGate.validate_final_proof(%{"validation_gate" => validation_gate, "git" => git_metadata}, git_metadata) do
      :ok ->
        []

      {:error, reasons} ->
        Enum.map(reasons, &"validation gate final proof invalid: #{&1}")
    end
  end

  defp validation_gate_change_classes(%{"change_classes" => classes}) when is_list(classes), do: classes
  defp validation_gate_change_classes(_validation_gate), do: []

  defp human_check_label(check) when is_binary(check), do: String.replace(check, "_", " ")

  defp checkpoint_missing_items(checkpoint) do
    []
    |> maybe_require_checkpoint_value(
      checkpoint,
      "checkpoint_type",
      fn value ->
        value in @allowed_checkpoint_types
      end,
      "`checkpoint_type` must be one of #{Enum.join(@allowed_checkpoint_types, ", ")}"
    )
    |> maybe_require_checkpoint_value(
      checkpoint,
      "risk_level",
      fn value ->
        value in @allowed_risk_levels
      end,
      "`risk_level` must be one of #{Enum.join(@allowed_risk_levels, ", ")}"
    )
    |> maybe_require_checkpoint_value(
      checkpoint,
      "summary",
      fn value ->
        not placeholder_value?(value)
      end,
      "`summary` must be filled with an evidence-backed handoff summary"
    )
  end

  defp maybe_require_checkpoint_value(acc, checkpoint, key, validator, message) do
    value = Map.get(checkpoint, key)

    if is_binary(value) and value != "" and validator.(value) do
      acc
    else
      acc ++ [message]
    end
  end

  defp artifact_manifest_missing_items(artifact_items, attachments) do
    uploaded =
      Enum.filter(artifact_items, fn item ->
        item["checked"] == true and item["kind"] == "uploaded_attachment"
      end)

    if uploaded == [] do
      ["artifact manifest is missing a checked uploaded attachment entry"]
    else
      attachment_titles = MapSet.new(Enum.map(attachments, & &1["title"]))

      Enum.flat_map(uploaded, fn item ->
        title = item["title"]

        cond do
          not is_binary(title) or title == "" ->
            ["artifact manifest entry must include an attachment title in backticks"]

          not MapSet.member?(attachment_titles, title) ->
            ["uploaded attachment `#{title}` is missing from the Linear issue attachments"]

          placeholder_value?(item["claim"]) ->
            ["uploaded attachment `#{title}` is missing a concrete proof claim"]

          true ->
            []
        end
      end)
    end
  end

  defp profile_missing_items("generic", _artifact_items, _attachments), do: []

  defp profile_missing_items(profile, artifact_items, attachments) do
    uploaded_present =
      artifact_items
      |> Enum.filter(fn item ->
        item["checked"] == true and item["kind"] == "uploaded_attachment" and
          attachment_present?(attachments, item["title"])
      end)

    profile_match? =
      Enum.any?(uploaded_present, fn item ->
        proof_matches_profile?(profile, item["title"], item["claim"])
      end)

    if profile_match? do
      []
    else
      ["profile `#{profile}` is missing a matching uploaded proof artifact"]
    end
  end

  defp pr_snapshot_missing_items(pr_snapshot) when map_size(pr_snapshot) == 0 do
    ["pull request snapshot is missing"]
  end

  defp pr_snapshot_missing_items(pr_snapshot) do
    []
    |> maybe_require_snapshot(Map.get(pr_snapshot, "all_checks_green") == true, "pull request checks are not fully green")
    |> maybe_require_snapshot(Map.get(pr_snapshot, "has_pending_checks") == false, "pull request still has pending checks")
    |> maybe_require_snapshot(Map.get(pr_snapshot, "has_actionable_feedback") == false, "pull request still has actionable feedback")
    |> maybe_require_snapshot(Map.get(pr_snapshot, "merge_state_status") not in ["DIRTY", "BLOCKED", "UNKNOWN"], "pull request is not merge-ready")
  end

  defp maybe_require_snapshot(acc, true, _message), do: acc
  defp maybe_require_snapshot(acc, false, message), do: acc ++ [message]

  defp summary_for_manifest(true, profile, _missing_items),
    do: "verification passed for profile `#{profile}`"

  defp summary_for_manifest(false, profile, missing_items) do
    trimmed =
      missing_items
      |> Enum.take(3)
      |> Enum.join("; ")

    "verification failed for profile `#{profile}`: #{trimmed}"
  end

  defp attachment_present?(attachments, title) when is_binary(title) do
    Enum.any?(attachments, &(&1["title"] == title))
  end

  defp attachment_present?(_attachments, _title), do: false

  defp proof_matches_profile?("ui", title, claim) do
    visual_file?(title) or claim_matches?(claim, ["screenshot", "screen recording", "visual", "gif", "video"])
  end

  defp proof_matches_profile?("data-extraction", title, claim) do
    machine_readable_file?(title) or claim_matches?(claim, ["fixture", "json", "jsonl", "csv", "representative run", "sample"])
  end

  defp proof_matches_profile?("runtime", title, claim) do
    runtime_proof_file?(title) or claim_matches?(claim, ["dashboard", "health", "log", "runtime", "smoke"])
  end

  defp artifact_kind(text, title, _claim) do
    normalized = String.downcase(text)

    cond do
      String.starts_with?(normalized, "uploaded attachment:") or String.starts_with?(normalized, "вложение:") ->
        "uploaded_attachment"

      String.starts_with?(normalized, "missing expected artifact:") or
          String.starts_with?(normalized, "ожидаемый, но не созданный артефакт:") ->
        "missing_expected_artifact"

      visual_file?(title) ->
        "visual_proof"

      machine_readable_file?(title) ->
        "machine_readable"

      runtime_proof_file?(title) ->
        "runtime_proof"

      true ->
        "artifact"
    end
  end

  defp artifact_title(text) do
    case Regex.run(~r/`([^`]+)`/, text) do
      [_, title] -> String.trim(title)
      _ -> nil
    end
  end

  defp artifact_claim(text) do
    case String.split(text, "->", parts: 2) do
      [_, claim] -> String.trim(claim)
      _ -> nil
    end
  end

  defp checkbox_label(text) when is_binary(text) do
    text
    |> String.split(":", parts: 2)
    |> hd()
    |> String.downcase()
    |> String.trim()
  end

  defp checkbox_command(text) when is_binary(text) do
    case Regex.run(~r/`([^`]+)`/, text) do
      [_, command] -> String.trim(command)
      _ -> text |> String.split(":", parts: 2) |> List.last() |> to_string() |> String.trim()
    end
  end

  defp resolve_validation_gate(parsed_workpad, opts) do
    explicit_errors = normalize_validation_gate_errors(Keyword.get(opts, :validation_gate_errors, []))
    git_metadata = normalize_git_metadata(Keyword.get(opts, :git, %{}))
    explicit_gate = Keyword.get(opts, :validation_gate)

    cond do
      is_map(explicit_gate) and map_size(explicit_gate) > 0 ->
        {Map.drop(explicit_gate, ["git"]), normalize_git_metadata(Map.get(explicit_gate, "git") || git_metadata), explicit_errors}

      Keyword.has_key?(opts, :change_classes) ->
        passed_checks = passed_validation_checks(parsed_workpad["validation"])

        case ValidationGate.final_proof(Keyword.get(opts, :change_classes), passed_checks, git_metadata) do
          {:ok, proof} -> {Map.drop(proof, ["git"]), Map.get(proof, "git"), explicit_errors}
          {:error, reasons} -> {%{}, git_metadata, explicit_errors ++ reasons}
        end

      true ->
        {%{}, git_metadata, explicit_errors ++ ["validation gate final proof metadata is missing"]}
    end
  end

  defp passed_validation_checks(validation_items) when is_list(validation_items) do
    ValidationGate.checked_validation_checks(validation_items)
  end

  defp normalize_validation_gate_errors(errors) when is_list(errors) do
    errors
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_validation_gate_errors(_errors), do: []

  defp normalize_git_metadata(metadata) when is_map(metadata) do
    %{
      "head_sha" => metadata["head_sha"] || metadata[:head_sha],
      "tree_sha" => metadata["tree_sha"] || metadata[:tree_sha],
      "worktree_clean" => metadata["worktree_clean"] || metadata[:worktree_clean] || false,
      "changed_paths" => normalize_string_list(metadata["changed_paths"] || metadata[:changed_paths] || [])
    }
  end

  defp normalize_git_metadata(_metadata), do: %{}

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_values), do: []

  defp current_git_metadata(opts) do
    repo_path = Keyword.get(opts, :repo_path) || Keyword.get(opts, :workspace) || File.cwd!()
    runner = Keyword.get(opts, :git_runner, &default_git_runner/2)

    with {:ok, head_sha} <- run_git(runner, repo_path, ["rev-parse", "HEAD"]),
         {:ok, tree_sha} <- run_git(runner, repo_path, ["rev-parse", "HEAD^{tree}"]),
         {:ok, status} <- run_git(runner, repo_path, ["status", "--porcelain", "--untracked-files=no"]) do
      {:ok,
       %{
         "head_sha" => String.trim(head_sha),
         "tree_sha" => String.trim(tree_sha),
         "worktree_clean" => String.trim(status) == ""
       }}
    end
  end

  defp run_git(runner, repo_path, args) when is_function(runner, 2) do
    runner.(args, repo_path: repo_path)
  end

  defp default_git_runner(args, opts) do
    repo_path = Keyword.get(opts, :repo_path) || File.cwd!()

    try do
      case System.cmd("git", ["-C", repo_path | args], stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, {:git_status, status, String.trim(output)}}
      end
    rescue
      error in ErlangError ->
        {:error, {:git_unavailable, error.original}}
    end
  end

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_labels(_labels), do: []

  defp normalize_attachments(attachments) when is_list(attachments) do
    Enum.map(attachments, fn
      %{} = attachment ->
        %{
          "title" => attachment["title"] || attachment[:title],
          "url" => attachment["url"] || attachment[:url]
        }

      _ ->
        %{}
    end)
  end

  defp normalize_attachments(_attachments), do: []

  defp normalize_pr_snapshot(%{} = pr_snapshot), do: pr_snapshot
  defp normalize_pr_snapshot(_pr_snapshot), do: %{}

  defp normalize_profile(nil), do: nil

  defp normalize_profile(profile) when is_binary(profile) do
    profile
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_profile(_profile), do: nil

  defp normalize_profile_labels(profile_labels) when is_map(profile_labels) do
    Enum.reduce(profile_labels, %{}, fn {profile, label}, acc ->
      normalized_profile = normalize_profile(to_string(profile))

      if normalized_profile in @supported_profiles do
        Map.put(acc, normalized_profile, label |> to_string() |> String.trim())
      else
        acc
      end
    end)
  end

  defp normalize_profile_labels(_profile_labels), do: @default_profile_labels

  defp placeholder_value?(nil), do: true

  defp placeholder_value?(value) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed == "" or String.starts_with?(trimmed, "<") or String.contains?(trimmed, "fill only")
  end

  defp surface_only_command?(value), do: is_binary(value) and String.contains?(String.downcase(value), "--help")

  defp claim_matches?(claim, phrases) when is_binary(claim) do
    normalized_claim = String.downcase(claim)
    Enum.any?(phrases, &String.contains?(normalized_claim, &1))
  end

  defp claim_matches?(_claim, _phrases), do: false

  defp visual_file?(title), do: MapSet.member?(@visual_extensions, extension(title))
  defp machine_readable_file?(title), do: MapSet.member?(@machine_readable_extensions, extension(title))
  defp runtime_proof_file?(title), do: MapSet.member?(@runtime_extensions, extension(title))

  defp extension(title) when is_binary(title) do
    title
    |> Path.extname()
    |> String.downcase()
  end

  defp extension(_title), do: ""

  defp sha256(body) when is_binary(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end

  defp sanitize_manifest_utf8(value) when is_binary(value) do
    if String.valid?(value), do: value, else: String.replace_invalid(value, " ")
  end

  defp sanitize_manifest_utf8(value) when is_list(value) do
    Enum.map(value, &sanitize_manifest_utf8/1)
  end

  defp sanitize_manifest_utf8(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, item}, acc ->
      Map.put(acc, sanitize_manifest_key(key), sanitize_manifest_utf8(item))
    end)
  end

  defp sanitize_manifest_utf8(value), do: value

  defp sanitize_manifest_key(key) when is_binary(key), do: sanitize_manifest_utf8(key)
  defp sanitize_manifest_key(key), do: key
end
