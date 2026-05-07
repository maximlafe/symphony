defmodule SymphonyElixir.OrchestratorInfraBreakerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator

  test "trips into paused_infra after infra threshold" do
    defaults = Orchestrator.tracker_infra_breaker_defaults_for_test()
    threshold = defaults.trip_threshold

    reason_code = "linear_api_status_502"
    workspace = "workspace-a"
    now_ms = 1_000_000

    first =
      Orchestrator.tracker_infra_breaker_transition_for_test(
        %{},
        :infra_fail,
        reason_code,
        workspace,
        :failure,
        now_ms
      )

    assert first.decision == :allow
    assert first.breaker_state == :open

    near_trip =
      Enum.reduce(2..(threshold - 1), first, fn step, acc ->
        Orchestrator.tracker_infra_breaker_transition_for_test(
          acc.breakers,
          :infra_fail,
          reason_code,
          workspace,
          :failure,
          now_ms + step
        )
      end)

    assert near_trip.decision == :allow

    tripped =
      Orchestrator.tracker_infra_breaker_transition_for_test(
        near_trip.breakers,
        :infra_fail,
        reason_code,
        workspace,
        :failure,
        now_ms + threshold
      )

    assert tripped.decision == :paused
    assert tripped.breaker_state == :tripped

    paused =
      Orchestrator.tracker_infra_breaker_transition_for_test(
        tripped.breakers,
        :infra_fail,
        reason_code,
        workspace,
        :failure,
        now_ms + threshold + 1
      )

    assert paused.decision == :paused
    assert paused.breaker_state == :paused_infra
    assert paused.remaining_ms > 0
  end

  test "cooldown probe resumes to open after configured success threshold" do
    defaults = Orchestrator.tracker_infra_breaker_defaults_for_test()
    threshold = defaults.trip_threshold
    cooldown_ms = defaults.cooldown_sec * 1_000
    resume_threshold = defaults.resume_success_threshold

    reason_code = "linear_api_status_503"
    workspace = "workspace-b"
    now_ms = 2_000_000

    tripped =
      Enum.reduce(1..threshold, %{breakers: %{}}, fn step, acc ->
        Orchestrator.tracker_infra_breaker_transition_for_test(
          acc.breakers,
          :infra_fail,
          reason_code,
          workspace,
          :failure,
          now_ms + step
        )
      end)

    assert tripped.decision == :paused

    success_start_at = now_ms + cooldown_ms + 10

    first_probe =
      Orchestrator.tracker_infra_breaker_transition_for_test(
        tripped.breakers,
        :infra_fail,
        reason_code,
        workspace,
        :success,
        success_start_at
      )

    if resume_threshold > 1 do
      assert first_probe.breaker_state == :cooldown
      assert first_probe.decision == :cooldown_probe
    else
      assert first_probe.breaker_state == :open
      assert first_probe.decision == :allow
    end

    resumed =
      Enum.reduce(2..resume_threshold, first_probe, fn step, acc ->
        Orchestrator.tracker_infra_breaker_transition_for_test(
          acc.breakers,
          :infra_fail,
          reason_code,
          workspace,
          :success,
          success_start_at + step
        )
      end)

    assert resumed.breaker_state == :open
    assert resumed.decision == :allow
  end

  test "policy_fail path never enters paused_infra" do
    reason_code = "linear_api_status_400"
    workspace = "workspace-c"
    now_ms = 3_000_000

    result =
      Enum.reduce(1..6, %{breakers: %{}}, fn step, acc ->
        Orchestrator.tracker_infra_breaker_transition_for_test(
          acc.breakers,
          :policy_fail,
          reason_code,
          workspace,
          :failure,
          now_ms + step
        )
      end)

    assert result.breaker_state == :open
    assert result.decision == :allow
    assert result.operator_matrix_row_id == "opm_v1_policy_fix"
    assert result.breakers == %{}
  end

  test "success recovery updates only the matching reason_code breaker key" do
    defaults = Orchestrator.tracker_infra_breaker_defaults_for_test()
    threshold = defaults.trip_threshold
    cooldown_ms = defaults.cooldown_sec * 1_000
    resume_threshold = defaults.resume_success_threshold

    reason_a = "linear_api_status_502"
    reason_b = "linear_api_status_503"
    workspace = "workspace-shared"
    now_ms = 4_000_000

    tripped_a =
      Enum.reduce(1..threshold, %{breakers: %{}}, fn step, acc ->
        Orchestrator.tracker_infra_breaker_transition_for_test(
          acc.breakers,
          :infra_fail,
          reason_a,
          workspace,
          :failure,
          now_ms + step
        )
      end)

    tripped_b =
      Enum.reduce(1..threshold, tripped_a, fn step, acc ->
        Orchestrator.tracker_infra_breaker_transition_for_test(
          acc.breakers,
          :infra_fail,
          reason_b,
          workspace,
          :failure,
          now_ms + threshold + step
        )
      end)

    success_start_at = now_ms + cooldown_ms + threshold + 100

    recovered_a =
      Enum.reduce(1..resume_threshold, tripped_b, fn step, acc ->
        Orchestrator.tracker_infra_breaker_transition_for_test(
          acc.breakers,
          :infra_fail,
          reason_a,
          workspace,
          :success,
          success_start_at + step
        )
      end)

    assert recovered_a.breaker_state == :open

    untouched_b =
      Orchestrator.tracker_infra_breaker_transition_for_test(
        recovered_a.breakers,
        :infra_fail,
        reason_b,
        workspace,
        :success,
        success_start_at + resume_threshold + 1
      )

    if resume_threshold > 1 do
      assert untouched_b.breaker_state == :cooldown
      assert untouched_b.decision == :cooldown_probe
    else
      assert untouched_b.breaker_state == :open
    end
  end
end
