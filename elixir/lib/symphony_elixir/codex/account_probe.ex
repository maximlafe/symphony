defmodule SymphonyElixir.Codex.AccountProbe do
  @moduledoc false

  alias SymphonyElixir.Codex.{Accounts, AppServer}

  @account_read_request_id 1001
  @rate_limits_read_request_id 1002

  @spec probe_accounts([map()], keyword()) :: [map()]
  def probe_accounts(accounts, opts \\ []) when is_list(accounts) do
    cwd = Keyword.get(opts, :cwd, System.tmp_dir!())
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    probe_mode = normalize_probe_mode(Keyword.get(opts, :probe_mode, :full))

    accounts
    |> Task.async_stream(
      &probe_account(
        &1,
        cwd: cwd,
        monitored_windows_mins: Keyword.get(opts, :monitored_windows_mins, []),
        minimum_remaining_percent: Keyword.get(opts, :minimum_remaining_percent, 0),
        probe_mode: probe_mode
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

  @spec probe_account(map(), keyword()) :: map()
  def probe_account(%{id: id, codex_home: codex_home} = account, opts)
      when is_binary(id) and is_binary(codex_home) do
    cwd = Keyword.get(opts, :cwd, System.tmp_dir!())
    monitored_windows_mins = Keyword.get(opts, :monitored_windows_mins, [])
    minimum_remaining_percent = Keyword.get(opts, :minimum_remaining_percent, 0)
    probe_mode = normalize_probe_mode(Keyword.get(opts, :probe_mode, :full))

    base_status = base_probe_status(account, id, codex_home, monitored_windows_mins)

    case AppServer.open_client(cwd, command_env: [{"CODEX_HOME", codex_home}], account_id: id) do
      {:ok, client} ->
        try do
          case AppServer.request(client, "account/read", %{}, @account_read_request_id) do
            {:ok, account_response} ->
              handle_account_probe_response(
                probe_mode,
                client,
                base_status,
                account_response,
                monitored_windows_mins,
                minimum_remaining_percent
              )

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

  defp base_probe_status(account, id, codex_home, monitored_windows_mins) do
    %{
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
      probe_scope: :full,
      missing_windows_mins: monitored_windows_mins,
      insufficient_windows_mins: []
    }
  end

  defp build_probe_status(
         base_status,
         account_response,
         rate_limits_response,
         monitored_windows_mins,
         minimum_remaining_percent
       ) do
    rate_limits = Accounts.select_rate_limits_snapshot(rate_limits_response)
    health = Accounts.health(rate_limits, monitored_windows_mins, minimum_remaining_percent)
    summary = Accounts.account_summary(account_response)
    logged_in? = logged_in?(summary)

    %{
      base_status
      | healthy: logged_in? and health.healthy?,
        health_reason: if(logged_in?, do: health.reason, else: "not logged in"),
        auth_mode: summary.auth_mode,
        email: summary.email,
        plan_type: summary.plan_type,
        requires_openai_auth: summary.requires_openai_auth,
        rate_limits: rate_limits,
        account: summary.account,
        missing_windows_mins: health.missing_windows_mins,
        insufficient_windows_mins: health.insufficient_windows_mins
    }
  end

  defp handle_account_probe_response(
         :account_only,
         _client,
         base_status,
         account_response,
         _monitored_windows_mins,
         _minimum_remaining_percent
       ) do
    build_account_only_probe_status(base_status, account_response)
  end

  defp handle_account_probe_response(
         :full,
         client,
         base_status,
         account_response,
         monitored_windows_mins,
         minimum_remaining_percent
       ) do
    case AppServer.request(
           client,
           "account/rateLimits/read",
           nil,
           @rate_limits_read_request_id
         ) do
      {:ok, rate_limits_response} ->
        build_probe_status(
          base_status,
          account_response,
          rate_limits_response,
          monitored_windows_mins,
          minimum_remaining_percent
        )

      {:error, reason} ->
        maybe_build_probe_status_without_rate_limits(
          base_status,
          account_response,
          reason
        )
    end
  end

  defp build_account_only_probe_status(base_status, account_response) do
    summary = Accounts.account_summary(account_response)
    logged_in? = logged_in?(summary)

    %{
      base_status
      | healthy: logged_in?,
        health_reason: if(logged_in?, do: nil, else: "not logged in"),
        auth_mode: summary.auth_mode,
        email: summary.email,
        plan_type: summary.plan_type,
        requires_openai_auth: summary.requires_openai_auth,
        rate_limits: nil,
        account: summary.account,
        missing_windows_mins: [],
        insufficient_windows_mins: [],
        probe_scope: :account_only
    }
  end

  defp maybe_build_probe_status_without_rate_limits(base_status, account_response, reason) do
    if rate_limits_auth_required?(reason) do
      summary = Accounts.account_summary(account_response)
      logged_in? = logged_in?(summary)

      %{
        base_status
        | healthy: logged_in?,
          health_reason: if(logged_in?, do: nil, else: "not logged in"),
          auth_mode: summary.auth_mode,
          email: summary.email,
          plan_type: summary.plan_type,
          requires_openai_auth: summary.requires_openai_auth,
          rate_limits: nil,
          account: summary.account,
          missing_windows_mins: [],
          insufficient_windows_mins: []
      }
    else
      %{base_status | health_reason: "probe failed: #{inspect(reason)}"}
    end
  end

  defp rate_limits_auth_required?({:response_error, error}) when is_map(error) do
    message = Map.get(error, "message") || Map.get(error, :message)

    is_binary(message) and
      String.contains?(String.downcase(message), "authentication required") and
      String.contains?(String.downcase(message), "read rate limits")
  end

  defp rate_limits_auth_required?(_reason), do: false

  defp logged_in?(summary) when is_map(summary) do
    account = summary.account

    account_has_email?(account) or
      account_has_type?(account) or
      populated_account?(account) or
      summary.requires_openai_auth != true
  end

  defp account_has_email?(%{"email" => email}) when is_binary(email) and email != "", do: true
  defp account_has_email?(%{email: email}) when is_binary(email) and email != "", do: true
  defp account_has_email?(_account), do: false

  defp account_has_type?(%{"type" => type}) when is_binary(type) and type != "", do: true
  defp account_has_type?(%{type: type}) when is_binary(type) and type != "", do: true
  defp account_has_type?(_account), do: false

  defp populated_account?(account) when is_map(account), do: map_size(account) > 0
  defp populated_account?(_account), do: false

  defp normalize_probe_mode(:account_only), do: :account_only
  defp normalize_probe_mode(_mode), do: :full
end
