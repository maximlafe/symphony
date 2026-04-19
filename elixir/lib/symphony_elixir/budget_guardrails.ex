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
           budget_signal_role: "hard_stop",
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
    %{stage: cost_stage, current_profile_key: current_profile_key} = cost_profile_context(context)
    progress = progress_surface_signal(context)

    attrs =
      %{
        budget_reason: :max_tokens_per_attempt_exceeded,
        budget_threshold: settings.codex.max_tokens_per_attempt,
        budget_observed_total: attempt_tokens,
        budget_issue_total_tokens: issue_total,
        budget_signal_role: "signal"
      }
      |> Map.put(:cost_stage, Atom.to_string(cost_stage))
      |> maybe_put(:budget_current_cost_profile_key, current_profile_key)
      |> maybe_put(:progress_status, progress_field(progress, :status))
      |> maybe_put(:progress_fingerprint, progress_field(progress, :fingerprint))
      |> maybe_put(:progress_repeat_count, progress_field(progress, :repeat_count))
      |> maybe_put(:checkpoint_usable?, progress_field(progress, :checkpoint_usable?))
      |> maybe_put(:progress_changed?, progress_field(progress, :changed?))

    base =
      decision(context, attrs)

    case cheaper_profile(settings, cost_stage, current_profile_key) do
      {:ok, profile_key, downshift_rule} ->
        if explicit_progress_guard?(progress) and not explicit_progress_allows_retry?(progress) do
          {:handoff, Map.put(base, :budget_decision, "handoff")}
        else
          {:downshift,
           base
           |> Map.put(:budget_decision, "downshift")
           |> Map.put(:budget_next_cost_profile_key, profile_key)
           |> Map.put(:budget_downshift_rule, downshift_rule)}
        end

      :error ->
        cond do
          explicit_progress_allows_retry?(progress) ->
            {:allow, Map.put(base, :budget_decision, "allow")}

          stage_bootstrap_retry?(context, settings, cost_stage, current_profile_key, progress) ->
            {:allow,
             base
             |> Map.put(:budget_decision, "allow")
             |> Map.put(:budget_signal_role, "bootstrap")}

          true ->
            {:handoff, Map.put(base, :budget_decision, "handoff")}
        end
    end
  end

  defp stage_bootstrap_retry?(context, settings, cost_stage, current_profile_key, progress)
       when cost_stage in [:implementation, :planning] and is_map(context) and
              is_binary(current_profile_key) do
    current_profile_key == stage_default(settings.codex.cost_policy, cost_stage) and
      map_get(context, :attempt) == 1 and bootstrap_progress_allows_retry?(progress)
  end

  defp stage_bootstrap_retry?(_context, _settings, _cost_stage, _current_profile_key, _progress),
    do: false

  defp bootstrap_progress_allows_retry?(%{mode: :implicit}), do: true

  defp bootstrap_progress_allows_retry?(%{mode: :explicit, checkpoint_usable?: false}),
    do: true

  defp bootstrap_progress_allows_retry?(_progress), do: false

  defp explicit_progress_guard?(%{mode: :explicit}), do: true
  defp explicit_progress_guard?(_progress), do: false

  defp explicit_progress_allows_retry?(%{mode: :explicit, checkpoint_usable?: true, changed?: true}), do: true
  defp explicit_progress_allows_retry?(_progress), do: false

  defp progress_surface_signal(context) when is_map(context) do
    if explicit_progress_context?(context), do: explicit_progress_surface_signal(context), else: %{mode: :implicit}
  end

  defp explicit_progress_surface_signal(context) when is_map(context) do
    previous_checkpoint = map_get(context, :previous_resume_checkpoint)
    current_checkpoint = map_get(context, :resume_checkpoint)
    previous_fingerprint = progress_fingerprint(previous_checkpoint)
    current_fingerprint = progress_fingerprint(current_checkpoint)

    checkpoint_usable? =
      checkpoint_usable?(previous_checkpoint) and checkpoint_usable?(current_checkpoint) and
        is_binary(previous_fingerprint) and is_binary(current_fingerprint)

    changed? = checkpoint_usable? and previous_fingerprint != current_fingerprint

    %{
      mode: :explicit,
      status: progress_status(checkpoint_usable?, changed?),
      fingerprint: current_fingerprint,
      repeat_count: progress_repeat_count(checkpoint_usable?, changed?),
      checkpoint_usable?: checkpoint_usable?,
      changed?: changed?
    }
  end

  defp progress_status(false, _changed), do: "unavailable"
  defp progress_status(true, true), do: "changed"
  defp progress_status(true, false), do: "repeated"

  defp progress_repeat_count(false, _changed), do: 0
  defp progress_repeat_count(true, true), do: 1
  defp progress_repeat_count(true, false), do: 2

  defp explicit_progress_context?(context) when is_map(context) do
    Map.has_key?(context, :resume_checkpoint) or
      Map.has_key?(context, "resume_checkpoint") or
      Map.has_key?(context, :previous_resume_checkpoint) or
      Map.has_key?(context, "previous_resume_checkpoint")
  end

  defp progress_field(%{mode: :explicit} = progress, key), do: Map.get(progress, key)
  defp progress_field(_progress, _key), do: nil

  defp checkpoint_usable?(%{} = checkpoint) do
    map_get(checkpoint, :resume_ready) == true or map_get(checkpoint, :available) == true
  end

  defp checkpoint_usable?(_checkpoint), do: false

  defp progress_fingerprint(%{} = checkpoint) do
    workpad_digest = checkpoint_workpad_digest(checkpoint)
    workspace_diff_fingerprint = checkpoint_workspace_diff_fingerprint(checkpoint)
    validation_bundle_fingerprint = checkpoint_validation_bundle_fingerprint(checkpoint)
    changed_files = checkpoint_changed_files(checkpoint)

    if is_binary(workpad_digest) or is_binary(workspace_diff_fingerprint) or
         is_binary(validation_bundle_fingerprint) or changed_files != [] do
      [
        "workpad_digest=#{workpad_digest || "none"}",
        "workspace_diff_fingerprint=#{workspace_diff_fingerprint || "none"}",
        "validation_bundle_fingerprint=#{validation_bundle_fingerprint || "none"}"
      ]
      |> Kernel.++(Enum.map(changed_files, &"changed_file=#{&1}"))
      |> Enum.join("|")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> then(&"progress:#{&1}")
    end
  end

  defp progress_fingerprint(_checkpoint), do: nil

  defp checkpoint_workpad_digest(%{} = checkpoint) do
    checkpoint
    |> map_get(:workpad_digest)
    |> normalize_optional_string()
  end

  defp checkpoint_workspace_diff_fingerprint(%{} = checkpoint) do
    checkpoint
    |> map_get(:workspace_diff_fingerprint)
    |> normalize_optional_string()
  end

  defp checkpoint_validation_bundle_fingerprint(%{} = checkpoint) do
    normalize_optional_string(map_get(checkpoint, :validation_bundle_fingerprint)) ||
      case map_get(checkpoint, :active_validation_snapshot) do
        %{} = snapshot ->
          snapshot
          |> map_get(:validation_bundle_fingerprint)
          |> normalize_optional_string()

        _ ->
          nil
      end
  end

  defp checkpoint_changed_files(%{} = checkpoint) do
    checkpoint
    |> map_get(:changed_files)
    |> normalize_changed_files()
  end

  defp normalize_changed_files(files) when is_list(files) do
    files
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_changed_files(_files), do: []

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

  defp cheaper_profile(settings, :implementation, current_profile_key) when is_binary(current_profile_key) do
    cheaper_stage_default_profile(settings, :implementation, current_profile_key, :implementation)
  end

  defp cheaper_profile(settings, :rework, current_profile_key) when is_binary(current_profile_key) do
    cheaper_stage_default_profile(settings, :rework, current_profile_key, :rework)
  end

  defp cheaper_profile(_settings, _cost_stage, _current_profile_key), do: :error

  defp cheaper_stage_default_profile(settings, default_stage, current_profile_key, cost_stage) do
    stage_default_key = stage_default(settings.codex.cost_policy, default_stage)

    with profile_key when is_binary(profile_key) <- stage_default_key,
         true <- profile_key != current_profile_key,
         {:ok, current_rank} <- profile_rank(settings.codex.cost_profiles, current_profile_key),
         {:ok, candidate_rank} <- profile_rank(settings.codex.cost_profiles, profile_key),
         true <- candidate_rank < current_rank do
      {:ok, profile_key, budget_downshift_rule(cost_stage)}
    else
      _ -> :error
    end
  end

  defp cost_profile_context(context) when is_map(context) do
    context_stage = context_cost_stage(context)
    context_profile_key = context_profile_key(context)

    case inferred_cost_decision(context) do
      %{stage: inferred_stage, profile_key: inferred_profile_key} ->
        %{
          stage: context_stage || normalize_cost_stage(inferred_stage),
          current_profile_key: context_profile_key || normalize_profile_key(inferred_profile_key)
        }

      _ ->
        %{
          stage: context_stage,
          current_profile_key: context_profile_key
        }
    end
  end

  defp context_cost_stage(context), do: context |> map_get(:cost_stage) |> normalize_cost_stage()

  defp context_profile_key(context),
    do: context |> map_get(:current_cost_profile_key) |> normalize_profile_key()

  defp inferred_cost_decision(%{issue: %Issue{} = issue}), do: Config.codex_cost_decision(issue)
  defp inferred_cost_decision(%{issue: issue}) when is_map(issue), do: Config.codex_cost_decision(issue)

  defp inferred_cost_decision(context) when is_map(context) do
    case map_get(context, :issue) do
      issue when is_map(issue) -> Config.codex_cost_decision(issue)
      _ -> %{}
    end
  end

  defp budget_downshift_rule(:implementation), do: "implementation_to_implementation_default"
  defp budget_downshift_rule(:rework), do: "rework_to_rework_default"

  defp normalize_cost_stage(stage) when stage in [:planning, :implementation, :rework, :handoff],
    do: stage

  defp normalize_cost_stage(stage) when is_binary(stage) do
    case stage |> String.trim() |> String.downcase() do
      "planning" -> :planning
      "implementation" -> :implementation
      "rework" -> :rework
      "handoff" -> :handoff
      _ -> nil
    end
  end

  defp normalize_cost_stage(_stage), do: nil

  defp normalize_profile_key(profile_key) when is_binary(profile_key) do
    case String.trim(profile_key) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_profile_key(_profile_key), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
