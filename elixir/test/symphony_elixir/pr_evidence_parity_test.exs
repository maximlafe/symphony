defmodule SymphonyElixir.PrEvidenceParityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrEvidence

  @matrix_fixture Path.expand("../fixtures/parity/parity_04_pr_evidence_matrix.json", __DIR__)
  @live_fixture Path.expand("../fixtures/parity/parity_04_pr_evidence_live_sanitized.json", __DIR__)
  @contract_doc Path.expand("../../../docs/symphony-next/contracts/PARITY-04_PR_EVIDENCE_CONTRACT.md", __DIR__)

  @required_acceptance_ids [
    "PARITY-04-AM-01",
    "PARITY-04-AM-02",
    "PARITY-04-AM-03",
    "PARITY-04-AM-04",
    "PARITY-04-AM-05",
    "PARITY-04-AM-06",
    "PARITY-04-AM-07",
    "PARITY-04-AM-08",
    "PARITY-04-AM-09"
  ]

  test "PARITY-04 deterministic PR evidence matrix cases pass" do
    payload = load_fixture!(@matrix_fixture)

    assert payload["ticket"] == "PARITY-04"
    assert payload["source"]["kind"] == "deterministic_matrix"

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    assert_pr_evidence_cases!(cases)
  end

  test "PARITY-04 live-sanitized PR evidence cases pass the same contract runner" do
    payload = load_fixture!(@live_fixture)

    assert payload["ticket"] == "PARITY-04"
    assert is_binary(payload["generated_at"])

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    expected_sources =
      cases
      |> Enum.map(&get_in(&1, ["expected", "source"]))
      |> MapSet.new()

    assert MapSet.member?(expected_sources, "issue_comment")
    assert MapSet.member?(expected_sources, "issue_attachment")
    assert MapSet.member?(expected_sources, "branch_lookup")

    assert_pr_evidence_cases!(cases)
  end

  test "PARITY-04 contract doc maps AM ids to executable suite" do
    body = File.read!(@contract_doc)

    Enum.each(@required_acceptance_ids, fn id ->
      assert String.contains?(body, id), "missing acceptance id #{id} in contract doc"
    end)

    Enum.each(
      ["workspace_checkpoint", "workpad", "issue_comment", "issue_attachment", "branch_lookup", "source=none"],
      fn marker ->
        assert String.contains?(body, marker), "missing contract marker #{marker}"
      end
    )
  end

  defp assert_pr_evidence_cases!(cases) when is_list(cases) do
    Enum.each(cases, fn case_entry ->
      case_id = case_entry["case_id"] || "UNKNOWN"
      input = Map.get(case_entry, "input", %{})
      expected = Map.get(case_entry, "expected", %{})

      lookup_result = Map.get(case_entry, "lookup_result")

      actual =
        PrEvidence.resolve(
          input,
          branch_lookup_fun: fn _repo, _branch ->
            lookup_result
          end
        )

      assert actual["source"] == expected["source"], "case #{case_id}: source mismatch"
      assert actual["repo"] == expected["repo"], "case #{case_id}: repo mismatch"
      assert actual["pr_number"] == expected["pr_number"], "case #{case_id}: pr_number mismatch"
      assert actual["url"] == expected["url"], "case #{case_id}: url mismatch"

      if expected["source"] != "none" do
        assert is_integer(actual["pr_number"]) and actual["pr_number"] > 0,
               "case #{case_id}: expected positive pr_number"

        assert is_binary(actual["url"]) and String.contains?(actual["url"], "/pull/"),
               "case #{case_id}: expected canonical pull URL"
      end
    end)
  end

  defp load_fixture!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
