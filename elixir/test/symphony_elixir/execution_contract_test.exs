defmodule SymphonyElixir.ExecutionContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionContract

  test "failure_class prioritizes policy tokens and classifies linear status families" do
    assert ExecutionContract.failure_class("workspace contract violation") == :policy_fail
    assert ExecutionContract.failure_class("linear_api_status_429") == :infra_fail
    assert ExecutionContract.failure_class("linear_api_status_503") == :infra_fail
    assert ExecutionContract.failure_class("linear_api_status_400") == :policy_fail
    assert ExecutionContract.failure_class({:response_timeout}) == :infra_fail
    assert ExecutionContract.failure_class(nil) == :policy_fail
    assert ExecutionContract.failure_class(:novel_reason) == :policy_fail
  end

  test "remediation_policy follows pause and operator rules by class" do
    assert ExecutionContract.remediation_policy(:infra_fail, "graphql timeout 429") == :pause_infra
    assert ExecutionContract.remediation_policy(:infra_fail, "socket hiccup") == :auto_retry_once
    assert ExecutionContract.remediation_policy(:policy_fail, "missing proof metadata in handoff") == :operator_required
    assert ExecutionContract.remediation_policy(:policy_fail, "missing make target") == :operator_required
  end

  test "classify_admission_failure normalizes payload and defaults with non-map input" do
    classified =
      ExecutionContract.classify_admission_failure(%{
        "reason_code" => "connection reset by peer",
        "operator_state" => "cooldown"
      })

    assert classified.failure_class == :infra_fail
    assert classified.remediation_policy == :auto_retry_once
    assert classified.operator_state == :cooldown
    assert classified.operator_matrix_row_id == "opm_v1_infra_retry_cooldown"

    fallback = ExecutionContract.classify_admission_failure("unknown reason", :ignored_payload)
    assert fallback.failure_class == :policy_fail
    assert fallback.remediation_policy == :operator_required
    assert fallback.operator_state == :open
  end

  test "classify_admission_failure extracts atom and reason fallback keys" do
    from_atom_key =
      ExecutionContract.classify_admission_failure(%{
        reason_code: "linear_api_status_429",
        operator_state: :tripped
      })

    assert from_atom_key.failure_class == :infra_fail
    assert from_atom_key.operator_state == :tripped
    assert from_atom_key.operator_matrix_row_id == "opm_v1_infra_pause"

    from_reason_atom =
      ExecutionContract.classify_admission_failure(%{
        "operator_state" => "open",
        reason: "workspace missing"
      })

    assert from_reason_atom.failure_class == :policy_fail
    assert from_reason_atom.remediation_policy == :operator_required

    from_reason_string =
      ExecutionContract.classify_admission_failure(%{
        "reason" => "turn_input_required from approval step"
      })

    assert from_reason_string.failure_class == :policy_fail
  end

  test "operator_state_for and operator_matrix_row_id normalize aliases and unknowns" do
    assert ExecutionContract.operator_state_for(:infra_fail, :pause_infra) == :tripped
    assert ExecutionContract.operator_state_for("policy", "operator_required") == :open
    assert ExecutionContract.operator_state_for(:infra_fail, :pause_infra, nil) == :tripped
    assert ExecutionContract.operator_state_for("infra", "retry_once", "open") == :open
    assert ExecutionContract.operator_state_for(:policy, :operator, :unknown_value) == :open
    assert ExecutionContract.operator_state_for(:unknown, :unknown, nil) == :open

    assert ExecutionContract.operator_matrix_row_id(:policy_fail, :operator_required) == "opm_v1_policy_fix"
    assert ExecutionContract.operator_matrix_row_id("policy", "operator", :open) == "opm_v1_policy_fix"
    assert ExecutionContract.operator_matrix_row_id("infra", "pause", :paused_infra) == "opm_v1_infra_pause"
    assert ExecutionContract.operator_matrix_row_id("infra", "retry_once", :cooldown) == "opm_v1_infra_retry_cooldown"
    assert ExecutionContract.operator_matrix_row_id("infra", "retry_once", :tripped) == "opm_v1_unmapped"
  end

  test "retry_fingerprint_v1 coalesces alternative keys and non-string values" do
    fp1 =
      ExecutionContract.retry_fingerprint_v1(%{
        issue_identifier: :LET_700,
        gate_layer: "handoff_guard",
        failure_reason: 429,
        revision: %{sha: "abc"}
      })

    fp2 =
      ExecutionContract.retry_fingerprint_v1(%{
        issue_key: "LET_700",
        guard: "handoff_guard",
        error_code: "429",
        artifact_revision: "%{sha: \"abc\"}"
      })

    assert is_binary(fp1)
    assert String.length(fp1) == 64
    assert fp1 == fp2

    fallback_fp =
      ExecutionContract.retry_fingerprint_v1(%{
        issue_id: "   ",
        guard_layer: "   ",
        reason_code: "   ",
        artifact_revision: "   "
      })

    assert is_binary(fallback_fp)
    assert String.length(fallback_fp) == 64
  end

  test "retry budget status/open/outcome handles nil, cooldown, expiry and unknown outcomes" do
    fingerprint = "fp"
    ttl_ms = 1_000

    assert ExecutionContract.retry_budget_status(%{}, fingerprint, 10, ttl_ms) == :open

    {ledger, opened} = ExecutionContract.open_retry_budget_attempt(%{}, fingerprint, 10, ttl_ms)
    assert opened.status == :opened
    assert opened.attempt_index == 1
    assert opened.attempt_count == 1
    assert ExecutionContract.retry_budget_status(ledger, fingerprint, 100, ttl_ms) == :cooldown
    assert get_in(ledger, [fingerprint, :fingerprint_version]) == "retry_fingerprint_v1"
    assert get_in(ledger, [fingerprint, :fingerprint_ttl_sec]) == 1
    assert get_in(ledger, [fingerprint, :first_seen_at_ms]) == 10
    assert get_in(ledger, [fingerprint, :last_seen_at_ms]) == 10
    assert get_in(ledger, [fingerprint, :attempt_count]) == 1

    {same_ledger, cooldown} = ExecutionContract.open_retry_budget_attempt(ledger, fingerprint, 100, ttl_ms)
    assert cooldown.status == :cooldown
    assert cooldown.attempt_count == 1
    assert same_ledger == ledger

    outcome_missing =
      ExecutionContract.record_retry_budget_outcome(%{}, fingerprint, :succeeded, 150)

    assert outcome_missing == %{}

    with_outcome =
      ExecutionContract.record_retry_budget_outcome(
        ledger,
        fingerprint,
        "succeeded",
        150
      )

    assert get_in(with_outcome, [fingerprint, :outcome]) == :succeeded
    assert get_in(with_outcome, [fingerprint, :outcome_at_ms]) == 150
    assert get_in(with_outcome, [fingerprint, :last_seen_at_ms]) == 150

    with_fallback =
      ExecutionContract.record_retry_budget_outcome(
        with_outcome,
        fingerprint,
        :unknown_outcome,
        200
      )

    assert get_in(with_fallback, [fingerprint, :outcome]) == :failed

    with_started = ExecutionContract.record_retry_budget_outcome(with_fallback, fingerprint, "started", 210)
    assert get_in(with_started, [fingerprint, :outcome]) == :started

    with_failed = ExecutionContract.record_retry_budget_outcome(with_started, fingerprint, "failed", 220)
    assert get_in(with_failed, [fingerprint, :outcome]) == :failed

    with_skipped = ExecutionContract.record_retry_budget_outcome(with_failed, fingerprint, "skipped", 230)
    assert get_in(with_skipped, [fingerprint, :outcome]) == :skipped

    {reopened_ledger, reopened} =
      ExecutionContract.open_retry_budget_attempt(with_skipped, fingerprint, 2_000, ttl_ms)

    assert reopened.status == :opened
    assert reopened.attempt_index == 1
    assert reopened.attempt_count == 1
    assert get_in(reopened_ledger, [fingerprint, :first_seen_at_ms]) == 2_000
    assert get_in(reopened_ledger, [fingerprint, :last_seen_at_ms]) == 2_000
    assert ExecutionContract.retry_budget_status(reopened_ledger, fingerprint, 2_001, ttl_ms) == :cooldown
  end

  test "tuple reason sources cover atom-status and atom-detail branches" do
    assert ExecutionContract.failure_class({:linear_api_status, 429}) == :infra_fail
    assert ExecutionContract.failure_class({:timeout, %{context: :api}}) == :infra_fail
  end

  test "unicode digits in linear status path fall back to policy classification" do
    # Arabic-Indic digits match \\d in regex but Integer.parse/1 cannot parse them.
    assert ExecutionContract.failure_class("linear_api_status_٤٢٩") == :policy_fail
  end
end
