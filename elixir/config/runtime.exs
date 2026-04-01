import Config

normalize_optional_path = fn
  nil ->
    nil

  value ->
    case String.trim(value) do
      "" -> nil
      "/" -> "/"
      trimmed -> "/" <> String.trim_leading(String.trim_trailing(trimmed, "/"), "/")
    end
end

normalize_optional_csv = fn
  nil ->
    nil

  value ->
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
end

if config_env() == :prod do
  public_host =
    System.get_env("SYMPHONY_PUBLIC_HOST")
    |> case do
      nil -> "127.0.0.1"
      "" -> "127.0.0.1"
      value -> String.trim(value)
    end

  public_path =
    System.get_env("SYMPHONY_PUBLIC_PATH")
    |> normalize_optional_path.()

  check_origin =
    case System.get_env("SYMPHONY_CHECK_ORIGIN") do
      nil -> ["//#{public_host}"]
      "" -> ["//#{public_host}"]
      "false" -> false
      "FALSE" -> false
      value -> normalize_optional_csv.(value) || ["//#{public_host}"]
    end

  endpoint_config =
    [
      check_origin: check_origin,
      url:
        [host: public_host]
        |> then(fn url ->
          case public_path do
            nil -> url
            path -> Keyword.put(url, :path, path)
          end
        end)
    ]
    |> then(fn config_items ->
      case System.get_env("SYMPHONY_SECRET_KEY_BASE") do
        value when is_binary(value) and value != "" ->
          Keyword.put(config_items, :secret_key_base, value)

        _ ->
          config_items
      end
    end)

  config :symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config
end
