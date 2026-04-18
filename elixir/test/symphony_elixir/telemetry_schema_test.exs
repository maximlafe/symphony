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
        codex_model: "gpt-5.3-codex",
        codex_effort: :medium,
        observed_model: "gpt-5.4",
        observed_effort: :high,
        observed_signal_source: :payload,
        routing_parity_status: "mismatch",
        routing_parity_reason: "model expected=gpt-5.3-codex observed=gpt-5.4; effort expected=medium observed=high",
        budget_decision: "downshift",
        budget_reason: :max_tokens_per_attempt_exceeded,
        budget_threshold: 100,
        budget_observed_total: 125,
        budget_attempt_tokens: 125,
        budget_issue_total_tokens: 300,
        budget_current_cost_profile_key: "escalated_implementation",
        budget_next_cost_profile_key: "cheap_planning",
        budget_downshift_rule: "rework_to_implementation_default",
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
        retry_failover_decision: %{
          selected_rule: "retry_dedupe_hit",
          selected_action: :stop_with_classified_handoff,
          reason: "identical retry surface",
          suppressed_rules: [:budget_exceeded_per_attempt_downshift],
          checkpoint_type: "human-action",
          risk_level: :medium
        },
        resume_mode: :fallback_reread,
        resume_fallback_reason: "resume_checkpoint_unavailable",
        run_phase: "waiting ci",
        wait_reason: :checks_pending,
        current_command: "github_wait_for_checks --poll",
        validation_guard_name: "review-ready",
        validation_guard_result: :passed,
        validation_guard_reason: "all required checks green"
      })

    assert payload == %{
             "budget_attempt_tokens" => 125,
             "budget_current_cost_profile_key" => "escalated_implementation",
             "budget_decision" => "downshift",
             "budget_downshift_rule" => "rework_to_implementation_default",
             "budget_issue_total_tokens" => 300,
             "budget_next_cost_profile_key" => "cheap_planning",
             "budget_observed_total" => 125,
             "budget_reason" => "max_tokens_per_attempt_exceeded",
             "budget_threshold" => 100,
             "codex_effort" => "medium",
             "codex_model" => "gpt-5.3-codex",
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
             "observed_effort" => "high",
             "observed_model" => "gpt-5.4",
             "observed_signal_source" => "payload",
             "retry_dedupe_reason" => "new_surface",
             "retry_dedupe_result" => "queued",
             "retry_dedupe_key" => "timeout::runtime-sha::feedback-1",
             "runtime_head_sha" => "runtime-sha",
             "routing_parity_reason" => "model expected=gpt-5.3-codex observed=gpt-5.4; effort expected=medium observed=high",
             "routing_parity_status" => "mismatch",
             "retry_failover_checkpoint_type" => "human-action",
             "retry_failover_reason" => "identical retry surface",
             "retry_failover_risk_level" => "medium",
             "retry_failover_selected_action" => "stop_with_classified_handoff",
             "retry_failover_selected_rule" => "retry_dedupe_hit",
             "retry_failover_suppressed_rules" => ["budget_exceeded_per_attempt_downshift"],
             "loop_break_triggered" => true,
             "loop_break_reason" => "retry_dedupe_hit",
             "resume_fallback_reason" => "resume_checkpoint_unavailable",
             "resume_mode" => "fallback_reread",
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
             "resume_mode" => "resume_checkpoint",
             "resume_ready" => true
           }

    assert TelemetrySchema.checkpoint_payload(
             %{"pending_checks" => true, "resume_ready" => false},
             "resume_checkpoint"
           ) == %{
             "checkpoint_origin" => "resume_checkpoint",
             "checkpoint_quality" => "pending_review",
             "checkpoint_fallback_reasons" => [],
             "resume_fallback_reason" => "checkpoint_not_ready",
             "resume_mode" => "fallback_reread",
             "resume_ready" => false
           }

    assert TelemetrySchema.checkpoint_payload(
             %{"fallback_reasons" => ["missing `branch` in resume checkpoint"], "resume_ready" => false},
             "resume_checkpoint"
           ) == %{
             "checkpoint_origin" => "resume_checkpoint",
             "checkpoint_quality" => "fallback",
             "checkpoint_fallback_reasons" => ["missing `branch` in resume checkpoint"],
             "resume_fallback_reason" => "checkpoint_missing_required_field",
             "resume_mode" => "fallback_reread",
             "resume_ready" => false
           }

    assert TelemetrySchema.checkpoint_payload(%{}, "resume_checkpoint") == %{
             "checkpoint_origin" => "resume_checkpoint",
             "checkpoint_quality" => "incomplete",
             "checkpoint_fallback_reasons" => [],
             "resume_fallback_reason" => "checkpoint_not_ready",
             "resume_mode" => "fallback_reread",
             "resume_ready" => false
           }
  end

  test "checkpoint_payload infers fallback reason codes for all known textual causes" do
    cases = [
      {"resume checkpoint is unavailable", "resume_checkpoint_unavailable"},
      {"workspace is unavailable for retry checkpoint capture", "workspace_unavailable"},
      {"resume checkpoint capture failed: boom", "checkpoint_capture_failed"},
      {"resume checkpoint directory creation failed: :eperm", "checkpoint_persist_failed"},
      {"resume checkpoint write failed: :eperm", "checkpoint_persist_failed"},
      {"resume checkpoint `head` mismatch: expected `abc`, current `def`", "checkpoint_mismatch"},
      {"missing `branch` in resume checkpoint", "checkpoint_missing_required_field"},
      {"unmapped fallback text", "checkpoint_not_ready"}
    ]

    for {reason, expected_code} <- cases do
      payload =
        TelemetrySchema.checkpoint_payload(
          %{"resume_ready" => false, "fallback_reasons" => [reason]},
          "resume_checkpoint"
        )

      assert payload["resume_mode"] == "fallback_reread"
      assert payload["resume_fallback_reason"] == expected_code
    end
  end

  test "checkpoint_payload prefers explicit machine-readable fallback reason and ignores fallback reason when resume is ready" do
    explicit_payload =
      TelemetrySchema.checkpoint_payload(
        %{
          "resume_ready" => false,
          "resume_fallback_reason" => "custom_machine_code",
          "fallback_reasons" => ["missing branch"]
        },
        "resume_checkpoint"
      )

    assert explicit_payload["resume_fallback_reason"] == "custom_machine_code"
    assert explicit_payload["resume_mode"] == "fallback_reread"

    blank_override_payload =
      TelemetrySchema.checkpoint_payload(
        %{
          "resume_ready" => false,
          "resume_fallback_reason" => "   ",
          "fallback_reasons" => ["resume checkpoint capture failed: boom"]
        },
        "resume_checkpoint"
      )

    assert blank_override_payload["resume_fallback_reason"] == "checkpoint_capture_failed"

    ready_payload =
      TelemetrySchema.checkpoint_payload(
        %{
          "resume_ready" => true,
          "resume_mode" => "resume_checkpoint",
          "resume_fallback_reason" => "should_be_ignored"
        },
        "resume_checkpoint"
      )

    assert ready_payload["resume_mode"] == "resume_checkpoint"
    refute Map.has_key?(ready_payload, "resume_fallback_reason")
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

  test "runtime_payload reads retry/failover decision aliases from flat keys or nested metadata" do
    assert TelemetrySchema.runtime_payload(%{
             retry_failover_selected_rule: :stale_workspace_head,
             retry_failover_selected_action: "stop_with_classified_handoff",
             retry_failover_reason: "workspace behind expected head",
             retry_failover_suppressed_rules: [:account_unhealthy_checkpoint_available],
             retry_failover_checkpoint_type: :human_action,
             retry_failover_risk_level: "high"
           }) == %{
             "retry_failover_checkpoint_type" => "human_action",
             "retry_failover_reason" => "workspace behind expected head",
             "retry_failover_risk_level" => "high",
             "retry_failover_selected_action" => "stop_with_classified_handoff",
             "retry_failover_selected_rule" => "stale_workspace_head",
             "retry_failover_suppressed_rules" => ["account_unhealthy_checkpoint_available"]
           }
  end

  test "runtime_payload includes lifecycle and replacement relation fields" do
    assert TelemetrySchema.runtime_payload(%{
             lifecycle_state: "replacing",
             replacement_of_session_id: "thread-old",
             replacement_session_id: "thread-new",
             continuation_reason: "normal_exit"
           }) == %{
             "continuation_reason" => "normal_exit",
             "lifecycle_state" => "replacing",
             "replacement_of_session_id" => "thread-old",
             "replacement_session_id" => "thread-new"
           }
  end

  test "runtime_payload derives continuation attempt and loop-break fields for continuation retries" do
    assert TelemetrySchema.runtime_payload(%{
             retry_delay_type: :continuation,
             retry_attempt: 3,
             continuation_reason: "normal_exit",
             retry_failover_decision: %{
               selected_rule: "retry_dedupe_hit",
               selected_action: "stop_with_classified_handoff",
               reason: "retry_dedupe_hit"
             }
           }) == %{
             "continuation_attempt" => 3,
             "continuation_reason" => "normal_exit",
             "loop_break_reason" => "retry_dedupe_hit",
             "loop_break_triggered" => true,
             "retry_failover_reason" => "retry_dedupe_hit",
             "retry_failover_selected_action" => "stop_with_classified_handoff",
             "retry_failover_selected_rule" => "retry_dedupe_hit"
           }
  end

  test "runtime_payload derives terminal loop-break proof from continuation attempt limit decisions" do
    payload =
      TelemetrySchema.runtime_payload(%{
        retry_failover_decision: %{
          selected_rule: "continuation_attempt_limit_exceeded",
          selected_action: "stop_with_classified_handoff",
          reason: "continuation_attempt_limit_exceeded",
          retry_metadata: %{
            continuation_reason: "auto_compaction"
          },
          signals: %{
            continuation_attempt_limit: %{
              continuation_attempt: 4
            }
          }
        }
      })

    assert payload["continuation_attempt"] == 4
    assert payload["continuation_reason"] == "auto_compaction"
    assert payload["loop_break_triggered"] == true
    assert payload["loop_break_reason"] == "continuation_attempt_limit_exceeded"
  end

  test "runtime_payload does not emit loop-break fields for non-continuation active runs" do
    payload =
      TelemetrySchema.runtime_payload(%{
        lifecycle_state: "attached",
        replacement_session_id: "thread-1",
        retry_failover_decision: %{
          selected_rule: "retry_dedupe_hit",
          selected_action: "stop_with_classified_handoff",
          reason: "retry_dedupe_hit"
        }
      })

    assert payload["lifecycle_state"] == "attached"
    assert payload["replacement_session_id"] == "thread-1"
    refute Map.has_key?(payload, "loop_break_triggered")
    refute Map.has_key?(payload, "loop_break_reason")
  end

  test "runtime_payload preserves explicit continuation and loop-break overrides" do
    payload =
      TelemetrySchema.runtime_payload(%{
        "continuation_attempt" => 2,
        "continuation_reason" => "manual_retry",
        "loop_break_triggered" => false,
        "loop_break_reason" => "manual_override",
        "retry_failover_selected_rule" => "retry_dedupe_hit"
      })

    assert payload["continuation_attempt"] == 2
    assert payload["continuation_reason"] == "manual_retry"
    assert payload["loop_break_triggered"] == false
    assert payload["loop_break_reason"] == "manual_override"
  end

  test "runtime_payload keeps continuation context without loop-break on allow rules" do
    payload =
      TelemetrySchema.runtime_payload(%{
        delay_type: "continuation",
        attempt: 2,
        continuation_reason: "normal_exit",
        retry_failover_selected_rule: "default_allow_retry"
      })

    assert payload["continuation_attempt"] == 2
    assert payload["continuation_reason"] == "normal_exit"
    refute Map.has_key?(payload, "loop_break_triggered")
    refute Map.has_key?(payload, "loop_break_reason")
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
               "resume_mode" => "resume_checkpoint",
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
             "resume_fallback_reason" => "checkpoint_missing_required_field",
             "resume_mode" => "fallback_reread",
             "resume_ready" => false
           }

    assert TelemetrySchema.put_checkpoint_payload(%{"issue_id" => "LET-494"}, %{
             "resume_ready" => false,
             "checkpoint_fallback_reasons" => ["missing head"]
           }) == %{
             "issue_id" => "LET-494",
             "checkpoint_quality" => "fallback",
             "checkpoint_fallback_reasons" => ["missing head"],
             "resume_fallback_reason" => "checkpoint_missing_required_field",
             "resume_mode" => "fallback_reread",
             "resume_ready" => false
           }
  end
end
