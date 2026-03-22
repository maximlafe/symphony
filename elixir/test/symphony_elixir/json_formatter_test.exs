defmodule SymphonyElixir.JsonFormatterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.JsonFormatter

  test "formats base fields as a JSON line" do
    event = %{
      level: :info,
      msg: {:string, "logger online"},
      meta: %{
        time: 1_710_000_000_123_456,
        mfa: {SymphonyElixir.LogFile, :configure, 0}
      }
    }

    payload = event |> JsonFormatter.format(%{}) |> decode_json_line()

    assert payload["level"] == "info"
    assert payload["module"] == "SymphonyElixir.LogFile"
    assert payload["message"] == "logger online"
    assert {:ok, _datetime, _offset} = DateTime.from_iso8601(payload["timestamp"])
  end

  test "includes required context fields by parsing message and metadata" do
    event = %{
      level: :warning,
      msg: {:string, "Retrying issue_id=abc issue_identifier=BUB-99 trace_id=trace-1 in 5000ms (attempt 2) session_id=s-1 workspace=/tmp/BUB-99"},
      meta: %{
        time: 1_710_000_000_223_456,
        mfa: {SymphonyElixir.Orchestrator, :handle_info, 2}
      }
    }

    payload = event |> JsonFormatter.format(%{}) |> decode_json_line()

    assert payload["issue_id"] == "abc"
    assert payload["issue_identifier"] == "BUB-99"
    assert payload["trace_id"] == "trace-1"
    assert payload["session_id"] == "s-1"
    assert payload["workspace"] == "/tmp/BUB-99"
  end

  test "agent logs always include required keys and metadata overrides parsed values" do
    event = %{
      level: :info,
      msg: {:string, "Completed agent run for issue_id=from-message issue_identifier=BUB-99 trace_id=from-message workspace=/tmp/from-message"},
      meta: %{
        time: 1_710_000_000_323_456,
        mfa: {SymphonyElixir.AgentRunner, :run, 3},
        issue_id: "from-metadata",
        issue_identifier: "BUB-99",
        session_id: "thread-1-turn-2",
        trace_id: "trace-metadata"
      }
    }

    payload = event |> JsonFormatter.format(%{}) |> decode_json_line()

    assert payload["issue_id"] == "from-metadata"
    assert payload["issue_identifier"] == "BUB-99"
    assert payload["session_id"] == "thread-1-turn-2"
    assert payload["trace_id"] == "trace-metadata"
    assert payload["workspace"] == "/tmp/from-message"
  end

  test "agent module logs include required context keys even when values are missing" do
    event = %{
      level: :info,
      msg: {:string, "agent heartbeat"},
      meta: %{
        time: 1_710_000_000_423_456,
        mfa: {SymphonyElixir.AgentRunner, :run, 3}
      }
    }

    payload = event |> JsonFormatter.format(%{}) |> decode_json_line()

    assert payload["module"] == "SymphonyElixir.AgentRunner"
    assert payload["issue_id"] == nil
    assert payload["issue_identifier"] == nil
    assert payload["session_id"] == nil
    assert payload["trace_id"] == nil
    assert payload["workspace"] == nil
  end

  test "invalid formatter config returns an error" do
    assert JsonFormatter.check_config(%{}) == :ok
    assert JsonFormatter.check_config(:invalid) == {:error, {:invalid_formatter_config, :invalid}}
  end

  defp decode_json_line(line_iodata) do
    line = IO.iodata_to_binary(line_iodata)
    assert String.ends_with?(line, "\n")
    line |> String.trim_trailing() |> Jason.decode!()
  end
end
