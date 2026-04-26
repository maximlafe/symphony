defmodule SymphonyElixir.ActionableFeedbackParityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config
  alias SymphonyElixir.ControllerFinalizer
  alias SymphonyElixir.HandoffCheck
  alias SymphonyElixir.Linear.Issue

  @matrix_fixture Path.expand("../fixtures/parity/parity_14_actionable_feedback_matrix.json", __DIR__)
  @live_fixture Path.expand("../fixtures/parity/parity_14_actionable_feedback_live_sanitized.json", __DIR__)
  @contract_doc Path.expand("../../../docs/symphony-next/contracts/PARITY-14_ACTIONABLE_REVIEW_FEEDBACK_CONTRACT.md", __DIR__)

  @required_acceptance_ids [
    "PARITY-14-AM-01",
    "PARITY-14-AM-02",
    "PARITY-14-AM-03",
    "PARITY-14-AM-04",
    "PARITY-14-AM-05",
    "PARITY-14-AM-06",
    "PARITY-14-AM-07",
    "PARITY-14-AM-08",
    "PARITY-14-AM-09",
    "PARITY-14-AM-10"
  ]

  defmodule TrackerOk do
    def update_issue_state(_issue_id, _state_name), do: :ok
  end

  test "PARITY-14 deterministic actionable feedback matrix cases pass" do
    payload = load_fixture!(@matrix_fixture)

    assert payload["ticket"] == "PARITY-14"
    assert payload["source"]["kind"] == "deterministic_matrix"

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    Enum.each(cases, fn case_entry ->
      case case_entry["kind"] do
        "snapshot" -> assert_snapshot_case!(case_entry)
        "handoff_gate" -> assert_handoff_gate_case!(case_entry)
        "finalizer_gate" -> assert_finalizer_gate_case!(case_entry)
        kind -> flunk("unsupported deterministic case kind: #{inspect(kind)}")
      end
    end)
  end

  test "PARITY-14 live-sanitized actionable feedback cases match canonical workflow mapping" do
    payload = load_fixture!(@live_fixture)

    assert payload["ticket"] == "PARITY-14"
    assert is_binary(payload["generated_at"])

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    states =
      cases
      |> Enum.map(&get_in(&1, ["observed", "actionable_feedback_state"]))
      |> MapSet.new()

    assert MapSet.member?(states, "changes_requested")
    assert MapSet.member?(states, "none")

    Enum.each(cases, &assert_live_case!/1)
  end

  test "PARITY-14 contract doc maps AM ids to executable suite" do
    body = File.read!(@contract_doc)

    Enum.each(@required_acceptance_ids, fn id ->
      assert String.contains?(body, id), "missing acceptance id #{id} in contract doc"
    end)

    Enum.each(
      ["actionable_feedback_state", "changes_requested", "actionable_comments", "none"],
      fn marker ->
        assert String.contains?(body, marker), "missing contract marker #{marker}"
      end
    )
  end

  defp assert_snapshot_case!(case_entry) do
    case_id = case_entry["case_id"] || "UNKNOWN"
    input = Map.get(case_entry, "input", %{})
    expected = Map.get(case_entry, "expected", %{})
    repo = input["repo"] || "maximlafe/symphony"
    pr_number = input["pr_number"] || 0

    response =
      DynamicTool.execute(
        "github_pr_snapshot",
        %{
          "repo" => repo,
          "pr_number" => pr_number,
          "include_feedback_details" => true
        },
        gh_runner: snapshot_gh_runner(input)
      )

    assert response["success"] == true, "case #{case_id}: snapshot call failed"
    payload = decode_tool_payload!(response)

    assert payload["actionable_feedback_state"] == expected["actionable_feedback_state"], "case #{case_id}: actionable_feedback_state mismatch"
    assert payload["has_actionable_feedback"] == expected["has_actionable_feedback"], "case #{case_id}: has_actionable_feedback mismatch"
    assert length(payload["actionable_feedback"]) == expected["actionable_feedback_count"], "case #{case_id}: actionable_feedback_count mismatch"
    assert payload["review_state_summary"] == expected["review_state_summary"], "case #{case_id}: review_state_summary mismatch"

    Enum.each(payload["actionable_feedback"], fn item ->
      assert item["classification"] in ["changes_requested_review", "actionable_comment"],
             "case #{case_id}: unexpected classification #{inspect(item["classification"])}"
    end)
  end

  defp assert_handoff_gate_case!(case_entry) do
    case_id = case_entry["case_id"] || "UNKNOWN"
    snapshot = get_in(case_entry, ["input", "snapshot"]) || %{}
    expected = Map.get(case_entry, "expected", %{})
    blocked = handoff_blocks_on_feedback?(snapshot)

    assert blocked == expected["workflow_blocks"], "case #{case_id}: handoff gate mismatch"
  end

  defp assert_finalizer_gate_case!(case_entry) do
    case_id = case_entry["case_id"] || "UNKNOWN"
    input = Map.get(case_entry, "input", %{})
    expected = Map.get(case_entry, "expected", %{})
    issue_identifier = input["issue_identifier"] || "LET-PARITY14-FINALIZER"
    issue = %Issue{id: input["issue_id"], identifier: issue_identifier, state: "In Progress"}
    _workspace = create_workspace!(issue_identifier)

    checkpoint = %{
      "head" => "head-#{String.downcase(issue_identifier)}",
      "open_pr" => %{"number" => 901, "url" => get_in(input, ["snapshot", "url"])}
    }

    script = %{
      "sync_workpad" => %{"ok" => %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => %{"ok" => %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" => %{"ok" => input["snapshot"]}
    }

    result =
      ControllerFinalizer.run(
        issue,
        checkpoint,
        repo: "maximlafe/symphony",
        tracker_module: TrackerOk,
        tool_executor: script_executor(script)
      )

    expected_outcome = outcome_atom(expected["outcome"])
    assert {^expected_outcome, payload} = result, "case #{case_id}: outcome mismatch"
    assert payload.reason == expected["reason"], "case #{case_id}: reason mismatch"
  end

  defp assert_live_case!(case_entry) do
    case_id = case_entry["case_id"] || "UNKNOWN"
    observed = Map.get(case_entry, "observed", %{})
    expected = Map.get(case_entry, "expected", %{})

    blocked =
      handoff_blocks_on_feedback?(%{
        "all_checks_green" => true,
        "has_pending_checks" => false,
        "merge_state_status" => "CLEAN",
        "has_actionable_feedback" => observed["has_actionable_feedback"],
        "actionable_feedback_state" => observed["actionable_feedback_state"],
        "url" => observed["pr_url"] || "https://example.test/live/#{case_id}"
      })

    assert blocked == expected["workflow_blocks"], "case #{case_id}: live workflow mapping mismatch"
  end

  defp handoff_blocks_on_feedback?(snapshot) do
    case HandoffCheck.evaluate(
           base_workpad(),
           issue_id: "LET-PARITY14-HANDOFF",
           profile: "generic",
           attachments: [%{"title" => "runtime-proof.log"}],
           pr_snapshot: snapshot,
           validation_gate: base_validation_gate(),
           git: base_git_metadata()
         ) do
      {:ok, _manifest} ->
        false

      {:error, manifest} ->
        "pull request still has actionable feedback" in Map.get(manifest, "missing_items", [])
    end
  end

  defp snapshot_gh_runner(input) do
    core = Map.get(input, "core", %{})
    issue_comments = Map.get(input, "issue_comments", [])
    reviews = Map.get(input, "reviews", [])
    inline_comments = Map.get(input, "inline_comments", [])
    repo = Map.get(input, "repo", "maximlafe/symphony")
    pr_number = input["pr_number"] |> to_string()
    {owner, name} = split_repo(repo)

    fn args, _opts ->
      case args do
        ["pr", "view", ^pr_number, "-R", ^repo, "--json", "state,url,labels,reviewDecision,mergeStateStatus,statusCheckRollup"] ->
          {:ok, Jason.encode!(core)}

        ["api", "repos/" <> ^owner <> "/" <> ^name <> "/issues/" <> ^pr_number <> "/comments?per_page=100"] ->
          {:ok, Jason.encode!(issue_comments)}

        ["api", "repos/" <> ^owner <> "/" <> ^name <> "/pulls/" <> ^pr_number <> "/reviews?per_page=100"] ->
          {:ok, Jason.encode!(reviews)}

        ["api", "repos/" <> ^owner <> "/" <> ^name <> "/pulls/" <> ^pr_number <> "/comments?per_page=100"] ->
          {:ok, Jason.encode!(inline_comments)}
      end
    end
  end

  defp split_repo(repo) when is_binary(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] -> {owner, name}
      _ -> {"maximlafe", "symphony"}
    end
  end

  defp decode_tool_payload!(%{"contentItems" => [%{"text" => text} | _]}) do
    {:ok, payload} = Jason.decode(text)
    payload
  end

  defp script_executor(script) when is_map(script) do
    fn tool_name, _arguments, _workspace ->
      case script[tool_name] do
        %{"ok" => payload} -> tool_success(payload)
        %{"error" => payload} -> tool_failure(payload)
        nil -> raise "unexpected tool call: #{tool_name}"
        other -> raise "unsupported tool script entry: #{inspect(other)}"
      end
    end
  end

  defp tool_success(payload) do
    %{
      "success" => true,
      "contentItems" => [%{"type" => "inputText", "text" => Jason.encode!(payload)}]
    }
  end

  defp tool_failure(payload) do
    %{
      "success" => false,
      "contentItems" => [%{"type" => "inputText", "text" => Jason.encode!(payload)}]
    }
  end

  defp create_workspace!(identifier) do
    workspace = Path.join(Config.settings!().workspace.root, identifier)

    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "workpad.md"), base_workpad())
    File.write!(Path.join(workspace, ".workpad-id"), "workpad-comment\n")

    workspace
  end

  defp base_workpad do
    """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/actionable_feedback_parity_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> actionable feedback parity evidence

    ### Checkpoint

    - `checkpoint_type`: `decision`
    - `risk_level`: `medium`
    - `summary`: Actionable feedback classification parity is complete.
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

  defp outcome_atom("ok"), do: :ok
  defp outcome_atom("retry"), do: :retry
  defp outcome_atom("fallback"), do: :fallback
  defp outcome_atom("not_applicable"), do: :not_applicable
  defp outcome_atom(other), do: raise("unsupported outcome #{inspect(other)}")

  defp load_fixture!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
