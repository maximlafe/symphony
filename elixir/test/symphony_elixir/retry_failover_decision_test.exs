defmodule SymphonyElixir.RetryFailoverDecisionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RetryFailoverDecision

  test "retry dedupe remains a hard stop over weaker alternatives" do
    decision =
      RetryFailoverDecision.decide(%{
        retry_dedupe_hit: %{reason: "retry_dedupe_hit"},
        account_unhealthy: %{reason: "quota exhausted"},
        checkpoint_available: true
      })

    assert decision.selected_rule == :retry_dedupe_hit
    assert decision.selected_action == :stop_with_classified_handoff
    assert decision.suppressed_rules == [:account_unhealthy_checkpoint_available]
    assert decision.checkpoint_type == "human-action"
    assert decision.risk_level == "medium"
  end

  test "stale workspace head wins over account failover" do
    decision =
      RetryFailoverDecision.decide(%{
        stale_workspace_head: %{reason: "stale_workspace_head"},
        account_unhealthy: %{reason: "account_unhealthy"},
        checkpoint_available: true
      })

    assert decision.selected_rule == :stale_workspace_head
    assert decision.selected_action == :stop_with_classified_handoff
    assert decision.suppressed_rules == [:account_unhealthy_checkpoint_available]
  end

  test "continuation attempt limit triggers classified decision handoff" do
    decision =
      RetryFailoverDecision.decide(%{
        continuation_attempt_limit: %{
          reason: "continuation_attempt_limit_exceeded",
          checkpoint_type: "decision",
          risk_level: "medium",
          retry_metadata: %{max_continuation_attempts: 3, continuation_attempt: 4},
          log_fields: %{continuation_reason: "continuation"}
        }
      })

    assert decision.selected_rule == :continuation_attempt_limit_exceeded
    assert decision.selected_action == :stop_with_classified_handoff
    assert decision.reason == "continuation_attempt_limit_exceeded"
    assert decision.checkpoint_type == "decision"
    assert decision.risk_level == "medium"
    assert decision.retry_metadata == %{max_continuation_attempts: 3, continuation_attempt: 4}
    assert decision.log_fields.continuation_reason == "continuation"
  end

  test "validation environment mismatch blocks retry" do
    decision =
      RetryFailoverDecision.decide(%{
        validation_env_mismatch: %{reason: "validation_env_mismatch"},
        account_unhealthy: %{reason: "quota exhausted"},
        checkpoint_available: true
      })

    assert decision.selected_rule == :validation_env_mismatch
    assert decision.selected_action == :stop_with_classified_handoff
    assert decision.suppressed_rules == [:account_unhealthy_checkpoint_available]
    assert decision.checkpoint_type == "human-action"
  end

  test "account unhealthy with milestone near drains instead of preempting" do
    decision =
      RetryFailoverDecision.decide(%{
        account_unhealthy: %{reason: "quota exhausted"},
        checkpoint_available: true,
        milestone_near: true
      })

    assert decision.selected_rule == :account_unhealthy_milestone_near
    assert decision.selected_action == :drain_to_milestone
    assert decision.suppressed_rules == [:account_unhealthy_checkpoint_available]
  end

  test "unsafe preemption remains absolute even near a milestone" do
    decision =
      RetryFailoverDecision.decide(%{
        unsafe_preemption_required: %{reason: "unsafe_preemption_required"},
        account_unhealthy: %{reason: "quota exhausted"},
        checkpoint_available: true,
        milestone_near: true
      })

    assert decision.selected_rule == :unsafe_preemption_required
    assert decision.selected_action == :immediate_preemption

    assert decision.suppressed_rules == [
             :account_unhealthy_milestone_near,
             :account_unhealthy_checkpoint_available
           ]
  end

  test "account unhealthy without checkpoint availability preempts immediately" do
    decision =
      RetryFailoverDecision.decide(%{
        account_unhealthy: %{reason: "quota exhausted"},
        checkpoint_available: false,
        milestone_near: false
      })

    assert decision.selected_rule == :account_unhealthy_no_checkpoint
    assert decision.selected_action == :immediate_preemption
    assert decision.checkpoint_type == "human-action"
    assert decision.risk_level == "high"
  end

  test "account unhealthy with checkpoint available checkpoints and fails over" do
    decision =
      RetryFailoverDecision.decide(%{
        account_unhealthy: %{reason: "quota exhausted"},
        checkpoint_available: true,
        milestone_near: false
      })

    assert decision.selected_rule == :account_unhealthy_checkpoint_available
    assert decision.selected_action == :checkpoint_and_failover
    assert decision.reason == "quota exhausted"
  end

  test "unknown legacy signal is ignored and does not affect routing" do
    assert RetryFailoverDecision.decide(%{legacy_guardrail: :active}).selected_rule ==
             :default_allow_retry

    decision =
      RetryFailoverDecision.decide(%{
        "legacy_guardrail" => %{"reason" => "legacy_guardrail"},
        "retry_dedupe_hit" => %{"reason" => "retry_dedupe_hit"}
      })

    assert decision.selected_rule == :retry_dedupe_hit
    assert decision.selected_action == :stop_with_classified_handoff
  end

  test "string-keyed validation mismatch falls back to canonical reason and atom metadata" do
    decision =
      RetryFailoverDecision.decide(%{
        "validation_env_mismatch" => %{
          "active" => true,
          "checkpoint_type" => :human_action,
          "risk_level" => :high
        },
        "checkpoint_available" => %{"active" => true}
      })

    assert decision.selected_rule == :validation_env_mismatch
    assert decision.reason == "validation_env_mismatch"
    assert decision.checkpoint_type == "human_action"
    assert decision.risk_level == "high"
    assert decision.signals.checkpoint_available == %{active: true}
  end

  test "atom shorthand signal becomes string reason" do
    decision = RetryFailoverDecision.decide(%{stale_workspace_head: :stale_workspace_head})

    assert decision.selected_rule == :stale_workspace_head
    assert decision.reason == "stale_workspace_head"
  end

  test "boolean shorthand activates signal and invalid checkpoint metadata fails closed" do
    shorthand = RetryFailoverDecision.decide(%{unsafe_preemption_required: true})

    assert shorthand.selected_rule == :unsafe_preemption_required
    assert shorthand.reason == "unsafe_preemption_required"

    decision =
      RetryFailoverDecision.decide(%{
        stale_workspace_head: %{
          reason: "stale_workspace_head",
          checkpoint_type: 123,
          risk_level: 456
        }
      })

    assert decision.selected_rule == :stale_workspace_head
    assert decision.checkpoint_type == "human-action"
    assert decision.risk_level == "high"
  end

  test "string-keyed metadata normalizes summary, retry metadata, and nested log fields" do
    decision =
      RetryFailoverDecision.decide(%{
        "continuation_attempt_limit" => %{
          "active" => true,
          "summary" => "continuation attempt limit reached",
          "checkpoint_type" => "decision",
          "risk_level" => "medium",
          "retry_metadata" => %{"nested" => %{"value" => :kept}},
          "log_fields" => %{"payload" => %{"kind" => "continuation"}},
          "custom_field" => "custom",
          7 => "non-string-key"
        }
      })

    metadata = RetryFailoverDecision.metadata(decision)

    assert decision.selected_rule == :continuation_attempt_limit_exceeded
    assert decision.reason == "continuation attempt limit reached"
    assert decision.retry_metadata == %{"nested" => %{"value" => :kept}}
    assert metadata.retry_metadata == %{"nested" => %{"value" => :kept}}
    assert metadata.log_fields["payload"] == %{"kind" => "continuation"}
  end

  test "non-map and invalid signal values fail closed to allow_retry" do
    assert RetryFailoverDecision.decide(:invalid_input).selected_rule == :default_allow_retry

    decision =
      RetryFailoverDecision.decide(%{
        unsafe_preemption_required: 99,
        checkpoint_available: "unknown"
      })

    assert decision.selected_rule == :default_allow_retry
    assert decision.selected_action == :allow_retry
    assert decision.signals.unsafe_preemption_required == %{active: false}
    assert decision.signals.checkpoint_available == %{active: false}
  end

  test "suppressed rule labels stringifies suppressed alternatives" do
    decision =
      RetryFailoverDecision.decide(%{
        unsafe_preemption_required: %{reason: "unsafe_preemption_required"},
        account_unhealthy: %{reason: "quota exhausted"},
        checkpoint_available: true
      })

    assert RetryFailoverDecision.suppressed_rule_labels(decision) == [
             "account_unhealthy_checkpoint_available"
           ]
  end

  test "default path allows retry when no stronger rule is active" do
    decision = RetryFailoverDecision.decide(%{})

    assert decision.selected_rule == :default_allow_retry
    assert decision.selected_action == :allow_retry
    assert decision.suppressed_rules == []
  end
end
