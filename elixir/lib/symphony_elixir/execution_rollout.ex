defmodule SymphonyElixir.ExecutionRollout do
  @moduledoc """
  Pure rollout/KPI contract helpers for staged execution mode control.
  """

  @type mode :: :observe | :shadow_enforce | :enforce

  @type threshold_manifest :: %{
          required(:observe_stability_window_hours) => pos_integer(),
          required(:shadow_divergence_limit_rate) => float(),
          required(:operator_path_determinism_floor) => float(),
          required(:auto_remediation_success_rate_floor) => float(),
          required(:infra_recovery_latency_tolerance_ms) => non_neg_integer()
        }

  @type breach :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(:metric) => atom(),
          optional(:details) => map()
        }

  @type decision :: %{
          required(:action) => :proceed | :pause_mode_promotion | :rollback_mode_to_shadow_enforce,
          required(:mode) => mode(),
          optional(:rollback_to) => mode(),
          optional(:next_mode) => mode() | nil,
          optional(:reason) => atom()
        }

  @type gate_status :: :ok | :pause_promotion | :rollback

  @type gate_result :: %{
          required(:status) => gate_status(),
          required(:breaches) => [breach()],
          required(:decision) => decision()
        }

  @required_threshold_keys [
    :observe_stability_window_hours,
    :shadow_divergence_limit_rate,
    :operator_path_determinism_floor,
    :auto_remediation_success_rate_floor,
    :infra_recovery_latency_tolerance_ms
  ]

  @spec modes() :: [mode()]
  def modes, do: [:observe, :shadow_enforce, :enforce]

  @spec promote_target(mode()) :: mode() | nil
  def promote_target(:observe), do: :shadow_enforce
  def promote_target(:shadow_enforce), do: :enforce
  def promote_target(:enforce), do: nil

  @spec rollback_target(mode()) :: mode() | nil
  def rollback_target(:enforce), do: :shadow_enforce
  def rollback_target(:observe), do: nil
  def rollback_target(:shadow_enforce), do: nil

  @spec parse_threshold_manifest(map()) ::
          {:ok, threshold_manifest()}
          | {:error, %{missing_keys: [atom()], invalid_keys: [atom()]}}
  def parse_threshold_manifest(manifest) when is_map(manifest) do
    normalized = normalize_manifest_keys(manifest)

    missing_keys =
      Enum.filter(@required_threshold_keys, fn key ->
        not Map.has_key?(normalized, key)
      end)

    invalid_keys =
      @required_threshold_keys
      |> Enum.reject(&(&1 in missing_keys))
      |> Enum.filter(fn key ->
        not valid_threshold_value?(key, Map.fetch!(normalized, key))
      end)

    case {missing_keys, invalid_keys} do
      {[], []} ->
        {:ok,
         %{
           observe_stability_window_hours: normalized.observe_stability_window_hours,
           shadow_divergence_limit_rate: normalized.shadow_divergence_limit_rate,
           operator_path_determinism_floor: normalized.operator_path_determinism_floor,
           auto_remediation_success_rate_floor: normalized.auto_remediation_success_rate_floor,
           infra_recovery_latency_tolerance_ms: normalized.infra_recovery_latency_tolerance_ms
         }}

      _ ->
        {:error, %{missing_keys: missing_keys, invalid_keys: invalid_keys}}
    end
  end

  @spec evaluate_kpi_gate(map(), map(), mode(), map()) :: gate_result()
  def evaluate_kpi_gate(snapshot, baseline, mode, threshold_manifest)
      when is_map(snapshot) and is_map(baseline) and is_map(threshold_manifest) do
    case parse_threshold_manifest(threshold_manifest) do
      {:ok, thresholds} ->
        breaches = collect_breaches(snapshot, baseline, mode, thresholds)
        gate_result_for(mode, breaches)

      {:error, %{missing_keys: missing_keys, invalid_keys: invalid_keys}} ->
        breaches =
          [
            %{
              code: :threshold_manifest_invalid,
              metric: :threshold_manifest,
              message: "Threshold manifest is missing keys or has invalid values",
              details: %{missing_keys: missing_keys, invalid_keys: invalid_keys}
            }
          ]

        gate_result_for(mode, breaches)
    end
  end

  defp gate_result_for(mode, []) do
    %{
      status: :ok,
      breaches: [],
      decision: %{action: :proceed, mode: mode, next_mode: promote_target(mode)}
    }
  end

  defp gate_result_for(:enforce = mode, breaches) do
    %{
      status: :rollback,
      breaches: breaches,
      decision: %{
        action: :rollback_mode_to_shadow_enforce,
        mode: mode,
        rollback_to: :shadow_enforce,
        reason: :kpi_breach
      }
    }
  end

  defp gate_result_for(mode, breaches) when mode in [:observe, :shadow_enforce] do
    %{
      status: :pause_promotion,
      breaches: breaches,
      decision: %{action: :pause_mode_promotion, mode: mode, reason: :kpi_breach}
    }
  end

  defp collect_breaches(snapshot, baseline, mode, thresholds) do
    []
    |> maybe_add_baseline_breach(baseline)
    |> maybe_add_observe_window_breach(snapshot, mode, thresholds)
    |> maybe_add_shadow_divergence_breach(snapshot, mode, thresholds)
    |> maybe_add_floor_breaches(snapshot, mode, thresholds)
    |> maybe_add_common_kpi_breaches(snapshot, baseline, thresholds)
  end

  defp maybe_add_baseline_breach(breaches, baseline) do
    baseline_required = [:per_gate_rejection_rate, :false_blocked_valid_run_rate]

    missing =
      Enum.filter(baseline_required, fn key ->
        not is_number(metric_value(baseline, key))
      end)

    case missing do
      [] ->
        breaches

      _ ->
        [
          %{
            code: :baseline_missing,
            metric: :baseline,
            message: "Baseline is missing required KPI fields",
            details: %{missing_keys: missing}
          }
          | breaches
        ]
    end
  end

  defp maybe_add_observe_window_breach(breaches, snapshot, :observe, thresholds) do
    observed_hours = metric_value(snapshot, :observed_window_hours)

    if is_number(observed_hours) and observed_hours >= thresholds.observe_stability_window_hours do
      breaches
    else
      [
        %{
          code: :observe_window_not_satisfied,
          metric: :observed_window_hours,
          message: "Observe stability window has not been satisfied",
          details: %{
            observed_window_hours: observed_hours,
            required_window_hours: thresholds.observe_stability_window_hours
          }
        }
        | breaches
      ]
    end
  end

  defp maybe_add_observe_window_breach(breaches, _snapshot, _mode, _thresholds), do: breaches

  defp maybe_add_shadow_divergence_breach(breaches, snapshot, mode, thresholds)
       when mode in [:shadow_enforce, :enforce] do
    divergence = metric_value(snapshot, :shadow_divergence_rate)

    if is_number(divergence) and divergence <= thresholds.shadow_divergence_limit_rate do
      breaches
    else
      [
        %{
          code: :shadow_divergence_limit_exceeded,
          metric: :shadow_divergence_rate,
          message: "Shadow divergence exceeded configured limit",
          details: %{
            value: divergence,
            limit: thresholds.shadow_divergence_limit_rate
          }
        }
        | breaches
      ]
    end
  end

  defp maybe_add_shadow_divergence_breach(breaches, _snapshot, _mode, _thresholds), do: breaches

  defp maybe_add_floor_breaches(breaches, snapshot, mode, thresholds)
       when mode in [:shadow_enforce, :enforce] do
    breaches
    |> maybe_add_floor_breach(
      snapshot,
      :operator_path_determinism_rate,
      :operator_path_determinism_floor_breach,
      thresholds.operator_path_determinism_floor
    )
    |> maybe_add_floor_breach(
      snapshot,
      :auto_remediation_success_rate,
      :auto_remediation_success_rate_floor_breach,
      thresholds.auto_remediation_success_rate_floor
    )
  end

  defp maybe_add_floor_breaches(breaches, _snapshot, _mode, _thresholds), do: breaches

  defp maybe_add_floor_breach(breaches, snapshot, metric, code, floor) do
    value = metric_value(snapshot, metric)

    if is_number(value) and value >= floor do
      breaches
    else
      [
        %{
          code: code,
          metric: metric,
          message: "#{metric} is below configured floor",
          details: %{value: value, floor: floor}
        }
        | breaches
      ]
    end
  end

  defp maybe_add_common_kpi_breaches(breaches, snapshot, baseline, thresholds) do
    breaches
    |> maybe_add_rejection_regression(snapshot, baseline)
    |> maybe_add_false_blocked_regression(snapshot, baseline)
    |> maybe_add_repeated_failure_regression(snapshot, baseline)
    |> maybe_add_new_failure_class_breach(snapshot)
    |> maybe_add_infra_latency_breach(snapshot, thresholds)
  end

  defp maybe_add_rejection_regression(breaches, snapshot, baseline) do
    current = metric_value(snapshot, :per_gate_rejection_rate)
    prior = metric_value(baseline, :per_gate_rejection_rate)

    if is_number(current) and is_number(prior) and current > prior * 1.2 do
      [
        %{
          code: :per_gate_rejection_regression,
          metric: :per_gate_rejection_rate,
          message: "Per-gate rejection rate exceeded baseline tolerance",
          details: %{value: current, baseline: prior, limit: prior * 1.2}
        }
        | breaches
      ]
    else
      breaches
    end
  end

  defp maybe_add_false_blocked_regression(breaches, snapshot, baseline) do
    current = metric_value(snapshot, :false_blocked_valid_run_rate)
    prior = metric_value(baseline, :false_blocked_valid_run_rate)

    if is_number(current) and is_number(prior) and current > prior do
      [
        %{
          code: :false_blocked_valid_run_regression,
          metric: :false_blocked_valid_run_rate,
          message: "False blocked valid run rate regressed over baseline",
          details: %{value: current, baseline: prior}
        }
        | breaches
      ]
    else
      breaches
    end
  end

  defp maybe_add_repeated_failure_regression(breaches, snapshot, baseline) do
    current = metric_value(snapshot, :repeated_failure_by_fingerprint_rate)
    prior = metric_value(baseline, :repeated_failure_by_fingerprint_rate)

    if is_number(current) and is_number(prior) and current > prior do
      [
        %{
          code: :repeated_failure_regression,
          metric: :repeated_failure_by_fingerprint_rate,
          message: "Repeated failure by fingerprint rose versus baseline",
          details: %{value: current, baseline: prior}
        }
        | breaches
      ]
    else
      breaches
    end
  end

  defp maybe_add_new_failure_class_breach(breaches, snapshot) do
    value = metric_value(snapshot, :new_failure_class_count)

    if is_number(value) and value > 0 do
      [
        %{
          code: :new_failure_class_detected,
          metric: :new_failure_class_count,
          message: "New failure class detected in active rollout window",
          details: %{value: value}
        }
        | breaches
      ]
    else
      breaches
    end
  end

  defp maybe_add_infra_latency_breach(breaches, snapshot, thresholds) do
    value = metric_value(snapshot, :median_infra_recovery_latency)

    if is_number(value) and value > thresholds.infra_recovery_latency_tolerance_ms do
      [
        %{
          code: :infra_recovery_latency_regression,
          metric: :median_infra_recovery_latency,
          message: "Infra recovery latency exceeded tolerance",
          details: %{value: value, tolerance: thresholds.infra_recovery_latency_tolerance_ms}
        }
        | breaches
      ]
    else
      breaches
    end
  end

  defp normalize_manifest_keys(manifest) do
    Enum.reduce(manifest, %{}, fn {key, value}, acc ->
      case normalize_key(key) do
        nil -> acc
        normalized_key -> Map.put(acc, normalized_key, value)
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> case do
      "" ->
        nil

      text ->
        try do
          String.to_existing_atom(text)
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp normalize_key(_), do: nil

  defp valid_threshold_value?(:observe_stability_window_hours, value) do
    is_integer(value) and value > 0
  end

  defp valid_threshold_value?(:infra_recovery_latency_tolerance_ms, value) do
    is_integer(value) and value >= 0
  end

  defp valid_threshold_value?(key, value)
       when key in [
              :shadow_divergence_limit_rate,
              :operator_path_determinism_floor,
              :auto_remediation_success_rate_floor
            ] do
    is_number(value) and value >= 0.0 and value <= 1.0
  end

  defp valid_threshold_value?(_key, _value), do: false

  defp metric_value(metrics, key) when is_map(metrics) do
    Map.get(metrics, key) || Map.get(metrics, Atom.to_string(key))
  end
end
