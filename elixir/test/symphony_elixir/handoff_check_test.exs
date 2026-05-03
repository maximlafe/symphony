defmodule SymphonyElixir.HandoffCheckTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HandoffCheck

  test "evaluate fails when the workpad is missing required checklist items and checkpoint fields" do
    workpad = """
    ## Codex Workpad

    ```text
    host:/tmp/workspace@abc1234
    ```

    ### Validation

    - [x] targeted tests: `mix test test/smoke.exs`

    ### Artifacts

    - [x] uploaded attachment: `proof.txt` -> proves something

    ### Checkpoint

    - `checkpoint_type`: `<human-verify|decision|human-action>` (fill only at handoff)
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-416",
               repo: "maximlafe/symphony",
               pr_number: 52,
               labels: [],
               attachments: [%{"title" => "proof.txt"}],
               pr_snapshot: %{
                 "all_checks_green" => true,
                 "has_pending_checks" => false,
                 "has_actionable_feedback" => false,
                 "merge_state_status" => "CLEAN",
                 "url" => "https://example.test/pr/52"
               }
             )

    refute manifest["passed"]
    assert "validation checklist is missing a checked `preflight` item" in manifest["missing_items"]
    assert Enum.any?(manifest["missing_items"], &String.contains?(&1, "`risk_level`"))
  end

  test "evaluate passes for a runtime profile with matching attachment, checklist, and green PR" do
    workpad = """
    ## Codex Workpad

    ```text
    host:/tmp/workspace@abc1234
    ```

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log from the health check

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: Runtime proof, tests, and repo validation are complete.
    """

    issue_description = """
    ## Symphony
    Repo: maximlafe/symphony
    Required capabilities: runtime_smoke, artifact_upload, repo_validation
    """

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_description: issue_description,
               issue_id: "LET-416",
               issue_identifier: "LET-416",
               workpad_path: "/tmp/workpad.md",
               repo: "maximlafe/symphony",
               pr_number: 52,
               labels: ["verification:runtime"],
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: %{
                 "all_checks_green" => true,
                 "has_pending_checks" => false,
                 "has_actionable_feedback" => false,
                 "merge_state_status" => "CLEAN",
                 "url" => "https://example.test/pr/52"
               },
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert manifest["passed"]
    assert manifest["contract_version"] == 3
    assert manifest["profile"] == "runtime"
    assert manifest["profile_source"] == "label"
    assert manifest["issue"]["required_capabilities"] == ["runtime_smoke", "artifact_upload"]
    assert manifest["validation_gate"]["gate"] == "final"
    assert manifest["git"]["head_sha"] == "abc123"
    assert manifest["missing_items"] == []
    assert manifest["summary"] =~ "verification passed"
    assert manifest["workpad"]["sha256"]
  end

  test "default accessors expose the verification contract and default evaluate fails closed" do
    assert HandoffCheck.supported_profiles() == ["ui", "data-extraction", "runtime", "generic"]
    assert HandoffCheck.default_profile_labels()["runtime"] == "verification:runtime"
    assert HandoffCheck.default_review_ready_states() == ["In Review", "Human Review"]
    assert HandoffCheck.default_manifest_path() == ".symphony/verification/handoff-manifest.json"
    assert HandoffCheck.default_contract_lock_path() == ".symphony/verification/acceptance-contract.lock.json"

    assert {:error, manifest} = HandoffCheck.evaluate("## Codex Workpad")

    assert manifest["profile"] == "generic"
    assert manifest["profile_source"] == "fallback"
    assert "pull request snapshot is missing" in manifest["missing_items"]
  end

  test "evaluate freezes canonical acceptance contract revision in manifest" do
    issue_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | Positive path | Canonical proof passes | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    """

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               """
               ## Codex Workpad

               ### Validation

               - [x] preflight: `make symphony-preflight`
               - [x] cheap gate: `same HEAD targeted proof completed`
               - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
               - [x] repo validation: `make symphony-validate`

               ### Artifacts

               - [x] uploaded attachment: `proof.log` -> deterministic proof artifact

               ### Proof Mapping

               - [x] `AM-1` -> validation:targeted tests

               ### Checkpoint

               - `checkpoint_type`: `human-verify`
               - `risk_level`: `low`
               - `summary`: Contract revision freeze path verified.
               """,
               issue_id: "LET-416",
               issue_description: issue_description,
               labels: ["mode:plan", "verification:generic"],
               attachments: [%{"title" => "proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert manifest["acceptance_contract"]["version"] == 1
    assert is_binary(manifest["contract_revision"])
    assert manifest["contract_revision"] == get_in(manifest, ["acceptance_contract", "revision"])
    assert manifest["contract_revision"] == get_in(manifest, ["issue", "acceptance_contract_revision"])
    assert get_in(manifest, ["handoff_failure", "kind"]) == "none"
  end

  test "write_acceptance_contract_lock writes a machine-readable lock file" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-handoff-contract-lock-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)

      issue = %{
        "id" => "LET-LOCK",
        "identifier" => "LET-LOCK",
        "description" => """
        ## Acceptance Matrix

        | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
        | -- | -- | -- | -- | -- | -- |
        | AM-1 | lock surface exists | lock revision is frozen | test | mix test | run_executed |
        """
      }

      assert {:ok, lock_path} = HandoffCheck.write_acceptance_contract_lock(workspace_root, issue)
      assert File.exists?(lock_path)

      lock = lock_path |> File.read!() |> Jason.decode!()
      assert lock["issue"]["id"] == "LET-LOCK"
      assert is_binary(lock["contract_revision"])
      assert lock["contract_revision"] == get_in(lock, ["acceptance_contract", "revision"])
    after
      File.rm_rf(workspace_root)
    end
  end

  test "write_acceptance_contract_lock fails closed on malformed acceptance matrix rows" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-handoff-contract-lock-malformed-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)

      malformed_issue = %{
        "id" => "LET-LOCK-BAD",
        "identifier" => "LET-LOCK-BAD",
        "description" => """
        ## Acceptance Matrix

        | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
        | -- | -- | -- | -- | -- | -- |
        | AM-1 | malformed row | lock freeze must fail | test | mix test
        """
      }

      assert {:error, {:acceptance_matrix_parse_error, details}} =
               HandoffCheck.write_acceptance_contract_lock(workspace_root, malformed_issue)

      assert details["reason"] =~ "cannot be frozen"
      assert details["issue_id"] == "LET-LOCK-BAD"
      assert Enum.any?(details["errors"], &String.contains?(&1, "not terminated"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "acceptance contract parser recovers continued acceptance matrix rows" do
    description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | recovered row | row continuation is merged | test | mix test test/symphony_elixir/handoff_check_test.exs
    | run_executed |
    | AM-2 | intact row | parser remains stable | test | mix test test/symphony_elixir/dynamic_tool_test.exs | run_executed |
    """

    contract = HandoffCheck.acceptance_contract_from_issue_description(description)
    errors = HandoffCheck.acceptance_matrix_parse_errors(description)

    assert errors == []
    assert Enum.map(get_in(contract, ["payload", "acceptance_matrix"]), & &1["id"]) == ["AM-1", "AM-2"]
  end

  test "acceptance matrix parser reports malformed table fragments" do
    description = """
    ## Acceptance Matrix

    orphan | fragment
    prose without table delimiters
    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |

    | -- | -- | -- | -- | -- | -- |
    dangling | fragment
    plain prose outside the table
    | AM-1 | unterminated row | parser reports it | test | mix test
    | AM-2 | next row | forces unterminated error | test | mix test | run_executed |
    trailing prose outside the table
    """

    errors = HandoffCheck.acceptance_matrix_parse_errors(description)

    assert HandoffCheck.acceptance_matrix_parse_errors(nil) == []
    assert Enum.any?(errors, &String.contains?(&1, "line is malformed: orphan | fragment"))
    assert Enum.any?(errors, &String.contains?(&1, "line is malformed: dangling | fragment"))
    assert Enum.any?(errors, &String.contains?(&1, "not terminated before next row starts"))
  end

  test "proof_contract_errors tolerates nil markdown" do
    assert HandoffCheck.proof_contract_errors(nil) == []
    assert HandoffCheck.proof_contract_errors(nil, attachments: [%{"title" => "proof.log"}]) == []
  end

  test "proof_contract_errors validates placeholder attachment claims with explicit attachments" do
    markdown = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | placeholder attachment claim | artifact proof needs concrete claim | artifact | runtime-proof.log | run_executed |

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> n/a

    ### Proof Mapping

    - [x] `AM-1` -> `artifact:runtime-proof.log`
    """

    errors =
      HandoffCheck.proof_contract_errors(markdown,
        attachments: [%{"title" => "runtime-proof.log"}]
      )

    assert "uploaded attachment `runtime-proof.log` is missing a concrete proof claim" in errors
  end

  test "proof_contract_errors reports duplicate and unknown proof mappings" do
    markdown = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | duplicate mapping | exactly one mapping is required | test | mix test | run_executed |

    ### Validation

    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`

    ### Proof Mapping

    - [x] `AM-1` -> `validation:targeted tests`
    - [x] `AM-1` -> `validation:targeted tests`
    - [x] `AM-UNKNOWN` -> `validation:targeted tests`
    """

    errors = HandoffCheck.proof_contract_errors(markdown)

    assert "acceptance matrix item `AM-1` has multiple proof mapping entries; exactly one is required" in errors
    assert "proof mapping references unknown acceptance matrix item `AM-UNKNOWN`" in errors
  end

  test "acceptance contract parser preserves UTF-8 matrix rows for lock encoding" do
    description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | UTF-8 row | Текущий шаг и детали находятся в устойчивой разметке | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    | AM-2 | UTF-8 row | Совместимость API сохранена: raw `attached` остается в JSON | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    """

    contract = HandoffCheck.acceptance_contract_from_issue_description(description)
    matrix_items = get_in(contract, ["payload", "acceptance_matrix"])

    assert Enum.map(matrix_items, & &1["id"]) == ["AM-1", "AM-2"]
    assert Enum.all?(matrix_items, &String.valid?(&1["expected_outcome"]))
    assert {:ok, _json} = Jason.encode(contract)
  end

  test "acceptance contract helpers handle invalid inputs and lock edge cases" do
    assert is_binary(HandoffCheck.acceptance_contract_from_issue_description(nil)["revision"])
    assert {:error, :invalid_contract_lock_input} = HandoffCheck.write_acceptance_contract_lock(nil, %{}, [])

    assert {:error, :handoff_manifest_invalid, invalid_manifest_details} =
             HandoffCheck.validate_contract_lock(nil, [])

    assert invalid_manifest_details["reason"] == "manifest is required for contract lock validation"

    manifest_with_nested_revision = %{
      "acceptance_contract" => %{"revision" => "rev-alpha"},
      "issue" => %{"id" => "LET-EDGE"}
    }

    lock_with_nested_revision = %{
      "acceptance_contract" => %{"revision" => "rev-alpha"},
      "issue" => %{"id" => "LET-EDGE"}
    }

    assert :ok = HandoffCheck.validate_contract_lock(manifest_with_nested_revision)

    assert :ok =
             HandoffCheck.validate_contract_lock(
               manifest_with_nested_revision,
               contract_lock: lock_with_nested_revision
             )

    assert {:error, :handoff_manifest_stale, missing_lock_revision_details} =
             HandoffCheck.validate_contract_lock(
               manifest_with_nested_revision,
               contract_lock: %{"issue" => %{"id" => "LET-EDGE"}}
             )

    assert missing_lock_revision_details["reason"] == "acceptance contract lock revision is missing"

    assert {:error, :handoff_manifest_stale, missing_manifest_revision_details} =
             HandoffCheck.validate_contract_lock(
               %{"issue" => %{"id" => "LET-EDGE"}},
               contract_lock: %{"contract_revision" => "rev-alpha", "issue" => %{"id" => "LET-EDGE"}}
             )

    assert missing_manifest_revision_details["reason"] == "acceptance contract revision is missing from manifest"

    assert {:error, :handoff_manifest_invalid, wrong_issue_details} =
             HandoffCheck.validate_contract_lock(
               manifest_with_nested_revision,
               contract_lock: %{"acceptance_contract" => %{"revision" => "rev-alpha"}, "issue" => %{"id" => "LET-OTHER"}}
             )

    assert wrong_issue_details["reason"] == "acceptance contract lock belongs to a different issue"

    assert Enum.any?(wrong_issue_details["details"], fn detail ->
             String.contains?(detail, "lock_issue_id=LET-OTHER")
           end)

    assert {:error, :handoff_manifest_stale, missing_path_details} =
             HandoffCheck.validate_contract_lock(
               manifest_with_nested_revision,
               require_contract_lock: true
             )

    assert missing_path_details["reason"] == "acceptance contract lock path is missing"
    assert missing_path_details["manifest"] == manifest_with_nested_revision

    missing_lock_path = Path.join(System.tmp_dir!(), "handoff-check-missing-lock-#{System.unique_integer([:positive])}.json")

    assert {:error, :handoff_manifest_stale, missing_file_details} =
             HandoffCheck.validate_contract_lock(
               manifest_with_nested_revision,
               require_contract_lock: true,
               contract_lock_path: missing_lock_path
             )

    assert missing_file_details["reason"] == "acceptance contract lock file is missing"

    invalid_lock_path = Path.join(System.tmp_dir!(), "handoff-check-invalid-lock-#{System.unique_integer([:positive])}.json")
    File.write!(invalid_lock_path, "{not-json")

    assert {:error, :handoff_manifest_invalid, invalid_lock_details} =
             HandoffCheck.validate_contract_lock(
               manifest_with_nested_revision,
               require_contract_lock: true,
               contract_lock_path: invalid_lock_path
             )

    assert invalid_lock_details["reason"] == "cannot read acceptance contract lock file"
  end

  test "review_ready_transition_allowed? blocks stale acceptance contract revision" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `proof.log` -> deterministic proof artifact

    ### Proof Mapping

    - [x] `AM-1` -> validation:targeted tests

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Contract revision freeze path verified.
    """

    issue_description_v1 = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | Positive path | Canonical proof passes | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    """

    issue_description_v2 = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | Positive path changed | Canonical proof passes with updated target | test | mix test test/symphony_elixir/dynamic_tool_test.exs | run_executed |
    """

    workpad_path = Path.join(System.tmp_dir!(), "handoff-check-contract-workpad-#{System.unique_integer([:positive])}.md")
    manifest_path = Path.join(System.tmp_dir!(), "handoff-check-contract-manifest-#{System.unique_integer([:positive])}.json")
    File.write!(workpad_path, workpad)

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-416",
               issue_description: issue_description_v1,
               workpad_path: workpad_path,
               labels: ["mode:plan", "verification:generic"],
               attachments: [%{"title" => "proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert {:ok, _path} = HandoffCheck.write_manifest(manifest, manifest_path)

    assert :ok =
             HandoffCheck.review_ready_transition_allowed?(
               manifest_path,
               "LET-416",
               "In Review",
               workpad_path,
               issue_description: issue_description_v1,
               git_runner: git_runner()
             )

    assert {:error, :handoff_manifest_stale, details} =
             HandoffCheck.review_ready_transition_allowed?(
               manifest_path,
               "LET-416",
               "In Review",
               workpad_path,
               issue_description: issue_description_v2,
               git_runner: git_runner()
             )

    assert details["reason"] =~ "acceptance contract revision is stale"
  end

  test "review_ready_transition_allowed? supports nested contract revision fallback and fails when revision is missing" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `proof.log` -> deterministic proof artifact

    ### Proof Mapping

    - [x] `AM-1` -> validation:targeted tests

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Contract revision freeze path verified.
    """

    issue_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | Positive path | Canonical proof passes | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    """

    workpad_path = Path.join(System.tmp_dir!(), "handoff-check-contract-fallback-workpad-#{System.unique_integer([:positive])}.md")
    manifest_path = Path.join(System.tmp_dir!(), "handoff-check-contract-fallback-manifest-#{System.unique_integer([:positive])}.json")
    File.write!(workpad_path, workpad)

    assert {:ok, baseline_manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-416",
               issue_description: issue_description,
               workpad_path: workpad_path,
               labels: ["mode:plan", "verification:generic"],
               attachments: [%{"title" => "proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    nested_only_revision_manifest =
      baseline_manifest
      |> Map.delete("contract_revision")
      |> put_in(["acceptance_contract", "revision"], get_in(baseline_manifest, ["acceptance_contract", "revision"]))

    assert {:ok, _path} = HandoffCheck.write_manifest(nested_only_revision_manifest, manifest_path)

    assert :ok =
             HandoffCheck.review_ready_transition_allowed?(
               manifest_path,
               "LET-416",
               "In Review",
               workpad_path,
               issue_description: issue_description,
               git_runner: git_runner()
             )

    missing_revision_manifest =
      nested_only_revision_manifest
      |> update_in(["acceptance_contract"], &Map.delete(&1, "revision"))

    assert {:ok, _path} = HandoffCheck.write_manifest(missing_revision_manifest, manifest_path)

    assert {:error, :handoff_manifest_stale, details} =
             HandoffCheck.review_ready_transition_allowed?(
               manifest_path,
               "LET-416",
               "In Review",
               workpad_path,
               issue_description: issue_description,
               git_runner: git_runner()
             )

    assert details["reason"] =~ "acceptance contract revision is missing from manifest"
  end

  test "review_ready_transition_allowed? blocks stale acceptance contract lock revision" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `proof.log` -> deterministic proof artifact

    ### Proof Mapping

    - [x] `AM-1` -> validation:targeted tests

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Contract lock drift path verified.
    """

    issue_description_v1 = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | Positive path | Canonical proof passes | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    """

    issue_description_v2 = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | Changed path | Canonical proof target changed | test | mix test test/symphony_elixir/dynamic_tool_test.exs | run_executed |
    """

    workpad_path = Path.join(System.tmp_dir!(), "handoff-check-lock-workpad-#{System.unique_integer([:positive])}.md")
    manifest_path = Path.join(System.tmp_dir!(), "handoff-check-lock-manifest-#{System.unique_integer([:positive])}.json")
    lock_path = Path.join(System.tmp_dir!(), "handoff-check-contract-lock-#{System.unique_integer([:positive])}.json")

    File.write!(workpad_path, workpad)

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-416",
               issue_description: issue_description_v1,
               workpad_path: workpad_path,
               labels: ["mode:plan", "verification:generic"],
               attachments: [%{"title" => "proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert {:ok, _path} = HandoffCheck.write_manifest(manifest, manifest_path)

    stale_contract = HandoffCheck.acceptance_contract_from_issue_description(issue_description_v2)

    File.write!(
      lock_path,
      Jason.encode!(%{
        "version" => 1,
        "locked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "issue" => %{"id" => "LET-416", "identifier" => "LET-416"},
        "contract_revision" => stale_contract["revision"],
        "acceptance_contract" => stale_contract
      })
    )

    assert {:error, :handoff_manifest_stale, details} =
             HandoffCheck.review_ready_transition_allowed?(
               manifest_path,
               "LET-416",
               "In Review",
               workpad_path,
               issue_description: issue_description_v1,
               contract_lock_path: lock_path,
               require_contract_lock: true,
               git_runner: git_runner()
             )

    assert details["reason"] =~ "acceptance contract lock revision does not match manifest"
  end

  test "evaluate carries required capabilities into manifest and fails missing capability proof" do
    workpad = """
    ## Codex Workpad

    ```text
    host:/tmp/workspace@abc1234
    ```

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [ ] uploaded attachment: `runtime-proof.log` -> runtime smoke log from the health check

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: Runtime proof is pending.
    """

    issue_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | bounded runtime smoke | artifact created | runtime_smoke | VPS | runtime_smoke |

    ## Symphony
    Repo: maximlafe/symphony
    Required capabilities: runtime_smoke, artifact_upload
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_description: issue_description,
               labels: ["verification:runtime"],
               attachments: [],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert manifest["issue"]["required_capabilities"] == ["runtime_smoke", "artifact_upload"]
    assert "required capability `runtime_smoke` is missing checked runtime smoke proof" in manifest["missing_items"]
    assert "required capability `artifact_upload` is missing a checked uploaded Linear attachment" in manifest["missing_items"]
  end

  test "evaluate reports unsupported profile metadata and malformed artifact entries" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: make symphony-preflight
    - [x] targeted tests: mix test test/smoke.exs
    - [x] repo validation: make symphony-validate

    ### Artifacts

    - [x] uploaded attachment: screenshot.png
    - [x] uploaded attachment: `evidence.json`

    ### Checkpoint

    - note: ignored
    - `checkpoint_type`: `decision`
    - `risk_level`: `low`
    - `summary`: Evidence captured.
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-416",
               profile: "unsupported",
               labels: :invalid,
               attachments: ["bad"],
               profile_labels: %{"bogus" => "verification:bogus"},
               pr_snapshot: green_pr_snapshot()
             )

    assert manifest["profile"] == "generic"
    assert "explicit profile `unsupported` is not supported" in manifest["missing_items"]
    assert "uploaded attachment `screenshot.png` is missing from the Linear issue attachments" in manifest["missing_items"]
    assert "uploaded attachment `evidence.json` is missing from the Linear issue attachments" in manifest["missing_items"]

    assert {:error, blank_profile_manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-416",
               profile: "   ",
               labels: :invalid,
               attachments: ["bad"],
               profile_labels: %{"bogus" => "verification:bogus"},
               pr_snapshot: green_pr_snapshot()
             )

    assert blank_profile_manifest["profile"] == "generic"
    assert blank_profile_manifest["profile_source"] == "fallback"
  end

  test "evaluate detects conflicting verification labels and missing ui proof" do
    conflicting_labels_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD UI proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] ui runtime proof: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] visual artifact: `notes.txt`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `notes.md` -> plain text evidence

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Handoff summary is filled.
    """

    assert {:error, conflict_manifest} =
             HandoffCheck.evaluate(
               conflicting_labels_workpad,
               issue_id: "LET-416",
               labels: ["verification:ui", "verification:runtime"],
               attachments: [%{"title" => "notes.md"}],
               pr_snapshot: green_pr_snapshot()
             )

    assert conflict_manifest["profile"] == "generic"

    assert "conflicting verification labels matched multiple profiles: ui, runtime" in conflict_manifest["missing_items"]

    ui_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD UI proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] ui runtime proof: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] visual artifact: `notes.txt`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: screenshot.png

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: Visual proof is ready.
    """

    assert {:error, ui_manifest} =
             HandoffCheck.evaluate(
               ui_workpad,
               issue_id: "LET-416",
               profile: "ui",
               attachments: [%{"title" => "notes.txt"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["ui"],
               git: git_metadata()
             )

    assert "uploaded attachment `screenshot.png` is missing from the Linear issue attachments" in ui_manifest["missing_items"]
    assert "profile `ui` is missing a matching uploaded proof artifact" in ui_manifest["missing_items"]
  end

  test "evaluate auto-reconciles free-form artifacts from existing Linear attachments when artifact proof is not required" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] PR: https://github.com/maximlafe/symphony/pull/156

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Contract checks are complete.
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-545",
               attachments: [%{"title" => "LET-545: Fix ValidationGate JS TS classification"}],
               pr_snapshot: green_pr_snapshot()
             )

    refute Enum.any?(manifest["missing_items"], fn item ->
             String.contains?(item, "artifact manifest is missing a checked uploaded attachment entry")
           end)

    assert get_in(manifest, ["workpad", "artifacts_auto_reconciled"]) == true

    assert Enum.any?(get_in(manifest, ["workpad", "artifacts"]), fn item ->
             item["kind"] == "uploaded_attachment" and
               item["title"] == "LET-545: Fix ValidationGate JS TS classification"
           end)
  end

  test "evaluate auto-reconcile tolerates mixed attachment payload shapes" do
    issue_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | Validation-only proof | Targeted tests are recorded | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    """

    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] runtime evidence artifact placeholder

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Attachment normalization edge cases are handled.
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-EDGE",
               issue_description: issue_description,
               labels: ["verification:generic"],
               attachments: [%{"url" => "https://example.test/no-title"}, %{"title" => 123}, :bad_payload],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert get_in(manifest, ["workpad", "artifacts_auto_reconciled"]) == true

    uploaded_titles =
      get_in(manifest, ["workpad", "artifacts"])
      |> Enum.filter(&(&1["kind"] == "uploaded_attachment"))
      |> Enum.map(& &1["title"])

    assert "123" in uploaded_titles
  end

  test "evaluate reports malformed uploaded attachment rows and missing artifact capability proof" do
    issue_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | -- | -- | -- | -- | -- | -- |
    | AM-1 | Runtime proof | attachment rows must be valid | runtime_smoke | VPS | runtime_smoke |

    ## Symphony
    Required capabilities: artifact_upload
    """

    malformed_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment:

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: malformed uploaded attachment should not satisfy artifact capability.
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               malformed_workpad,
               issue_id: "LET-EDGE",
               issue_description: issue_description,
               labels: ["verification:runtime"],
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "artifact manifest entry must include an attachment title in backticks" in manifest["missing_items"]
  end

  test "evaluate requires explicit red proof when delivery:tdd is enabled" do
    workpad_without_tdd_evidence = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `notes.md` -> test notes

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Handoff summary is filled.
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad_without_tdd_evidence,
               issue_id: "LET-431",
               labels: ["delivery:tdd"],
               attachments: [%{"title" => "notes.md"}],
               pr_snapshot: green_pr_snapshot()
             )

    assert "validation checklist is missing a checked `red proof` item" in manifest["missing_items"]

    workpad_with_tdd_evidence = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] red proof: `mix test test/symphony_elixir/handoff_check_test.exs:235`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log from the health check

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: TDD proof and validation are complete.
    """

    assert {:ok, passing_manifest} =
             HandoffCheck.evaluate(
               workpad_with_tdd_evidence,
               issue_id: "LET-431",
               labels: ["delivery:tdd", "verification:runtime"],
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert passing_manifest["missing_items"] == []
    assert passing_manifest["profile"] == "runtime"
  end

  test "evaluate enforces acceptance matrix proof mapping for mode:plan issues" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] am-plain-reg: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-inv: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-strict: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-fail: `make symphony-preflight`
    - [x] am-neg: `make symphony-preflight`
    - [x] am-reg: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-side: `make symphony-validate`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log from the health check

    ### Proof Mapping

    - [x] `AM-1` -> `validation:targeted tests`
    - [x] `AM-2` -> `validation:runtime smoke`
    - [x] `AM-3` -> `artifact:runtime-proof.log`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Acceptance matrix coverage is complete.
    """

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: acceptance_matrix_description(),
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert manifest["missing_items"] == []
    assert get_in(manifest, ["proof_signals", "acceptance_matrix_covered"]) == true
    assert get_in(manifest, ["proof_signals", "proof_surface_exists"]) == true
    assert get_in(manifest, ["proof_signals", "proof_run_executed"]) == true
  end

  test "evaluate rejects missing and non-executed acceptance matrix proof mappings for mode:plan issues" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `scripts/proof_runner --help`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log from the health check

    ### Proof Mapping

    - [x] `AM-1` -> `validation:targeted tests`
    - [x] `AM-2` -> `validation:runtime smoke`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: Matrix coverage is partial.
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: acceptance_matrix_description_run_executed_runtime(),
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "acceptance matrix item `AM-3` is missing a checked proof mapping entry" in manifest["missing_items"]

    assert "acceptance matrix item `AM-2` requires executed proof; mapped validation command looks surface-only (`--help`)" in manifest["missing_items"]
  end

  test "evaluate defers done-phase acceptance matrix proofs during review handoff" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Proof Mapping

    - [x] `AM-1` -> `validation:targeted tests`

    ### Artifacts

    - [x] uploaded attachment: `review-proof.log` -> review handoff proof

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Review proof is complete; runtime proof is post-merge.
    """

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-518",
               phase: "review",
               labels: ["mode:plan", "verification:generic"],
               issue_description: phase_acceptance_matrix_description(),
               attachments: [%{"title" => "review-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert manifest["phase"] == "review"
    assert manifest["missing_items"] == []
    assert get_in(manifest, ["proof_signals", "acceptance_matrix_covered"]) == true
    assert get_in(manifest, ["proof_signals", "acceptance_matrix_required_items"]) == 1
    assert get_in(manifest, ["proof_signals", "acceptance_matrix_deferred_items"]) == 1
    assert [%{"id" => "AM-2", "required_before" => "done"}] = manifest["deferred_proofs"]
  end

  test "evaluate requires deferred acceptance matrix proofs during done handoff" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Proof Mapping

    - [x] `AM-1` -> `validation:targeted tests`

    ### Artifacts

    - [x] uploaded attachment: `review-proof.log` -> review handoff proof

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Done proof is still missing.
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-518",
               phase: "done",
               labels: ["mode:plan", "verification:generic"],
               issue_description: phase_acceptance_matrix_description(),
               attachments: [%{"title" => "review-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert manifest["phase"] == "done"
    assert manifest["deferred_proofs"] == []
    assert "acceptance matrix item `AM-2` is missing a checked proof mapping entry" in manifest["missing_items"]
  end

  test "evaluate fails closed for unsupported handoff phase values" do
    assert {:error, string_phase_manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-518",
               phase: "release",
               profile: "runtime",
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert string_phase_manifest["phase"] == "review"
    assert "handoff phase `release` is unsupported; expected one of: review, done" in string_phase_manifest["missing_items"]

    assert {:error, non_string_phase_manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-518",
               phase: :done,
               profile: "runtime",
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert non_string_phase_manifest["phase"] == "review"
    assert "handoff phase must be a string, got: :done" in non_string_phase_manifest["missing_items"]
  end

  test "evaluate reports missing and malformed acceptance matrix definitions" do
    assert {:error, non_binary_manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: :invalid,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "acceptance matrix section is missing or empty in issue description for `mode:plan` handoff" in non_binary_manifest["missing_items"]

    assert {:error, missing_section_manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: "## Overview\nNo acceptance matrix section here.",
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "acceptance matrix section is missing or empty in issue description for `mode:plan` handoff" in missing_section_manifest["missing_items"]

    malformed_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | <id> | bad | bad | test | <target> | run_executed |
    | AM-TYPE | bad | bad | unknown | target | run_executed |
    | AM-BAD | bad | bad | test | target | unknown |
    | AM-DUP | dup one | dup | test | target-a | run_executed |
    | AM-DUP | dup two | dup | test | target-b | run_executed |
    | only | two |
    """

    assert {:error, malformed_manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: malformed_description,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert Enum.any?(malformed_manifest["missing_items"], &String.contains?(&1, "missing required id or proof_target"))
    assert Enum.any?(malformed_manifest["missing_items"], &String.contains?(&1, "unsupported proof_type/proof_semantic"))
    assert Enum.any?(malformed_manifest["missing_items"], &String.contains?(&1, "invalid column count"))
    assert "acceptance matrix contains duplicate id `AM-DUP`" in malformed_manifest["missing_items"]

    unsupported_phase_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
    | --- | --- | --- | --- | --- | --- | --- |
    | AM-PHASE | bad | bad | test | target | run_executed | release |
    """

    assert {:error, unsupported_phase_manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: unsupported_phase_description,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert Enum.any?(unsupported_phase_manifest["missing_items"], &String.contains?(&1, "unsupported required_before"))
  end

  test "evaluate validates proof mapping format, unknown ids, duplicate refs, and duplicate matrix mappings" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] am-plain-reg: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-inv: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-strict: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-fail: `make symphony-preflight`
    - [x] am-neg: `make symphony-preflight`
    - [x] am-reg: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-side: `make symphony-validate`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log from the health check

    ### Proof Mapping

    - [ ] `AM-1` -> `validation:targeted tests`
    - [x] AM-1 -> validation:targeted tests
    - [x] `AM-3` validation:targeted tests
    - [x] `AM-2` -> `evidence`
    - [x] `AM-UNKNOWN` -> `validation:targeted tests`
    - [x] `AM-1` -> `validation:targeted tests`
    - [x] `AM-1` -> `validation:runtime smoke`
    - [x] `AM-2` -> `validation:targeted tests`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: Mapping guardrails are under test.
    """

    description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-1 | Positive path | Canonical proof passes | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    | AM-2 | Runtime smoke path | Runtime smoke proof exists | runtime_smoke | mix test test/symphony_elixir/handoff_check_test.exs | runtime_smoke |
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: description,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "proof mapping entry is missing matrix item id in backticks" in manifest["missing_items"]

    assert Enum.any?(
             manifest["missing_items"],
             &String.contains?(&1, "proof mapping entry for `AM-2` must use `validation:<label>`, `artifact:<title>`, or `runtime:<label>`")
           )

    assert "proof mapping references unknown acceptance matrix item `AM-UNKNOWN`" in manifest["missing_items"]

    assert Enum.any?(
             manifest["missing_items"],
             &String.contains?(&1, "proof mapping reference `validation:targeted tests` is reused by multiple acceptance matrix items")
           )

    assert "acceptance matrix item `AM-1` has multiple proof mapping entries; exactly one is required" in manifest["missing_items"]
  end

  test "evaluate accepts legacy proof aliases and selector-based test mappings" do
    alias_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-1 | Legacy alias path | Selector proof is covered by checked targeted tests | artifact/test | test_apply_chat_add_source_close_policy_matrix[seed-presence-0] | positive proof |
    """

    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `poetry run pytest tests/unit/test_team_master_ui.py -q`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `selector-proof.log` -> targeted selector coverage evidence

    ### Proof Mapping

    - [x] `AM-1` -> `validation:test_apply_chat_add_source_close_policy_matrix[seed-presence-0]`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Legacy aliases are normalized.
    """

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-619",
               labels: ["mode:plan", "verification:generic"],
               issue_description: alias_description,
               attachments: [%{"title" => "selector-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert manifest["missing_items"] == []
  end

  test "evaluate accepts selector mapping resolved directly from a checked command substring" do
    issue_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-1 | Command selector path | Selector proof resolves from checked command substring | test | tests/unit/test_team_master_ui.py | run_executed |
    """

    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `poetry run pytest tests/unit/test_team_master_ui.py -q`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `selector-proof.log` -> targeted selector coverage evidence

    ### Proof Mapping

    - [x] `AM-1` -> `validation:tests/unit/test_team_master_ui.py`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Command substring matching resolves selector mapping.
    """

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-622",
               labels: ["mode:plan", "verification:generic"],
               issue_description: issue_description,
               attachments: [%{"title" => "selector-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert manifest["missing_items"] == []
  end

  test "evaluate accepts canonical AM label mapping for run_executed proof items" do
    issue_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-1 | Active retry path | Active retry proof is executed | test | retry active path | run_executed |
    | AM-2 | Missing retry path | Missing retry proof is executed | test | retry missing path | run_executed |
    """

    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-1: `mix test test/symphony_elixir/handoff_check_test.exs --only am_1`
    - [x] am-2: `mix test test/symphony_elixir/handoff_check_test.exs --only am_2`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `selector-proof.log` -> targeted selector coverage evidence

    ### Proof Mapping

    - [x] `AM-1` -> `validation:am-1`
    - [x] `AM-2` -> `validation:am-2`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Canonical AM label mapping is explicit and deterministic.
    """

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-651",
               labels: ["mode:plan", "verification:generic"],
               issue_description: issue_description,
               attachments: [%{"title" => "selector-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert manifest["missing_items"] == []
    assert get_in(manifest, ["proof_signals", "proof_run_executed"]) == true
  end

  test "evaluate reports deterministic AM label hint when prose mapping is not checked" do
    issue_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-539-1 | Active retry path | Active retry proof is executed | test | retry active path | run_executed |
    """

    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `cd elixir && mix test test/symphony_elixir/orchestrator_status_test.exs --include let_539 --only let_539`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `selector-proof.log` -> targeted selector coverage evidence

    ### Proof Mapping

    - [x] `AM-539-1` -> `validation:orchestrator_status_test.exs @let_539 active retry targeted fetch`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Prose mapping should be rejected with a canonical hint.
    """

    assert {:error, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-651",
               labels: ["mode:plan", "verification:generic"],
               issue_description: issue_description,
               attachments: [%{"title" => "selector-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert "acceptance matrix item `AM-539-1` maps to validation `orchestrator_status_test.exs @let_539 active retry targeted fetch` that is not checked" in manifest["missing_items"]

    assert "acceptance matrix item `AM-539-1` mapping drift: use canonical validation label `am-539-1` in `Validation` and map via `validation:am-539-1`" in manifest["missing_items"]
  end

  test "evaluate accepts pytest-style selector with scope delimiter" do
    issue_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-1 | Pytest selector path | Scoped selector resolves through targeted tests fallback | test | tests/unit/test_team_master_ui.py::test_apply_chat_add_source_close_policy_matrix | run_executed |
    """

    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `poetry run pytest tests/unit/test_team_master_ui.py -q`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `selector-proof.log` -> targeted selector coverage evidence

    ### Proof Mapping

    - [x] `AM-1` -> `validation:tests/unit/test_team_master_ui.py::test_apply_chat_add_source_close_policy_matrix`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Scoped selector fallback is accepted.
    """

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-623",
               labels: ["mode:plan", "verification:generic"],
               issue_description: issue_description,
               attachments: [%{"title" => "selector-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert manifest["missing_items"] == []
  end

  test "evaluate enforces artifact and validation mapping types plus semantic execution checks" do
    artifact_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-A | Artifact proof path | Artifact uploaded | artifact | runtime-proof.log | run_executed |
    """

    artifact_workpad_wrong_type = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log

    ### Proof Mapping

    - [x] `AM-A` -> `validation:targeted tests`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Wrong artifact mapping type.
    """

    assert {:error, wrong_type_manifest} =
             HandoffCheck.evaluate(
               artifact_workpad_wrong_type,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: artifact_description,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "acceptance matrix item `AM-A` expects artifact mapping `artifact:<title>`" in wrong_type_manifest["missing_items"]

    artifact_workpad_empty_target = String.replace(artifact_workpad_wrong_type, "`validation:targeted tests`", "`artifact:<title>`")

    assert {:error, empty_target_manifest} =
             HandoffCheck.evaluate(
               artifact_workpad_empty_target,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: artifact_description,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert Enum.any?(
             empty_target_manifest["missing_items"],
             &String.contains?(&1, "proof mapping entry for `AM-A` must use `validation:<label>`, `artifact:<title>`, or `runtime:<label>`")
           )

    missing_artifact_workpad = String.replace(artifact_workpad_wrong_type, "`validation:targeted tests`", "`artifact:missing.log`")

    assert {:error, missing_artifact_manifest} =
             HandoffCheck.evaluate(
               missing_artifact_workpad,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: artifact_description,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "acceptance matrix item `AM-A` maps to artifact `missing.log` that is not checked in `Artifacts`" in missing_artifact_manifest["missing_items"]

    uploaded_but_not_attached_workpad = String.replace(artifact_workpad_wrong_type, "`validation:targeted tests`", "`artifact:runtime-proof.log`")

    assert {:error, not_attached_manifest} =
             HandoffCheck.evaluate(
               uploaded_but_not_attached_workpad,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: artifact_description,
               attachments: [],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "acceptance matrix item `AM-A` maps to artifact `runtime-proof.log` that is not uploaded in Linear attachments" in not_attached_manifest["missing_items"]

    validation_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-TYPE | Validation type check | Validation proof exists | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    | AM-NIL | Missing validation check | Validation entry missing | test | missing validation | run_executed |
    | AM-RUNTIME-MISSING | Runtime smoke missing check | Runtime smoke validation entry must exist | runtime_smoke | runtime smoke missing | runtime_smoke |
    | AM-RUNTIME-BAD | Runtime smoke check | Runtime smoke uses correct label | runtime_smoke | mix test test/symphony_elixir/handoff_check_test.exs | runtime_smoke |
    | AM-HELP | Executed proof check | Help-only command must fail | test | scripts/proof_runner --help | run_executed |
    | AM-SURFACE | Surface-only signal | Surface exists is allowed | test | mix test test/symphony_elixir/handoff_check_test.exs | surface_exists |
    """

    validation_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `scripts/proof_runner --help`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log

    ### Proof Mapping

    - [x] `AM-TYPE` -> `artifact:runtime-proof.log`
    - [x] `AM-NIL` -> `validation:missing validation`
    - [x] `AM-RUNTIME-MISSING` -> `validation:runtime smoke missing`
    - [x] `AM-RUNTIME-BAD` -> `validation:targeted tests`
    - [x] `AM-HELP` -> `validation:runtime smoke`
    - [x] `AM-SURFACE` -> `validation:targeted tests`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: Validation mapping semantics are under test.
    """

    assert {:error, validation_manifest} =
             HandoffCheck.evaluate(
               validation_workpad,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: validation_description,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "acceptance matrix item `AM-TYPE` expects validation mapping `validation:<label>`" in validation_manifest["missing_items"]
    assert "acceptance matrix item `AM-NIL` maps to validation `missing validation` that is not checked" in validation_manifest["missing_items"]
    assert "acceptance matrix item `AM-RUNTIME-MISSING` maps to validation `runtime smoke missing` that is not checked" in validation_manifest["missing_items"]

    assert "acceptance matrix item `AM-RUNTIME-BAD` with proof_type `runtime_smoke` must map to `runtime smoke` validation entry" in validation_manifest["missing_items"]

    assert "acceptance matrix item `AM-HELP` requires executed proof; mapped validation command looks surface-only (`--help`)" in validation_manifest["missing_items"]

    runtime_semantic_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-RUNTIME-OK | Runtime smoke check | Runtime smoke signal is explicit | runtime_smoke | mix test test/symphony_elixir/handoff_check_test.exs | runtime_smoke |
    """

    runtime_semantic_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log

    ### Proof Mapping

    - [x] `AM-RUNTIME-OK` -> `validation:runtime smoke`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: Runtime smoke semantic path is valid.
    """

    assert {:ok, runtime_semantic_manifest} =
             HandoffCheck.evaluate(
               runtime_semantic_workpad,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:runtime"],
               issue_description: runtime_semantic_description,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert get_in(runtime_semantic_manifest, ["proof_signals", "runtime_smoke"]) == true
    assert get_in(runtime_semantic_manifest, ["proof_signals", "acceptance_matrix_covered"]) == true
  end

  test "evaluate accepts known legacy proof semantic aliases for mode:plan matrices" do
    alias_semantics_description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-PLAIN-REG | Plain regression alias | Plain regression legacy semantic is canonicalized | test | mix test test/symphony_elixir/handoff_check_test.exs | regression |
    | AM-INV | Plain invariant alias | Plain invariant legacy semantic is canonicalized | test | mix test test/symphony_elixir/handoff_check_test.exs | invariant |
    | AM-STRICT | Strictness invariant alias | Strictness invariant legacy semantic is canonicalized | test | mix test test/symphony_elixir/handoff_check_test.exs | strictness invariant |
    | AM-FAIL | Fail-closed invariant alias | Fail-closed invariant legacy semantic is canonicalized | test | make symphony-preflight | fail-closed invariant |
    | AM-NEG | Negative path guard | Negative-path checks are executed | test | make symphony-preflight | negative proof |
    | AM-REG | Regression guard | Regression checks are executed | test | mix test test/symphony_elixir/handoff_check_test.exs | regression guard |
    | AM-SIDE | Side-effect guard | Side effects are validated via executed check | test | make symphony-validate | side-effect guard |
    """

    alias_semantics_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] am-plain-reg: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-inv: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-strict: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-fail: `make symphony-preflight`
    - [x] am-neg: `make symphony-preflight`
    - [x] am-reg: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] am-side: `make symphony-validate`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime evidence for validation guard requirements

    ### Proof Mapping

    - [x] `AM-PLAIN-REG` -> `validation:am-plain-reg`
    - [x] `AM-INV` -> `validation:am-inv`
    - [x] `AM-STRICT` -> `validation:am-strict`
    - [x] `AM-FAIL` -> `validation:am-fail`
    - [x] `AM-NEG` -> `validation:am-neg`
    - [x] `AM-REG` -> `validation:am-reg`
    - [x] `AM-SIDE` -> `validation:am-side`

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: Legacy semantics are normalized to canonical run semantics.
    """

    assert {:ok, alias_manifest} =
             HandoffCheck.evaluate(
               alias_semantics_workpad,
               issue_id: "LET-504",
               labels: ["mode:plan", "verification:generic"],
               issue_description: alias_semantics_description,
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert get_in(alias_manifest, ["proof_signals", "acceptance_matrix_covered"]) == true
    assert get_in(alias_manifest, ["proof_signals", "proof_run_executed"]) == true
  end

  test "evaluate normalizes validation gate errors and git changed paths for invalid change classes" do
    assert {:error, manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-504",
               labels: ["verification:runtime"],
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: [123],
               validation_gate_errors: [:custom_error],
               git: %{
                 "head_sha" => "abc123",
                 "tree_sha" => "tree123",
                 "worktree_clean" => true,
                 "changed_paths" => [123, :workflow_file]
               }
             )

    assert Enum.any?(manifest["missing_items"], &String.contains?(&1, "custom_error"))
    assert Enum.any?(manifest["missing_items"], &String.contains?(&1, "unsupported change class `123`"))
  end

  test "review_ready_transition_allowed? fails when the workpad digest no longer matches the manifest" do
    workpad_path = Path.join(System.tmp_dir!(), "handoff-check-workpad-#{System.unique_integer([:positive])}.md")
    manifest_path = Path.join(System.tmp_dir!(), "handoff-check-manifest-#{System.unique_integer([:positive])}.json")

    File.write!(workpad_path, "original")

    manifest =
      %{
        "passed" => true,
        "issue" => %{"id" => "LET-416"},
        "workpad" => %{
          "file_path" => workpad_path,
          "sha256" => :crypto.hash(:sha256, "original") |> Base.encode16(case: :lower)
        }
      }
      |> Map.merge(valid_gate_manifest_fields())

    assert {:ok, _path} = HandoffCheck.write_manifest(manifest, manifest_path)
    File.write!(workpad_path, "changed")

    assert {:error, :handoff_manifest_stale, details} =
             HandoffCheck.review_ready_transition_allowed?(manifest_path, "LET-416", "In Review", nil, git_runner: git_runner())

    assert details["reason"] =~ "workpad changed"
  end

  test "write_manifest sanitizes invalid UTF-8 strings instead of crashing" do
    manifest_path = Path.join(System.tmp_dir!(), "handoff-check-invalid-utf8-#{System.unique_integer([:positive])}.json")
    invalid_tail = <<208, 189, 208, 181, 32, 209>>

    manifest = %{
      "passed" => false,
      "missing_items" => [invalid_tail],
      summary: invalid_tail
    }

    assert {:ok, written_path} = HandoffCheck.write_manifest(manifest, manifest_path)
    assert {:ok, encoded} = File.read(written_path)
    assert {:ok, decoded} = Jason.decode(encoded)
    assert String.valid?(decoded["summary"])
    assert String.valid?(List.first(decoded["missing_items"]))
  end

  test "write_manifest preserves non-binary map keys while sanitizing values" do
    manifest_path = Path.join(System.tmp_dir!(), "handoff-check-non-binary-key-#{System.unique_integer([:positive])}.json")

    manifest = %{
      7 => "numeric-key",
      "summary" => "ok",
      passed: true
    }

    assert {:ok, written_path} = HandoffCheck.write_manifest(manifest, manifest_path)
    assert {:ok, encoded} = File.read(written_path)
    assert {:ok, decoded} = Jason.decode(encoded)
    assert decoded["passed"] == true
    assert decoded["7"] == "numeric-key"
    assert decoded["summary"] == "ok"
  end

  test "review_ready_transition_allowed? rejects invalid manifest states and missing workpad references" do
    manifest_dir = Path.join(System.tmp_dir!(), "handoff-check-manifest-dir-#{System.unique_integer([:positive])}")
    missing_workpad = Path.join(System.tmp_dir!(), "handoff-check-review-#{System.unique_integer([:positive])}.md")
    failed_manifest_path = Path.join(System.tmp_dir!(), "handoff-check-failed-#{System.unique_integer([:positive])}.json")
    invalid_json_manifest_path = Path.join(System.tmp_dir!(), "handoff-check-invalid-json-#{System.unique_integer([:positive])}.json")
    mismatch_manifest_path = Path.join(System.tmp_dir!(), "handoff-check-mismatch-#{System.unique_integer([:positive])}.json")
    wrong_issue_manifest_path = Path.join(System.tmp_dir!(), "handoff-check-wrong-issue-#{System.unique_integer([:positive])}.json")
    unreadable_workpad_manifest_path = Path.join(System.tmp_dir!(), "handoff-check-unreadable-workpad-#{System.unique_integer([:positive])}.json")
    no_workpad_manifest_path = Path.join(System.tmp_dir!(), "handoff-check-no-workpad-#{System.unique_integer([:positive])}.json")
    missing_manifest_path = Path.join(System.tmp_dir!(), "handoff-check-missing-#{System.unique_integer([:positive])}.json")

    File.mkdir_p!(manifest_dir)
    File.write!(missing_workpad, "unchanged")

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(manifest_dir, nil, "In Review", nil)

    assert details["reason"] == "issue_id is required"

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(manifest_dir, "LET-416", "In Review")

    assert details["reason"] == "cannot read manifest file"

    assert {:error, :handoff_manifest_missing, details} =
             HandoffCheck.review_ready_transition_allowed?(missing_manifest_path, "LET-416", "In Review")

    assert details["reason"] == "manifest file is missing"

    File.write!(invalid_json_manifest_path, "{")

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(invalid_json_manifest_path, "LET-416", "In Review")

    assert details["reason"] == "manifest file is not valid JSON"

    assert {:ok, _path} =
             HandoffCheck.write_manifest(
               %{
                 "passed" => false,
                 "issue" => %{"id" => "LET-416"},
                 "workpad" => %{
                   "file_path" => missing_workpad,
                   "sha256" => sha256("unchanged")
                 }
               },
               failed_manifest_path
             )

    assert {:error, :handoff_manifest_failed, details} =
             HandoffCheck.review_ready_transition_allowed?(failed_manifest_path, "LET-416", "In Review")

    assert details["reason"] =~ "successful handoff check"

    assert {:ok, _path} =
             HandoffCheck.write_manifest(
               %{
                 "passed" => true,
                 "issue" => %{"id" => "LET-999"},
                 "workpad" => %{
                   "file_path" => missing_workpad,
                   "sha256" => sha256("unchanged")
                 }
               },
               wrong_issue_manifest_path
             )

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(wrong_issue_manifest_path, "LET-416", "In Review")

    assert details["reason"] =~ "different issue"

    assert {:ok, _path} =
             HandoffCheck.write_manifest(
               %{
                 "passed" => true,
                 "target_state" => "Human Review",
                 "issue" => %{"id" => "LET-416"},
                 "workpad" => %{
                   "file_path" => missing_workpad,
                   "sha256" => sha256("unchanged")
                 }
               },
               mismatch_manifest_path
             )

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(mismatch_manifest_path, "LET-416", "In Review")

    assert details["reason"] =~ "target state does not match"

    assert {:ok, _path} =
             HandoffCheck.write_manifest(
               Map.merge(
                 %{
                   "passed" => true,
                   "issue" => %{"id" => "LET-416"},
                   "workpad" => %{
                     "file_path" => Path.join(manifest_dir, "missing-workpad.md"),
                     "sha256" => sha256("missing")
                   }
                 },
                 valid_gate_manifest_fields()
               ),
               unreadable_workpad_manifest_path
             )

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(
               unreadable_workpad_manifest_path,
               "LET-416",
               "In Review",
               nil,
               git_runner: git_runner()
             )

    assert details["reason"] =~ "cannot read workpad referenced by manifest"

    assert {:ok, _path} =
             HandoffCheck.write_manifest(
               Map.merge(
                 %{
                   "passed" => true,
                   "issue" => %{"id" => "LET-416"},
                   "workpad" => %{}
                 },
                 valid_gate_manifest_fields()
               ),
               no_workpad_manifest_path
             )

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(
               no_workpad_manifest_path,
               "LET-416",
               "In Review",
               nil,
               git_runner: git_runner()
             )

    assert details["reason"] =~ "does not point to a workpad file"
  end

  test "review_ready_transition_allowed? blocks missing or stale validation gate metadata" do
    workpad_path = Path.join(System.tmp_dir!(), "handoff-check-gate-workpad-#{System.unique_integer([:positive])}.md")
    missing_gate_manifest_path = Path.join(System.tmp_dir!(), "handoff-check-missing-gate-#{System.unique_integer([:positive])}.json")
    stale_head_manifest_path = Path.join(System.tmp_dir!(), "handoff-check-stale-head-#{System.unique_integer([:positive])}.json")

    File.write!(workpad_path, "unchanged")

    base_manifest = %{
      "passed" => true,
      "issue" => %{"id" => "LET-416"},
      "workpad" => %{
        "file_path" => workpad_path,
        "sha256" => sha256("unchanged")
      }
    }

    assert {:ok, _path} = HandoffCheck.write_manifest(base_manifest, missing_gate_manifest_path)

    assert {:error, :handoff_manifest_stale, missing_details} =
             HandoffCheck.review_ready_transition_allowed?(
               missing_gate_manifest_path,
               "LET-416",
               "In Review",
               nil,
               git_runner: git_runner()
             )

    assert "validation gate final proof metadata is missing" in missing_details["details"]

    stale_gate =
      valid_gate_manifest_fields()
      |> put_in(["git", "head_sha"], "stale-head")

    assert {:ok, _path} =
             HandoffCheck.write_manifest(Map.merge(base_manifest, stale_gate), stale_head_manifest_path)

    assert {:error, :handoff_manifest_stale, stale_details} =
             HandoffCheck.review_ready_transition_allowed?(
               stale_head_manifest_path,
               "LET-416",
               "In Review",
               nil,
               git_runner: git_runner()
             )

    assert "final proof HEAD does not match current HEAD" in stale_details["details"]
  end

  test "evaluate parses Russian workpad section aliases for validation and artifacts" do
    workpad = """
    ## Рабочий журнал Codex

    ### Проверка

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Артефакты

    - [x] вложение: `runtime-proof.log` -> runtime smoke log from the health check

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: Runtime proof, tests, and repo validation are complete.
    """

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
               issue_id: "LET-416",
               profile: "runtime",
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert manifest["passed"]
    assert "Проверка" in manifest["workpad"]["sections"]
    assert "Артефакты" in manifest["workpad"]["sections"]
  end

  test "evaluate accepts ui and data-extraction proof claims and rejects bad PR snapshots" do
    ui_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD UI proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] ui runtime proof: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] visual artifact: `notes.txt`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `notes.txt` -> screenshot evidence from the UI review

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `low`
    - `summary`: UI proof is ready.
    """

    assert {:ok, ui_manifest} =
             HandoffCheck.evaluate(
               ui_workpad,
               issue_id: "LET-416",
               profile: "ui",
               attachments: [%{"title" => "notes.txt"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["ui"],
               git: git_metadata()
             )

    assert ui_manifest["profile"] == "ui"

    data_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `notes.txt` -> representative json fixture sample

    ### Checkpoint

    - `checkpoint_type`: `decision`
    - `risk_level`: `medium`
    - `summary`: Data extraction proof is ready.
    """

    assert {:ok, data_manifest} =
             HandoffCheck.evaluate(
               data_workpad,
               issue_id: "LET-416",
               profile: "data-extraction",
               attachments: [%{"title" => "notes.txt"}],
               pr_snapshot: green_pr_snapshot(),
               change_classes: ["backend_only"],
               git: git_metadata()
             )

    assert data_manifest["profile"] == "data-extraction"

    assert {:error, pr_manifest} =
             HandoffCheck.evaluate(
               ui_workpad,
               issue_id: "LET-416",
               profile: "ui",
               attachments: [%{"title" => "notes.txt"}],
               pr_snapshot: %{
                 "all_checks_green" => false,
                 "has_pending_checks" => true,
                 "has_actionable_feedback" => true,
                 "merge_state_status" => "DIRTY"
               },
               change_classes: ["ui"],
               git: git_metadata()
             )

    assert "pull request checks are not fully green" in pr_manifest["missing_items"]
    assert "pull request still has pending checks" in pr_manifest["missing_items"]
    assert "pull request still has actionable feedback" in pr_manifest["missing_items"]
    assert "pull request is not merge-ready" in pr_manifest["missing_items"]
  end

  test "evaluate accepts explicit validation gate metadata and normalizes gate option shapes" do
    explicit_gate =
      valid_gate_manifest_fields()
      |> Map.fetch!("validation_gate")
      |> Map.put("git", Map.put(git_metadata(), "changed_paths", :invalid))

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-416",
               profile: "runtime",
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: green_pr_snapshot(),
               validation_gate: explicit_gate,
               validation_gate_errors: :invalid,
               git: :invalid
             )

    assert manifest["passed"]
    assert manifest["git"]["changed_paths"] == []
  end

  test "review_ready_transition_allowed? exercises default git runner success and failure paths" do
    repo_path = init_git_repo!()
    workpad_path = Path.join(repo_path, "workpad.md")
    manifest_path = Path.join(repo_path, "handoff-manifest.json")
    File.write!(workpad_path, "unchanged")

    manifest =
      %{
        "passed" => true,
        "issue" => %{"id" => "LET-416"},
        "workpad" => %{
          "file_path" => workpad_path,
          "sha256" => sha256("unchanged")
        }
      }
      |> Map.merge(valid_gate_manifest_fields(git_metadata_for_repo!(repo_path)))

    assert {:ok, _path} = HandoffCheck.write_manifest(manifest, manifest_path)

    assert :ok =
             HandoffCheck.review_ready_transition_allowed?(
               manifest_path,
               "LET-416",
               "In Review",
               nil,
               repo_path: repo_path
             )

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(
               manifest_path,
               "LET-416",
               "In Review",
               nil,
               repo_path: Path.join(repo_path, "missing-repo")
             )

    assert details["reason"] == "cannot read current git metadata"
    assert details["details"] =~ "git_status"
  end

  test "review_ready_transition_allowed? surfaces missing git executable from the default runner" do
    repo_path = init_git_repo!()
    workpad_path = Path.join(repo_path, "workpad.md")
    manifest_path = Path.join(repo_path, "handoff-manifest.json")
    File.write!(workpad_path, "unchanged")

    manifest =
      %{
        "passed" => true,
        "issue" => %{"id" => "LET-416"},
        "workpad" => %{
          "file_path" => workpad_path,
          "sha256" => sha256("unchanged")
        }
      }
      |> Map.merge(valid_gate_manifest_fields(git_metadata_for_repo!(repo_path)))

    assert {:ok, _path} = HandoffCheck.write_manifest(manifest, manifest_path)

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)
    System.put_env("PATH", "")

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(
               manifest_path,
               "LET-416",
               "In Review",
               nil,
               repo_path: repo_path
             )

    assert details["reason"] == "cannot read current git metadata"
    assert details["details"] =~ "git_unavailable"
  end

  test "evaluate normalizes loose artifact metadata and flags missing attachment claims" do
    loose_artifacts_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] missing expected artifact: `missing.png`
    - [x] `ui-proof.png` -> screenshot proof
    - [x] `dataset.json` -> sample json fixture
    - [x] raw artifact without title

    ### Checkpoint

    - `checkpoint_type`: `human-action`
    - `risk_level`: `high`
    - `summary`: Artifact normalization paths were exercised.
    """

    assert {:error, loose_manifest} =
             HandoffCheck.evaluate(
               loose_artifacts_workpad,
               issue_id: "LET-416",
               profile: :runtime,
               attachments: :invalid,
               profile_labels: :invalid,
               pr_snapshot: green_pr_snapshot()
             )

    assert loose_manifest["profile"] == "generic"

    claimless_attachment_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `evidence.txt`

    ### Checkpoint

    - `checkpoint_type`: `decision`
    - `risk_level`: `low`
    - `summary`: Claimless attachments should fail closed.
    """

    assert {:error, claimless_manifest} =
             HandoffCheck.evaluate(
               claimless_attachment_workpad,
               issue_id: "LET-416",
               profile: "ui",
               attachments: [%{"title" => "evidence.txt"}],
               pr_snapshot: green_pr_snapshot()
             )

    assert "uploaded attachment `evidence.txt` is missing a concrete proof claim" in claimless_manifest["missing_items"]
  end

  defp runtime_workpad do
    """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] runtime smoke: `mix test test/symphony_elixir/handoff_check_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts

    - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log from the health check

    ### Checkpoint

    - `checkpoint_type`: `human-verify`
    - `risk_level`: `medium`
    - `summary`: Runtime proof, tests, and repo validation are complete.
    """
  end

  defp acceptance_matrix_description do
    """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-1 | Positive path | Canonical proof passes | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed |
    | AM-2 | Runner surface check | Surface exists signal is present | runtime_smoke | scripts/proof_runner --help | surface_exists |
    | AM-3 | Runner execution proof | Artifact is generated and uploaded | artifact | runtime-proof.log | run_executed |
    """
  end

  defp acceptance_matrix_description_run_executed_runtime do
    String.replace(acceptance_matrix_description(), "surface_exists", "run_executed")
  end

  defp phase_acceptance_matrix_description do
    """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |
    | --- | --- | --- | --- | --- | --- | --- |
    | AM-1 | Review proof | Targeted tests pass | test | mix test test/symphony_elixir/handoff_check_test.exs | run_executed | review |
    | AM-2 | Post-merge runtime proof | Runtime smoke is dispatched on main | runtime_smoke | post-merge workflow dispatch | runtime_smoke | done |
    """
  end

  defp green_pr_snapshot do
    %{
      "all_checks_green" => true,
      "has_pending_checks" => false,
      "has_actionable_feedback" => false,
      "merge_state_status" => "CLEAN",
      "url" => "https://example.test/pr/52"
    }
  end

  defp git_metadata do
    %{
      "head_sha" => "abc123",
      "tree_sha" => "tree123",
      "worktree_clean" => true
    }
  end

  defp valid_gate_manifest_fields(git_metadata \\ git_metadata()) do
    %{
      "validation_gate" => %{
        "gate" => "final",
        "change_classes" => ["backend_only"],
        "strictest_change_class" => "backend_only",
        "requires_final_gate" => true,
        "required_checks" => ["preflight", "cheap_gate", "targeted_tests", "repo_validation"],
        "passed_checks" => ["preflight", "cheap_gate", "targeted_tests", "repo_validation"],
        "remote_finalization_allowed" => true
      },
      "git" => git_metadata
    }
  end

  defp git_runner do
    fn
      ["rev-parse", "HEAD"], _opts -> {:ok, "abc123\n"}
      ["rev-parse", "HEAD^{tree}"], _opts -> {:ok, "tree123\n"}
      ["status", "--porcelain", "--untracked-files=no"], _opts -> {:ok, ""}
    end
  end

  defp init_git_repo! do
    repo_path = Path.join(System.tmp_dir!(), "handoff-check-repo-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo_path)
    File.mkdir_p!(repo_path)
    File.write!(Path.join(repo_path, "tracked.txt"), "tracked\n")

    assert {_, 0} = System.cmd("git", ["init"], cd: repo_path, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["config", "user.name", "Symphony Tests"], cd: repo_path)
    assert {_, 0} = System.cmd("git", ["config", "user.email", "symphony-tests@example.com"], cd: repo_path)
    assert {_, 0} = System.cmd("git", ["add", "tracked.txt"], cd: repo_path)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: repo_path, stderr_to_stdout: true)

    repo_path
  end

  defp git_metadata_for_repo!(repo_path) do
    {head_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
    {tree_sha, 0} = System.cmd("git", ["rev-parse", "HEAD^{tree}"], cd: repo_path)
    {status, 0} = System.cmd("git", ["status", "--porcelain", "--untracked-files=no"], cd: repo_path)

    %{
      "head_sha" => String.trim(head_sha),
      "tree_sha" => String.trim(tree_sha),
      "worktree_clean" => String.trim(status) == ""
    }
  end

  defp sha256(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end
end
