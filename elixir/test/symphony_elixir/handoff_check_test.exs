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
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
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
               }
             )

    assert manifest["passed"]
    assert manifest["profile"] == "runtime"
    assert manifest["profile_source"] == "label"
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
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
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
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
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
               pr_snapshot: green_pr_snapshot()
             )

    assert "artifact manifest entry must include an attachment title in backticks" in ui_manifest["missing_items"]
    assert "profile `ui` is missing a matching uploaded proof artifact" in ui_manifest["missing_items"]
  end

  test "review_ready_transition_allowed? fails when the workpad digest no longer matches the manifest" do
    workpad_path = Path.join(System.tmp_dir!(), "handoff-check-workpad-#{System.unique_integer([:positive])}.md")
    manifest_path = Path.join(System.tmp_dir!(), "handoff-check-manifest-#{System.unique_integer([:positive])}.json")

    File.write!(workpad_path, "original")

    manifest = %{
      "passed" => true,
      "issue" => %{"id" => "LET-416"},
      "workpad" => %{
        "file_path" => workpad_path,
        "sha256" => :crypto.hash(:sha256, "original") |> Base.encode16(case: :lower)
      }
    }

    assert {:ok, _path} = HandoffCheck.write_manifest(manifest, manifest_path)
    File.write!(workpad_path, "changed")

    assert {:error, :handoff_manifest_stale, details} =
             HandoffCheck.review_ready_transition_allowed?(manifest_path, "LET-416", "In Review")

    assert details["reason"] =~ "workpad changed"
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
               %{
                 "passed" => true,
                 "issue" => %{"id" => "LET-416"},
                 "workpad" => %{
                   "file_path" => Path.join(manifest_dir, "missing-workpad.md"),
                   "sha256" => sha256("missing")
                 }
               },
               unreadable_workpad_manifest_path
             )

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(unreadable_workpad_manifest_path, "LET-416", "In Review")

    assert details["reason"] =~ "cannot read workpad referenced by manifest"

    assert {:ok, _path} =
             HandoffCheck.write_manifest(
               %{
                 "passed" => true,
                 "issue" => %{"id" => "LET-416"},
                 "workpad" => %{}
               },
               no_workpad_manifest_path
             )

    assert {:error, :handoff_manifest_invalid, details} =
             HandoffCheck.review_ready_transition_allowed?(no_workpad_manifest_path, "LET-416", "In Review")

    assert details["reason"] =~ "does not point to a workpad file"
  end

  test "evaluate accepts ui and data-extraction proof claims and rejects bad PR snapshots" do
    ui_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
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
               pr_snapshot: green_pr_snapshot()
             )

    assert ui_manifest["profile"] == "ui"

    data_workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
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
               pr_snapshot: green_pr_snapshot()
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
               }
             )

    assert "pull request checks are not fully green" in pr_manifest["missing_items"]
    assert "pull request still has pending checks" in pr_manifest["missing_items"]
    assert "pull request still has actionable feedback" in pr_manifest["missing_items"]
    assert "pull request is not merge-ready" in pr_manifest["missing_items"]
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

  defp green_pr_snapshot do
    %{
      "all_checks_green" => true,
      "has_pending_checks" => false,
      "has_actionable_feedback" => false,
      "merge_state_status" => "CLEAN",
      "url" => "https://example.test/pr/52"
    }
  end

  defp sha256(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end
end
