defmodule SymphonyElixir.RunPhase do
  @moduledoc """
  Classifies active runs into coarse execution phases and derives heartbeat metadata.
  """

  @type phase ::
          :editing
          | :targeted_tests
          | :verification
          | :runtime_proof
          | :full_validate
          | :waiting_external
          | :waiting_ci
          | :publishing_pr

  @type milestone ::
          :code_ready
          | :validation_running
          | :pr_opened
          | :ci_failed
          | :handoff_ready

  @phase_labels %{
    editing: "editing",
    targeted_tests: "targeted tests",
    verification: "verification",
    runtime_proof: "runtime proof",
    full_validate: "full validate",
    waiting_external: "waiting external",
    waiting_ci: "waiting CI",
    publishing_pr: "publishing PR"
  }

  @milestone_labels %{
    code_ready: "code-ready",
    validation_running: "validation-running",
    pr_opened: "PR-opened",
    ci_failed: "CI-failed",
    handoff_ready: "handoff-ready"
  }

  @milestone_order [:code_ready, :validation_running, :pr_opened, :ci_failed, :handoff_ready]
  @milestone_rank Map.new(Enum.with_index(@milestone_order))
  @validation_phases MapSet.new([:targeted_tests, :verification, :runtime_proof, :full_validate])
  @phase_keys Map.keys(@phase_labels)

  @reportable_phases MapSet.new([
                       :targeted_tests,
                       :verification,
                       :runtime_proof,
                       :full_validate,
                       :waiting_external,
                       :waiting_ci,
                       :publishing_pr
                     ])

  @launch_app_notice "launch-app missing, using local HTTP/UI fallback"

  @spec initialize(map(), DateTime.t() | nil) :: map()
  def initialize(running_entry, started_at \\ nil) when is_map(running_entry) do
    started_at = started_at || Map.get(running_entry, :started_at) || DateTime.utc_now()

    running_entry
    |> Map.put_new(:run_phase, :editing)
    |> Map.put_new(:phase_started_at, started_at)
    |> Map.put_new(:current_command, nil)
    |> Map.put_new(:external_step, nil)
    |> Map.put_new(:operational_notice, nil)
    |> Map.put_new(:last_reported_phase, nil)
    |> Map.put_new(:reported_milestones, MapSet.new())
    |> Map.put_new(:pending_milestones, MapSet.new())
    |> Map.put_new(:pre_run_hook_active, false)
    |> Map.put_new(:pre_run_hook_started_at, nil)
    |> Map.put_new(:pre_run_hook_timeout_ms, nil)
  end

  @spec apply_update(map(), map()) :: map()
  def apply_update(running_entry, update) when is_map(running_entry) and is_map(update) do
    running_entry = initialize(running_entry)
    timestamp = Map.get(update, :timestamp) || DateTime.utc_now()
    existing_phase = normalize_phase(Map.get(running_entry, :run_phase)) || :editing
    existing_notice = Map.get(running_entry, :operational_notice)
    {current_command, external_step} = resolve_step_context(running_entry, update)
    phase = resolve_phase(current_command, external_step)
    phase_started_at = resolve_phase_started_at(running_entry, phase, existing_phase, timestamp)
    operational_notice = resolve_operational_notice(existing_notice, update, phase, existing_phase)

    running_entry
    |> Map.put(:run_phase, phase)
    |> Map.put(:phase_started_at, phase_started_at)
    |> Map.put(:current_command, current_command)
    |> Map.put(:external_step, external_step)
    |> Map.put(:operational_notice, operational_notice)
  end

  @spec activity_fields(map(), DateTime.t(), integer(), integer() | nil) :: map()
  def activity_fields(running_entry, now, stall_timeout_ms, hook_timeout_ms)
      when is_map(running_entry) do
    last_activity_at = Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
    effective_stall_timeout_ms = effective_stall_timeout_ms(running_entry, now, stall_timeout_ms, hook_timeout_ms)
    elapsed_ms = elapsed_since(last_activity_at, now)

    %{
      last_activity_at: last_activity_at,
      elapsed_ms: elapsed_ms,
      stall_timeout_ms: effective_stall_timeout_ms,
      activity_state: activity_state(elapsed_ms, effective_stall_timeout_ms)
    }
  end

  @spec snapshot_fields(map(), DateTime.t(), integer(), integer() | nil) :: map()
  def snapshot_fields(running_entry, now, stall_timeout_ms, hook_timeout_ms \\ nil)
      when is_map(running_entry) do
    phase =
      normalize_phase(Map.get(running_entry, :run_phase)) ||
        phase_for_command(Map.get(running_entry, :current_command)) ||
        phase_for_external_step(Map.get(running_entry, :external_step)) ||
        :editing

    phase_started_at = Map.get(running_entry, :phase_started_at) || Map.get(running_entry, :started_at)
    activity = activity_fields(running_entry, now, stall_timeout_ms, hook_timeout_ms)

    %{
      run_phase: phase_label(phase),
      phase_started_at: phase_started_at,
      last_activity_at: activity.last_activity_at,
      activity_state: activity.activity_state,
      current_command: Map.get(running_entry, :current_command),
      external_step: Map.get(running_entry, :external_step),
      current_step: current_step(running_entry),
      operational_notice: Map.get(running_entry, :operational_notice)
    }
  end

  @spec current_step(map()) :: String.t() | nil
  def current_step(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :current_command) || Map.get(running_entry, :external_step)
  end

  @spec transition_reportable?(map(), map()) :: boolean()
  def transition_reportable?(previous_entry, current_entry)
      when is_map(previous_entry) and is_map(current_entry) do
    previous_phase = normalize_phase(Map.get(previous_entry, :run_phase))
    current_phase = normalize_phase(Map.get(current_entry, :run_phase))

    current_phase != previous_phase and reportable_phase?(current_phase)
  end

  @spec phase_signal_comment(map()) :: String.t() | nil
  def phase_signal_comment(running_entry) when is_map(running_entry) do
    phase = normalize_phase(Map.get(running_entry, :run_phase))

    if reportable_phase?(phase) do
      [
        "### Symphony run phase",
        "",
        "- phase: `#{phase_label(phase)}`"
      ]
      |> maybe_append_labeled_detail("command", Map.get(running_entry, :current_command))
      |> maybe_append_labeled_detail("external_step", Map.get(running_entry, :external_step))
      |> maybe_append_labeled_detail("notice", Map.get(running_entry, :operational_notice))
      |> Enum.join("\n")
    end
  end

  @spec mark_phase_reported(map()) :: map()
  def mark_phase_reported(running_entry) when is_map(running_entry) do
    Map.put(running_entry, :last_reported_phase, normalize_phase(Map.get(running_entry, :run_phase)))
  end

  @spec phase_label(phase() | String.t() | nil) :: String.t() | nil
  def phase_label(nil), do: nil

  def phase_label(phase) do
    phase
    |> normalize_phase()
    |> then(&Map.get(@phase_labels, &1))
  end

  @spec reportable_phase?(phase() | String.t() | nil) :: boolean()
  def reportable_phase?(phase) do
    phase
    |> normalize_phase()
    |> then(&MapSet.member?(@reportable_phases, &1))
  end

  @spec transition_milestones(map(), map()) :: [milestone()]
  def transition_milestones(previous_entry, current_entry)
      when is_map(previous_entry) and is_map(current_entry) do
    previous_phase = normalize_phase(Map.get(previous_entry, :run_phase))
    current_phase = normalize_phase(Map.get(current_entry, :run_phase))

    []
    |> maybe_add_validation_milestones(previous_phase, current_phase)
    |> maybe_add_pr_opened_milestone(previous_phase, current_phase)
    |> Enum.uniq()
  end

  def transition_milestones(_previous_entry, _current_entry), do: []

  @spec sort_milestones([milestone()]) :: [milestone()]
  def sort_milestones(milestones) when is_list(milestones) do
    milestones
    |> Enum.filter(&(&1 in @milestone_order))
    |> Enum.uniq()
    |> Enum.sort_by(&Map.get(@milestone_rank, &1, 999))
  end

  def sort_milestones(_milestones), do: []

  @spec milestone_label(milestone() | String.t() | nil) :: String.t() | nil
  def milestone_label(nil), do: nil

  def milestone_label(value) do
    case normalize_milestone(value) do
      nil -> nil
      milestone -> Map.get(@milestone_labels, milestone)
    end
  end

  @spec milestone_comment(milestone(), map()) :: String.t()
  def milestone_comment(milestone, running_entry \\ %{}) do
    label = milestone_label(milestone) || "unknown"

    [
      "### Symphony milestone",
      "",
      "- milestone: `#{label}`"
    ]
    |> maybe_append_labeled_detail("command", Map.get(running_entry, :current_command))
    |> maybe_append_labeled_detail("external_step", Map.get(running_entry, :external_step))
    |> maybe_append_labeled_detail("notice", Map.get(running_entry, :operational_notice))
    |> Enum.join("\n")
  end

  @spec milestone_reported?(map(), milestone()) :: boolean()
  def milestone_reported?(running_entry, milestone) when is_map(running_entry) do
    normalized = normalize_milestone(milestone)

    running_entry
    |> Map.get(:reported_milestones, MapSet.new())
    |> normalize_milestone_set()
    |> MapSet.member?(normalized)
  end

  @spec mark_milestone_reported(map(), milestone()) :: map()
  def mark_milestone_reported(running_entry, milestone) when is_map(running_entry) do
    normalized = normalize_milestone(milestone)

    if is_nil(normalized) do
      running_entry
    else
      reported =
        running_entry
        |> Map.get(:reported_milestones, MapSet.new())
        |> normalize_milestone_set()
        |> MapSet.put(normalized)

      Map.put(running_entry, :reported_milestones, reported)
    end
  end

  @spec mark_milestone_pending(map(), milestone()) :: map()
  def mark_milestone_pending(running_entry, milestone) when is_map(running_entry) do
    normalized = normalize_milestone(milestone)

    if is_nil(normalized) do
      running_entry
    else
      pending =
        running_entry
        |> Map.get(:pending_milestones, MapSet.new())
        |> normalize_milestone_set()
        |> MapSet.put(normalized)

      Map.put(running_entry, :pending_milestones, pending)
    end
  end

  @spec clear_pending_milestone(map(), milestone()) :: map()
  def clear_pending_milestone(running_entry, milestone) when is_map(running_entry) do
    normalized = normalize_milestone(milestone)

    if is_nil(normalized) do
      running_entry
    else
      pending =
        running_entry
        |> Map.get(:pending_milestones, MapSet.new())
        |> normalize_milestone_set()
        |> MapSet.delete(normalized)

      Map.put(running_entry, :pending_milestones, pending)
    end
  end

  defp activity_state(_elapsed_ms, stall_timeout_ms)
       when not is_integer(stall_timeout_ms) or stall_timeout_ms <= 0,
       do: "alive"

  defp activity_state(elapsed_ms, stall_timeout_ms) when is_integer(elapsed_ms) do
    slow_threshold_ms = max(div(stall_timeout_ms, 2), 1)

    cond do
      elapsed_ms >= stall_timeout_ms -> "stalled"
      elapsed_ms >= slow_threshold_ms -> "slow"
      true -> "alive"
    end
  end

  defp activity_state(_elapsed_ms, _stall_timeout_ms), do: "alive"

  defp effective_stall_timeout_ms(running_entry, now, stall_timeout_ms, hook_timeout_ms) do
    base_timeout_ms = normalize_timeout_ms(stall_timeout_ms)
    hook_timeout_ms = resolve_pre_run_hook_timeout_ms(running_entry, hook_timeout_ms)

    if pre_run_hook_guard_active?(running_entry, now, hook_timeout_ms) do
      max(base_timeout_ms, hook_timeout_ms)
    else
      base_timeout_ms
    end
  end

  defp pre_run_hook_guard_active?(running_entry, now, hook_timeout_ms)
       when is_map(running_entry) and is_integer(hook_timeout_ms) and hook_timeout_ms > 0 do
    pre_run_hook_active? = Map.get(running_entry, :pre_run_hook_active) == true
    pre_run_hook_started_at = Map.get(running_entry, :pre_run_hook_started_at) || Map.get(running_entry, :started_at)
    codex_started? = match?(%DateTime{}, Map.get(running_entry, :last_codex_timestamp))
    elapsed_ms = elapsed_since(pre_run_hook_started_at, now)

    pre_run_hook_active? and not codex_started? and
      match?(%DateTime{}, pre_run_hook_started_at) and
      is_integer(elapsed_ms) and elapsed_ms <= hook_timeout_ms
  end

  defp pre_run_hook_guard_active?(_running_entry, _now, _hook_timeout_ms), do: false

  defp resolve_pre_run_hook_timeout_ms(running_entry, hook_timeout_ms) when is_map(running_entry) do
    running_entry
    |> Map.get(:pre_run_hook_timeout_ms)
    |> normalize_timeout_ms()
    |> case do
      0 -> normalize_timeout_ms(hook_timeout_ms)
      value -> value
    end
  end

  defp elapsed_since(%DateTime{} = timestamp, %DateTime{} = now) do
    max(0, DateTime.diff(now, timestamp, :millisecond))
  end

  defp elapsed_since(_timestamp, _now), do: nil

  defp normalize_timeout_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout_ms(_value), do: 0

  defp phase_for_command(nil), do: nil

  defp phase_for_command(command) when is_binary(command) do
    normalized = command |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        nil

      waiting_ci_command?(normalized) ->
        :waiting_ci

      publishing_pr_command?(normalized) ->
        :publishing_pr

      full_validate_command?(normalized) ->
        :full_validate

      waiting_external_command?(normalized) ->
        :waiting_external

      runtime_proof_command?(normalized) ->
        :runtime_proof

      targeted_tests_command?(normalized) ->
        :targeted_tests

      true ->
        nil
    end
  end

  defp phase_for_command(_command), do: nil

  defp waiting_ci_command?(normalized) do
    matches_any?(normalized, [
      "github_wait_for_checks",
      "gh pr checks --watch",
      "gh run watch"
    ])
  end

  defp publishing_pr_command?(normalized) do
    matches_any?(normalized, ["git push", "gh pr "])
  end

  defp full_validate_command?(normalized) do
    matches_any?(normalized, ["make symphony-validate", "make -c elixir all"]) or
      Regex.match?(~r/(^|[;&|])\s*make test(\s|$)/, normalized)
  end

  defp waiting_external_command?(normalized) do
    matches_any?(normalized, ["make symphony-live-e2e", "live_e2e"])
  end

  defp runtime_proof_command?(normalized) do
    matches_any?(normalized, [
      "make symphony-dashboard-checks",
      "launch-app",
      "/health",
      "/api/dashboard",
      "team-master-ui-e2e"
    ])
  end

  defp targeted_tests_command?(normalized) do
    matches_any?(normalized, ["mix test", "pytest", "symphony-preflight"])
  end

  defp phase_for_external_step(nil), do: nil

  defp phase_for_external_step(external_step) when is_binary(external_step) do
    normalized = external_step |> String.trim() |> String.downcase()

    cond do
      normalized == "github_wait_for_checks" ->
        :waiting_ci

      normalized == "symphony_handoff_check" ->
        :verification

      normalized == "exec_wait" ->
        :waiting_external

      String.ends_with?(normalized, "browser_wait_for") ->
        :waiting_external

      true ->
        nil
    end
  end

  defp phase_for_external_step(_external_step), do: nil

  defp command_finished?(%{event: :notification, payload: payload}) when is_map(payload) do
    method = normalize_event_method(map_value(payload, ["method", :method]))

    method == "codex/event/exec_command_end" or
      command_execution_item_lifecycle?(payload, ["item/completed", "codex/event/item_completed"])
  end

  defp command_finished?(_update), do: false

  defp tool_step_finished?(%{event: event})
       when event in [:tool_call_completed, :tool_call_failed, :unsupported_tool_call],
       do: true

  defp tool_step_finished?(_update), do: false

  defp extract_command(%{payload: payload}) when is_map(payload) do
    method = normalize_event_method(map_value(payload, ["method", :method]))

    if method in [
         "codex/event/exec_command_begin",
         "item/commandExecution/requestApproval",
         "execCommandApproval"
       ] or command_execution_item_lifecycle?(payload, ["item/started", "codex/event/item_started"]) do
      payload
      |> extract_first_path([
        ["params", "msg", "command"],
        [:params, :msg, :command],
        ["params", "msg", "parsed_cmd"],
        [:params, :msg, :parsed_cmd],
        ["params", "parsedCmd"],
        [:params, :parsedCmd],
        ["params", "command"],
        [:params, :command],
        ["params", "cmd"],
        [:params, :cmd],
        ["params", "argv"],
        [:params, :argv],
        ["params", "args"],
        [:params, :args],
        ["params", "item", "command"],
        [:params, :item, :command],
        ["params", "item"],
        [:params, :item],
        ["params", "item", "parsedCmd"],
        [:params, :item, :parsedCmd],
        ["params", "item", "cmd"],
        [:params, :item, :cmd],
        ["params", "item", "argv"],
        [:params, :item, :argv],
        ["params", "item", "args"],
        [:params, :item, :args],
        ["params", "msg", "payload", "command"],
        [:params, :msg, :payload, :command],
        ["params", "msg", "payload"],
        [:params, :msg, :payload],
        ["params", "msg", "payload", "parsedCmd"],
        [:params, :msg, :payload, :parsedCmd],
        ["params", "msg", "payload", "cmd"],
        [:params, :msg, :payload, :cmd],
        ["params", "msg", "payload", "argv"],
        [:params, :msg, :payload, :argv],
        ["params", "msg", "payload", "args"],
        [:params, :msg, :payload, :args]
      ])
      |> normalize_command()
    end
  end

  defp extract_command(_update), do: nil

  defp command_execution_item_lifecycle?(payload, expected_methods)
       when is_map(payload) and is_list(expected_methods) do
    method = normalize_event_method(map_value(payload, ["method", :method]))

    method in expected_methods and command_execution_item_type?(payload)
  end

  defp command_execution_item_type?(payload) when is_map(payload) do
    payload
    |> extract_first_path([
      ["params", "item", "type"],
      [:params, :item, :type],
      ["params", "msg", "payload", "type"],
      [:params, :msg, :payload, :type]
    ])
    |> normalize_command_execution_type?()
  end

  defp normalize_command_execution_type?(type) do
    if is_binary(type) do
      normalized =
        type
        |> String.trim()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]/u, "")

      normalized == "commandexecution"
    else
      false
    end
  end

  defp normalize_event_method(method) do
    normalized =
      cond do
        is_binary(method) -> method
        is_atom(method) -> Atom.to_string(method)
        true -> nil
      end

    if is_binary(normalized) do
      trimmed = String.trim(normalized)
      if trimmed == "", do: nil, else: trimmed
    end
  end

  defp extract_external_step(%{event: :tool_call_started, payload: payload}) when is_map(payload) do
    extract_tool_name(payload)
  end

  defp extract_external_step(_update), do: nil

  defp extract_tool_name(payload) when is_map(payload) do
    payload
    |> extract_first_path([
      ["params", "tool"],
      [:params, :tool],
      ["params", "name"],
      [:params, :name]
    ])
    |> normalize_command()
  end

  defp extract_tool_name(_payload), do: nil

  defp extract_operational_notice(update) when is_map(update) do
    update
    |> operational_notice_candidates()
    |> Enum.find_value(&operational_notice_from_text/1)
  end

  defp operational_notice_candidates(update) do
    [
      extract_first_path(update, [
        [:payload, "params", "msg", "payload", "delta"],
        [:payload, :params, :msg, :payload, :delta],
        [:payload, "params", "msg", "content"],
        [:payload, :params, :msg, :content],
        [:payload, "params", "msg", "payload", "summaryText"],
        [:payload, :params, :msg, :payload, :summaryText]
      ]),
      Map.get(update, :raw),
      inspect(Map.get(update, :payload))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp operational_notice_from_text(text) when is_binary(text) do
    normalized = String.downcase(text)

    cond do
      String.contains?(normalized, "launch-app missing") and String.contains?(normalized, "fallback") ->
        @launch_app_notice

      String.contains?(normalized, @launch_app_notice) ->
        @launch_app_notice

      true ->
        nil
    end
  end

  defp operational_notice_from_text(_text), do: nil

  defp maybe_add_validation_milestones(milestones, previous_phase, current_phase) do
    cond do
      validation_phase?(current_phase) and not validation_phase?(previous_phase) ->
        milestones ++ [:code_ready, :validation_running]

      validation_phase?(current_phase) and validation_phase?(previous_phase) ->
        milestones ++ [:validation_running]

      true ->
        milestones
    end
  end

  defp maybe_add_pr_opened_milestone(milestones, previous_phase, current_phase) do
    if current_phase == :publishing_pr and previous_phase != :publishing_pr do
      milestones ++ [:pr_opened]
    else
      milestones
    end
  end

  defp validation_phase?(phase) do
    MapSet.member?(@validation_phases, phase)
  end

  defp normalize_milestone(milestone) when milestone in @milestone_order, do: milestone

  defp normalize_milestone(milestone) when is_binary(milestone) do
    normalized =
      milestone
      |> String.trim()
      |> String.downcase()

    Enum.find_value(@milestone_labels, fn {key, label} ->
      if String.downcase(label) == normalized, do: key
    end)
  end

  defp normalize_milestone(_milestone), do: nil

  defp normalize_milestone_set(%MapSet{} = milestones), do: milestones
  defp normalize_milestone_set(milestones) when is_list(milestones), do: MapSet.new(milestones)
  defp normalize_milestone_set(_milestones), do: MapSet.new()

  defp maybe_append_labeled_detail(lines, _label, value) when value in [nil, ""], do: lines

  defp maybe_append_labeled_detail(lines, label, value),
    do: lines ++ ["- #{label}: `#{value}`"]

  defp normalize_phase(phase) when phase in @phase_keys, do: phase

  defp normalize_phase(phase) when is_binary(phase) do
    normalized =
      phase
      |> String.trim()
      |> String.downcase()

    Enum.find_value(@phase_labels, fn {key, label} ->
      if String.downcase(label) == normalized, do: key
    end)
  end

  defp normalize_phase(_phase), do: nil

  defp resolve_step_context(running_entry, update) do
    cond do
      tool_step = extract_external_step(update) ->
        {Map.get(running_entry, :current_command), tool_step}

      command = extract_command(update) ->
        {command, nil}

      tool_step_finished?(update) ->
        if extract_tool_name(Map.get(update, :payload)) == "exec_wait" do
          {nil, nil}
        else
          {Map.get(running_entry, :current_command), nil}
        end

      command_finished?(update) ->
        {nil, Map.get(running_entry, :external_step)}

      true ->
        {Map.get(running_entry, :current_command), Map.get(running_entry, :external_step)}
    end
  end

  defp resolve_phase(current_command, external_step) do
    phase_for_external_step(external_step) ||
      phase_for_command(current_command) ||
      :editing
  end

  defp resolve_phase_started_at(running_entry, phase, existing_phase, timestamp) do
    if phase == existing_phase do
      Map.get(running_entry, :phase_started_at) || timestamp
    else
      timestamp
    end
  end

  defp resolve_operational_notice(existing_notice, update, phase, existing_phase) do
    case extract_operational_notice(update) do
      nil when phase != existing_phase -> nil
      nil -> existing_notice
      notice -> notice
    end
  end

  defp extract_first_path(_payload, []), do: nil

  defp extract_first_path(payload, [path | rest]) do
    case map_path(payload, path) do
      nil -> extract_first_path(payload, rest)
      value -> value
    end
  end

  defp map_path(value, []), do: value

  defp map_path(value, [segment | rest]) when is_map(value) do
    value
    |> Map.get(segment)
    |> case do
      nil ->
        alternate = alternate_key(segment)

        if is_nil(alternate) do
          nil
        else
          map_path(Map.get(value, alternate), rest)
        end

      next ->
        map_path(next, rest)
    end
  end

  defp map_path(_value, _path), do: nil

  defp map_value(value, keys) when is_map(value) and is_list(keys) do
    Enum.find_value(keys, &Map.get(value, &1))
  end

  defp matches_any?(normalized, patterns) do
    Enum.any?(patterns, &String.contains?(normalized, &1))
  end

  defp alternate_key(key) when is_binary(key), do: String.to_atom(key)
  defp alternate_key(key) when is_atom(key), do: Atom.to_string(key)

  defp normalize_command(%{} = command) do
    binary_command = map_value(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])
    args = map_value(command, ["args", :args, "argv", :argv])

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> normalize_command()
    end
  end

  defp normalize_command(_command), do: nil
end
