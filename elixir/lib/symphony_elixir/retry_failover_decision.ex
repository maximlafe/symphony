defmodule SymphonyElixir.RetryFailoverDecision do
  @moduledoc """
  Resolves retry/failover boundary signals into one authoritative decision.
  """

  @type action ::
          :stop_with_classified_handoff
          | :allow_retry
          | :allow_downshifted_retry
          | :drain_to_milestone
          | :checkpoint_and_failover
          | :immediate_preemption

  @type rule ::
          :unsafe_preemption_required
          | :stale_workspace_head
          | :validation_env_mismatch
          | :retry_dedupe_hit
          | :continuation_attempt_limit_exceeded
          | :budget_exceeded_cumulative
          | :budget_exceeded_per_attempt_bootstrap
          | :budget_exceeded_per_attempt_progressing
          | :budget_exceeded_per_attempt_handoff
          | :account_unhealthy_milestone_near
          | :account_unhealthy_checkpoint_available
          | :account_unhealthy_no_checkpoint
          | :budget_exceeded_per_attempt_downshift
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
      budget_exceeded: normalize_budget_signal(signal_input(input, :budget_exceeded)),
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

  defp normalize_budget_signal(value) when value in [nil, false], do: %{active: false, scope: nil}

  defp normalize_budget_signal(scope) when scope in [:cumulative, :per_attempt] do
    %{active: true, scope: scope}
  end

  defp normalize_budget_signal(value) when is_map(value) do
    normalized = atomize_keys(value)
    scope = normalize_budget_scope(normalized[:scope] || normalized[:kind] || normalized[:mode])
    active = normalized[:active] != false and not is_nil(scope)
    progress_status_present? = Map.has_key?(normalized, :progress_status)
    progress_status = normalize_progress_status_string(normalized[:progress_status])
    progress_changed_present? = Map.has_key?(normalized, :progress_changed?)
    progress_changed = normalized[:progress_changed?] == true or progress_status == "changed"
    checkpoint_usable_present? = Map.has_key?(normalized, :checkpoint_usable?)
    progress_repeat_count_present? = Map.has_key?(normalized, :progress_repeat_count)
    progress_repeat_count = normalize_non_negative_integer(normalized[:progress_repeat_count])
    progress_fingerprint_present? = Map.has_key?(normalized, :progress_fingerprint)
    progress_fingerprint = normalize_non_empty_string(normalized[:progress_fingerprint])
    budget_signal_role_present? = Map.has_key?(normalized, :budget_signal_role)
    budget_signal_role = normalize_non_empty_string(normalized[:budget_signal_role])

    normalized
    |> Map.put(:active, active)
    |> Map.put(:scope, scope)
    |> Map.put_new(:cheaper_profile?, cheaper_profile?(normalized))
    |> maybe_put_budget_signal_field(
      checkpoint_usable_present?,
      :checkpoint_usable?,
      normalized[:checkpoint_usable?] == true
    )
    |> maybe_put_budget_signal_field(progress_status_present?, :progress_status, progress_status)
    |> maybe_put_budget_signal_field(
      progress_changed_present? || progress_status_present?,
      :progress_changed?,
      progress_changed
    )
    |> maybe_put_budget_signal_field(progress_repeat_count_present?, :progress_repeat_count, progress_repeat_count)
    |> maybe_put_budget_signal_field(progress_fingerprint_present?, :progress_fingerprint, progress_fingerprint)
    |> maybe_put_budget_signal_field(budget_signal_role_present?, :budget_signal_role, budget_signal_role)
  end

  defp normalize_budget_signal(_value), do: %{active: false, scope: nil}

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
    |> maybe_add_rule(:budget_exceeded_cumulative, cumulative_budget?(signals.budget_exceeded))
    |> maybe_add_rule(
      :budget_exceeded_per_attempt_bootstrap,
      per_attempt_budget_bootstrap?(signals.budget_exceeded)
    )
    |> maybe_add_rule(
      :budget_exceeded_per_attempt_handoff,
      per_attempt_budget_handoff?(signals.budget_exceeded)
    )
    |> maybe_add_rule(
      :budget_exceeded_per_attempt_progressing,
      per_attempt_budget_progressing?(signals.budget_exceeded)
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
    |> maybe_add_rule(
      :budget_exceeded_per_attempt_downshift,
      per_attempt_budget_downshift?(signals.budget_exceeded)
    )
  end

  defp pick_rule([]), do: {:default_allow_retry, []}
  defp pick_rule([selected | suppressed]), do: {selected, suppressed}

  defp action_for_rule(:unsafe_preemption_required), do: :immediate_preemption
  defp action_for_rule(:stale_workspace_head), do: :stop_with_classified_handoff
  defp action_for_rule(:validation_env_mismatch), do: :stop_with_classified_handoff
  defp action_for_rule(:retry_dedupe_hit), do: :stop_with_classified_handoff
  defp action_for_rule(:continuation_attempt_limit_exceeded), do: :stop_with_classified_handoff
  defp action_for_rule(:budget_exceeded_cumulative), do: :stop_with_classified_handoff
  defp action_for_rule(:budget_exceeded_per_attempt_bootstrap), do: :allow_retry
  defp action_for_rule(:budget_exceeded_per_attempt_progressing), do: :allow_retry
  defp action_for_rule(:budget_exceeded_per_attempt_handoff), do: :stop_with_classified_handoff
  defp action_for_rule(:account_unhealthy_milestone_near), do: :drain_to_milestone
  defp action_for_rule(:account_unhealthy_checkpoint_available), do: :checkpoint_and_failover
  defp action_for_rule(:account_unhealthy_no_checkpoint), do: :immediate_preemption
  defp action_for_rule(:budget_exceeded_per_attempt_downshift), do: :allow_downshifted_retry
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

  defp reason_for_rule(:budget_exceeded_cumulative, signals),
    do: signal_reason(signals.budget_exceeded, "budget_exceeded_cumulative")

  defp reason_for_rule(:budget_exceeded_per_attempt_bootstrap, signals),
    do: signal_reason(signals.budget_exceeded, "budget_exceeded_per_attempt_bootstrap")

  defp reason_for_rule(:budget_exceeded_per_attempt_progressing, signals),
    do: signal_reason(signals.budget_exceeded, "budget_exceeded_per_attempt_progressing")

  defp reason_for_rule(:budget_exceeded_per_attempt_handoff, signals),
    do: signal_reason(signals.budget_exceeded, "budget_exceeded_per_attempt_handoff")

  defp reason_for_rule(:account_unhealthy_milestone_near, signals),
    do: signal_reason(signals.account_unhealthy, "account_unhealthy_milestone_near")

  defp reason_for_rule(:account_unhealthy_checkpoint_available, signals),
    do: signal_reason(signals.account_unhealthy, "account_unhealthy_checkpoint_available")

  defp reason_for_rule(:account_unhealthy_no_checkpoint, signals),
    do: signal_reason(signals.account_unhealthy, "account_unhealthy_no_checkpoint")

  defp reason_for_rule(:budget_exceeded_per_attempt_downshift, signals),
    do: signal_reason(signals.budget_exceeded, "budget_exceeded_per_attempt_downshift")

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

  defp checkpoint_type_for_rule(:budget_exceeded_cumulative, signals),
    do: signal_field(signals.budget_exceeded, :checkpoint_type, "decision")

  defp checkpoint_type_for_rule(:budget_exceeded_per_attempt_bootstrap, signals),
    do: signal_field(signals.budget_exceeded, :checkpoint_type, "decision")

  defp checkpoint_type_for_rule(:budget_exceeded_per_attempt_progressing, signals),
    do: signal_field(signals.budget_exceeded, :checkpoint_type, "decision")

  defp checkpoint_type_for_rule(:budget_exceeded_per_attempt_handoff, signals),
    do: signal_field(signals.budget_exceeded, :checkpoint_type, "decision")

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

  defp risk_level_for_rule(:budget_exceeded_cumulative, signals),
    do: signal_field(signals.budget_exceeded, :risk_level, "medium")

  defp risk_level_for_rule(:budget_exceeded_per_attempt_bootstrap, signals),
    do: signal_field(signals.budget_exceeded, :risk_level, "medium")

  defp risk_level_for_rule(:budget_exceeded_per_attempt_progressing, signals),
    do: signal_field(signals.budget_exceeded, :risk_level, "medium")

  defp risk_level_for_rule(:budget_exceeded_per_attempt_handoff, signals),
    do: signal_field(signals.budget_exceeded, :risk_level, "medium")

  defp risk_level_for_rule(rule, signals)
       when rule in [:unsafe_preemption_required, :account_unhealthy_no_checkpoint] do
    signals
    |> signal_for_rule(rule)
    |> signal_field(:risk_level, "high")
  end

  defp risk_level_for_rule(_rule, _signals), do: nil

  defp retry_metadata_for_rule(:budget_exceeded_cumulative, signals),
    do: signal_retry_metadata(signals.budget_exceeded)

  defp retry_metadata_for_rule(:budget_exceeded_per_attempt_bootstrap, signals),
    do: signal_retry_metadata(signals.budget_exceeded)

  defp retry_metadata_for_rule(:budget_exceeded_per_attempt_progressing, signals),
    do: signal_retry_metadata(signals.budget_exceeded)

  defp retry_metadata_for_rule(:budget_exceeded_per_attempt_handoff, signals),
    do: signal_retry_metadata(signals.budget_exceeded)

  defp retry_metadata_for_rule(:budget_exceeded_per_attempt_downshift, signals),
    do: signal_retry_metadata(signals.budget_exceeded)

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
      budget_exceeded: budget_signal_payload(signals.budget_exceeded),
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

  defp budget_signal_payload(%{} = signal) do
    signal
    |> signal_payload()
    |> maybe_put(:scope, normalize_budget_scope_string(signal[:scope]))
    |> maybe_put(:cheaper_profile?, signal[:cheaper_profile?] == true)
    |> maybe_put_budget_payload_field(signal, :checkpoint_usable?)
    |> maybe_put_budget_payload_field(signal, :progress_status)
    |> maybe_put_budget_payload_field(signal, :progress_fingerprint)
    |> maybe_put_budget_payload_field(signal, :progress_repeat_count)
    |> maybe_put_budget_payload_field(signal, :budget_signal_role)
  end

  defp maybe_add_rule(rules, _rule, false), do: rules
  defp maybe_add_rule(rules, rule, true), do: rules ++ [rule]

  defp signal_active?(%{active: true}), do: true
  defp signal_active?(_signal), do: false

  defp cumulative_budget?(%{active: true, scope: :cumulative}), do: true
  defp cumulative_budget?(_signal), do: false

  defp per_attempt_budget_handoff?(%{active: true, scope: :per_attempt} = signal) do
    cond do
      not per_attempt_budget_progress_allows_retry?(signal) -> true
      per_attempt_budget_bootstrap?(signal) -> false
      signal[:cheaper_profile?] == true -> false
      explicit_progress_signal?(signal) -> false
      true -> true
    end
  end

  defp per_attempt_budget_handoff?(_signal), do: false

  defp per_attempt_budget_bootstrap?(%{active: true, scope: :per_attempt} = signal) do
    signal[:cheaper_profile?] != true and signal[:budget_signal_role] == "bootstrap" and
      not explicit_progress_signal?(signal)
  end

  defp per_attempt_budget_bootstrap?(_signal), do: false

  defp per_attempt_budget_progressing?(%{active: true, scope: :per_attempt} = signal) do
    explicit_progress_signal?(signal) and signal[:cheaper_profile?] != true and
      per_attempt_budget_progress_allows_retry?(signal)
  end

  defp per_attempt_budget_progressing?(_signal), do: false

  defp per_attempt_budget_downshift?(%{active: true, scope: :per_attempt} = signal) do
    signal[:cheaper_profile?] == true and per_attempt_budget_progress_allows_retry?(signal)
  end

  defp per_attempt_budget_downshift?(_signal), do: false

  defp per_attempt_budget_progress_allows_retry?(signal) when is_map(signal) do
    if explicit_progress_signal?(signal) do
      signal[:checkpoint_usable?] == true and progress_changed?(signal)
    else
      true
    end
  end

  defp explicit_progress_signal?(signal) when is_map(signal) do
    Map.has_key?(signal, :checkpoint_usable?) or
      Map.has_key?(signal, :progress_status) or
      Map.has_key?(signal, :progress_changed?) or
      Map.has_key?(signal, :progress_fingerprint) or
      Map.has_key?(signal, :progress_repeat_count)
  end

  defp progress_changed?(signal) when is_map(signal) do
    signal[:progress_changed?] == true or normalize_progress_status(signal[:progress_status]) == :changed
  end

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
  defp signal_for_rule(signals, :budget_exceeded_cumulative), do: signals.budget_exceeded
  defp signal_for_rule(signals, :budget_exceeded_per_attempt_bootstrap), do: signals.budget_exceeded
  defp signal_for_rule(signals, :budget_exceeded_per_attempt_progressing), do: signals.budget_exceeded
  defp signal_for_rule(signals, :budget_exceeded_per_attempt_handoff), do: signals.budget_exceeded
  defp signal_for_rule(signals, :budget_exceeded_per_attempt_downshift), do: signals.budget_exceeded
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

  defp cheaper_profile?(signal) do
    signal[:cheaper_profile?] == true or
      (is_binary(signal[:cost_profile_key]) and signal[:cost_profile_key] != "")
  end

  defp normalize_budget_scope(value) when value in [:cumulative, :per_attempt], do: value

  defp normalize_budget_scope(value) when is_binary(value) do
    case String.trim(value) do
      "cumulative" -> :cumulative
      "per_attempt" -> :per_attempt
      _ -> nil
    end
  end

  defp normalize_budget_scope(_value), do: nil

  defp normalize_budget_scope_string(nil), do: nil
  defp normalize_budget_scope_string(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_progress_status_string(value) do
    case normalize_progress_status(value) do
      nil -> nil
      status -> Atom.to_string(status)
    end
  end

  defp normalize_progress_status(value) when value in [:changed, :repeated, :unavailable], do: value

  defp normalize_progress_status(value) when is_binary(value) do
    case String.trim(value) do
      "changed" -> :changed
      "repeated" -> :repeated
      "unavailable" -> :unavailable
      _ -> nil
    end
  end

  defp normalize_progress_status(_value), do: nil

  defp normalize_non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_non_empty_string(_value), do: nil

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_integer(_value), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {known_string_key_to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp known_string_key_to_atom("active"), do: :active
  defp known_string_key_to_atom("scope"), do: :scope
  defp known_string_key_to_atom("kind"), do: :kind
  defp known_string_key_to_atom("mode"), do: :mode
  defp known_string_key_to_atom("reason"), do: :reason
  defp known_string_key_to_atom("summary"), do: :summary
  defp known_string_key_to_atom("checkpoint_type"), do: :checkpoint_type
  defp known_string_key_to_atom("risk_level"), do: :risk_level
  defp known_string_key_to_atom("cheaper_profile?"), do: :cheaper_profile?
  defp known_string_key_to_atom("cost_profile_key"), do: :cost_profile_key
  defp known_string_key_to_atom("checkpoint_usable?"), do: :checkpoint_usable?
  defp known_string_key_to_atom("progress_status"), do: :progress_status
  defp known_string_key_to_atom("progress_fingerprint"), do: :progress_fingerprint
  defp known_string_key_to_atom("progress_repeat_count"), do: :progress_repeat_count
  defp known_string_key_to_atom("progress_changed?"), do: :progress_changed?
  defp known_string_key_to_atom("budget_signal_role"), do: :budget_signal_role
  defp known_string_key_to_atom("retry_metadata"), do: :retry_metadata
  defp known_string_key_to_atom("log_fields"), do: :log_fields
  defp known_string_key_to_atom(other), do: other

  defp maybe_put_budget_signal_field(signal, true, key, value), do: Map.put(signal, key, value)
  defp maybe_put_budget_signal_field(signal, false, _key, _value), do: signal

  defp maybe_put_budget_payload_field(payload, signal, key) when is_map(payload) and is_map(signal) do
    if Map.has_key?(signal, key) do
      Map.put(payload, key, Map.get(signal, key))
    else
      payload
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value), do: value
end
