defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.Endpoint

  @secret_key_bytes 48
  @managed_url_path_key :http_server_managed_url_path
  @managed_previous_url_path_key :http_server_previous_url_path

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        host = Keyword.get(opts, :host, Config.settings!().server.host)
        path = Keyword.get(opts, :path, Config.settings!().server.path)
        orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

        with {:ok, ip} <- parse_host(host) do
          existing_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
          existing_url = Keyword.get(existing_endpoint_config, :url, [])
          managed_url_path = Keyword.get(existing_endpoint_config, @managed_url_path_key)

          managed_previous_url_path =
            Keyword.get(existing_endpoint_config, @managed_previous_url_path_key)

          endpoint_opts = [
            server: true,
            http: [ip: ip, port: port],
            url: endpoint_url(existing_url, host, path, managed_url_path, managed_previous_url_path),
            orchestrator: orchestrator,
            snapshot_timeout_ms: snapshot_timeout_ms,
            secret_key_base: Keyword.get(existing_endpoint_config, :secret_key_base) || secret_key_base()
          ]

          endpoint_config =
            existing_endpoint_config
            |> Keyword.merge(endpoint_opts)
            |> track_managed_url_path(
              existing_url,
              path,
              managed_url_path,
              managed_previous_url_path
            )

          Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
          Endpoint.start_link()
        end

      _ ->
        :ignore
    end
  end

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp normalize_host(host) when host in ["", nil], do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host), do: to_string(host)

  defp endpoint_url(existing_url, host, nil, managed_url_path, managed_previous_url_path) do
    existing_url
    |> restore_url_path(managed_url_path, managed_previous_url_path)
    |> Keyword.merge(host: normalize_host(host))
  end

  defp endpoint_url(existing_url, host, path, _managed_url_path, _managed_previous_url_path)
       when is_binary(path) do
    existing_url
    |> Keyword.merge(host: normalize_host(host))
    |> Keyword.put(:path, path)
  end

  defp restore_url_path(existing_url, managed_url_path, managed_previous_url_path) do
    if managed_url_path?(existing_url, managed_url_path) do
      case managed_previous_url_path do
        path when is_binary(path) -> Keyword.put(existing_url, :path, path)
        _ -> Keyword.delete(existing_url, :path)
      end
    else
      existing_url
    end
  end

  defp track_managed_url_path(
         endpoint_config,
         _existing_url,
         nil,
         _managed_url_path,
         _managed_previous_url_path
       ) do
    endpoint_config
    |> Keyword.delete(@managed_url_path_key)
    |> Keyword.delete(@managed_previous_url_path_key)
  end

  defp track_managed_url_path(
         endpoint_config,
         existing_url,
         path,
         managed_url_path,
         managed_previous_url_path
       )
       when is_binary(path) do
    previous_url_path =
      if managed_url_path?(existing_url, managed_url_path) do
        managed_previous_url_path
      else
        Keyword.get(existing_url, :path)
      end

    endpoint_config
    |> Keyword.put(@managed_url_path_key, path)
    |> put_previous_url_path(previous_url_path)
  end

  defp put_previous_url_path(endpoint_config, path) when is_binary(path) do
    Keyword.put(endpoint_config, @managed_previous_url_path_key, path)
  end

  defp put_previous_url_path(endpoint_config, _path) do
    Keyword.delete(endpoint_config, @managed_previous_url_path_key)
  end

  defp managed_url_path?(existing_url, managed_url_path) when is_binary(managed_url_path) do
    Keyword.get(existing_url, :path) == managed_url_path
  end

  defp managed_url_path?(_existing_url, _managed_url_path) do
    false
  end

  defp secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end
end
