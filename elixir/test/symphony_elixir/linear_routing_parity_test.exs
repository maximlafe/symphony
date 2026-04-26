defmodule SymphonyElixir.LinearRoutingParityTest do
  use SymphonyElixir.TestSupport

  @matrix_fixture Path.expand("../fixtures/parity/parity_01_linear_routing_matrix.json", __DIR__)
  @live_fixture Path.expand("../fixtures/parity/parity_01_linear_routing_live_sanitized.json", __DIR__)

  test "PARITY-01 canonical routing matrix cases pass" do
    payload = load_fixture!(@matrix_fixture)

    assert payload["ticket"] == "PARITY-01"
    assert payload["scope"]["team_key"] == "LET"

    configure_replacement_scope!(payload["scope"], payload["assignee_filter"])
    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    assert_matrix_cases!(cases, payload["assignee_filter"])
  end

  test "PARITY-01 live-sanitized routing cases pass the same matrix runner" do
    payload = load_fixture!(@live_fixture)

    assert payload["ticket"] == "PARITY-01"
    assert is_binary(payload["generated_at"])

    configure_replacement_scope!(payload["scope"], payload["assignee_filter"])
    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    assert_matrix_cases!(cases, payload["assignee_filter"])
  end

  defp assert_matrix_cases!(cases, assignee_filter) when is_list(cases) do
    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(), max_concurrent_agents: 10}
    normalized_assignee_filter = normalize_optional_binary(assignee_filter)

    Enum.each(cases, fn case_entry ->
      case_id = case_entry["case_id"] || "UNKNOWN"
      issue_map = Map.get(case_entry, "issue", %{})
      expected = Map.get(case_entry, "expected", %{})

      normalized_issue = Client.normalize_issue_for_test(issue_map, normalized_assignee_filter)
      assert normalized_issue, "case #{case_id}: normalize_issue_for_test returned nil"

      assert normalized_issue.assigned_to_worker == expected["assigned_to_worker"],
             "case #{case_id}: assigned_to_worker mismatch"

      assert Orchestrator.should_dispatch_issue_for_test(normalized_issue, state) == expected["dispatch_eligible"],
             "case #{case_id}: dispatch_eligible mismatch"
    end)
  end

  defp configure_replacement_scope!(scope, assignee_filter) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team_key: scope["team_key"],
      tracker_assignee: normalize_optional_binary(assignee_filter),
      tracker_active_states: Map.get(scope, "active_states", []),
      tracker_manual_intervention_state: Map.get(scope, "manual_intervention_state", "Blocked"),
      tracker_terminal_states: Map.get(scope, "terminal_states", [])
    )
  end

  defp load_fixture!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp normalize_optional_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_binary(_value), do: nil
end
