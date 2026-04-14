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

    assert {:ok, manifest} =
             HandoffCheck.evaluate(
               workpad,
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
    assert manifest["contract_version"] == 2
    assert manifest["profile"] == "runtime"
    assert manifest["profile_source"] == "label"
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

    assert {:error, manifest} = HandoffCheck.evaluate("## Codex Workpad")

    assert manifest["profile"] == "generic"
    assert manifest["profile_source"] == "fallback"
    assert "pull request snapshot is missing" in manifest["missing_items"]
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
    assert "artifact manifest entry must include an attachment title in backticks" in manifest["missing_items"]
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

    assert "artifact manifest entry must include an attachment title in backticks" in ui_manifest["missing_items"]
    assert "profile `ui` is missing a matching uploaded proof artifact" in ui_manifest["missing_items"]
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
      "summary" => invalid_tail,
      "missing_items" => [invalid_tail]
    }

    assert {:ok, written_path} = HandoffCheck.write_manifest(manifest, manifest_path)
    assert {:ok, encoded} = File.read(written_path)
    assert {:ok, decoded} = Jason.decode(encoded)
    assert String.valid?(decoded["summary"])
    assert String.valid?(List.first(decoded["missing_items"]))
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
