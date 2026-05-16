defmodule SymphonyElixir.OrchestratorTrackerEscalationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator

  test "classifies tracker linear api status infra failures" do
    assert %{failure_class: :infra_fail, reason_code: "linear_api_status_503"} =
             Orchestrator.classify_tracker_escalation_reason_for_test({:linear_api_status, 503})

    assert %{failure_class: :infra_fail, reason_code: "linear_api_status_429"} =
             Orchestrator.classify_tracker_escalation_reason_for_test({:linear_api_status, 429})
  end

  test "keeps non-infra linear api status as policy failures" do
    assert %{failure_class: :policy_fail, reason_code: "linear_api_status_400"} =
             Orchestrator.classify_tracker_escalation_reason_for_test({:linear_api_status, 400})
  end

  test "applies poll backoff for tracker 429 failures" do
    assert 60_000 ==
             Orchestrator.tracker_fetch_poll_interval_ms_for_test(
               5_000,
               {:linear_api_status, 429}
             )

    assert 120_000 ==
             Orchestrator.tracker_fetch_poll_interval_ms_for_test(
               120_000,
               {:linear_api_status, 429}
             )

    assert 5_000 ==
             Orchestrator.tracker_fetch_poll_interval_ms_for_test(
               5_000,
               {:linear_api_status, 400}
             )
  end

  test "deduplicates infra tracker escalation retries within ttl window by fingerprint" do
    issue_id = "issue-123"
    tracker_reason = {:linear_api_status, 502}
    now_ms = 100_000

    first_context = %{resume_checkpoint: %{"head" => "abc123"}}

    first =
      Orchestrator.tracker_escalation_dedupe_decision_for_test(
        %{},
        issue_id,
        tracker_reason,
        first_context,
        now_ms
      )

    assert first.status == :recorded

    second =
      Orchestrator.tracker_escalation_dedupe_decision_for_test(
        first.dedupe,
        issue_id,
        tracker_reason,
        first_context,
        now_ms + 1_000
      )

    assert second.status == :dedupe_hit

    changed_context = %{resume_checkpoint: %{"head" => "def456"}}

    third =
      Orchestrator.tracker_escalation_dedupe_decision_for_test(
        second.dedupe,
        issue_id,
        tracker_reason,
        changed_context,
        now_ms + 2_000
      )

    assert third.status == :recorded
  end

  test "rollout rejection rate uses attempted transitions as denominator" do
    started_at_ms = 1_000_000
    snapshot = Orchestrator.execution_rollout_snapshot_defaults_for_test()

    success_snapshot =
      Orchestrator.execution_rollout_snapshot_transition_for_test(
        snapshot,
        %{
          transition_attempted: true,
          transition_rejected: false,
          failure_class: nil,
          dedupe_hit: false,
          retry_budget_status: :open,
          retry_budget_outcome: :n_a
        },
        started_at_ms,
        started_at_ms + 1_000
      )

    assert success_snapshot.attempted_transitions_total == 1
    assert success_snapshot.rejected_transitions_total == 0
    assert success_snapshot.per_gate_rejection_rate == 0.0

    rejected_snapshot =
      Orchestrator.execution_rollout_snapshot_transition_for_test(
        success_snapshot,
        %{
          transition_attempted: true,
          transition_rejected: true,
          failure_class: :infra_fail,
          dedupe_hit: false,
          retry_budget_status: :open,
          retry_budget_outcome: :retry_scheduled
        },
        started_at_ms,
        started_at_ms + 2_000
      )

    assert rejected_snapshot.attempted_transitions_total == 2
    assert rejected_snapshot.rejected_transitions_total == 1
    assert rejected_snapshot.per_gate_rejection_rate == 0.5
  end
end
