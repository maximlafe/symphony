defmodule SymphonyElixir.MergeGatingParityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HandoffCheck

  @matrix_fixture Path.expand("../fixtures/parity/parity_06_merge_gating_matrix.json", __DIR__)
  @live_fixture Path.expand("../fixtures/parity/parity_06_merge_gating_live_sanitized.json", __DIR__)
  @contract_doc Path.expand("../../../docs/symphony-next/contracts/PARITY-06_MERGE_GATING_CONTRACT.md", __DIR__)

  @required_acceptance_ids [
    "PARITY-06-AM-01",
    "PARITY-06-AM-02",
    "PARITY-06-AM-03",
    "PARITY-06-AM-04",
    "PARITY-06-AM-05",
    "PARITY-06-AM-06",
    "PARITY-06-AM-07",
    "PARITY-06-AM-08",
    "PARITY-06-AM-09",
    "PARITY-06-AM-10"
  ]

  test "PARITY-06 deterministic merge gating matrix cases pass" do
    payload = load_fixture!(@matrix_fixture)

    assert payload["ticket"] == "PARITY-06"
    assert payload["source"]["kind"] == "deterministic_matrix"

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    Enum.each(cases, fn case_entry ->
      case case_entry["kind"] do
        "evaluate" -> assert_evaluate_case!(case_entry)
        "transition" -> assert_transition_case!(case_entry)
        kind -> flunk("unsupported deterministic case kind: #{inspect(kind)}")
      end
    end)
  end

  test "PARITY-06 live-sanitized merge gating traces match canonical decision mapping" do
    payload = load_fixture!(@live_fixture)

    assert payload["ticket"] == "PARITY-06"
    assert is_binary(payload["generated_at"])

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    merge_ready_values =
      cases
      |> Enum.map(&get_in(&1, ["expected", "merge_ready"]))
      |> MapSet.new()

    assert MapSet.member?(merge_ready_values, true)
    assert MapSet.member?(merge_ready_values, false)

    Enum.each(cases, &assert_live_case!/1)
  end

  test "PARITY-06 contract doc maps AM ids to executable suite" do
    body = File.read!(@contract_doc)

    Enum.each(@required_acceptance_ids, fn id ->
      assert String.contains?(body, id), "missing acceptance id #{id} in contract doc"
    end)

    Enum.each(
      ["pull request is not merge-ready", "CLEAN", "HAS_HOOKS"],
      fn marker ->
        assert String.contains?(body, marker), "missing contract marker #{marker}"
      end
    )
  end

  defp assert_evaluate_case!(case_entry) do
    case_id = case_entry["case_id"] || "UNKNOWN"
    pr_snapshot = Map.get(case_entry, "pr_snapshot", %{})
    expected = Map.get(case_entry, "expected", %{})

    result = evaluate_snapshot(pr_snapshot)

    case expected["outcome"] do
      "ok" ->
        assert {:ok, manifest} = result
        assert manifest["missing_items"] == [], "case #{case_id}: expected zero missing items"

      "error" ->
        assert {:error, manifest} = result

        Enum.each(Map.get(expected, "required_missing_items", []), fn item ->
          assert item in manifest["missing_items"], "case #{case_id}: missing item not found #{inspect(item)}"
        end)

      other ->
        flunk("unsupported expected outcome #{inspect(other)} for case #{case_id}")
    end
  end

  defp assert_transition_case!(case_entry) do
    case_id = case_entry["case_id"] || "UNKNOWN"
    input = Map.get(case_entry, "transition_input", %{})
    expected = Map.get(case_entry, "expected", %{})
    issue_id = Map.get(input, "issue_id", "LET-PARITY06-TRANSITION")
    state_name = Map.get(input, "state_name", "In Review")
    workpad_body = Map.get(input, "workpad_body", "runtime evidence unchanged\n")
    manifest_git = Map.get(input, "manifest_git", base_git_metadata())
    runtime_git = Map.get(input, "runtime_git", manifest_git)
    mutate_workpad = Map.get(input, "mutate_workpad", false)

    tmp_dir = Path.join(System.tmp_dir!(), "parity-06-transition-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    workpad_path = Path.join(tmp_dir, "workpad.md")
    manifest_path = Path.join(tmp_dir, "handoff-manifest.json")
    File.write!(workpad_path, workpad_body)

    manifest =
      %{
        "passed" => true,
        "issue" => %{"id" => issue_id},
        "workpad" => %{
          "file_path" => workpad_path,
          "sha256" => sha256(workpad_body)
        },
        "validation_gate" => base_validation_gate(),
        "git" => manifest_git
      }

    assert {:ok, _} = HandoffCheck.write_manifest(manifest, manifest_path)

    if mutate_workpad do
      File.write!(workpad_path, workpad_body <> "changed\n")
    end

    result =
      HandoffCheck.review_ready_transition_allowed?(
        manifest_path,
        issue_id,
        state_name,
        workpad_path,
        git_runner: git_runner(runtime_git),
        repo_path: tmp_dir
      )

    if expected["allowed"] == true do
      assert :ok = result
    else
      assert {:error, reason, details} = result
      assert Atom.to_string(reason) == expected["error_type"], "case #{case_id}: error type mismatch"
      assert String.contains?(details["reason"], expected["reason_contains"]), "case #{case_id}: reason mismatch"

      if is_binary(expected["details_contains"]) do
        details_list = normalize_string_list(details["details"])

        assert Enum.any?(details_list, &String.contains?(&1, expected["details_contains"])),
               "case #{case_id}: missing details marker #{inspect(expected["details_contains"])}"
      end
    end
  end

  defp assert_live_case!(case_entry) do
    case_id = case_entry["case_id"] || "UNKNOWN"
    observed = Map.get(case_entry, "observed", %{})
    expected = Map.get(case_entry, "expected", %{})

    {merge_ready, missing_items} =
      evaluate_merge_gating(%{
        "all_checks_green" => observed["all_checks_green"],
        "has_pending_checks" => observed["has_pending_checks"],
        "has_actionable_feedback" => observed["has_actionable_feedback"],
        "merge_state_status" => observed["merge_state_status"],
        "url" => "https://example.test/live/#{case_id}"
      })

    assert merge_ready == expected["merge_ready"], "case #{case_id}: merge_ready mismatch"

    Enum.each(Map.get(expected, "required_missing_items", []), fn item ->
      assert item in missing_items, "case #{case_id}: missing item not found #{inspect(item)}"
    end)
  end

  defp evaluate_snapshot(pr_snapshot) do
    HandoffCheck.evaluate(
      base_workpad(),
      issue_id: "LET-PARITY06-EVAL",
      profile: "generic",
      attachments: [%{"title" => "runtime-proof.log"}],
      pr_snapshot: pr_snapshot,
      validation_gate: base_validation_gate(),
      git: base_git_metadata()
    )
  end

  defp evaluate_merge_gating(pr_snapshot) do
    case evaluate_snapshot(pr_snapshot) do
      {:ok, manifest} -> {true, Map.get(manifest, "missing_items", [])}
      {:error, manifest} -> {false, Map.get(manifest, "missing_items", [])}
    end
  end

  defp base_workpad do
    """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/merge_gating_parity_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> merge gating parity evidence

    ### Checkpoint

    - `checkpoint_type`: `decision`
    - `risk_level`: `medium`
    - `summary`: Merge gating proof is complete.
    """
  end

  defp base_validation_gate do
    %{
      "gate" => "final",
      "change_classes" => ["backend_only"],
      "strictest_change_class" => "backend_only",
      "requires_final_gate" => true,
      "required_checks" => ["preflight", "cheap_gate", "targeted_tests", "repo_validation"],
      "passed_checks" => ["preflight", "cheap_gate", "targeted_tests", "repo_validation"],
      "remote_finalization_allowed" => true
    }
  end

  defp base_git_metadata do
    %{
      "head_sha" => "head-sha",
      "tree_sha" => "tree-sha",
      "worktree_clean" => true
    }
  end

  defp git_runner(runtime_git) when is_map(runtime_git) do
    head_sha = "#{Map.get(runtime_git, "head_sha", "")}\n"
    tree_sha = "#{Map.get(runtime_git, "tree_sha", "")}\n"
    status = if Map.get(runtime_git, "worktree_clean", false), do: "", else: " M changed\n"

    fn
      ["rev-parse", "HEAD"], _opts -> {:ok, head_sha}
      ["rev-parse", "HEAD^{tree}"], _opts -> {:ok, tree_sha}
      ["status", "--porcelain", "--untracked-files=no"], _opts -> {:ok, status}
    end
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(value) when is_binary(value), do: [value]
  defp normalize_string_list(_value), do: []

  defp sha256(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end

  defp load_fixture!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
