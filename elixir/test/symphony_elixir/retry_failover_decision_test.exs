defmodule SymphonyElixir.RetryFailoverDecisionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RetryFailoverDecision

  test "retry dedupe stops even when a weaker budget downshift is available" do
    decision =
      RetryFailoverDecision.decide(%{
        retry_dedupe_hit: %{reason: "retry_dedupe_hit"},
        budget_exceeded: %{
          scope: :per_attempt,
          reason: :max_tokens_per_attempt_exceeded,
          cheaper_profile?: true
        }
      })

    assert decision.selected_rule == :retry_dedupe_hit
    assert decision.selected_action == :stop_with_classified_handoff
    assert decision.suppressed_rules == [:budget_exceeded_per_attempt_downshift]
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
        budget_exceeded: %{
          scope: :per_attempt,
          reason: :max_tokens_per_attempt_exceeded,
          cheaper_profile?: true
        }
      })

    assert decision.selected_rule == :validation_env_mismatch
    assert decision.selected_action == :stop_with_classified_handoff
    assert decision.suppressed_rules == [:budget_exceeded_per_attempt_downshift]
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

  test "per-attempt budget without a cheaper profile still hands off" do
    decision =
      RetryFailoverDecision.decide(%{
        budget_exceeded: %{
          scope: :per_attempt,
          reason: :max_tokens_per_attempt_exceeded,
          cheaper_profile?: false,
          checkpoint_type: "decision",
          risk_level: "medium"
        }
      })

    assert decision.selected_rule == :budget_exceeded_per_attempt_handoff
    assert decision.selected_action == :stop_with_classified_handoff
    assert decision.checkpoint_type == "decision"
    assert decision.risk_level == "medium"
  end

  test "per-attempt bootstrap signal allows retry and stays distinguishable" do
    decision =
      RetryFailoverDecision.decide(%{
        budget_exceeded: %{
          scope: :per_attempt,
          reason: :max_tokens_per_attempt_exceeded,
          cheaper_profile?: false,
          budget_signal_role: "bootstrap",
          checkpoint_type: "decision",
          risk_level: "medium"
        }
      })

    assert decision.selected_rule == :budget_exceeded_per_attempt_bootstrap
    assert decision.selected_action == :allow_retry
    assert decision.checkpoint_type == "decision"
    assert decision.risk_level == "medium"
    assert decision.signals.budget_exceeded.budget_signal_role == "bootstrap"
  end

  test "per-attempt budget with changed explicit progress surface allows retry" do
    decision =
      RetryFailoverDecision.decide(%{
        budget_exceeded: %{
          scope: :per_attempt,
          reason: :max_tokens_per_attempt_exceeded,
          cheaper_profile?: false,
          checkpoint_usable?: true,
          progress_status: :changed,
          progress_fingerprint: "progress:abc123",
          progress_repeat_count: 1,
          budget_signal_role: "signal",
          checkpoint_type: "decision",
          risk_level: "medium"
        }
      })

    assert decision.selected_rule == :budget_exceeded_per_attempt_progressing
    assert decision.selected_action == :allow_retry
    assert decision.reason == "max_tokens_per_attempt_exceeded"
    assert decision.checkpoint_type == "decision"
    assert decision.risk_level == "medium"
    assert decision.signals.budget_exceeded.progress_status == "changed"
    assert decision.signals.budget_exceeded.progress_fingerprint == "progress:abc123"
    assert decision.signals.budget_exceeded.progress_repeat_count == 1
    assert decision.signals.budget_exceeded.budget_signal_role == "signal"
  end

  test "per-attempt budget with repeated explicit progress surface handoffs even when cheaper profile exists" do
    decision =
      RetryFailoverDecision.decide(%{
        budget_exceeded: %{
          scope: :per_attempt,
          reason: :max_tokens_per_attempt_exceeded,
          cheaper_profile?: true,
          checkpoint_usable?: true,
          progress_status: "repeated",
          progress_fingerprint: "progress:stable",
          progress_repeat_count: 2
        }
      })

    assert decision.selected_rule == :budget_exceeded_per_attempt_handoff
    assert decision.selected_action == :stop_with_classified_handoff
    assert decision.reason == "max_tokens_per_attempt_exceeded"
  end

  test "string-keyed explicit progress fields normalize safely" do
    decision =
      RetryFailoverDecision.decide(%{
        "budget_exceeded" => %{
          "scope" => "per_attempt",
          "reason" => "max_tokens_per_attempt_exceeded",
          "checkpoint_usable?" => true,
          "progress_status" => "changed",
          "progress_changed?" => true,
          "progress_fingerprint" => "   ",
          "progress_repeat_count" => 1,
          "budget_signal_role" => "signal"
        }
      })

    assert decision.selected_rule == :budget_exceeded_per_attempt_progressing
    assert decision.selected_action == :allow_retry
    assert decision.signals.budget_exceeded.progress_status == "changed"
    assert decision.signals.budget_exceeded.progress_repeat_count == 1
    assert decision.signals.budget_exceeded.budget_signal_role == "signal"
    assert is_nil(decision.signals.budget_exceeded.progress_fingerprint)
  end

  test "explicit progress with unknown status fails closed to handoff" do
    decision =
      RetryFailoverDecision.decide(%{
        budget_exceeded: %{
          scope: :per_attempt,
          reason: :max_tokens_per_attempt_exceeded,
          cheaper_profile?: false,
          checkpoint_usable?: true,
          progress_status: "unexpected_status",
          progress_fingerprint: "progress:unknown",
          progress_repeat_count: 1
        }
      })

    assert decision.selected_rule == :budget_exceeded_per_attempt_handoff
    assert decision.selected_action == :stop_with_classified_handoff
  end

  test "string-keyed budget downshift metadata is normalized and serialized" do
    decision =
      RetryFailoverDecision.decide(%{
        "budget_exceeded" => %{
          "scope" => "per_attempt",
          "summary" => "downshift to cheaper profile",
          "cheaper_profile?" => true,
          "checkpoint_usable?" => true,
          "progress_status" => "changed",
          "progress_fingerprint" => "progress:downshift",
          "progress_repeat_count" => 1,
          "cost_profile_key" => "cheap_implementation",
          "retry_metadata" => %{"source" => "budget"},
          "log_fields" => %{"nested" => %{"kind" => "budget"}}
        },
        "checkpoint_available" => %{"reason" => "resume-ready"},
        "milestone_near" => 0
      })

    metadata = RetryFailoverDecision.metadata(decision)

    assert decision.selected_rule == :budget_exceeded_per_attempt_downshift
    assert decision.selected_action == :allow_downshifted_retry
    assert decision.reason == "downshift to cheaper profile"
    assert decision.retry_metadata == %{"source" => "budget"}
    assert decision.signals.budget_exceeded.scope == "per_attempt"
    assert decision.signals.budget_exceeded[:cheaper_profile?] == true
    assert decision.signals.budget_exceeded.progress_status == "changed"
    assert decision.signals.budget_exceeded.progress_fingerprint == "progress:downshift"
    assert decision.signals.budget_exceeded.progress_repeat_count == 1
    assert metadata.selected_rule == "budget_exceeded_per_attempt_downshift"
    assert metadata.selected_action == "allow_downshifted_retry"
    assert metadata.retry_metadata == %{"source" => "budget"}
    assert metadata.log_fields["nested"] == %{"kind" => "budget"}
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

  test "cumulative budget shorthand maps directly to classified handoff" do
    decision = RetryFailoverDecision.decide(%{budget_exceeded: :cumulative})

    assert decision.selected_rule == :budget_exceeded_cumulative
    assert decision.selected_action == :stop_with_classified_handoff
    assert decision.reason == "budget_exceeded_cumulative"
  end

  test "non-map and invalid signal values fail closed to allow_retry" do
    assert RetryFailoverDecision.decide(:invalid_input).selected_rule == :default_allow_retry

    decision =
      RetryFailoverDecision.decide(%{
        budget_exceeded: 123,
        unsafe_preemption_required: 99,
        checkpoint_available: "unknown"
      })

    assert decision.selected_rule == :default_allow_retry
    assert decision.selected_action == :allow_retry
    assert decision.signals.budget_exceeded == %{active: false}
    assert decision.signals.unsafe_preemption_required == %{active: false}
    assert decision.signals.checkpoint_available == %{active: false}
  end

  test "invalid budget scope and numeric metadata fall back safely" do
    invalid_scope =
      RetryFailoverDecision.decide(%{
        budget_exceeded: %{scope: "unexpected"},
        stale_workspace_head: %{reason: "stale", checkpoint_type: 123, risk_level: 999}
      })

    cumulative_kind =
      RetryFailoverDecision.decide(%{
        "budget_exceeded" => %{
          "kind" => "cumulative",
          "custom_rule" => "ignored"
        }
      })

    per_attempt_mode =
      RetryFailoverDecision.decide(%{
        "budget_exceeded" => %{
          "mode" => "per_attempt",
          "cheaper_profile?" => false
        }
      })

    assert invalid_scope.selected_rule == :stale_workspace_head
    assert invalid_scope.checkpoint_type == "human-action"
    assert invalid_scope.risk_level == "high"
    assert cumulative_kind.selected_rule == :budget_exceeded_cumulative
    assert per_attempt_mode.selected_rule == :budget_exceeded_per_attempt_handoff
    assert RetryFailoverDecision.decide(%{budget_exceeded: %{scope: 1}}).selected_rule == :default_allow_retry
  end

  test "atom and boolean shorthand signals normalize into preemption metadata" do
    decision =
      RetryFailoverDecision.decide(%{
        unsafe_preemption_required: true,
        checkpoint_available: %{active: true},
        milestone_near: true
      })

    assert decision.selected_rule == :unsafe_preemption_required
    assert decision.selected_action == :immediate_preemption
    assert decision.reason == "unsafe_preemption_required"
    assert decision.checkpoint_type == "human-action"
    assert decision.risk_level == "high"
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
