defmodule SymphonyElixir.TelemetrySchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TelemetrySchema

  test "runtime_payload normalizes canonical flat decision keys" do
    payload =
      TelemetrySchema.runtime_payload(%{
        cost_profile_key: "cheap_implementation",
        cost_profile_reason: :budget_downshift,
        cost_stage: "implementation",
        cost_signals: [:retry],
        command_source: "cost_profile",
        budget_decision: "downshift",
        budget_reason: :max_tokens_per_attempt_exceeded,
        budget_threshold: 100,
        budget_observed_total: 125,
        budget_attempt_tokens: 125,
        budget_issue_total_tokens: 300,
        budget_next_cost_profile_key: "cheap_planning",
        retry_dedupe_result: "queued",
        retry_dedupe_reason: "new_surface",
        error_signature: "timeout",
        feedback_digest: "feedback-1",
        runtime_head_sha: "runtime-sha",
        expected_head_sha: "expected-sha",
        failover_decision: "switch_account",
        failover_reason: :account_unhealthy,
        failover_from_account_id: "primary",
        failover_to_account_id: "backup",
        run_phase: "waiting ci",
        wait_reason: :checks_pending,
        current_command: "github_wait_for_checks --poll",
        validation_guard_name: "review-ready",
        validation_guard_result: :passed,
        validation_guard_reason: "all required checks green"
      })

    assert payload == %{
             "budget_attempt_tokens" => 125,
             "budget_decision" => "downshift",
             "budget_issue_total_tokens" => 300,
             "budget_next_cost_profile_key" => "cheap_planning",
             "budget_observed_total" => 125,
             "budget_reason" => "max_tokens_per_attempt_exceeded",
             "budget_threshold" => 100,
             "command_source" => "cost_profile",
             "cost_profile_key" => "cheap_implementation",
             "cost_profile_reason" => "budget_downshift",
             "cost_signals" => ["retry"],
             "cost_stage" => "implementation",
             "error_signature" => "timeout",
             "expected_head_sha" => "expected-sha",
             "failover_decision" => "switch_account",
             "failover_from_account_id" => "primary",
             "failover_reason" => "account_unhealthy",
             "failover_to_account_id" => "backup",
             "feedback_digest" => "feedback-1",
             "head_relation" => "mismatch",
             "retry_dedupe_reason" => "new_surface",
             "retry_dedupe_result" => "queued",
             "retry_dedupe_key" => "timeout::runtime-sha::feedback-1",
             "runtime_head_sha" => "runtime-sha",
             "validation_guard_name" => "review-ready",
             "validation_guard_reason" => "all required checks green",
             "validation_guard_result" => "passed",
             "wait_mode" => "ci",
             "wait_reason" => "checks_pending",
             "wait_source" => "command"
           }
  end

  test "runtime_payload derives external wait metadata and omits incomplete retry dedupe key" do
    payload =
      TelemetrySchema.runtime_payload(%{
        run_phase: "waiting external",
        external_step: "human review",
        operational_notice: "waiting on review",
        runtime_head_sha: "same-sha",
        expected_head_sha: "same-sha",
        error_signature: "timeout"
      })

    assert payload["wait_mode"] == "external"
    assert payload["wait_reason"] == "waiting on review"
    assert payload["wait_source"] == "external_step"
    assert is_nil(payload["wait_tool"])
    assert payload["head_relation"] == "match"
    refute Map.has_key?(payload, "retry_dedupe_key")
  end

  test "runtime_payload normalizes legacy budget aliases for checkpoint readers" do
    assert TelemetrySchema.runtime_payload(%{
             "issue_total_tokens" => "42",
             "attempt_tokens" => 12,
             "cost_profile_key" => "cheap_implementation",
             "reason" => :max_tokens_per_attempt_exceeded,
             "decision" => :downshift
           }) == %{
             "budget_attempt_tokens" => 12,
             "budget_decision" => "downshift",
             "budget_issue_total_tokens" => "42",
             "budget_next_cost_profile_key" => "cheap_implementation",
             "budget_reason" => "max_tokens_per_attempt_exceeded",
             "cost_profile_key" => "cheap_implementation"
           }
  end

  test "checkpoint_payload computes canonical quality states" do
    assert TelemetrySchema.checkpoint_payload(%{"resume_ready" => true}, "resume_checkpoint") == %{
             "checkpoint_origin" => "resume_checkpoint",
             "checkpoint_quality" => "ready",
             "checkpoint_fallback_reasons" => [],
             "resume_ready" => true
           }

    assert TelemetrySchema.checkpoint_payload(
             %{"pending_checks" => true, "resume_ready" => false},
             "resume_checkpoint"
           ) == %{
             "checkpoint_origin" => "resume_checkpoint",
             "checkpoint_quality" => "pending_review",
             "checkpoint_fallback_reasons" => [],
             "resume_ready" => false
           }

    assert TelemetrySchema.checkpoint_payload(
             %{"fallback_reasons" => ["missing branch"], "resume_ready" => false},
             "resume_checkpoint"
           ) == %{
             "checkpoint_origin" => "resume_checkpoint",
             "checkpoint_quality" => "fallback",
             "checkpoint_fallback_reasons" => ["missing branch"],
             "resume_ready" => false
           }

    assert TelemetrySchema.checkpoint_payload(%{}, "resume_checkpoint") == %{
             "checkpoint_origin" => "resume_checkpoint",
             "checkpoint_quality" => "incomplete",
             "checkpoint_fallback_reasons" => [],
             "resume_ready" => false
           }
  end

  test "validation_guard_payload supports canonical and legacy keys" do
    assert TelemetrySchema.validation_guard_payload(%{
             verification_profile: "runtime",
             verification_result: "passed",
             verification_summary: "all checks green"
           }) == %{
             "validation_guard_name" => "runtime",
             "validation_guard_result" => "passed",
             "validation_guard_reason" => "all checks green"
           }

    assert TelemetrySchema.validation_guard_payload(%{
             validation_guard_name: "handoff",
             validation_guard_result: :failed,
             validation_guard_reason: "missing artifact"
           }) == %{
             "validation_guard_name" => "handoff",
             "validation_guard_result" => "failed",
             "validation_guard_reason" => "missing artifact"
           }
  end

  test "logger_metadata, put helpers, and empty inputs stay canonical" do
    metadata =
      TelemetrySchema.logger_metadata(%{
        budget_decision: "handoff",
        budget_reason: "max_total_tokens_exceeded",
        runtime_head_sha: "runtime-sha",
        expected_head_sha: "expected-sha"
      })

    assert metadata.budget_decision == "handoff"
    assert metadata.budget_reason == "max_total_tokens_exceeded"
    assert metadata.runtime_head_sha == "runtime-sha"
    assert metadata.expected_head_sha == "expected-sha"
    assert metadata.head_relation == "mismatch"

    assert TelemetrySchema.put_runtime_payload(%{"issue_id" => "LET-494"}, %{run_phase: "idle"}) ==
             %{"issue_id" => "LET-494"}

    assert TelemetrySchema.put_checkpoint_payload(%{}, %{"resume_ready" => true}, "resume_checkpoint") ==
             %{
               "checkpoint_origin" => "resume_checkpoint",
               "checkpoint_quality" => "ready",
               "checkpoint_fallback_reasons" => [],
               "resume_ready" => true
             }

    assert TelemetrySchema.put_validation_guard_payload(%{}, %{verification_profile: "runtime"}) ==
             %{"validation_guard_name" => "runtime"}

    assert TelemetrySchema.runtime_payload(nil) == %{}
    assert TelemetrySchema.checkpoint_payload(nil, "resume_checkpoint") == %{}
    assert TelemetrySchema.validation_guard_payload(nil) == %{}
    assert TelemetrySchema.logger_metadata(nil) == %{}
    assert TelemetrySchema.head_relation(nil, "expected") == nil
  end

  test "default arities and normalization edge cases stay canonical" do
    payload =
      TelemetrySchema.runtime_payload(%{
        "cost_signals" => [nil, :retry, true],
        "retry_dedupe_key" => "explicit-key",
        "error_signature" => "timeout",
        "feedback_digest" => "feedback-1",
        "runtime_head_sha" => "runtime-sha",
        "external_step" => "exec_wait",
        "wait_reason" => true,
        "current_command" => 123,
        "validation_guard_result" => true
      })

    assert payload["cost_signals"] == [nil, "retry", true]
    assert payload["retry_dedupe_key"] == "explicit-key"
    assert payload["wait_tool"] == "exec_wait"
    refute Map.has_key?(payload, "wait_reason")
    refute Map.has_key?(payload, "validation_guard_result")

    assert TelemetrySchema.checkpoint_payload(%{
             "checkpoint_origin" => "  ",
             "checkpoint_fallback_reasons" => "missing digest"
           }) == %{
             "checkpoint_quality" => "fallback",
             "checkpoint_fallback_reasons" => ["missing digest"],
             "resume_ready" => false
           }

    assert TelemetrySchema.put_checkpoint_payload(%{"issue_id" => "LET-494"}, %{
             "resume_ready" => false,
             "checkpoint_fallback_reasons" => ["missing head"]
           }) == %{
             "issue_id" => "LET-494",
             "checkpoint_quality" => "fallback",
             "checkpoint_fallback_reasons" => ["missing head"],
             "resume_ready" => false
           }
  end
end
