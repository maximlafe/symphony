defmodule SymphonyElixir.ExecutionRolloutTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionRollout

  @threshold_manifest %{
    observe_stability_window_hours: 24,
    shadow_divergence_limit_rate: 0.03,
    operator_path_determinism_floor: 0.95,
    auto_remediation_success_rate_floor: 0.9,
    infra_recovery_latency_tolerance_ms: 45_000
  }

  @baseline %{
    per_gate_rejection_rate: 0.1,
    false_blocked_valid_run_rate: 0.02,
    repeated_failure_by_fingerprint_rate: 0.04
  }

  @healthy_snapshot %{
    observed_window_hours: 24,
    shadow_divergence_rate: 0.02,
    operator_path_determinism_rate: 0.97,
    auto_remediation_success_rate: 0.95,
    median_infra_recovery_latency: 30_000,
    per_gate_rejection_rate: 0.11,
    false_blocked_valid_run_rate: 0.02,
    repeated_failure_by_fingerprint_rate: 0.03,
    new_failure_class_count: 0
  }

  test "parse_threshold_manifest accepts atom and string keys" do
    manifest = %{
      "observe_stability_window_hours" => 24,
      :shadow_divergence_limit_rate => 0.03,
      "operator_path_determinism_floor" => 0.95,
      :auto_remediation_success_rate_floor => 0.9,
      "infra_recovery_latency_tolerance_ms" => 45_000
    }

    assert {:ok, parsed} = ExecutionRollout.parse_threshold_manifest(manifest)
    assert parsed == @threshold_manifest
  end

  test "parse_threshold_manifest returns missing key errors" do
    manifest = Map.delete(@threshold_manifest, :operator_path_determinism_floor)

    assert {:error, %{missing_keys: missing, invalid_keys: []}} =
             ExecutionRollout.parse_threshold_manifest(manifest)

    assert :operator_path_determinism_floor in missing
  end

  test "mode transition and rollback helpers follow rollout contract" do
    assert ExecutionRollout.promote_target(:observe) == :shadow_enforce
    assert ExecutionRollout.promote_target(:shadow_enforce) == :enforce
    assert ExecutionRollout.promote_target(:enforce) == nil

    assert ExecutionRollout.rollback_target(:observe) == nil
    assert ExecutionRollout.rollback_target(:shadow_enforce) == nil
    assert ExecutionRollout.rollback_target(:enforce) == :shadow_enforce
  end

  test "evaluate_kpi_gate returns ok in observe mode for healthy snapshot" do
    result =
      ExecutionRollout.evaluate_kpi_gate(
        @healthy_snapshot,
        @baseline,
        :observe,
        @threshold_manifest
      )

    assert %{status: :ok, breaches: [], decision: %{action: :proceed, mode: :observe}} = result
  end

  test "evaluate_kpi_gate pauses promotion in observe mode on breach" do
    snapshot = Map.put(@healthy_snapshot, :new_failure_class_count, 1)

    result =
      ExecutionRollout.evaluate_kpi_gate(
        snapshot,
        @baseline,
        :observe,
        @threshold_manifest
      )

    assert result.status == :pause_promotion
    assert result.decision.action == :pause_mode_promotion
    assert Enum.any?(result.breaches, &(&1.code == :new_failure_class_detected))
  end

  test "evaluate_kpi_gate returns ok in shadow_enforce for healthy snapshot" do
    result =
      ExecutionRollout.evaluate_kpi_gate(
        @healthy_snapshot,
        @baseline,
        :shadow_enforce,
        @threshold_manifest
      )

    assert %{status: :ok, breaches: [], decision: %{action: :proceed, mode: :shadow_enforce}} = result
  end

  test "evaluate_kpi_gate pauses promotion in shadow_enforce on floor breach" do
    snapshot = Map.put(@healthy_snapshot, :operator_path_determinism_rate, 0.7)

    result =
      ExecutionRollout.evaluate_kpi_gate(
        snapshot,
        @baseline,
        :shadow_enforce,
        @threshold_manifest
      )

    assert result.status == :pause_promotion
    assert result.decision.action == :pause_mode_promotion
    assert Enum.any?(result.breaches, &(&1.code == :operator_path_determinism_floor_breach))
  end

  test "evaluate_kpi_gate returns ok in enforce for healthy snapshot" do
    result =
      ExecutionRollout.evaluate_kpi_gate(
        @healthy_snapshot,
        @baseline,
        :enforce,
        @threshold_manifest
      )

    assert %{status: :ok, breaches: [], decision: %{action: :proceed, mode: :enforce}} = result
  end

  test "evaluate_kpi_gate rolls back in enforce mode on breach" do
    snapshot = Map.put(@healthy_snapshot, :shadow_divergence_rate, 0.2)

    result =
      ExecutionRollout.evaluate_kpi_gate(
        snapshot,
        @baseline,
        :enforce,
        @threshold_manifest
      )

    assert result.status == :rollback
    assert result.decision.action == :rollback_mode_to_shadow_enforce
    assert result.decision.rollback_to == :shadow_enforce
    assert Enum.any?(result.breaches, &(&1.code == :shadow_divergence_limit_exceeded))
  end

  test "missing threshold manifest falls back to pause in observe and rollback in enforce" do
    bad_manifest = Map.drop(@threshold_manifest, [:infra_recovery_latency_tolerance_ms])

    observe_result =
      ExecutionRollout.evaluate_kpi_gate(
        @healthy_snapshot,
        @baseline,
        :observe,
        bad_manifest
      )

    enforce_result =
      ExecutionRollout.evaluate_kpi_gate(
        @healthy_snapshot,
        @baseline,
        :enforce,
        bad_manifest
      )

    assert observe_result.status == :pause_promotion
    assert observe_result.decision.action == :pause_mode_promotion
    assert Enum.any?(observe_result.breaches, &(&1.code == :threshold_manifest_invalid))

    assert enforce_result.status == :rollback
    assert enforce_result.decision.action == :rollback_mode_to_shadow_enforce
    assert Enum.any?(enforce_result.breaches, &(&1.code == :threshold_manifest_invalid))
  end
end
