defmodule SymphonyElixir.ExecutionContract do
  @moduledoc """
  Execution contract helpers for policy/infra failure classification,
  remediation policy selection, and retry fingerprinting.
  """

  @type failure_class :: :policy_fail | :infra_fail
  @type remediation_policy :: :operator_required | :auto_retry_once | :pause_infra
  @type operator_state :: :open | :cooldown | :tripped | :paused_infra | :unknown
  @type one_shot_outcome :: :started | :succeeded | :failed | :skipped

  @infra_patterns [
    "rate limit",
    "ratelimited",
    "429",
    "502",
    "503",
    "504",
    "timeout",
    "timed out",
    "response_timeout",
    "connection reset",
    "connection refused",
    "service unavailable",
    "econnreset",
    "econnrefused",
    "eai_again",
    "enotfound"
  ]

  @policy_patterns [
    "workspace",
    "spec",
    "handoff",
    "contract",
    "manifest",
    "lock",
    "capability",
    "invalid_workspace",
    "approval_required",
    "turn_input_required",
    "acceptance"
  ]

  @pause_infra_patterns [
    "linear",
    "graphql",
    "rate limit",
    "ratelimited",
    "429",
    "502",
    "503",
    "504",
    "timeout",
    "timed out",
    "response_timeout"
  ]

  @auto_retry_policy_patterns [
    "stale lock",
    "stale_lock",
    "stale manifest",
    "stale_manifest",
    "missing proof metadata",
    "missing_proof_metadata"
  ]

  @spec failure_class(term()) :: failure_class()
  def failure_class(reason_or_reason_code) do
    reason_code = normalize_reason_code(reason_or_reason_code)

    cond do
      matches_any_pattern?(reason_code, @policy_patterns) ->
        :policy_fail

      linear_status_code = linear_api_status_code(reason_code) ->
        if linear_status_code == 429 or linear_status_code >= 500 do
          :infra_fail
        else
          :policy_fail
        end

      matches_any_pattern?(reason_code, @infra_patterns) ->
        :infra_fail

      true ->
        :policy_fail
    end
  end

  @spec remediation_policy(failure_class(), term()) :: remediation_policy()
  def remediation_policy(:infra_fail, reason_or_reason_code) do
    reason_code = normalize_reason_code(reason_or_reason_code)

    if matches_any_pattern?(reason_code, @pause_infra_patterns) do
      :pause_infra
    else
      :auto_retry_once
    end
  end

  def remediation_policy(:policy_fail, reason_or_reason_code) do
    reason_code = normalize_reason_code(reason_or_reason_code)

    if matches_any_pattern?(reason_code, @auto_retry_policy_patterns) do
      :auto_retry_once
    else
      :operator_required
    end
  end

  @spec retry_fingerprint_v1(map()) :: String.t()
  def retry_fingerprint_v1(context) when is_map(context) do
    issue_id = extract_context_value(context, [:issue_id, :issue_identifier, :issue, :issue_key], "unknown_issue")

    guard_layer =
      extract_context_value(context, [:guard_layer, :gate_layer, :layer, :guard], "unknown_guard")

    reason_code =
      extract_context_value(context, [:reason_code, :reason, :failure_reason, :error_code], "unknown_reason")

    artifact_revision =
      extract_context_value(context, [:artifact_revision, :spec_revision, :contract_revision, :revision], "unknown_artifact")

    payload = Enum.join([issue_id, guard_layer, reason_code, artifact_revision], "|")

    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  @spec classify_admission_failure(map()) :: map()
  def classify_admission_failure(%{} = payload) do
    reason_code =
      Map.get(payload, :reason_code) ||
        Map.get(payload, "reason_code") ||
        Map.get(payload, :reason) ||
        Map.get(payload, "reason")

    classify_admission_failure(reason_code, payload)
  end

  @spec classify_admission_failure(term(), map()) :: map()
  def classify_admission_failure(reason_or_reason_code, payload) when is_map(payload) do
    failure_class = failure_class(reason_or_reason_code)
    remediation_policy = remediation_policy(failure_class, reason_or_reason_code)

    operator_state =
      operator_state_for(
        failure_class,
        remediation_policy,
        Map.get(payload, :operator_state) ||
          Map.get(payload, "operator_state") ||
          Map.get(payload, :circuit_state) ||
          Map.get(payload, "circuit_state") ||
          Map.get(payload, :breaker_state) ||
          Map.get(payload, "breaker_state") ||
          Map.get(payload, :account_state) ||
          Map.get(payload, "account_state")
      )

    %{
      failure_class: failure_class,
      remediation_policy: remediation_policy,
      operator_state: operator_state,
      operator_matrix_row_id: operator_matrix_row_id(failure_class, remediation_policy, operator_state)
    }
  end

  @spec classify_admission_failure(term(), term()) :: map()
  def classify_admission_failure(reason_or_reason_code, _payload) do
    classify_admission_failure(reason_or_reason_code, %{})
  end

  @spec operator_state_for(term(), term(), term() | nil) :: operator_state()
  def operator_state_for(failure_class, remediation_policy, raw_state \\ nil) do
    normalized_failure_class = normalize_execution_failure_class(failure_class)
    normalized_policy = normalize_remediation_policy(remediation_policy)

    case normalize_operator_state(raw_state) do
      :unknown ->
        default_operator_state(normalized_failure_class, normalized_policy)

      state ->
        state
    end
  end

  @spec operator_matrix_row_id(term(), term(), term() | nil) :: String.t()
  def operator_matrix_row_id(failure_class, remediation_policy, operator_state \\ nil) do
    normalized_failure_class = normalize_execution_failure_class(failure_class)
    normalized_policy = normalize_remediation_policy(remediation_policy)
    normalized_operator_state = operator_state_for(normalized_failure_class, normalized_policy, operator_state)

    case {normalized_failure_class, normalized_policy, normalized_operator_state} do
      {:policy_fail, :operator_required, _state} ->
        "opm_v1_policy_fix"

      {:infra_fail, :auto_retry_once, :open} ->
        "opm_v1_infra_retry_open"

      {:infra_fail, :auto_retry_once, :cooldown} ->
        "opm_v1_infra_retry_cooldown"

      {:infra_fail, :pause_infra, operator_state} when operator_state in [:tripped, :paused_infra] ->
        "opm_v1_infra_pause"

      _other ->
        "opm_v1_unmapped"
    end
  end

  @spec retry_budget_status(map(), String.t(), integer(), pos_integer()) :: :open | :cooldown
  def retry_budget_status(ledger, fingerprint, now_ms, ttl_ms)
      when is_map(ledger) and is_binary(fingerprint) and is_integer(now_ms) and is_integer(ttl_ms) and ttl_ms > 0 do
    case Map.get(ledger, fingerprint) do
      nil ->
        :open

      entry ->
        if now_ms >= entry_value(entry, :expires_at_ms, now_ms + ttl_ms), do: :open, else: :cooldown
    end
  end

  @spec open_retry_budget_attempt(map(), String.t(), integer(), pos_integer()) ::
          {map(), %{status: :opened | :cooldown, attempt_index: non_neg_integer(), expires_at_ms: integer()}}
  def open_retry_budget_attempt(ledger, fingerprint, now_ms, ttl_ms)
      when is_map(ledger) and is_binary(fingerprint) and is_integer(now_ms) and is_integer(ttl_ms) and ttl_ms > 0 do
    existing = Map.get(ledger, fingerprint)

    case retry_budget_status(ledger, fingerprint, now_ms, ttl_ms) do
      :cooldown ->
        attempt_index = entry_value(existing, :attempt_index, 0)
        expires_at_ms = entry_value(existing, :expires_at_ms, now_ms + ttl_ms)
        {ledger, %{status: :cooldown, attempt_index: attempt_index, expires_at_ms: expires_at_ms}}

      :open ->
        next_attempt_index = entry_value(existing, :attempt_index, 0) + 1
        expires_at_ms = now_ms + ttl_ms

        next_entry = %{
          attempt_index: next_attempt_index,
          opened_at_ms: now_ms,
          expires_at_ms: expires_at_ms,
          outcome: :started,
          outcome_at_ms: now_ms
        }

        {Map.put(ledger, fingerprint, next_entry),
         %{status: :opened, attempt_index: next_attempt_index, expires_at_ms: expires_at_ms}}
    end
  end

  @spec record_retry_budget_outcome(map(), String.t(), term(), integer()) :: map()
  def record_retry_budget_outcome(ledger, fingerprint, outcome, now_ms)
      when is_map(ledger) and is_binary(fingerprint) and is_integer(now_ms) do
    case Map.get(ledger, fingerprint) do
      nil ->
        ledger

      entry ->
        normalized_outcome = normalize_retry_outcome(outcome)

        Map.put(
          ledger,
          fingerprint,
          entry
          |> Map.new()
          |> Map.put(:outcome, normalized_outcome)
          |> Map.put(:outcome_at_ms, now_ms)
        )
    end
  end

  defp extract_context_value(context, keys, fallback) do
    keys
    |> Enum.find_value(fn key ->
      atom_value = Map.get(context, key)
      string_value = Map.get(context, Atom.to_string(key))
      coalesce_context_value(atom_value || string_value)
    end)
    |> case do
      nil -> fallback
      value -> value
    end
  end

  defp coalesce_context_value(nil), do: nil

  defp coalesce_context_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp coalesce_context_value(value) when is_atom(value), do: Atom.to_string(value)
  defp coalesce_context_value(value) when is_integer(value), do: Integer.to_string(value)

  defp coalesce_context_value(value) do
    value
    |> inspect(pretty: false, limit: 30, printable_limit: 2_000)
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp normalize_reason_code(reason_or_reason_code) do
    reason_or_reason_code
    |> reason_code_source()
    |> coalesce_context_value()
    |> case do
      nil -> ""
      text -> String.downcase(text)
    end
  end

  defp reason_code_source(%{} = payload) do
    extract_context_value(
      payload,
      [:reason_code, :reason, :failure_reason, :error_code, :summary, :message],
      inspect(payload, pretty: false, limit: 20, printable_limit: 1_000)
    )
  end

  defp reason_code_source({reason_code, status}) when is_atom(reason_code) and is_integer(status) do
    "#{Atom.to_string(reason_code)}_#{status}"
  end

  defp reason_code_source({reason_code, _details}) when is_atom(reason_code) do
    Atom.to_string(reason_code)
  end

  defp reason_code_source(reason_or_reason_code), do: reason_or_reason_code

  defp normalize_execution_failure_class(value) when value in [:policy_fail, "policy_fail", :policy, "policy"],
    do: :policy_fail

  defp normalize_execution_failure_class(value) when value in [:infra_fail, "infra_fail", :infra, "infra"],
    do: :infra_fail

  defp normalize_execution_failure_class(_value), do: :policy_fail

  defp normalize_remediation_policy(value)
       when value in [:operator_required, "operator_required", :operator, "operator"],
       do: :operator_required

  defp normalize_remediation_policy(value)
       when value in [:auto_retry_once, "auto_retry_once", :retry_once, "retry_once"],
       do: :auto_retry_once

  defp normalize_remediation_policy(value)
       when value in [:pause_infra, "pause_infra", :pause, "pause"],
       do: :pause_infra

  defp normalize_remediation_policy(_value), do: :operator_required

  defp normalize_operator_state(value) when value in [:open, "open"], do: :open
  defp normalize_operator_state(value) when value in [:cooldown, "cooldown"], do: :cooldown
  defp normalize_operator_state(value) when value in [:tripped, "tripped"], do: :tripped
  defp normalize_operator_state(value) when value in [:paused_infra, "paused_infra"], do: :paused_infra
  defp normalize_operator_state(_value), do: :unknown

  defp default_operator_state(:infra_fail, :pause_infra), do: :tripped
  defp default_operator_state(_failure_class, _remediation_policy), do: :open

  defp entry_value(nil, _key, default), do: default

  defp entry_value(entry, key, default) when is_map(entry) do
    string_key = Atom.to_string(key)
    Map.get(entry, key, Map.get(entry, string_key, default))
  end

  defp normalize_retry_outcome(value) when value in [:started, :succeeded, :failed, :skipped], do: value
  defp normalize_retry_outcome("started"), do: :started
  defp normalize_retry_outcome("succeeded"), do: :succeeded
  defp normalize_retry_outcome("failed"), do: :failed
  defp normalize_retry_outcome("skipped"), do: :skipped
  defp normalize_retry_outcome(_value), do: :failed

  defp linear_api_status_code(reason_code) when is_binary(reason_code) do
    case Regex.run(~r/linear_api_status_(\d{3})/, reason_code) do
      [_, status] ->
        case Integer.parse(status) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp linear_api_status_code(_reason_code), do: nil

  defp matches_any_pattern?(text, patterns) when is_binary(text) do
    Enum.any?(patterns, &String.contains?(text, &1))
  end
end
