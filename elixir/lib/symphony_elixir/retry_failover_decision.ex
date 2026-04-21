defmodule SymphonyElixir.RetryFailoverDecision do
  @moduledoc """
  Resolves retry/failover boundary signals into one authoritative decision.
  """

  @type action ::
          :stop_with_classified_handoff
          | :allow_retry
          | :drain_to_milestone
          | :checkpoint_and_failover
          | :immediate_preemption

  @type rule ::
          :unsafe_preemption_required
          | :stale_workspace_head
          | :validation_env_mismatch
          | :retry_dedupe_hit
          | :continuation_attempt_limit_exceeded
          | :account_unhealthy_milestone_near
          | :account_unhealthy_checkpoint_available
          | :account_unhealthy_no_checkpoint
          | :default_allow_retry

  defstruct [
    :selected_rule,
    :selected_action,
    :reason,
    :signals,
    :checkpoint_type,
    :risk_level,
    suppressed_rules: [],
    retry_metadata: %{},
    log_fields: %{}
  ]

  @type t :: %__MODULE__{
          selected_rule: rule(),
          selected_action: action(),
          reason: String.t(),
          signals: map(),
          suppressed_rules: [rule()],
          checkpoint_type: String.t() | nil,
          risk_level: String.t() | nil,
          retry_metadata: map(),
          log_fields: map()
        }

  @spec decide(map()) :: t()
  def decide(input) when is_map(input) do
    signals = normalize_signals(input)

    {selected_rule, suppressed_rules} =
      signals
      |> matched_rules()
      |> pick_rule()

    %__MODULE__{
      selected_rule: selected_rule,
      selected_action: action_for_rule(selected_rule),
      reason: reason_for_rule(selected_rule, signals),
      signals: signals_payload(signals),
      suppressed_rules: suppressed_rules,
      checkpoint_type: checkpoint_type_for_rule(selected_rule, signals),
      risk_level: risk_level_for_rule(selected_rule, signals),
      retry_metadata: retry_metadata_for_rule(selected_rule, signals),
      log_fields: log_fields_for_rule(selected_rule, signals, suppressed_rules)
    }
  end

  def decide(_input), do: decide(%{})

  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = decision) do
    %{
      selected_rule: Atom.to_string(decision.selected_rule),
      selected_action: Atom.to_string(decision.selected_action),
      reason: decision.reason,
      signals: decision.signals,
      suppressed_rules: Enum.map(decision.suppressed_rules, &Atom.to_string/1),
      checkpoint_type: decision.checkpoint_type,
      risk_level: decision.risk_level,
      retry_metadata: decision.retry_metadata,
      log_fields: stringify_map(decision.log_fields)
    }
  end

  @spec suppressed_rule_labels(t()) :: [String.t()]
  def suppressed_rule_labels(%__MODULE__{} = decision) do
    Enum.map(decision.suppressed_rules, &Atom.to_string/1)
  end

  defp normalize_signals(input) do
    %{
      stale_workspace_head: normalize_signal(signal_input(input, :stale_workspace_head)),
      retry_dedupe_hit: normalize_signal(signal_input(input, :retry_dedupe_hit)),
      continuation_attempt_limit: normalize_signal(signal_input(input, :continuation_attempt_limit)),
      validation_env_mismatch: normalize_signal(signal_input(input, :validation_env_mismatch)),
      account_unhealthy: normalize_signal(signal_input(input, :account_unhealthy)),
      unsafe_preemption_required: normalize_signal(signal_input(input, :unsafe_preemption_required)),
      checkpoint_available: normalize_boolean_signal(signal_input(input, :checkpoint_available)),
      milestone_near: normalize_boolean_signal(signal_input(input, :milestone_near))
    }
  end

  defp signal_input(input, key) when is_map(input) and is_atom(key) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end

  defp normalize_signal(value) when value in [nil, false], do: %{active: false}
  defp normalize_signal(true), do: %{active: true}

  defp normalize_signal(value) when is_map(value) do
    value
    |> atomize_keys()
    |> Map.put_new(:active, true)
  end

  defp normalize_signal(value) when is_binary(value) or is_atom(value) do
    %{active: true, reason: to_string(value)}
  end

  defp normalize_signal(_value), do: %{active: false}

  defp normalize_boolean_signal(value) when value in [true, false], do: %{active: value}
  defp normalize_boolean_signal(%{} = value), do: normalize_signal(value)
  defp normalize_boolean_signal(_value), do: %{active: false}

  defp matched_rules(signals) do
    []
    |> maybe_add_rule(:unsafe_preemption_required, signal_active?(signals.unsafe_preemption_required))
    |> maybe_add_rule(:stale_workspace_head, signal_active?(signals.stale_workspace_head))
    |> maybe_add_rule(:validation_env_mismatch, signal_active?(signals.validation_env_mismatch))
    |> maybe_add_rule(:retry_dedupe_hit, signal_active?(signals.retry_dedupe_hit))
    |> maybe_add_rule(
      :continuation_attempt_limit_exceeded,
      signal_active?(signals.continuation_attempt_limit)
    )
    |> maybe_add_rule(
      :account_unhealthy_milestone_near,
      signal_active?(signals.account_unhealthy) and signal_active?(signals.milestone_near)
    )
    |> maybe_add_rule(
      :account_unhealthy_checkpoint_available,
      signal_active?(signals.account_unhealthy) and signal_active?(signals.checkpoint_available)
    )
    |> maybe_add_rule(
      :account_unhealthy_no_checkpoint,
      signal_active?(signals.account_unhealthy) and not signal_active?(signals.checkpoint_available)
    )
  end

  defp pick_rule([]), do: {:default_allow_retry, []}
  defp pick_rule([selected | suppressed]), do: {selected, suppressed}

  defp action_for_rule(:unsafe_preemption_required), do: :immediate_preemption
  defp action_for_rule(:stale_workspace_head), do: :stop_with_classified_handoff
  defp action_for_rule(:validation_env_mismatch), do: :stop_with_classified_handoff
  defp action_for_rule(:retry_dedupe_hit), do: :stop_with_classified_handoff
  defp action_for_rule(:continuation_attempt_limit_exceeded), do: :stop_with_classified_handoff
  defp action_for_rule(:account_unhealthy_milestone_near), do: :drain_to_milestone
  defp action_for_rule(:account_unhealthy_checkpoint_available), do: :checkpoint_and_failover
  defp action_for_rule(:account_unhealthy_no_checkpoint), do: :immediate_preemption
  defp action_for_rule(:default_allow_retry), do: :allow_retry

  defp reason_for_rule(:unsafe_preemption_required, signals),
    do: signal_reason(signals.unsafe_preemption_required, "unsafe_preemption_required")

  defp reason_for_rule(:stale_workspace_head, signals),
    do: signal_reason(signals.stale_workspace_head, "stale_workspace_head")

  defp reason_for_rule(:validation_env_mismatch, signals),
    do: signal_reason(signals.validation_env_mismatch, "validation_env_mismatch")

  defp reason_for_rule(:retry_dedupe_hit, signals),
    do: signal_reason(signals.retry_dedupe_hit, "retry_dedupe_hit")

  defp reason_for_rule(:continuation_attempt_limit_exceeded, signals),
    do:
      signal_reason(
        signals.continuation_attempt_limit,
        "continuation_attempt_limit_exceeded"
      )

  defp reason_for_rule(:account_unhealthy_milestone_near, signals),
    do: signal_reason(signals.account_unhealthy, "account_unhealthy_milestone_near")

  defp reason_for_rule(:account_unhealthy_checkpoint_available, signals),
    do: signal_reason(signals.account_unhealthy, "account_unhealthy_checkpoint_available")

  defp reason_for_rule(:account_unhealthy_no_checkpoint, signals),
    do: signal_reason(signals.account_unhealthy, "account_unhealthy_no_checkpoint")

  defp reason_for_rule(:default_allow_retry, _signals),
    do: "no stronger retry/failover rule matched"

  defp checkpoint_type_for_rule(rule, signals)
       when rule in [:stale_workspace_head, :validation_env_mismatch, :retry_dedupe_hit] do
    signals
    |> signal_for_rule(rule)
    |> signal_field(:checkpoint_type, "human-action")
  end

  defp checkpoint_type_for_rule(:continuation_attempt_limit_exceeded, signals),
    do:
      signal_field(
        signals.continuation_attempt_limit,
        :checkpoint_type,
        "decision"
      )

  defp checkpoint_type_for_rule(rule, signals)
       when rule in [:unsafe_preemption_required, :account_unhealthy_no_checkpoint] do
    signals
    |> signal_for_rule(rule)
    |> signal_field(:checkpoint_type, "human-action")
  end

  defp checkpoint_type_for_rule(_rule, _signals), do: nil

  defp risk_level_for_rule(rule, signals)
       when rule in [:stale_workspace_head, :validation_env_mismatch] do
    signals
    |> signal_for_rule(rule)
    |> signal_field(:risk_level, "high")
  end

  defp risk_level_for_rule(:retry_dedupe_hit, signals),
    do: signal_field(signals.retry_dedupe_hit, :risk_level, "medium")

  defp risk_level_for_rule(:continuation_attempt_limit_exceeded, signals),
    do: signal_field(signals.continuation_attempt_limit, :risk_level, "medium")

  defp risk_level_for_rule(rule, signals)
       when rule in [:unsafe_preemption_required, :account_unhealthy_no_checkpoint] do
    signals
    |> signal_for_rule(rule)
    |> signal_field(:risk_level, "high")
  end

  defp risk_level_for_rule(_rule, _signals), do: nil

  defp retry_metadata_for_rule(:continuation_attempt_limit_exceeded, signals),
    do: signal_retry_metadata(signals.continuation_attempt_limit)

  defp retry_metadata_for_rule(rule, signals)
       when rule in [:account_unhealthy_checkpoint_available, :account_unhealthy_no_checkpoint] do
    signal_retry_metadata(signals.account_unhealthy)
  end

  defp retry_metadata_for_rule(_rule, _signals), do: %{}

  defp log_fields_for_rule(selected_rule, signals, suppressed_rules) do
    signal = signal_for_rule(signals, selected_rule)

    %{
      selected_rule: Atom.to_string(selected_rule),
      selected_action: Atom.to_string(action_for_rule(selected_rule)),
      reason: reason_for_rule(selected_rule, signals),
      checkpoint_type: checkpoint_type_for_rule(selected_rule, signals),
      risk_level: risk_level_for_rule(selected_rule, signals),
      suppressed_rules: Enum.map(suppressed_rules, &Atom.to_string/1)
    }
    |> Map.merge(signal_log_fields(signal))
  end

  defp signals_payload(signals) do
    %{
      stale_workspace_head: signal_payload(signals.stale_workspace_head),
      retry_dedupe_hit: signal_payload(signals.retry_dedupe_hit),
      continuation_attempt_limit: signal_payload(signals.continuation_attempt_limit),
      validation_env_mismatch: signal_payload(signals.validation_env_mismatch),
      account_unhealthy: signal_payload(signals.account_unhealthy),
      unsafe_preemption_required: signal_payload(signals.unsafe_preemption_required),
      checkpoint_available: signal_payload(signals.checkpoint_available),
      milestone_near: signal_payload(signals.milestone_near)
    }
  end

  defp signal_payload(%{active: active} = signal) do
    signal
    |> Map.take([:active, :reason, :checkpoint_type, :risk_level])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:active, active == true)
  end

  defp maybe_add_rule(rules, _rule, false), do: rules
  defp maybe_add_rule(rules, rule, true), do: rules ++ [rule]

  defp signal_active?(%{active: true}), do: true
  defp signal_active?(_signal), do: false

  defp signal_reason(signal, fallback) when is_map(signal) do
    cond do
      is_binary(signal[:summary]) and signal[:summary] != "" -> signal[:summary]
      is_binary(signal[:reason]) and signal[:reason] != "" -> signal[:reason]
      is_atom(signal[:reason]) and not is_nil(signal[:reason]) -> Atom.to_string(signal[:reason])
      true -> fallback
    end
  end

  defp signal_for_rule(signals, :unsafe_preemption_required), do: signals.unsafe_preemption_required
  defp signal_for_rule(signals, :stale_workspace_head), do: signals.stale_workspace_head
  defp signal_for_rule(signals, :validation_env_mismatch), do: signals.validation_env_mismatch
  defp signal_for_rule(signals, :retry_dedupe_hit), do: signals.retry_dedupe_hit
  defp signal_for_rule(signals, :continuation_attempt_limit_exceeded), do: signals.continuation_attempt_limit
  defp signal_for_rule(signals, :account_unhealthy_milestone_near), do: signals.account_unhealthy
  defp signal_for_rule(signals, :account_unhealthy_checkpoint_available), do: signals.account_unhealthy
  defp signal_for_rule(signals, :account_unhealthy_no_checkpoint), do: signals.account_unhealthy
  defp signal_for_rule(_signals, :default_allow_retry), do: %{}

  defp signal_field(signal, field, default) when is_map(signal) do
    case Map.get(signal, field) do
      nil -> default
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> default
    end
  end

  defp signal_retry_metadata(%{retry_metadata: metadata}) when is_map(metadata), do: metadata
  defp signal_retry_metadata(_signal), do: %{}

  defp signal_log_fields(%{log_fields: log_fields}) when is_map(log_fields), do: log_fields
  defp signal_log_fields(_signal), do: %{}

  defp atomize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key =
        cond do
          is_atom(key) -> key
          is_binary(key) -> normalize_atom_key(key)
          true -> key
        end

      Map.put(acc, normalized_key, value)
    end)
  end

  defp normalize_atom_key("active"), do: :active
  defp normalize_atom_key("reason"), do: :reason
  defp normalize_atom_key("summary"), do: :summary
  defp normalize_atom_key("checkpoint_type"), do: :checkpoint_type
  defp normalize_atom_key("risk_level"), do: :risk_level
  defp normalize_atom_key("retry_metadata"), do: :retry_metadata
  defp normalize_atom_key("log_fields"), do: :log_fields
  defp normalize_atom_key(other), do: other

  defp stringify_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), stringify_value(value))
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
