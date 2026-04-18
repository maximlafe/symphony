defmodule SymphonyElixir.TelemetrySchema do
  @moduledoc """
  Canonical flat-key telemetry contract for runtime decision surfaces.
  """

  @cost_fields [
    :cost_profile_key,
    :cost_profile_reason,
    :cost_stage,
    :cost_signals,
    :command_source,
    :codex_model,
    :codex_effort,
    :observed_model,
    :observed_effort,
    :observed_signal_source,
    :routing_parity_status,
    :routing_parity_reason
  ]
  @budget_fields [
    :budget_decision,
    :budget_reason,
    :budget_threshold,
    :budget_observed_total,
    :budget_attempt_tokens,
    :budget_issue_total_tokens,
    :budget_current_cost_profile_key,
    :budget_next_cost_profile_key,
    :budget_downshift_rule
  ]
  @retry_dedupe_fields [
    :retry_dedupe_result,
    :retry_dedupe_reason,
    :retry_dedupe_key,
    :error_signature,
    :feedback_digest
  ]
  @retry_failover_fields [
    :retry_failover_selected_rule,
    :retry_failover_selected_action,
    :retry_failover_reason,
    :retry_failover_suppressed_rules,
    :retry_failover_checkpoint_type,
    :retry_failover_risk_level
  ]
  @failover_fields [
    :failover_decision,
    :failover_reason,
    :failover_from_account_id,
    :failover_to_account_id
  ]
  @continuation_fields [
    :continuation_reason,
    :resume_mode,
    :resume_fallback_reason,
    :auto_compaction_signal,
    :auto_compaction_threshold,
    :auto_compaction_observed_total
  ]
  @wait_fields [:wait_mode, :wait_reason, :wait_source, :wait_tool]
  @checkpoint_fields [
    :checkpoint_quality,
    :checkpoint_origin,
    :checkpoint_fallback_reasons,
    :resume_ready
  ]
  @validation_guard_fields [
    :validation_guard_name,
    :validation_guard_result,
    :validation_guard_reason
  ]
  @execution_head_fields [:runtime_head_sha, :expected_head_sha, :head_relation]
  @all_fields Enum.uniq(
                @cost_fields ++
                  @budget_fields ++
                  @retry_dedupe_fields ++
                  @retry_failover_fields ++
                  @failover_fields ++
                  @continuation_fields ++
                  @wait_fields ++
                  @checkpoint_fields ++
                  @validation_guard_fields ++
                  @execution_head_fields
              )

  @spec logger_metadata_fields() :: [atom()]
  def logger_metadata_fields, do: @all_fields

  @spec logger_metadata(map()) :: map()
  def logger_metadata(source) when is_map(source) do
    source
    |> runtime_payload()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, String.to_atom(key), value)
    end)
  end

  def logger_metadata(_source), do: %{}

  @spec runtime_payload(map()) :: map()
  def runtime_payload(source) when is_map(source) do
    %{}
    |> Map.merge(head_fields(source))
    |> Map.merge(wait_fields(source))
    |> Map.merge(continuation_fields(source))
    |> Map.merge(validation_guard_fields(source))
    |> Map.merge(budget_fields(source))
    |> Map.merge(retry_dedupe_fields(source))
    |> Map.merge(retry_failover_fields(source))
    |> Map.merge(failover_fields(source))
    |> Map.merge(cost_fields(source))
  end

  def runtime_payload(_source), do: %{}

  @spec checkpoint_payload(map(), String.t() | nil) :: map()
  def checkpoint_payload(checkpoint, origin \\ nil)

  @spec checkpoint_payload(map(), String.t() | nil) :: map()
  def checkpoint_payload(checkpoint, origin) when is_map(checkpoint) do
    fallback_reasons =
      (normalize_string_list(fetch(checkpoint, :checkpoint_fallback_reasons)) ++
         normalize_string_list(fetch(checkpoint, :fallback_reasons)))
      |> Enum.uniq()

    resume_ready = fetch(checkpoint, :resume_ready)
    pending_checks = fetch(checkpoint, :pending_checks)
    open_feedback = fetch(checkpoint, :open_feedback)
    resume_mode = derive_resume_mode(checkpoint, resume_ready)
    resume_fallback_reason = derive_resume_fallback_reason(checkpoint, resume_mode, fallback_reasons)

    quality =
      cond do
        fallback_reasons != [] -> "fallback"
        pending_checks == true or open_feedback == true -> "pending_review"
        resume_ready == true -> "ready"
        true -> "incomplete"
      end

    %{
      "checkpoint_quality" => quality,
      "checkpoint_origin" => normalize_string(fetch(checkpoint, :checkpoint_origin) || origin),
      "checkpoint_fallback_reasons" => fallback_reasons,
      "resume_mode" => resume_mode,
      "resume_fallback_reason" => resume_fallback_reason,
      "resume_ready" => resume_ready == true
    }
    |> reject_nil_values()
  end

  def checkpoint_payload(_checkpoint, _origin), do: %{}

  @spec validation_guard_payload(map()) :: map()
  def validation_guard_payload(source) when is_map(source) do
    %{
      "validation_guard_name" => normalize_string(fetch(source, :validation_guard_name) || fetch(source, :verification_profile)),
      "validation_guard_result" => normalize_string(fetch(source, :validation_guard_result) || fetch(source, :verification_result)),
      "validation_guard_reason" => normalize_string(fetch(source, :validation_guard_reason) || fetch(source, :verification_summary))
    }
    |> reject_nil_values()
  end

  def validation_guard_payload(_source), do: %{}

  @spec head_relation(term(), term()) :: String.t() | nil
  def head_relation(runtime_head_sha, expected_head_sha)
      when is_binary(runtime_head_sha) and runtime_head_sha != "" and is_binary(expected_head_sha) and
             expected_head_sha != "" do
    if runtime_head_sha == expected_head_sha, do: "match", else: "mismatch"
  end

  def head_relation(_runtime_head_sha, _expected_head_sha), do: nil

  @spec put_runtime_payload(map(), map()) :: map()
  def put_runtime_payload(map, source) when is_map(map) and is_map(source) do
    Map.merge(map, runtime_payload(source))
  end

  @spec put_checkpoint_payload(map(), map(), String.t() | nil) :: map()
  def put_checkpoint_payload(map, checkpoint, origin \\ nil)
      when is_map(map) and is_map(checkpoint) do
    Map.merge(map, checkpoint_payload(checkpoint, origin))
  end

  @spec put_validation_guard_payload(map(), map()) :: map()
  def put_validation_guard_payload(map, source) when is_map(map) and is_map(source) do
    Map.merge(map, validation_guard_payload(source))
  end

  defp cost_fields(source) do
    take_fields(source, @cost_fields)
  end

  defp budget_fields(source) do
    budget_current_cost_profile_key =
      fetch(source, :budget_current_cost_profile_key) || fetch(source, :current_cost_profile_key)

    budget_next_cost_profile_key =
      fetch(source, :budget_next_cost_profile_key) || fetch(source, :cost_profile_key)

    %{
      "budget_decision" => normalize_string(fetch(source, :budget_decision) || fetch(source, :decision)),
      "budget_reason" => normalize_string(fetch(source, :budget_reason) || fetch(source, :reason)),
      "budget_threshold" => fetch(source, :budget_threshold) || fetch(source, :threshold),
      "budget_observed_total" => fetch(source, :budget_observed_total) || fetch(source, :observed_total),
      "budget_attempt_tokens" => fetch(source, :budget_attempt_tokens) || fetch(source, :attempt_tokens),
      "budget_issue_total_tokens" => fetch(source, :budget_issue_total_tokens) || fetch(source, :issue_total_tokens),
      "budget_current_cost_profile_key" => normalize_string(budget_current_cost_profile_key),
      "budget_next_cost_profile_key" => normalize_string(budget_next_cost_profile_key),
      "budget_downshift_rule" => normalize_string(fetch(source, :budget_downshift_rule))
    }
    |> reject_nil_values()
  end

  defp retry_dedupe_fields(source) do
    error_signature = normalize_string(fetch(source, :error_signature))
    feedback_digest = normalize_string(fetch(source, :feedback_digest))
    runtime_head_sha = normalize_string(fetch(source, :runtime_head_sha))

    retry_key =
      normalize_string(fetch(source, :retry_dedupe_key)) ||
        if(error_signature && feedback_digest && runtime_head_sha,
          do: Enum.join([error_signature, runtime_head_sha, feedback_digest], "::")
        )

    %{
      "retry_dedupe_result" => normalize_string(fetch(source, :retry_dedupe_result)),
      "retry_dedupe_reason" => normalize_string(fetch(source, :retry_dedupe_reason)),
      "retry_dedupe_key" => retry_key,
      "error_signature" => error_signature,
      "feedback_digest" => feedback_digest
    }
    |> reject_nil_values()
  end

  defp retry_failover_fields(source) do
    decision = fetch(source, :retry_failover_decision)

    %{
      "retry_failover_selected_rule" =>
        normalize_string(
          fetch(source, :retry_failover_selected_rule) ||
            decision_field(decision, :selected_rule)
        ),
      "retry_failover_selected_action" =>
        normalize_string(
          fetch(source, :retry_failover_selected_action) ||
            decision_field(decision, :selected_action)
        ),
      "retry_failover_reason" => normalize_string(fetch(source, :retry_failover_reason) || decision_field(decision, :reason)),
      "retry_failover_suppressed_rules" =>
        normalize_nonempty_string_list(
          fetch(source, :retry_failover_suppressed_rules) ||
            decision_field(decision, :suppressed_rules)
        ),
      "retry_failover_checkpoint_type" =>
        normalize_string(
          fetch(source, :retry_failover_checkpoint_type) ||
            decision_field(decision, :checkpoint_type)
        ),
      "retry_failover_risk_level" =>
        normalize_string(
          fetch(source, :retry_failover_risk_level) ||
            decision_field(decision, :risk_level)
        )
    }
    |> reject_nil_values()
  end

  defp failover_fields(source) do
    %{
      "failover_decision" => normalize_string(fetch(source, :failover_decision)),
      "failover_reason" => normalize_string(fetch(source, :failover_reason)),
      "failover_from_account_id" => normalize_string(fetch(source, :failover_from_account_id)),
      "failover_to_account_id" => normalize_string(fetch(source, :failover_to_account_id))
    }
    |> reject_nil_values()
  end

  defp continuation_fields(source) do
    %{
      "continuation_reason" => normalize_string(fetch(source, :continuation_reason)),
      "resume_mode" => normalize_string(fetch(source, :resume_mode)),
      "resume_fallback_reason" => normalize_string(fetch(source, :resume_fallback_reason)),
      "auto_compaction_signal" => normalize_string(fetch(source, :auto_compaction_signal)),
      "auto_compaction_threshold" => fetch(source, :auto_compaction_threshold),
      "auto_compaction_observed_total" => fetch(source, :auto_compaction_observed_total)
    }
    |> reject_nil_values()
  end

  defp derive_resume_mode(checkpoint, resume_ready) do
    normalize_string(fetch(checkpoint, :resume_mode)) ||
      if(resume_ready == true, do: "resume_checkpoint", else: "fallback_reread")
  end

  defp derive_resume_fallback_reason(_checkpoint, "resume_checkpoint", _fallback_reasons), do: nil

  defp derive_resume_fallback_reason(checkpoint, _resume_mode, fallback_reasons) do
    normalize_fallback_reason(fetch(checkpoint, :resume_fallback_reason)) ||
      fallback_reasons
      |> List.first()
      |> normalize_fallback_reason() ||
      "checkpoint_not_ready"
  end

  defp normalize_fallback_reason(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    cond do
      trimmed == "" ->
        nil

      String.match?(trimmed, ~r/^[a-z0-9_]+$/) ->
        trimmed

      true ->
        infer_fallback_reason_code(trimmed)
    end
  end

  defp normalize_fallback_reason(_reason), do: nil

  defp infer_fallback_reason_code(reason) when is_binary(reason) do
    normalized = String.downcase(String.trim(reason))

    cond do
      String.starts_with?(normalized, "resume checkpoint is unavailable") ->
        "resume_checkpoint_unavailable"

      String.starts_with?(normalized, "workspace is unavailable for retry checkpoint capture") ->
        "workspace_unavailable"

      String.starts_with?(normalized, "resume checkpoint capture failed") ->
        "checkpoint_capture_failed"

      String.starts_with?(normalized, "resume checkpoint directory creation failed") or
          String.starts_with?(normalized, "resume checkpoint write failed") ->
        "checkpoint_persist_failed"

      String.contains?(normalized, " mismatch:") ->
        "checkpoint_mismatch"

      String.starts_with?(normalized, "missing ") ->
        "checkpoint_missing_required_field"

      true ->
        "checkpoint_not_ready"
    end
  end

  defp wait_fields(source) do
    run_phase = normalize_string(fetch(source, :run_phase))
    current_command = normalize_string(fetch(source, :current_command))
    external_step = normalize_string(fetch(source, :external_step))
    wait_mode = wait_mode_for_phase(run_phase)
    wait_source = wait_source(external_step, current_command, wait_mode)
    wait_tool = wait_tool(external_step, current_command)

    %{
      "wait_mode" => wait_mode,
      "wait_reason" => normalize_string(fetch(source, :wait_reason) || fetch(source, :operational_notice)),
      "wait_source" => wait_source,
      "wait_tool" => wait_tool
    }
    |> reject_nil_values()
  end

  defp validation_guard_fields(source), do: validation_guard_payload(source)

  defp head_fields(source) do
    runtime_head_sha = normalize_string(fetch(source, :runtime_head_sha))
    expected_head_sha = normalize_string(fetch(source, :expected_head_sha))

    %{
      "runtime_head_sha" => runtime_head_sha,
      "expected_head_sha" => expected_head_sha,
      "head_relation" => head_relation(runtime_head_sha, expected_head_sha)
    }
    |> reject_nil_values()
  end

  defp take_fields(source, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case fetch(source, field) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(field), normalize_value(value))
      end
    end)
  end

  defp reject_nil_values(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, normalize_value(value))
    end)
  end

  defp fetch(source, key) when is_map(source) and is_atom(key) do
    Map.get(source, key) || Map.get(source, Atom.to_string(key))
  end

  defp decision_field(decision, key) when is_map(decision) do
    Map.get(decision, key) || Map.get(decision, Atom.to_string(key))
  end

  defp decision_field(_decision, _key), do: nil

  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_boolean(value), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(value) when is_binary(value), do: [value]
  defp normalize_string_list(_value), do: []

  defp normalize_nonempty_string_list(values) do
    case normalize_string_list(values) do
      [] -> nil
      normalized -> normalized
    end
  end

  defp wait_mode_for_phase("waiting ci"), do: "ci"
  defp wait_mode_for_phase("waiting external"), do: "external"
  defp wait_mode_for_phase(_run_phase), do: nil

  defp wait_source(external_step, _current_command, _wait_mode) when external_step not in [nil, ""],
    do: "external_step"

  defp wait_source(_external_step, current_command, wait_mode)
       when current_command not in [nil, ""] and wait_mode != nil,
       do: "command"

  defp wait_source(_external_step, _current_command, _wait_mode), do: nil

  defp wait_tool("exec_wait", _current_command), do: "exec_wait"

  defp wait_tool(_external_step, current_command) when is_binary(current_command) do
    if String.contains?(current_command, "exec_wait"), do: "exec_wait"
  end

  defp wait_tool(_external_step, _current_command), do: nil
end
