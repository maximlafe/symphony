defmodule SymphonyElixir.BudgetGuardrails do
  @moduledoc """
  Deterministic token budget policy for retry boundaries.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @effort_rank %{
    "low" => 1,
    "medium" => 2,
    "high" => 3,
    "xhigh" => 4
  }

  @type decision :: {:allow, map()} | {:downshift, map()} | {:handoff, map()}

  @spec decide(map()) :: decision()
  def decide(context) when is_map(context) do
    settings = Config.settings!()
    attempt_tokens = non_negative_integer(Map.get(context, :attempt_tokens))
    issue_tokens_before_attempt = non_negative_integer(Map.get(context, :issue_tokens_before_attempt))
    issue_total = issue_tokens_before_attempt + attempt_tokens

    cond do
      exceeded?(issue_total, settings.codex.max_total_tokens) ->
        {:handoff,
         decision(context, %{
           budget_reason: :max_total_tokens_exceeded,
           budget_threshold: settings.codex.max_total_tokens,
           budget_observed_total: issue_total,
           budget_issue_total_tokens: issue_total,
           budget_decision: "handoff"
         })}

      exceeded?(attempt_tokens, settings.codex.max_tokens_per_attempt) ->
        per_attempt_decision(context, settings, attempt_tokens, issue_total)

      true ->
        {:allow, %{budget_attempt_tokens: attempt_tokens, budget_issue_total_tokens: issue_total}}
    end
  end

  def decide(_context), do: {:allow, %{budget_attempt_tokens: 0, budget_issue_total_tokens: 0}}

  defp per_attempt_decision(context, settings, attempt_tokens, issue_total) do
    base =
      decision(context, %{
        budget_reason: :max_tokens_per_attempt_exceeded,
        budget_threshold: settings.codex.max_tokens_per_attempt,
        budget_observed_total: attempt_tokens,
        budget_issue_total_tokens: issue_total,
        budget_decision: "downshift"
      })

    case cheaper_profile(context, settings) do
      {:ok, profile_key} ->
        {:downshift, Map.put(base, :budget_next_cost_profile_key, profile_key)}

      :error ->
        {:handoff, base}
    end
  end

  defp decision(context, attrs) do
    issue = Map.get(context, :issue)

    %{
      checkpoint_type: "decision",
      risk_level: "medium",
      summary: summary(attrs),
      issue_id: issue_id(issue),
      issue_identifier: issue_identifier(issue),
      budget_decision: Map.get(attrs, :budget_decision),
      attempt: Map.get(context, :attempt),
      delay_type: Map.get(context, :delay_type),
      budget_attempt_tokens: non_negative_integer(Map.get(context, :attempt_tokens)),
      issue_tokens_before_attempt: non_negative_integer(Map.get(context, :issue_tokens_before_attempt))
    }
    |> Map.merge(attrs)
  end

  defp summary(%{budget_reason: reason, budget_observed_total: observed, budget_threshold: threshold}) do
    "budget #{reason}: observed #{observed} exceeded threshold #{threshold}"
  end

  defp cheaper_profile(context, settings) do
    current = current_profile_key(context)
    implementation_default = stage_default(settings.codex.cost_policy, :implementation)

    with profile_key when is_binary(profile_key) <- implementation_default,
         true <- profile_key != current,
         {:ok, current_rank} <- profile_rank(settings.codex.cost_profiles, current),
         {:ok, candidate_rank} <- profile_rank(settings.codex.cost_profiles, profile_key),
         true <- candidate_rank < current_rank do
      {:ok, profile_key}
    else
      _ -> :error
    end
  end

  defp current_profile_key(%{current_cost_profile_key: profile_key}) when is_binary(profile_key),
    do: profile_key

  defp current_profile_key(%{issue: %Issue{} = issue}), do: Config.codex_cost_decision(issue).profile_key
  defp current_profile_key(%{issue: issue}) when is_map(issue), do: Config.codex_cost_decision(issue).profile_key
  defp current_profile_key(_context), do: nil

  defp stage_default(cost_policy, stage) when is_map(cost_policy) do
    cost_policy
    |> nested_map("stage_defaults")
    |> map_get(stage)
  end

  defp stage_default(_cost_policy, _stage), do: nil

  defp profile_rank(profiles, profile_key) when is_map(profiles) and is_binary(profile_key) do
    case map_get(profiles, profile_key) do
      profile when is_map(profile) ->
        effort = profile |> map_get("effort") |> normalize_effort()

        case Map.fetch(@effort_rank, effort) do
          {:ok, rank} -> {:ok, rank}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp profile_rank(_profiles, _profile_key), do: :error

  defp exceeded?(observed, threshold)
       when is_integer(observed) and is_integer(threshold) and threshold > 0,
       do: observed > threshold

  defp exceeded?(_observed, _threshold), do: false

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0

  defp issue_id(%Issue{id: id}), do: id
  defp issue_id(%{id: id}), do: id
  defp issue_id(_issue), do: nil

  defp issue_identifier(%Issue{identifier: identifier}), do: identifier
  defp issue_identifier(%{identifier: identifier}), do: identifier
  defp issue_identifier(_issue), do: nil

  defp normalize_effort(effort) when is_binary(effort), do: effort |> String.trim() |> String.downcase()
  defp normalize_effort(_effort), do: nil

  defp nested_map(map, key) do
    case map_get(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> map_get_atom_string_key(map, key)
    end
  end

  defp map_get(_map, _key), do: nil

  defp map_get_atom_string_key(map, key) do
    Enum.find_value(map, fn
      {map_key, value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: value

      _entry ->
        nil
    end)
  end
end
