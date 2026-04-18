defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, TelemetrySchema}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    release = Config.release_metadata()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running_by_identifier = entries_by_identifier(snapshot.running)
        retry_by_identifier = entries_by_identifier(snapshot.retrying)

        %{
          generated_at: generated_at,
          release: release,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          active_codex_account_id: Map.get(snapshot, :active_codex_account_id),
          codex_accounts: Enum.map(Map.get(snapshot, :codex_accounts, []), &account_payload/1),
          running:
            Enum.map(snapshot.running, fn running ->
              running_entry_payload(running, Map.get(retry_by_identifier, Map.get(running, :identifier)))
            end),
          retrying:
            Enum.map(snapshot.retrying, fn retry ->
              retry_entry_payload(retry, Map.get(running_by_identifier, Map.get(retry, :identifier)))
            end),
          codex_totals: snapshot.codex_totals,
          token_reason_totals: Map.get(snapshot, :token_reason_totals, %{}),
          rate_limits: snapshot.rate_limits,
          workspace: workspace_payload(Map.get(snapshot, :workspace))
        }

      :timeout ->
        %{
          generated_at: generated_at,
          release: release,
          error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
        }

      :unavailable ->
        %{
          generated_at: generated_at,
          release: release,
          error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}
        }
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    lifecycle = lifecycle_surface(running, retry)

    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      trace_id: trace_id_from_entries(running, retry),
      session_id: session_id_from_entries(running, retry),
      thread_id: thread_id_from_entries(running, retry),
      turn_id: turn_id_from_entries(running, retry),
      status: issue_status(running, retry),
      lifecycle_state: lifecycle.lifecycle_state,
      replacement_of_session_id: lifecycle.replacement_of_session_id,
      replacement_session_id: lifecycle.replacement_session_id,
      continuation_reason: lifecycle.continuation_reason,
      workspace: %{
        path: Path.join(Config.settings!().workspace.root, issue_identifier)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running, retry),
      retry: retry && retry_issue_payload(retry, running),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: runtime_payload(running, retry)
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp trace_id_from_entries(running, retry),
    do: (running && running.trace_id) || (retry && retry.trace_id)

  defp session_id_from_entries(running, retry),
    do: (running && Map.get(running, :session_id)) || (retry && Map.get(retry, :session_id))

  defp thread_id_from_entries(running, retry),
    do: (running && Map.get(running, :thread_id)) || (retry && Map.get(retry, :thread_id))

  defp turn_id_from_entries(running, retry),
    do: (running && Map.get(running, :turn_id)) || (retry && Map.get(retry, :turn_id))

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry, retry) do
    lifecycle = lifecycle_surface(entry, retry)
    runtime_source = Map.merge(entry, lifecycle)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      trace_id: Map.get(entry, :trace_id),
      state: entry.state,
      codex_account_id: Map.get(entry, :codex_account_id),
      session_id: entry.session_id,
      thread_id: Map.get(entry, :thread_id),
      turn_id: Map.get(entry, :turn_id),
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      run_phase: Map.get(entry, :run_phase) || "editing",
      phase_started_at: iso8601(Map.get(entry, :phase_started_at) || entry.started_at),
      last_activity_at: iso8601(Map.get(entry, :last_activity_at) || entry.last_codex_timestamp || entry.started_at),
      activity_state: Map.get(entry, :activity_state) || "alive",
      lifecycle_state: lifecycle.lifecycle_state,
      replacement_of_session_id: lifecycle.replacement_of_session_id,
      replacement_session_id: lifecycle.replacement_session_id,
      continuation_reason: lifecycle.continuation_reason,
      current_command: Map.get(entry, :current_command),
      external_step: Map.get(entry, :external_step),
      current_step:
        Map.get(entry, :current_step) || Map.get(entry, :current_command) ||
          Map.get(entry, :external_step),
      operational_notice: Map.get(entry, :operational_notice),
      verification_profile: Map.get(entry, :verification_profile),
      verification_result: Map.get(entry, :verification_result),
      verification_summary: Map.get(entry, :verification_summary),
      verification_missing_items: Map.get(entry, :verification_missing_items, []),
      verification_checked_at: iso8601(Map.get(entry, :verification_checked_at)),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
    |> Map.merge(TelemetrySchema.runtime_payload(runtime_source))
  end

  defp retry_entry_payload(entry, running) do
    lifecycle = lifecycle_surface(running, entry)
    runtime_source = Map.merge(entry, lifecycle)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      trace_id: Map.get(entry, :trace_id),
      session_id: Map.get(entry, :session_id),
      thread_id: Map.get(entry, :thread_id),
      turn_id: Map.get(entry, :turn_id),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      error_class: Map.get(entry, :error_class),
      lifecycle_state: lifecycle.lifecycle_state,
      replacement_of_session_id: lifecycle.replacement_of_session_id,
      replacement_session_id: lifecycle.replacement_session_id,
      continuation_reason: lifecycle.continuation_reason
    }
    |> Map.merge(TelemetrySchema.runtime_payload(runtime_source))
  end

  defp running_issue_payload(running, retry) do
    lifecycle = lifecycle_surface(running, retry)
    runtime_source = Map.merge(running, lifecycle)

    %{
      codex_account_id: Map.get(running, :codex_account_id),
      trace_id: Map.get(running, :trace_id),
      session_id: running.session_id,
      thread_id: Map.get(running, :thread_id),
      turn_id: Map.get(running, :turn_id),
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      run_phase: Map.get(running, :run_phase) || "editing",
      phase_started_at: iso8601(Map.get(running, :phase_started_at) || running.started_at),
      last_activity_at: iso8601(Map.get(running, :last_activity_at) || running.last_codex_timestamp || running.started_at),
      activity_state: Map.get(running, :activity_state) || "alive",
      lifecycle_state: lifecycle.lifecycle_state,
      replacement_of_session_id: lifecycle.replacement_of_session_id,
      replacement_session_id: lifecycle.replacement_session_id,
      continuation_reason: lifecycle.continuation_reason,
      current_command: Map.get(running, :current_command),
      external_step: Map.get(running, :external_step),
      current_step:
        Map.get(running, :current_step) || Map.get(running, :current_command) ||
          Map.get(running, :external_step),
      operational_notice: Map.get(running, :operational_notice),
      verification_profile: Map.get(running, :verification_profile),
      verification_result: Map.get(running, :verification_result),
      verification_summary: Map.get(running, :verification_summary),
      verification_missing_items: Map.get(running, :verification_missing_items, []),
      verification_checked_at: iso8601(Map.get(running, :verification_checked_at)),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
    |> Map.merge(TelemetrySchema.runtime_payload(runtime_source))
  end

  defp retry_issue_payload(retry, running) do
    lifecycle = lifecycle_surface(running, retry)
    runtime_source = Map.merge(retry, lifecycle)

    %{
      trace_id: Map.get(retry, :trace_id),
      session_id: Map.get(retry, :session_id),
      thread_id: Map.get(retry, :thread_id),
      turn_id: Map.get(retry, :turn_id),
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      error_class: Map.get(retry, :error_class),
      lifecycle_state: lifecycle.lifecycle_state,
      replacement_of_session_id: lifecycle.replacement_of_session_id,
      replacement_session_id: lifecycle.replacement_session_id,
      continuation_reason: lifecycle.continuation_reason
    }
    |> Map.merge(TelemetrySchema.runtime_payload(runtime_source))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        trace_id: Map.get(running, :trace_id),
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp runtime_payload(nil, _retry), do: %{}

  defp runtime_payload(running, retry) do
    lifecycle = lifecycle_surface(running, retry)
    runtime_source = Map.merge(running, lifecycle)

    %{
      run_phase: Map.get(running, :run_phase) || "editing",
      phase_started_at: iso8601(Map.get(running, :phase_started_at) || running.started_at),
      last_activity_at: iso8601(Map.get(running, :last_activity_at) || running.last_codex_timestamp || running.started_at),
      activity_state: Map.get(running, :activity_state) || "alive",
      lifecycle_state: lifecycle.lifecycle_state,
      replacement_of_session_id: lifecycle.replacement_of_session_id,
      replacement_session_id: lifecycle.replacement_session_id,
      continuation_reason: lifecycle.continuation_reason,
      current_command: Map.get(running, :current_command),
      external_step: Map.get(running, :external_step),
      current_step:
        Map.get(running, :current_step) || Map.get(running, :current_command) ||
          Map.get(running, :external_step),
      operational_notice: Map.get(running, :operational_notice),
      verification_profile: Map.get(running, :verification_profile),
      verification_result: Map.get(running, :verification_result),
      verification_summary: Map.get(running, :verification_summary),
      verification_missing_items: Map.get(running, :verification_missing_items, []),
      verification_checked_at: iso8601(Map.get(running, :verification_checked_at))
    }
    |> Map.merge(TelemetrySchema.runtime_payload(runtime_source))
  end

  defp lifecycle_surface(running, retry) do
    lifecycle_state = lifecycle_state(running, retry)

    replacement_of_session_id =
      entry_optional_string(retry, :replacement_of_session_id) ||
        entry_optional_string(running, :replacement_of_session_id) ||
        fallback_replacement_of_session_id(running, retry)

    replacement_session_id =
      entry_optional_string(running, :replacement_session_id) ||
        entry_optional_string(retry, :replacement_session_id) ||
        fallback_replacement_session_id(running, retry, replacement_of_session_id)

    continuation_reason =
      entry_optional_string(retry, :continuation_reason) ||
        entry_optional_string(running, :continuation_reason)

    %{
      lifecycle_state: lifecycle_state,
      replacement_of_session_id: replacement_of_session_id,
      replacement_session_id: replacement_session_id,
      continuation_reason: continuation_reason
    }
  end

  defp lifecycle_state(%{} = _running, %{} = _retry), do: "replacing"

  defp lifecycle_state(%{} = running, nil) do
    if session_id(running), do: "attached", else: "launch_pending"
  end

  defp lifecycle_state(nil, %{}), do: "retry_scheduled"
  defp lifecycle_state(nil, nil), do: nil

  defp fallback_replacement_of_session_id(%{} = running, %{} = _retry), do: session_id(running)
  defp fallback_replacement_of_session_id(_running, _retry), do: nil

  defp fallback_replacement_session_id(%{} = running, nil, replacement_of_session_id)
       when is_binary(replacement_of_session_id),
       do: session_id(running)

  defp fallback_replacement_session_id(_running, _retry, _replacement_of_session_id), do: nil

  defp session_id(entry), do: entry_optional_string(entry, :session_id)

  defp entries_by_identifier(entries) when is_list(entries) do
    entries
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn entry -> {Map.get(entry, :identifier), entry} end)
  end

  defp entries_by_identifier(_entries), do: %{}

  defp entry_optional_string(nil, _key), do: nil

  defp entry_optional_string(entry, key) when is_map(entry) and is_atom(key) do
    key_string = Atom.to_string(key)

    case Map.get(entry, key) || Map.get(entry, key_string) do
      nil ->
        nil

      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      value when is_atom(value) ->
        Atom.to_string(value)

      _ ->
        nil
    end
  end

  defp account_payload(account) when is_map(account) do
    %{
      id: Map.get(account, :id),
      healthy: Map.get(account, :healthy, false),
      health_reason: Map.get(account, :health_reason),
      auth_mode: Map.get(account, :auth_mode),
      email: Map.get(account, :email),
      plan_type: Map.get(account, :plan_type),
      requires_openai_auth: Map.get(account, :requires_openai_auth, false),
      checked_at: iso8601(Map.get(account, :checked_at)),
      missing_windows_mins: Map.get(account, :missing_windows_mins, []),
      insufficient_windows_mins: Map.get(account, :insufficient_windows_mins, []),
      rate_limits: Map.get(account, :rate_limits)
    }
  end

  defp account_payload(_account), do: %{}

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp workspace_payload(%{} = workspace) do
    keep_recent = Map.get(workspace, :done_closed_keep_count) || Map.get(workspace, :cleanup_keep_recent)

    %{
      usage_bytes: non_negative_integer(Map.get(workspace, :usage_bytes), 0),
      warning_threshold_bytes:
        positive_integer(
          Map.get(workspace, :warning_threshold_bytes),
          10 * 1024 * 1024 * 1024
        ),
      done_closed_keep_count: non_negative_integer(keep_recent, 5)
    }
  end

  defp workspace_payload(_workspace) do
    %{
      usage_bytes: 0,
      warning_threshold_bytes: 10 * 1024 * 1024 * 1024,
      done_closed_keep_count: 5
    }
  end

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
