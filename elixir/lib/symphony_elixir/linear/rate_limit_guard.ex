defmodule SymphonyElixir.Linear.RateLimitGuard do
  @moduledoc false

  @linear_rate_limit_guard_key {__MODULE__, :linear_rate_limit_guard_until_ms}
  @linear_rate_limit_default_cooldown_ms 60_000
  @linear_rate_limit_min_cooldown_ms 5_000
  @linear_rate_limit_max_cooldown_ms 300_000

  @spec enforce_guard() :: :ok | {:error, {:linear_rate_limited, non_neg_integer()}}
  def enforce_guard do
    case linear_rate_limit_retry_after_ms() do
      retry_after_ms when is_integer(retry_after_ms) and retry_after_ms > 0 ->
        {:error, {:linear_rate_limited, retry_after_ms}}

      _ ->
        :ok
    end
  end

  @spec normalize_rate_limited_status(map(), integer()) :: {integer(), integer() | nil}
  def normalize_rate_limited_status(response, status) when is_integer(status) do
    cooldown_ms = rate_limited_cooldown_ms(response, status)

    if is_integer(cooldown_ms) and cooldown_ms > 0 do
      activate_linear_rate_limit_guard(cooldown_ms)
      {429, cooldown_ms}
    else
      {status, nil}
    end
  end

  @spec rate_limit_context(integer() | nil) :: String.t()
  def rate_limit_context(cooldown_ms) when is_integer(cooldown_ms) and cooldown_ms > 0 do
    " cooldown_ms=#{cooldown_ms}"
  end

  def rate_limit_context(_cooldown_ms), do: ""

  @spec clear_guard_for_test() :: :ok
  def clear_guard_for_test do
    :persistent_term.erase(@linear_rate_limit_guard_key)
    :ok
  end

  defp linear_rate_limit_retry_after_ms do
    now_ms = System.system_time(:millisecond)

    case lookup_linear_rate_limit_guard_until_ms() do
      until_ms when is_integer(until_ms) and until_ms > now_ms ->
        until_ms - now_ms

      _ ->
        0
    end
  end

  defp rate_limited_cooldown_ms(response, status) when is_integer(status) do
    cond do
      status == 429 ->
        @linear_rate_limit_default_cooldown_ms

      status in [400, 403] and linear_rate_limited_response?(response) ->
        response
        |> linear_rate_limit_duration_ms_from_body()
        |> clamp_linear_rate_limit_cooldown_ms()

      true ->
        nil
    end
  end

  defp linear_rate_limited_response?(response) do
    response
    |> Map.get(:body, %{})
    |> linear_response_errors()
    |> Enum.any?(&linear_rate_limited_error_entry?/1)
  end

  defp linear_response_errors(body) when is_map(body) do
    case map_value_with_atom_fallback(body, "errors") do
      errors when is_list(errors) -> errors
      _ -> []
    end
  end

  defp linear_response_errors(_body), do: []

  defp linear_rate_limited_error_entry?(entry) when is_map(entry) do
    extensions = map_value_with_atom_fallback(entry, "extensions")
    code = map_string_field(extensions, "code")
    message = map_string_field(entry, "message")

    status_code =
      map_integer_field(extensions, "statusCode") ||
        extensions
        |> map_value_with_atom_fallback("http")
        |> map_integer_field("status")

    status_code == 429 ||
      string_contains_case_insensitive?(code, "ratelimited") ||
      string_contains_case_insensitive?(message, "rate limit")
  end

  defp linear_rate_limited_error_entry?(_entry), do: false

  defp linear_rate_limit_duration_ms_from_body(response) do
    response
    |> Map.get(:body, %{})
    |> linear_response_errors()
    |> Enum.find_value(@linear_rate_limit_default_cooldown_ms, fn entry ->
      entry
      |> map_value_with_atom_fallback("extensions")
      |> map_value_with_atom_fallback("meta")
      |> map_value_with_atom_fallback("rateLimitResult")
      |> map_integer_field("duration")
    end)
  end

  defp clamp_linear_rate_limit_cooldown_ms(ms) when is_integer(ms) and ms > 0 do
    ms
    |> max(@linear_rate_limit_min_cooldown_ms)
    |> min(@linear_rate_limit_max_cooldown_ms)
  end

  defp clamp_linear_rate_limit_cooldown_ms(_ms), do: @linear_rate_limit_default_cooldown_ms

  defp activate_linear_rate_limit_guard(cooldown_ms) when is_integer(cooldown_ms) and cooldown_ms > 0 do
    now_ms = System.system_time(:millisecond)
    until_ms = now_ms + cooldown_ms

    case lookup_linear_rate_limit_guard_until_ms() do
      previous_until when is_integer(previous_until) and previous_until > until_ms ->
        :ok

      _ ->
        :persistent_term.put(@linear_rate_limit_guard_key, until_ms)
        :ok
    end
  end

  defp lookup_linear_rate_limit_guard_until_ms do
    case :persistent_term.get(@linear_rate_limit_guard_key, 0) do
      until_ms when is_integer(until_ms) -> until_ms
      _ -> 0
    end
  end

  defp map_value_with_atom_fallback(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp map_value_with_atom_fallback(_map, _key), do: nil

  defp map_string_field(map, key) do
    case map_value_with_atom_fallback(map, key) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  defp map_integer_field(map, key) do
    case map_value_with_atom_fallback(map, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> safe_string_to_integer(value)
      _ -> nil
    end
  end

  defp safe_string_to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp string_contains_case_insensitive?(value, needle) when is_binary(value) and is_binary(needle) do
    String.contains?(String.downcase(value), String.downcase(needle))
  end

  defp string_contains_case_insensitive?(_value, _needle), do: false
end
