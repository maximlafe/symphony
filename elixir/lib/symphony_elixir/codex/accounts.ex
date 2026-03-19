defmodule SymphonyElixir.Codex.Accounts do
  @moduledoc false

  @type health_result :: %{
          healthy?: boolean(),
          reason: String.t() | nil,
          missing_windows_mins: [pos_integer()],
          insufficient_windows_mins: [pos_integer()],
          remaining_percent_by_window: %{optional(pos_integer()) => float()}
        }

  @spec select_rate_limits_snapshot(term()) :: map() | nil
  def select_rate_limits_snapshot(payload) when is_map(payload) do
    payload = unwrap_response_payload(payload)

    rate_limits_by_limit_id =
      map_value(payload, [
        "rateLimitsByLimitId",
        :rateLimitsByLimitId,
        "rate_limits_by_limit_id",
        :rate_limits_by_limit_id
      ])

    cond do
      is_map(rate_limits_by_limit_id) ->
        Map.get(rate_limits_by_limit_id, "codex") ||
          Map.get(rate_limits_by_limit_id, :codex) ||
          fallback_rate_limits_snapshot(payload)

      rate_limits_snapshot?(payload) ->
        payload

      true ->
        fallback_rate_limits_snapshot(payload)
    end
  end

  def select_rate_limits_snapshot(_payload), do: nil

  @spec rate_limits_snapshot?(term()) :: boolean()
  def rate_limits_snapshot?(payload) when is_map(payload) do
    Enum.any?(["primary", :primary, "secondary", :secondary, "credits", :credits], &Map.has_key?(payload, &1)) and
      not is_nil(
        map_value(payload, [
          "limitId",
          :limitId,
          "limit_id",
          :limit_id,
          "limitName",
          :limitName,
          "limit_name",
          :limit_name
        ])
      )
  end

  def rate_limits_snapshot?(_payload), do: false

  @spec health(map() | nil, [pos_integer()], non_neg_integer()) :: health_result()
  def health(rate_limits, monitored_windows_mins, minimum_remaining_percent)
      when is_list(monitored_windows_mins) and is_integer(minimum_remaining_percent) do
    windows = windows_by_duration(rate_limits)
    missing_windows_mins = monitored_windows_mins -- Map.keys(windows)

    insufficient_windows_mins =
      monitored_windows_mins
      |> Enum.filter(fn window_mins ->
        case Map.get(windows, window_mins) do
          remaining when is_number(remaining) -> remaining < minimum_remaining_percent
          _ -> true
        end
      end)

    healthy? = missing_windows_mins == [] and insufficient_windows_mins == []

    %{
      healthy?: healthy?,
      reason: health_reason(rate_limits, missing_windows_mins, insufficient_windows_mins, windows),
      missing_windows_mins: missing_windows_mins,
      insufficient_windows_mins: insufficient_windows_mins,
      remaining_percent_by_window: windows
    }
  end

  @spec account_summary(map() | nil) :: map()
  def account_summary(response) when is_map(response) do
    response = unwrap_response_payload(response)
    account = map_value(response, ["account", :account]) || %{}
    account_present? = account_present?(account)
    requires_openai_auth? =
      if(account_present?,
        do: false,
        else:
          truthy?(
            map_value(response, [
              "requiresOpenaiAuth",
              :requiresOpenaiAuth,
              "requires_openai_auth",
              :requires_openai_auth
            ])
          )
      )

    %{
      account: account,
      auth_mode:
        map_value(account, ["type", :type]) ||
          if(requires_openai_auth?,
            do: "missing",
            else: "unknown"
          ),
      email: map_value(account, ["email", :email]),
      plan_type: map_value(account, ["planType", :planType, "plan_type", :plan_type]),
      requires_openai_auth: requires_openai_auth?
    }
  end

  def account_summary(_response) do
    %{
      account: nil,
      auth_mode: "unknown",
      email: nil,
      plan_type: nil,
      requires_openai_auth: false
    }
  end

  defp fallback_rate_limits_snapshot(payload) when is_map(payload) do
    map_value(payload, ["rateLimits", :rateLimits, "rate_limits", :rate_limits])
  end

  defp fallback_rate_limits_snapshot(_payload), do: nil

  defp windows_by_duration(rate_limits) when is_map(rate_limits) do
    [map_value(rate_limits, ["primary", :primary]), map_value(rate_limits, ["secondary", :secondary])]
    |> Enum.reduce(%{}, fn bucket, acc ->
      case bucket_window_minutes(bucket) do
        window_mins when is_integer(window_mins) and window_mins > 0 ->
          case bucket_remaining_percent(bucket) do
            remaining when is_number(remaining) -> Map.put(acc, window_mins, remaining)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp windows_by_duration(_rate_limits), do: %{}

  defp bucket_window_minutes(bucket) when is_map(bucket) do
    map_value(bucket, [
      "windowDurationMins",
      :windowDurationMins,
      "window_minutes",
      :window_minutes,
      "windowMinutes",
      :windowMinutes
    ])
  end

  defp bucket_window_minutes(_bucket), do: nil

  defp bucket_remaining_percent(bucket) when is_map(bucket) do
    used_percent =
      map_value(bucket, [
        "usedPercent",
        :usedPercent,
        "used_percent",
        :used_percent
      ])

    cond do
      is_number(used_percent) ->
        max(0.0, 100.0 - used_percent * 1.0)

      true ->
        remaining = map_value(bucket, ["remaining", :remaining])
        limit = map_value(bucket, ["limit", :limit])

        if integer_like?(remaining) and integer_like?(limit) and to_int(limit) > 0 do
          max(0.0, to_int(remaining) * 100.0 / to_int(limit))
        end
    end
  end

  defp bucket_remaining_percent(_bucket), do: nil

  defp health_reason(nil, _missing_windows_mins, _insufficient_windows_mins, _windows),
    do: "rate limits unavailable"

  defp health_reason(_rate_limits, missing_windows_mins, _insufficient_windows_mins, _windows)
       when missing_windows_mins != [] do
    "missing windows #{Enum.map_join(missing_windows_mins, ", ", &"#{&1}m")}"
  end

  defp health_reason(_rate_limits, _missing_windows_mins, insufficient_windows_mins, windows)
       when insufficient_windows_mins != [] do
    insufficient_windows_mins
    |> Enum.map(fn window_mins ->
      remaining = Map.get(windows, window_mins)
      "#{window_mins}m=#{format_remaining(remaining)}"
    end)
    |> Enum.join(", ")
    |> then(&"threshold exceeded #{&1}")
  end

  defp health_reason(_rate_limits, _missing_windows_mins, _insufficient_windows_mins, _windows), do: nil

  defp format_remaining(remaining) when is_number(remaining) do
    :erlang.float_to_binary(remaining * 1.0, decimals: 1) <> "%"
  end

  defp format_remaining(_remaining), do: "n/a"

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key)
    end)
  end

  defp map_value(_map, _keys), do: nil

  defp unwrap_response_payload(payload) when is_map(payload) do
    case map_value(payload, ["result", :result]) do
      %{} = result -> result
      _ -> payload
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp account_present?(account) when is_map(account) do
    map_size(account) > 0 and
      Enum.any?(
        [
          map_value(account, ["email", :email]),
          map_value(account, ["type", :type]),
          map_value(account, ["planType", :planType, "plan_type", :plan_type])
        ],
        &(is_binary(&1) and &1 != "")
      )
  end

  defp account_present?(_account), do: false

  defp integer_like?(value) when is_integer(value), do: true

  defp integer_like?(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {_integer, ""} -> true
      _ -> false
    end
  end

  defp integer_like?(_value), do: false

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp to_int(_value), do: 0
end
