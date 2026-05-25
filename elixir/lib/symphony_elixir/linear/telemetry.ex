defmodule SymphonyElixir.Linear.Telemetry do
  @moduledoc """
  Bounded Linear GraphQL telemetry helpers.
  """

  @event [:symphony, :linear, :graphql]
  @summary_key {__MODULE__, :graphql_summary}

  @spec emit_graphql(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: :ok
  def emit_graphql(operation_name, latency_ms, response_size_bytes, status)
      when is_binary(operation_name) and is_integer(latency_ms) and is_integer(response_size_bytes) and
             is_binary(status) do
    measurements = %{
      count: 1,
      latency_ms: latency_ms,
      response_size_bytes: response_size_bytes
    }

    metadata = %{
      operation_name: operation_name,
      status: status
    }

    :telemetry.execute(@event, measurements, metadata)
    record_current_process(operation_name, latency_ms, response_size_bytes, status)
  end

  @spec event_name() :: [atom()]
  def event_name, do: @event

  @spec reset_current_process_summary() :: :ok
  def reset_current_process_summary do
    Process.put(@summary_key, empty_summary())
    :ok
  end

  @spec current_process_summary() :: map()
  def current_process_summary do
    case Process.get(@summary_key) do
      %{} = summary -> summarize(summary)
      _ -> empty_summary()
    end
  end

  @spec consume_current_process_summary() :: map()
  def consume_current_process_summary do
    summary = current_process_summary()
    reset_current_process_summary()
    summary
  end

  @spec empty_summary() :: map()
  def empty_summary do
    %{
      request_count: 0,
      total_latency_ms: 0,
      total_response_size_bytes: 0,
      operations: %{}
    }
  end

  @spec summarize(term()) :: map()
  def summarize(%{} = summary) do
    %{
      request_count: non_negative_integer(Map.get(summary, :request_count) || Map.get(summary, "request_count")),
      total_latency_ms: non_negative_integer(Map.get(summary, :total_latency_ms) || Map.get(summary, "total_latency_ms")),
      total_response_size_bytes: non_negative_integer(Map.get(summary, :total_response_size_bytes) || Map.get(summary, "total_response_size_bytes")),
      operations: normalize_operations(Map.get(summary, :operations) || Map.get(summary, "operations") || %{})
    }
  end

  def summarize(_summary), do: empty_summary()

  defp record_current_process(operation_name, latency_ms, response_size_bytes, status) do
    summary = current_process_summary()
    operation = operation_summary(summary.operations, operation_name)

    operation = %{
      request_count: operation.request_count + 1,
      total_latency_ms: operation.total_latency_ms + latency_ms,
      total_response_size_bytes: operation.total_response_size_bytes + response_size_bytes,
      success_count: operation.success_count + success_increment(status),
      failure_count: operation.failure_count + failure_increment(status)
    }

    Process.put(@summary_key, %{
      request_count: summary.request_count + 1,
      total_latency_ms: summary.total_latency_ms + latency_ms,
      total_response_size_bytes: summary.total_response_size_bytes + response_size_bytes,
      operations: Map.put(summary.operations, operation_name, operation)
    })

    :ok
  end

  defp normalize_operations(operations) when is_map(operations) do
    Map.new(operations, fn {name, operation} ->
      normalized_name = to_string(name)
      {normalized_name, operation_summary(%{normalized_name => operation}, normalized_name)}
    end)
  end

  defp normalize_operations(_operations), do: %{}

  defp operation_summary(operations, operation_name) when is_map(operations) do
    case Map.get(operations, operation_name) do
      %{} = operation ->
        %{
          request_count: non_negative_integer(Map.get(operation, :request_count) || Map.get(operation, "request_count")),
          total_latency_ms: non_negative_integer(Map.get(operation, :total_latency_ms) || Map.get(operation, "total_latency_ms")),
          total_response_size_bytes: non_negative_integer(Map.get(operation, :total_response_size_bytes) || Map.get(operation, "total_response_size_bytes")),
          success_count: non_negative_integer(Map.get(operation, :success_count) || Map.get(operation, "success_count")),
          failure_count: non_negative_integer(Map.get(operation, :failure_count) || Map.get(operation, "failure_count"))
        }

      _ ->
        %{request_count: 0, total_latency_ms: 0, total_response_size_bytes: 0, success_count: 0, failure_count: 0}
    end
  end

  defp success_increment("success"), do: 1
  defp success_increment(_status), do: 0

  defp failure_increment("success"), do: 0
  defp failure_increment(_status), do: 1

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0
end
