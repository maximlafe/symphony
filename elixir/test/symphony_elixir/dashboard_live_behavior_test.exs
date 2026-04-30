defmodule SymphonyElixir.DashboardLiveBehaviorTest do
  use SymphonyElixir.TestSupport

  alias __MODULE__.StaticOrchestrator
  alias Phoenix.HTML.Safe
  alias SymphonyElixirWeb.{DashboardLive, Endpoint, Presenter}

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call({:select_active_codex_account, account_id}, _from, state) do
      snapshot = Keyword.fetch!(state, :snapshot)

      case Enum.find(snapshot.codex_accounts, &(&1.id == account_id)) do
        %{healthy: true} ->
          updated_snapshot = %{snapshot | active_codex_account_id: account_id}
          {:reply, {:ok, account_id}, Keyword.put(state, :snapshot, updated_snapshot)}

        %{} ->
          {:reply, {:error, :unhealthy_account}, state}

        nil ->
          {:reply, {:error, :invalid_account}, state}
      end
    end

    def handle_call(:request_refresh, _from, state) do
      refresh =
        Keyword.get(state, :refresh, %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        })

      {:reply, refresh, state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    end)

    :ok
  end

  test "render prioritizes operations, shows active account metadata, and collapses the accounts table" do
    payload = payload_from_snapshot(multi_account_snapshot())

    html = render_dashboard(%{payload: payload}, codex_accounts_expanded: true)

    assert section_offset(html, "Running sessions") < section_offset(html, "Retry queue")
    assert section_offset(html, "Retry queue") < section_offset(html, "Codex accounts")
    assert html =~ "Run phase"
    assert html =~ "Lifecycle"
    assert html =~ "full validate"
    assert html =~ "Active session"
    refute html =~ ~s(>attached</span>)
    assert html =~ "slow"
    assert html =~ "make symphony-validate"
    assert html =~ "launch-app missing, using local HTTP/UI fallback"
    assert html =~ "metric-value-break"
    assert html =~ "very.long.primary.email.address+alerts@example.com"
    assert html =~ ~s(<table class="data-table data-table-running">)
    assert html =~ ~s(<th>Current step</th>)
    assert html =~ ~s(<td data-label="Current step" class="current-step-cell">)
    assert html =~ ~s(<td data-label="Run phase">)
    assert html =~ ~s(<td data-label="Tokens">)
    assert html =~ ~s(<table class="data-table data-table-retry">)
    assert html =~ ~s(<th>Error</th>)
    assert html =~ ~s(<td data-label="Error">)
    assert html =~ ~s(<table class="data-table data-table-codex-accounts">)
    assert html =~ ~s(<th>Limits</th>)
    assert html =~ ~s(<td data-label="Limits">)
    assert html =~ ~s(<td data-label="Reason">)
    assert html =~ "ID primary"
    assert html =~ "enterprise"
    refute html =~ "<th>Email</th>"
    assert html =~ "5h: 18/100 left"
    assert html =~ "· at 22:00 UTC"
    assert html =~ "data-local-reset-at=\"2026-03-25T22:00:00Z\""
    assert html =~ "data-local-reset-style=\"time\""
    assert html =~ "7d: 12% used"
    assert html =~ "· 31 Mar UTC"
    assert html =~ "data-local-reset-at=\"2026-03-31T00:00:00Z\""
    assert html =~ "data-local-reset-style=\"date\""
    assert html =~ "· at 23:30 UTC"
    assert html =~ "data-local-reset-at=\"2026-03-25T23:30:00Z\""
    assert html =~ "· 1 Apr UTC"
    assert html =~ "data-local-reset-at=\"2026-04-01T00:00:00Z\""
    refute html =~ "Credits:"
    assert html =~ "Make active"

    collapsed_html = render_dashboard(%{payload: payload}, codex_accounts_expanded: false)
    assert collapsed_html =~ "Table collapsed."
    refute collapsed_html =~ "Make active"
  end

  test "render separates current step details and uses user-facing lifecycle labels" do
    long_current_step =
      "reviewing an intentionally long current step that must wrap inside the current step column without crowding lifecycle or token details"

    long_message =
      "last message with enough detail to prove secondary status copy stays in its own muted row instead of sharing the primary line"

    long_summary =
      "verification summary with a long runtime profile explanation that should wrap inside the current step detail stack"

    snapshot =
      multi_account_snapshot()
      |> put_in([:running, Access.at(0), :current_step], long_current_step)
      |> put_in([:running, Access.at(0), :last_codex_message], long_message)
      |> put_in([:running, Access.at(0), :verification_summary], long_summary)

    payload = payload_from_snapshot(snapshot)
    html = render_dashboard(%{payload: payload}, codex_accounts_expanded: true)

    assert html =~ "Active session"
    refute html =~ ~s(>attached</span>)
    assert html =~ ~s(<td data-label="Current step" class="current-step-cell">)
    assert html =~ ~s(<div class="current-step-stack">)
    assert html =~ ~s(<span class="current-step-primary">)
    assert html =~ ~s(<col style="width: 24rem;">)
    assert html =~ ~s(class="current-step-detail muted event-meta")
    assert html =~ ~s(class="current-step-detail muted")
    assert html =~ long_current_step
    assert html =~ long_message
    assert html =~ long_summary
  end

  test "render anchors relative resetInSeconds to payload generated_at instead of runtime now" do
    payload =
      multi_account_snapshot()
      |> put_in(
        [
          :codex_accounts,
          Access.at(0),
          :rate_limits,
          "primary"
        ],
        %{
          "windowDurationMins" => 300,
          "remaining" => 18,
          "limit" => 100,
          "resetInSeconds" => 1_800
        }
      )
      |> payload_from_snapshot()
      |> Map.put(:generated_at, "2026-03-25T21:30:00Z")

    html =
      render_dashboard(
        %{payload: payload, now: ~U[2026-03-25 21:30:00Z]},
        codex_accounts_expanded: true
      )

    rerendered_html =
      render_dashboard(
        %{payload: payload, now: ~U[2026-03-25 21:40:00Z]},
        codex_accounts_expanded: true
      )

    assert html =~ "5h: 18/100 left"
    assert html =~ "· at 22:00 UTC"
    assert html =~ "data-local-reset-at=\"2026-03-25T22:00:00Z\""
    assert rerendered_html =~ "· at 22:00 UTC"
    assert rerendered_html =~ "data-local-reset-at=\"2026-03-25T22:00:00Z\""
    refute rerendered_html =~ "data-local-reset-at=\"2026-03-25T22:10:00Z\""
  end

  test "render ignores credits-only variants and keeps window chips visible" do
    payload =
      multi_account_snapshot()
      |> put_in(
        [:codex_accounts, Access.at(0), :rate_limits, "credits"],
        %{"balance" => 42}
      )
      |> put_in(
        [:codex_accounts, Access.at(1), :rate_limits, "credits"],
        %{"hasCredits" => false}
      )
      |> payload_from_snapshot()

    html = render_dashboard(%{payload: payload}, codex_accounts_expanded: true)

    refute html =~ "Credits:"
    assert html =~ "5h: 18/100 left"
    assert html =~ "7d: 12% used"
    assert html =~ "5h: 76/100 left"
    assert html =~ "7d: 4% used"
  end

  test "render shows replacing lifecycle and relation metadata when retry is queued for a running issue" do
    payload =
      multi_account_snapshot()
      |> put_in([:retrying, Access.at(0), :identifier], "MT-HTTP")
      |> put_in([:retrying, Access.at(0), :continuation_reason], "normal_exit")
      |> payload_from_snapshot()

    html = render_dashboard(%{payload: payload}, codex_accounts_expanded: true)

    assert html =~ "Replacing session"
    assert html =~ "replaces"
    assert html =~ "thread-http"
    assert html =~ "reason"
    assert html =~ "normal_exit"
  end

  test "render uses danger styling for limit chips on unhealthy accounts" do
    payload =
      multi_account_snapshot()
      |> put_in([:codex_accounts, Access.at(1), :healthy], false)
      |> put_in([:codex_accounts, Access.at(1), :health_reason], "rate limited")
      |> payload_from_snapshot()

    html = render_dashboard(%{payload: payload}, codex_accounts_expanded: true)

    healthy_row = account_row_html(html, "primary")
    unhealthy_row = account_row_html(html, "secondary")

    assert healthy_row =~ ~s(class="limit-chip mono")
    refute healthy_row =~ "limit-chip-danger"

    assert unhealthy_row =~ ~s(class="limit-chip limit-chip-danger mono")
    assert unhealthy_row =~ "5h: 76/100 left"
    assert unhealthy_row =~ "7d: 4% used"
    assert unhealthy_row =~ "· at 23:30 UTC"
    assert unhealthy_row =~ "· 1 Apr UTC"
  end

  test "render sorts healthy accounts above unhealthy accounts" do
    payload =
      multi_account_snapshot()
      |> put_in([:codex_accounts, Access.at(0), :healthy], false)
      |> put_in([:codex_accounts, Access.at(0), :health_reason], "token expired")
      |> payload_from_snapshot()

    html = render_dashboard(%{payload: payload}, codex_accounts_expanded: true)

    healthy_offset = section_offset(html, account_row_html(html, "secondary"))
    unhealthy_offset = section_offset(html, account_row_html(html, "primary"))

    assert healthy_offset < unhealthy_offset
  end

  test "render humanizes raw probe failures for auth errors" do
    payload =
      multi_account_snapshot()
      |> put_in([:codex_accounts, Access.at(0), :healthy], false)
      |> put_in(
        [:codex_accounts, Access.at(0), :health_reason],
        "probe failed: {:response_error, %{\"code\" => -32603, \"message\" => \"failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; content-type=text/plain; body={\\n \\\"error\\\": {\\n \\\"message\\\": \\\"Provided authentication token is expired. Please try signing in again.\\\",\\n \\\"type\\\": null,\\n \\\"code\\\": \\\"token_expired\\\",\\n \\\"param\\\": null\\n },\\n \\\"status\\\": 401\\n}\"}}"
      )
      |> payload_from_snapshot()

    html = render_dashboard(%{payload: payload}, codex_accounts_expanded: true)

    assert html =~ "Session expired. Sign in again."
    refute html =~ "failed to fetch codex rate limits"
    refute html =~ "token_expired"
  end

  test "handle_event toggles the accounts section and switches the active healthy account" do
    snapshot = multi_account_snapshot()
    orchestrator_name = unique_orchestrator_name(:EventOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = Presenter.state_payload(orchestrator_name, 50)
    socket = dashboard_socket(payload)

    {:noreply, toggled_socket} = DashboardLive.handle_event("toggle_codex_accounts", %{}, socket)
    assert toggled_socket.assigns.codex_accounts_expanded == false

    {:noreply, switched_socket} =
      DashboardLive.handle_event(
        "select_active_codex_account",
        %{"account_id" => "secondary"},
        socket
      )

    assert switched_socket.assigns.payload.active_codex_account_id == "secondary"

    assert switched_socket.assigns.account_selection_notice ==
             "Active account switched to standby.healthy@example.com."

    assert switched_socket.assigns.account_selection_error == nil

    switched_html = render_dashboard(switched_socket.assigns)
    assert switched_html =~ "standby.healthy@example.com"
    assert switched_html =~ "ID secondary"

    updated_snapshot = GenServer.call(orchestrator_name, :snapshot)
    assert updated_snapshot.active_codex_account_id == "secondary"
  end

  test "handle_event queues a refresh and shows a dashboard notice" do
    snapshot = multi_account_snapshot()
    orchestrator_name = unique_orchestrator_name(:RefreshEventOrchestrator)

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator_name,
       snapshot: snapshot,
       refresh: %{
         queued: true,
         coalesced: false,
         requested_at: DateTime.utc_now(),
         operations: ["poll", "reconcile"]
       }}
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = Presenter.state_payload(orchestrator_name, 50)
    socket = dashboard_socket(payload)

    {:noreply, refreshed_socket} = DashboardLive.handle_event("request_refresh", %{}, socket)

    assert refreshed_socket.assigns.refresh_notice ==
             "Refresh queued. The dashboard will update after the next reconcile finishes."

    assert refreshed_socket.assigns.refresh_error == nil

    refreshed_html = render_dashboard(refreshed_socket.assigns)
    assert refreshed_html =~ "Refresh now"

    assert refreshed_html =~
             "Refresh queued. The dashboard will update after the next reconcile finishes."
  end

  test "http server renders the prioritized dashboard and exposes the updated account payload" do
    snapshot = multi_account_snapshot()
    orchestrator_name = unique_orchestrator_name(:HttpOrchestrator)
    orchestrator_opts = [name: orchestrator_name, snapshot: snapshot]

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    http_server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, Keyword.put(orchestrator_opts, :refresh, refresh)})
    start_supervised!({HttpServer, http_server_opts})

    port = wait_for_bound_port()

    dashboard_response = Req.get!("http://127.0.0.1:#{port}/")
    dashboard_body = dashboard_response.body
    running_sessions_offset = section_offset(dashboard_body, "Running sessions")
    retry_queue_offset = section_offset(dashboard_body, "Retry queue")
    codex_accounts_offset = section_offset(dashboard_body, "Codex accounts")

    assert dashboard_response.status == 200
    assert running_sessions_offset < retry_queue_offset
    assert retry_queue_offset < codex_accounts_offset
    assert dashboard_body =~ "full validate"
    assert dashboard_body =~ "Active session"
    refute dashboard_body =~ ~s(>attached</span>)
    assert dashboard_body =~ "make symphony-validate"
    assert dashboard_body =~ "launch-app missing, using local HTTP/UI fallback"
    assert dashboard_body =~ "verification failed for profile `runtime`"
    assert dashboard_body =~ "verification failed"
    assert dashboard_body =~ "very.long.primary.email.address+alerts@example.com"
    assert dashboard_body =~ "5h: 18/100 left"
    assert dashboard_body =~ "· at 22:00 UTC"
    assert dashboard_body =~ "· 31 Mar UTC"
    assert dashboard_body =~ "· at 23:30 UTC"
    assert dashboard_body =~ "· 1 Apr UTC"
    refute dashboard_body =~ "Credits:"
    assert dashboard_body =~ "Make active"

    api_response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert api_response.status == 200
    assert api_response.body["active_codex_account_id"] == "primary"
    assert get_in(api_response.body, ["running", Access.at(0), "run_phase"]) == "full validate"
    assert get_in(api_response.body, ["running", Access.at(0), "activity_state"]) == "slow"
    assert get_in(api_response.body, ["running", Access.at(0), "lifecycle_state"]) == "attached"

    assert get_in(api_response.body, ["retrying", Access.at(0), "lifecycle_state"]) ==
             "retry_scheduled"

    assert get_in(api_response.body, ["running", Access.at(0), "current_command"]) ==
             "make symphony-validate"

    assert get_in(api_response.body, ["running", Access.at(0), "verification_profile"]) ==
             "runtime"

    assert get_in(api_response.body, ["running", Access.at(0), "verification_result"]) == "failed"

    primary_account =
      Enum.find(
        api_response.body["codex_accounts"],
        &(&1["email"] == "very.long.primary.email.address+alerts@example.com")
      )

    assert primary_account

    assert get_in(primary_account, ["rate_limits", "primary", "resetAt"]) ==
             "2026-03-25T22:00:00Z"

    assert get_in(primary_account, ["rate_limits", "secondary", "resetsAt"]) ==
             "2026-03-31T00:00:00Z"

    secondary_account =
      Enum.find(
        api_response.body["codex_accounts"],
        &(&1["email"] == "standby.healthy@example.com")
      )

    assert secondary_account

    assert get_in(secondary_account, ["rate_limits", "primary", "reset_at"]) ==
             "2026-03-25T23:30:00Z"

    assert get_in(secondary_account, ["rate_limits", "secondary", "resets_at"]) ==
             "2026-04-01T00:00:00Z"
  end

  defp configure_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
  end

  defp start_test_endpoint(overrides) do
    configure_endpoint(
      Keyword.merge(
        [server: false, secret_key_base: String.duplicate("s", 64)],
        overrides
      )
    )

    start_supervised!({Endpoint, []})
  end

  defp payload_from_snapshot(snapshot) do
    orchestrator_name = unique_orchestrator_name(:RenderOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})
    Presenter.state_payload(orchestrator_name, 50)
  end

  defp render_dashboard(assigns, overrides \\ []) do
    assigns =
      assigns
      |> Map.new()
      |> ensure_assign(:payload, fn -> payload_from_snapshot(multi_account_snapshot()) end)
      |> ensure_assign(:now, &DateTime.utc_now/0)
      |> ensure_assign(:tracking_scope, fn -> %{label: "Project", value: "letterl"} end)
      |> ensure_assign(:service_name, fn -> "letterl" end)
      |> ensure_assign(:server_port, fn -> 4000 end)
      |> ensure_assign(:codex_accounts_expanded, fn -> true end)
      |> ensure_assign(:account_selection_notice, fn -> nil end)
      |> ensure_assign(:account_selection_error, fn -> nil end)
      |> ensure_assign(:refresh_notice, fn -> nil end)
      |> ensure_assign(:refresh_error, fn -> nil end)
      |> Map.merge(Map.new(overrides))

    assigns
    |> DashboardLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp dashboard_socket(payload) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        payload: payload,
        now: DateTime.utc_now(),
        tracking_scope: %{label: "Project", value: "letterl"},
        service_name: "letterl",
        server_port: 4000,
        codex_accounts_expanded: true,
        account_selection_notice: nil,
        account_selection_error: nil,
        refresh_notice: nil,
        refresh_error: nil
      }
    }
  end

  defp account_row_html(html, account_id) do
    regex =
      ~r/<tr\b[^>]*>(?:(?!<\/tr>).)*<span class="issue-id">#{Regex.escape(account_id)}<\/span>(?:(?!<\/tr>).)*<\/tr>/s

    case Regex.run(regex, html) do
      [row] -> row
      _ -> raise "account row not found for #{account_id}"
    end
  end

  defp multi_account_snapshot do
    %{
      active_codex_account_id: "primary",
      codex_accounts: [
        %{
          id: "primary",
          healthy: true,
          health_reason: nil,
          auth_mode: "chatgpt",
          email: "very.long.primary.email.address+alerts@example.com",
          plan_type: "enterprise",
          requires_openai_auth: false,
          checked_at: DateTime.utc_now(),
          missing_windows_mins: [],
          insufficient_windows_mins: [],
          rate_limits: %{
            "primary" => %{
              "windowDurationMins" => 300,
              "remaining" => 18,
              "limit" => 100,
              "resetAt" => "2026-03-25T22:00:00Z"
            },
            "secondary" => %{
              "windowDurationMins" => 10_080,
              "usedPercent" => 12,
              "resetsAt" => "2026-03-31T00:00:00Z"
            },
            "credits" => %{"unlimited" => true}
          }
        },
        %{
          id: "secondary",
          healthy: true,
          health_reason: nil,
          auth_mode: "chatgpt",
          email: "standby.healthy@example.com",
          plan_type: "pro",
          requires_openai_auth: false,
          checked_at: DateTime.utc_now(),
          missing_windows_mins: [],
          insufficient_windows_mins: [],
          rate_limits: %{
            "primary" => %{
              "windowDurationMins" => 300,
              "remaining" => 76,
              "limit" => 100,
              "reset_at" => "2026-03-25T23:30:00Z"
            },
            "secondary" => %{
              "windowDurationMins" => 10_080,
              "usedPercent" => 4,
              "resets_at" => "2026-04-01T00:00:00Z"
            },
            "credits" => %{"hasCredits" => true}
          }
        }
      ],
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          trace_id: "trace-http",
          state: "In Progress",
          codex_account_id: "primary",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          run_phase: "full validate",
          phase_started_at: ~U[2026-03-25 21:20:00Z],
          last_activity_at: ~U[2026-03-25 21:25:00Z],
          activity_state: "slow",
          current_command: "make symphony-validate",
          current_step: "make symphony-validate",
          external_step: nil,
          operational_notice: "launch-app missing, using local HTTP/UI fallback",
          verification_profile: "runtime",
          verification_result: "failed",
          verification_summary: "verification failed for profile `runtime`: profile `runtime` is missing a matching uploaded proof artifact",
          verification_missing_items: [
            "profile `runtime` is missing a matching uploaded proof artifact"
          ],
          verification_checked_at: ~U[2026-03-25 21:26:00Z],
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          trace_id: "trace-retry",
          due_in_ms: 2_000,
          error: "boom",
          error_class: "transient"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 18, "limit" => 100}},
      workspace: %{
        usage_bytes: 2_147_483_648,
        warning_threshold_bytes: 10_737_418_240,
        done_closed_keep_count: 5
      }
    }
  end

  defp unique_orchestrator_name(suffix) do
    Module.concat(__MODULE__, :"#{suffix}#{System.unique_integer([:positive])}")
  end

  defp ensure_assign(assigns, key, fun) when is_map(assigns) and is_function(fun, 0) do
    if Map.has_key?(assigns, key) do
      assigns
    else
      Map.put(assigns, key, fun.())
    end
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp section_offset(html, text) when is_binary(html) and is_binary(text) do
    case :binary.match(html, text) do
      {offset, _length} -> offset
      :nomatch -> flunk("section #{inspect(text)} not found")
    end
  end
end
