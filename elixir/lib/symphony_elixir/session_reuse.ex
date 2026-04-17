defmodule SymphonyElixir.SessionReuse do
  @moduledoc """
  Resolves persisted Codex thread continuity into a reused or fresh launch decision.
  """
  @dialyzer {:nowarn_function, build_launch_context: 3}
  @dialyzer {:nowarn_function, explicit_reset_requested?: 1}

  alias SymphonyElixir.{Config, ResumeCheckpoint}

  @policy_source "cost_profile+runtime_settings"
  @fresh_reasons ~w(dead_session account_failover explicit_reset phase_boundary)

  @type launch_context :: %{
          disposition: String.t(),
          fresh_reason: String.t() | nil,
          thread_id: String.t() | nil,
          account_id: String.t() | nil,
          policy_fingerprint: String.t(),
          policy_source: String.t(),
          account_transition: String.t() | nil
        }

  @spec build_launch_context(map(), Path.t()) :: launch_context()
  def build_launch_context(issue, workspace), do: build_launch_context(issue, workspace, [])

  @spec build_launch_context(map(), Path.t(), keyword()) :: launch_context()
  def build_launch_context(issue, workspace, opts) when is_list(opts) do
    checkpoint =
      opts
      |> Keyword.get(:resume_checkpoint)
      |> ResumeCheckpoint.for_prompt()

    account_id = normalize_optional_string(Keyword.get(opts, :account_id))
    cost_profile_key = normalize_optional_string(Keyword.get(opts, :cost_profile_key))
    current_policy_fingerprint = current_policy_fingerprint(issue, workspace, cost_profile_key)
    carrier = checkpoint_carrier(checkpoint)
    persisted_thread_id = carrier_field(carrier, "thread_id")
    persisted_account_id = carrier_field(carrier, "account_id")
    persisted_policy_fingerprint = carrier_field(carrier, "policy_fingerprint")

    fresh_reason =
      fresh_reason(
        checkpoint,
        persisted_thread_id,
        persisted_account_id,
        account_id,
        persisted_policy_fingerprint,
        current_policy_fingerprint
      )

    disposition = if(is_nil(fresh_reason), do: "reused", else: "fresh")

    %{
      disposition: disposition,
      fresh_reason: normalize_fresh_reason(fresh_reason),
      thread_id: if(disposition == "reused", do: persisted_thread_id),
      account_id: account_id,
      policy_fingerprint: current_policy_fingerprint,
      policy_source: @policy_source,
      account_transition: account_transition(persisted_account_id, account_id)
    }
  end

  @spec dead_session_fallback(launch_context()) :: launch_context()
  def dead_session_fallback(%{} = launch_context) do
    launch_context
    |> Map.put(:disposition, "fresh")
    |> Map.put(:fresh_reason, "dead_session")
    |> Map.put(:thread_id, nil)
  end

  @spec checkpoint_carrier(map() | nil) :: map()
  def checkpoint_carrier(checkpoint) when is_map(checkpoint) do
    case continuation_session(checkpoint) do
      %{} = carrier ->
        normalize_carrier(carrier)

      _ ->
        checkpoint
        |> flat_carrier_fields()
        |> normalize_carrier()
    end
  end

  def checkpoint_carrier(_checkpoint), do: %{}

  @spec checkpoint_payload(map()) :: map()
  def checkpoint_payload(source) when is_map(source) do
    existing_carrier = checkpoint_carrier(source)

    carrier =
      existing_carrier
      |> with_carrier_value("thread_id", source_value(source, :session_thread_id))
      |> with_carrier_value("account_id", source_value(source, :session_account_id))
      |> with_carrier_value("policy_fingerprint", source_value(source, :session_policy_fingerprint))
      |> with_carrier_value("policy_source", source_value(source, :session_policy_source))
      |> with_carrier_value("fresh_reason", source_fresh_reason(source))
      |> with_carrier_value("disposition", source_value(source, :session_reuse_disposition))
      |> normalize_carrier()

    %{
      "continuation_session" => carrier,
      "session_thread_id" => Map.get(carrier, "thread_id"),
      "session_account_id" => Map.get(carrier, "account_id"),
      "session_policy_fingerprint" => Map.get(carrier, "policy_fingerprint"),
      "session_policy_source" => Map.get(carrier, "policy_source"),
      "session_reuse_disposition" => Map.get(carrier, "disposition"),
      "fresh_reason" => Map.get(carrier, "fresh_reason")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def checkpoint_payload(_source), do: %{}

  defp continuation_session(checkpoint) when is_map(checkpoint) do
    Map.get(checkpoint, "continuation_session") || Map.get(checkpoint, :continuation_session)
  end

  defp fresh_reason(
         checkpoint,
         persisted_thread_id,
         persisted_account_id,
         account_id,
         persisted_policy_fingerprint,
         current_policy_fingerprint
       ) do
    cond do
      explicit_reset_requested?(checkpoint) ->
        "explicit_reset"

      is_nil(persisted_thread_id) ->
        "dead_session"

      account_failover?(persisted_account_id, account_id) ->
        "account_failover"

      phase_boundary?(persisted_policy_fingerprint, current_policy_fingerprint) ->
        "phase_boundary"

      true ->
        nil
    end
  end

  defp flat_carrier_fields(checkpoint) when is_map(checkpoint) do
    %{
      "thread_id" => source_value(checkpoint, :session_thread_id),
      "account_id" => source_value(checkpoint, :session_account_id),
      "policy_fingerprint" => source_value(checkpoint, :session_policy_fingerprint),
      "policy_source" => source_value(checkpoint, :session_policy_source),
      "fresh_reason" => source_fresh_reason(checkpoint),
      "disposition" => source_value(checkpoint, :session_reuse_disposition)
    }
  end

  defp with_carrier_value(carrier, _key, nil), do: carrier
  defp with_carrier_value(carrier, key, value), do: Map.put(carrier, key, value)

  defp carrier_field(carrier, key), do: normalize_optional_string(Map.get(carrier, key))

  defp current_policy_fingerprint(issue, workspace, cost_profile_key) do
    {:ok, settings} = Config.codex_runtime_settings(workspace)

    cost_context =
      issue
      |> issue_to_map()
      |> maybe_put_cost_profile_key(cost_profile_key)

    cost_decision = Config.codex_cost_decision(cost_context)

    payload = %{
      "approval_policy" => settings.approval_policy,
      "thread_sandbox" => settings.thread_sandbox,
      "turn_sandbox_policy" => settings.turn_sandbox_policy,
      "cost_profile_key" => Map.get(cost_decision, :profile_key),
      "cost_stage" => Map.get(cost_decision, :stage) |> normalize_atom_string(),
      "command_source" => Map.get(cost_decision, :command_source)
    }

    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp issue_to_map(%_{} = struct), do: Map.from_struct(struct)
  defp issue_to_map(%{} = map), do: map
  defp issue_to_map(_issue), do: %{}

  defp maybe_put_cost_profile_key(map, profile_key)
       when is_binary(profile_key) and profile_key != "" do
    Map.put(map, :cost_profile_key, profile_key)
  end

  defp maybe_put_cost_profile_key(map, _profile_key), do: map

  defp source_value(source, field) when is_map(source) do
    normalize_optional_string(Map.get(source, field) || Map.get(source, Atom.to_string(field)))
  end

  defp source_fresh_reason(source) when is_map(source) do
    normalize_fresh_reason(Map.get(source, :fresh_reason) || Map.get(source, "fresh_reason"))
  end

  defp normalize_carrier(%{} = carrier) do
    %{
      "thread_id" => normalize_optional_string(Map.get(carrier, "thread_id") || Map.get(carrier, :thread_id)),
      "account_id" => normalize_optional_string(Map.get(carrier, "account_id") || Map.get(carrier, :account_id)),
      "policy_fingerprint" => normalize_optional_string(Map.get(carrier, "policy_fingerprint") || Map.get(carrier, :policy_fingerprint)),
      "policy_source" => normalize_optional_string(Map.get(carrier, "policy_source") || Map.get(carrier, :policy_source)),
      "fresh_reason" => normalize_fresh_reason(Map.get(carrier, "fresh_reason") || Map.get(carrier, :fresh_reason)),
      "disposition" => normalize_optional_string(Map.get(carrier, "disposition") || Map.get(carrier, :disposition))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp explicit_reset_requested?(checkpoint) when is_map(checkpoint) do
    Map.get(checkpoint, "session_reset_requested") === true or
      Map.get(checkpoint, :session_reset_requested) === true
  end

  defp account_failover?(persisted_account_id, account_id) do
    is_binary(persisted_account_id) and is_binary(account_id) and persisted_account_id != account_id
  end

  defp phase_boundary?(persisted_policy_fingerprint, current_policy_fingerprint) do
    is_binary(persisted_policy_fingerprint) and
      persisted_policy_fingerprint != current_policy_fingerprint
  end

  defp account_transition(nil, _current), do: nil
  defp account_transition(previous, previous), do: nil

  defp account_transition(previous, current) do
    if is_binary(previous) and is_binary(current), do: "#{previous}->#{current}", else: nil
  end

  defp normalize_fresh_reason(reason) when reason in @fresh_reasons, do: reason

  defp normalize_fresh_reason(reason) when is_atom(reason),
    do: normalize_fresh_reason(Atom.to_string(reason))

  defp normalize_fresh_reason(_reason), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_atom_string(value) do
    if is_atom(value), do: Atom.to_string(value), else: normalize_optional_string(value)
  end
end
