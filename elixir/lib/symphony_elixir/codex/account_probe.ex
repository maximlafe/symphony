defmodule SymphonyElixir.Codex.AccountProbe do
  @moduledoc false

  alias SymphonyElixir.Codex.{Accounts, AppServer}

  @account_read_request_id 1001
  @rate_limits_read_request_id 1002

  @spec probe_accounts([map()], keyword()) :: [map()]
  def probe_accounts(accounts, opts \\ []) when is_list(accounts) do
    cwd = Keyword.get(opts, :cwd, System.tmp_dir!())
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)

    accounts
    |> Task.async_stream(
      &probe_account(
        &1,
        cwd: cwd,
        monitored_windows_mins: Keyword.get(opts, :monitored_windows_mins, []),
        minimum_remaining_percent: Keyword.get(opts, :minimum_remaining_percent, 0)
      ),
      ordered: true,
      timeout: timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(accounts)
    |> Enum.map(fn
      {{:ok, result}, _account} ->
        result

      {{:exit, reason}, account} ->
        %{
          id: Map.get(account, :id),
          explicit?: Map.get(account, :explicit?, true),
          codex_home: Map.get(account, :codex_home),
          checked_at: DateTime.utc_now(),
          healthy: false,
          health_reason: "probe failed: #{inspect(reason)}",
          auth_mode: "unknown",
          email: nil,
          plan_type: nil,
          requires_openai_auth: false,
          rate_limits: nil,
          account: nil,
          missing_windows_mins: Keyword.get(opts, :monitored_windows_mins, []),
          insufficient_windows_mins: []
        }
    end)
  end

  @spec probe_account(map(), keyword()) :: map()
  def probe_account(account, opts \\ [])
  def probe_account(%{id: id, codex_home: codex_home} = account, opts)
      when is_binary(id) and is_binary(codex_home) do
    cwd = Keyword.get(opts, :cwd, System.tmp_dir!())
    monitored_windows_mins = Keyword.get(opts, :monitored_windows_mins, [])
    minimum_remaining_percent = Keyword.get(opts, :minimum_remaining_percent, 0)

    base_status = %{
      id: id,
      explicit?: Map.get(account, :explicit?, true),
      checked_at: DateTime.utc_now(),
      healthy: false,
      health_reason: "probe unavailable",
      codex_home: codex_home,
      auth_mode: "unknown",
      email: nil,
      plan_type: nil,
      requires_openai_auth: false,
      rate_limits: nil,
      account: nil,
      missing_windows_mins: monitored_windows_mins,
      insufficient_windows_mins: []
    }

    case AppServer.open_client(cwd, command_env: [{"CODEX_HOME", codex_home}], account_id: id) do
      {:ok, client} ->
        try do
          with {:ok, account_response} <- AppServer.request(client, "account/read", %{}, @account_read_request_id),
               {:ok, rate_limits_response} <- AppServer.request(client, "account/rateLimits/read", nil, @rate_limits_read_request_id) do
            rate_limits = Accounts.select_rate_limits_snapshot(rate_limits_response)
            health = Accounts.health(rate_limits, monitored_windows_mins, minimum_remaining_percent)
            summary = Accounts.account_summary(account_response)

            logged_in? =
              case summary.account do
                %{"email" => email} when is_binary(email) and email != "" -> true
                %{email: email} when is_binary(email) and email != "" -> true
                %{"type" => type} when is_binary(type) and type != "" -> true
                %{type: type} when is_binary(type) and type != "" -> true
                account when is_map(account) and map_size(account) > 0 -> true
                _ -> summary.requires_openai_auth != true
              end

            %{
              base_status
              | healthy: logged_in? and health.healthy?,
                health_reason:
                  cond do
                    not logged_in? -> "not logged in"
                    true -> health.reason
                  end,
                auth_mode: summary.auth_mode,
                email: summary.email,
                plan_type: summary.plan_type,
                requires_openai_auth: summary.requires_openai_auth,
                rate_limits: rate_limits,
                account: summary.account,
                missing_windows_mins: health.missing_windows_mins,
                insufficient_windows_mins: health.insufficient_windows_mins
            }
          else
            {:error, reason} ->
              %{base_status | health_reason: "probe failed: #{inspect(reason)}"}
          end
        after
          AppServer.stop_client(client)
        end

      {:error, reason} ->
        %{base_status | health_reason: "startup failed: #{inspect(reason)}"}
    end
  end

  def probe_account(account, _opts),
    do: %{id: Map.get(account, :id), healthy: false, health_reason: "invalid account"}
end
