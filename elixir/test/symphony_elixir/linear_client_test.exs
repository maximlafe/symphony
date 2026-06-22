defmodule SymphonyElixir.LinearClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Telemetry, as: LinearTelemetry

  setup do
    Client.clear_viewer_cache_for_test()
    LinearTelemetry.reset_current_process_summary()

    on_exit(fn ->
      Client.clear_viewer_cache_for_test()
      LinearTelemetry.reset_current_process_summary()
    end)

    :ok
  end

  test "graphql emits bounded telemetry on success and failure paths" do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        LinearTelemetry.event_name(),
        fn event, measurements, metadata, _config ->
          send(parent, {:linear_graphql_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}} =
             Client.graphql(
               "query SymphonyLinearViewer { viewer { id } }",
               %{},
               request_fun: fn payload, headers ->
                 assert payload["operationName"] == nil
                 assert {"Authorization", "token"} in headers
                 {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}}
               end
             )

    {measurements, metadata} = assert_linear_graphql_event("SymphonyLinearViewer")
    assert measurements.count == 1
    assert is_integer(measurements.latency_ms)
    assert measurements.response_size_bytes > 0
    assert metadata.operation_name == "SymphonyLinearViewer"
    assert metadata.status == "success"

    assert {:error, {:linear_api_status, 503}} =
             Client.graphql(
               "mutation SymphonyLinearCommentCreate { commentCreate(input: {}) { success } }",
               %{},
               operation_name: "SymphonyLinearCommentCreate",
               request_fun: fn _payload, _headers ->
                 {:ok, %{status: 503, body: "service unavailable"}}
               end
             )

    {failure_measurements, failure_metadata} = assert_linear_graphql_event("SymphonyLinearCommentCreate")
    assert failure_measurements.count == 1
    assert failure_measurements.response_size_bytes == byte_size("service unavailable")
    assert failure_metadata.operation_name == "SymphonyLinearCommentCreate"
    assert failure_metadata.status == "failure"

    summary = LinearTelemetry.current_process_summary()
    assert summary.request_count == 2
    assert summary.operations["SymphonyLinearViewer"].success_count == 1
    assert summary.operations["SymphonyLinearCommentCreate"].failure_count == 1
  end

  test "graphql uses anonymous telemetry operation names for non-client-owned queries" do
    assert {:ok, %{"data" => %{}}} =
             Client.graphql(
               "query AdHocViewerLookup { viewer { id } }",
               %{},
               request_fun: fn _payload, _headers ->
                 {:ok, %{status: 200, body: %{"data" => %{}}}}
               end
             )

    summary = LinearTelemetry.current_process_summary()
    assert summary.request_count == 1
    assert summary.operations["anonymous"].request_count == 1
  end

  test "linear telemetry summary normalizes malformed values" do
    assert LinearTelemetry.summarize(%{
             "request_count" => "many",
             "total_latency_ms" => -1,
             "total_response_size_bytes" => nil,
             "operations" => :invalid
           }) == LinearTelemetry.empty_summary()
  end

  test "viewer assignee lookup is cached per effective Linear credentials" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token-one",
      tracker_endpoint: "https://linear.example/graphql"
    )

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(calls) do
        Agent.stop(calls)
      end
    end)

    graphql_fun = fn query, variables ->
      Agent.update(calls, &(&1 + 1))
      assert query =~ "SymphonyLinearViewer"
      assert variables == %{}
      {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-one"}}}}
    end

    assert {:ok, %{configured_assignee: "me", match_values: match_values}} =
             Client.resolve_viewer_assignee_filter_for_test(graphql_fun)

    assert MapSet.member?(match_values, "viewer-one")

    assert {:ok, %{match_values: cached_match_values}} =
             Client.resolve_viewer_assignee_filter_for_test(fn _query, _variables ->
               flunk("viewer cache should avoid a second GraphQL request")
             end)

    assert cached_match_values == match_values
    assert Agent.get(calls, & &1) == 1

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token-two",
      tracker_endpoint: "https://linear.example/graphql"
    )

    assert {:ok, %{match_values: next_match_values}} =
             Client.resolve_viewer_assignee_filter_for_test(fn _query, _variables ->
               Agent.update(calls, &(&1 + 1))
               {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-two"}}}}
             end)

    assert MapSet.member?(next_match_values, "viewer-two")
    assert Agent.get(calls, & &1) == 2
  end

  defp assert_linear_graphql_event(operation_name) do
    assert_receive {:linear_graphql_telemetry, [:symphony, :linear, :graphql], measurements, metadata}, 1_000

    if metadata.operation_name == operation_name do
      {measurements, metadata}
    else
      assert_linear_graphql_event(operation_name)
    end
  end
end
