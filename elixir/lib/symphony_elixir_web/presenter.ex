defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    release = Config.release_metadata()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          release: release,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          active_codex_account_id: Map.get(snapshot, :active_codex_account_id),
          codex_accounts: Enum.map(Map.get(snapshot, :codex_accounts, []), &account_payload/1),
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
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
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      trace_id: trace_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: Path.join(Config.settings!().workspace.root, issue_identifier)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: runtime_payload(running)
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp trace_id_from_entries(running, retry),
    do: (running && running.trace_id) || (retry && retry.trace_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      trace_id: Map.get(entry, :trace_id),
      state: entry.state,
      codex_account_id: Map.get(entry, :codex_account_id),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      run_phase: Map.get(entry, :run_phase) || "editing",
      phase_started_at: iso8601(Map.get(entry, :phase_started_at) || entry.started_at),
      last_activity_at: iso8601(Map.get(entry, :last_activity_at) || entry.last_codex_timestamp || entry.started_at),
      activity_state: Map.get(entry, :activity_state) || "alive",
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
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      trace_id: Map.get(entry, :trace_id),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      error_class: Map.get(entry, :error_class)
    }
  end

  defp running_issue_payload(running) do
    %{
      codex_account_id: Map.get(running, :codex_account_id),
      trace_id: Map.get(running, :trace_id),
      session_id: running.session_id,
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
  end

  defp retry_issue_payload(retry) do
    %{
      trace_id: Map.get(retry, :trace_id),
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      error_class: Map.get(retry, :error_class)
    }
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

  defp runtime_payload(nil), do: %{}

  defp runtime_payload(running) do
    %{
      run_phase: Map.get(running, :run_phase) || "editing",
      phase_started_at: iso8601(Map.get(running, :phase_started_at) || running.started_at),
      last_activity_at: iso8601(Map.get(running, :last_activity_at) || running.last_codex_timestamp || running.started_at),
      activity_state: Map.get(running, :activity_state) || "alive",
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
