defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:tracking_scope, tracking_scope())
      |> assign(:service_name, service_name())
      |> assign(:server_port, Config.server_port())
      |> assign(:codex_accounts_expanded, true)
      |> assign(:account_selection_notice, nil)
      |> assign(:account_selection_error, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())
     |> assign(:tracking_scope, tracking_scope())
     |> assign(:service_name, service_name())
     |> assign(:server_port, Config.server_port())}
  end

  @impl true
  def handle_event("toggle_codex_accounts", _params, socket) do
    {:noreply, update(socket, :codex_accounts_expanded, &(!&1))}
  end

  @impl true
  def handle_event("select_active_codex_account", %{"account_id" => account_id}, socket) do
    case Orchestrator.select_active_codex_account(orchestrator(), account_id) do
      {:ok, _active_codex_account_id} ->
        payload = load_payload()

        {:noreply,
         socket
         |> assign(:payload, payload)
         |> assign(:now, DateTime.utc_now())
         |> assign(:account_selection_notice, "Active account switched to #{active_account_label(payload)}.")
         |> assign(:account_selection_error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:account_selection_notice, nil)
         |> assign(:account_selection_error, active_account_selection_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              <%= @service_name %>
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
            <div class="meta-row">
              <span class="meta-chip">
                <%= @tracking_scope.label %>: <span class="mono"><%= @tracking_scope.value %></span>
              </span>
              <span class="meta-chip">
                Port: <span class="mono"><%= @server_port %></span>
              </span>
            </div>
          </div>

          <div class="status-stack">
            <span class={api_badge_class(@payload)}>
              <span class="status-badge-dot"></span>
              <%= api_badge_text(@payload) %>
            </span>
            <div id="liveview-status-stack" class="liveview-status-stack" phx-update="ignore">
              <span
                id="liveview-status-live"
                class="status-badge status-badge-liveview-live"
                hidden
                aria-hidden="true"
              >
                <span class="status-badge-dot"></span>
                LiveView
              </span>
              <span
                id="liveview-status-offline"
                class="status-badge status-badge-liveview-offline"
                aria-hidden="false"
              >
                <span class="status-badge-dot"></span>
                LiveView offline
              </span>
            </div>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Active account</p>
            <p class="metric-value metric-value-break"><%= active_account_label(@payload) %></p>
            <p class="metric-detail">
              Global account used for new Codex starts.
              <span :if={active_account_meta(@payload)} class="metric-detail-block mono">
                <%= active_account_meta(@payload) %>
              </span>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Workspace disk</p>
            <p class="metric-value numeric"><%= format_bytes(@payload.workspace && @payload.workspace.usage_bytes) %></p>
            <p class="metric-detail numeric">
              Warn <%= format_bytes(@payload.workspace && @payload.workspace.warning_threshold_bytes) %>
              · Keep recent <%= format_keep_recent(@payload.workspace && @payload.workspace.done_closed_keep_count) %>
            </p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Account</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td class="mono"><%= entry.codex_account_id || "n/a" %></td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Class</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td class="mono"><%= entry.error_class || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Codex accounts</h2>
              <p class="section-copy">Current health and safe metadata for each configured `CODEX_HOME`.</p>
            </div>
            <div class="section-header-actions">
              <p class="section-meta"><%= codex_accounts_summary(@payload) %></p>
              <button
                id="codex-accounts-toggle"
                type="button"
                class="secondary"
                phx-click="toggle_codex_accounts"
                aria-controls="codex-accounts-body"
                aria-expanded={to_string(@codex_accounts_expanded)}
              >
                <%= if @codex_accounts_expanded, do: "Collapse", else: "Expand" %>
              </button>
            </div>
          </div>

          <p :if={@account_selection_notice} class="section-feedback">
            <%= @account_selection_notice %>
          </p>
          <p :if={@account_selection_error} class="section-feedback section-feedback-error">
            <%= @account_selection_error %>
          </p>

          <%= if @payload.codex_accounts in [nil, []] do %>
            <p class="empty-state">No Codex account metadata available.</p>
          <% else %>
            <div :if={!@codex_accounts_expanded} id="codex-accounts-body">
              <p class="collapsed-summary">
                Table collapsed. <%= codex_accounts_summary(@payload) %>
              </p>
            </div>

            <div :if={@codex_accounts_expanded} id="codex-accounts-body" class="table-wrap">
              <table class="data-table data-table-codex-accounts">
                <thead>
                  <tr>
                    <th>Account</th>
                    <th>Status</th>
                    <th>Auth</th>
                    <th>Plan</th>
                    <th>Email</th>
                    <th>Limits</th>
                    <th>Selection</th>
                    <th>Checked</th>
                    <th>Reason</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={account <- @payload.codex_accounts}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= account.id || "n/a" %></span>
                        <span :if={account.id == @payload.active_codex_account_id} class="muted">active</span>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(if(account.healthy, do: "active", else: "blocked"))}>
                        <%= if account.healthy, do: "healthy", else: "unhealthy" %>
                      </span>
                    </td>
                    <td><%= account.auth_mode || "n/a" %></td>
                    <td><%= account.plan_type || "n/a" %></td>
                    <td class="mono cell-break"><%= account.email || "n/a" %></td>
                    <td>
                      <div class="limit-stack">
                        <span :for={item <- account_rate_limit_items(account.rate_limits)} class="limit-chip mono">
                          <%= item %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="account-action-stack">
                        <span
                          :if={account.id == @payload.active_codex_account_id}
                          class="state-badge state-badge-active"
                        >
                          active
                        </span>
                        <button
                          :if={account.healthy && account.id != @payload.active_codex_account_id}
                          id={"select-account-#{account.id}"}
                          type="button"
                          class="subtle-button"
                          phx-click="select_active_codex_account"
                          phx-value-account_id={account.id}
                          phx-disable-with="Switching..."
                        >
                          Make active
                        </button>
                        <span
                          :if={!account.healthy && account.id != @payload.active_codex_account_id}
                          class="muted"
                        >
                          healthy only
                        </span>
                      </div>
                    </td>
                    <td class="mono"><%= account.checked_at || "n/a" %></td>
                    <td><%= account.health_reason || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0 and bytes < 1024 do
    "#{bytes} B"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    bytes
    |> Kernel./(1024)
    |> scale_bytes(["KB", "MB", "GB", "TB", "PB"])
  end

  defp format_bytes(_bytes), do: "n/a"

  defp scale_bytes(value, [unit]) do
    :erlang.float_to_binary(value, decimals: 2) <> " " <> unit
  end

  defp scale_bytes(value, [unit | _rest_units]) when value < 1024.0 do
    :erlang.float_to_binary(value, decimals: 2) <> " " <> unit
  end

  defp scale_bytes(value, [_unit | rest_units]), do: scale_bytes(value / 1024.0, rest_units)

  defp format_keep_recent(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  defp format_keep_recent(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp tracking_scope do
    case Config.linear_polling_scope() do
      {:project, project_slug} -> %{label: "Project", value: project_slug}
      {:team, team_key} -> %{label: "Team", value: team_key}
      nil -> %{label: "Scope", value: "unknown-scope"}
    end
  end

  defp service_name do
    tracking_scope().value
    |> String.replace(~r/-[0-9a-f]{8,}$/i, "")
    |> case do
      "" -> "operations-dashboard"
      "unknown-scope" -> "operations-dashboard"
      name -> name
    end
  end

  defp api_badge_class(%{error: error}) when not is_nil(error), do: "status-badge status-badge-offline"
  defp api_badge_class(_payload), do: "status-badge status-badge-api"

  defp api_badge_text(%{error: error}) when not is_nil(error), do: "API degraded"
  defp api_badge_text(_payload), do: "API OK"

  defp active_account_label(payload) when is_map(payload) do
    case active_account(payload) do
      %{email: email} when is_binary(email) and email != "" -> email
      %{id: id} when is_binary(id) and id != "" -> id
      _ -> payload.active_codex_account_id || "n/a"
    end
  end

  defp active_account_meta(payload) when is_map(payload) do
    payload
    |> active_account()
    |> case do
      %{} = account ->
        []
        |> append_account_meta("ID #{account.id}", account.id)
        |> append_account_meta(account.plan_type, account.plan_type)
        |> case do
          [] -> nil
          values -> Enum.join(values, " · ")
        end

      _ ->
        nil
    end
  end

  defp active_account(payload) when is_map(payload) do
    Enum.find(payload.codex_accounts || [], &(&1.id == payload.active_codex_account_id))
  end

  defp codex_accounts_summary(payload) when is_map(payload) do
    accounts = payload.codex_accounts || []
    healthy_count = Enum.count(accounts, &(&1.healthy == true))
    active_id = payload.active_codex_account_id || "n/a"

    "#{length(accounts)} total · #{healthy_count} healthy · active #{active_id}"
  end

  defp account_rate_limit_items(rate_limits) when is_map(rate_limits) do
    items =
      [
        rate_limit_bucket_item("Primary", map_value(rate_limits, ["primary", :primary])),
        rate_limit_bucket_item("Secondary", map_value(rate_limits, ["secondary", :secondary])),
        credits_rate_limit_item(map_value(rate_limits, ["credits", :credits]))
      ]
      |> Enum.reject(&is_nil/1)

    if items == [], do: ["n/a"], else: items
  end

  defp account_rate_limit_items(_rate_limits), do: ["n/a"]

  defp rate_limit_bucket_item(default_label, bucket) when is_map(bucket) do
    label = rate_limit_window_label(bucket) || default_label
    summary = rate_limit_bucket_summary(bucket)

    if is_binary(summary), do: "#{label}: #{summary}"
  end

  defp rate_limit_bucket_item(_default_label, _bucket), do: nil

  defp credits_rate_limit_item(bucket) when is_map(bucket) do
    balance = integer_like(map_value(bucket, ["balance", :balance]))

    cond do
      map_value(bucket, ["unlimited", :unlimited]) == true -> "Credits: unlimited"
      is_integer(balance) -> "Credits: #{format_int(balance)}"
      map_value(bucket, ["hasCredits", :hasCredits]) == true -> "Credits: available"
      map_value(bucket, ["hasCredits", :hasCredits]) == false -> "Credits: unavailable"
      true -> nil
    end
  end

  defp credits_rate_limit_item(_bucket), do: nil

  defp rate_limit_window_label(bucket) when is_map(bucket) do
    case integer_like(map_value(bucket, ["windowDurationMins", :windowDurationMins])) do
      mins when is_integer(mins) and mins >= 1_440 and rem(mins, 1_440) == 0 -> "#{div(mins, 1_440)}d"
      mins when is_integer(mins) and mins >= 60 and rem(mins, 60) == 0 -> "#{div(mins, 60)}h"
      mins when is_integer(mins) -> "#{mins}m"
      _ -> nil
    end
  end

  defp rate_limit_window_label(_bucket), do: nil

  defp rate_limit_bucket_summary(bucket) when is_map(bucket) do
    remaining = integer_like(map_value(bucket, ["remaining", :remaining]))
    limit = integer_like(map_value(bucket, ["limit", :limit]))
    used_percent = map_value(bucket, ["usedPercent", :usedPercent])

    cond do
      is_integer(remaining) and is_integer(limit) -> "#{format_int(remaining)}/#{format_int(limit)} left"
      is_integer(remaining) -> "#{format_int(remaining)} remaining"
      is_integer(limit) -> "limit #{format_int(limit)}"
      is_number(used_percent) -> "#{format_percent(used_percent)} used"
      true -> nil
    end
  end

  defp rate_limit_bucket_summary(_bucket), do: nil

  defp map_value(map, [key | rest]) when is_map(map) do
    Map.get(map, key) || map_value(map, rest)
  end

  defp map_value(_map, []), do: nil
  defp map_value(_map, _keys), do: nil

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp format_percent(value) when is_integer(value), do: "#{value}%"

  defp format_percent(value) when is_float(value) do
    "#{:erlang.float_to_binary(value, decimals: 1)}%"
  end

  defp format_percent(value), do: to_string(value)

  defp append_account_meta(list, formatted, value) when is_binary(value) and value != "",
    do: list ++ [formatted]

  defp append_account_meta(list, _formatted, _value), do: list

  defp active_account_selection_error(:invalid_account), do: "Selected account is no longer configured."
  defp active_account_selection_error(:unhealthy_account), do: "Only healthy accounts can be made active."
  defp active_account_selection_error(:unavailable), do: "Orchestrator is unavailable."
  defp active_account_selection_error(_reason), do: "Failed to update the active account."

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
