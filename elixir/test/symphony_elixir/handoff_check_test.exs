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
    assert manifest["contract_version"] == 2
    assert manifest["profile"] == "runtime"
    assert manifest["profile_source"] == "label"
    assert manifest["issue"]["required_capabilities"] == ["runtime_smoke", "artifact_upload", "repo_validation"]
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

  test "evaluate enforces acceptance matrix proof mapping for mode:plan issues" do
    workpad = """
    ## Codex Workpad

    ### Validation

    - [x] preflight: `make symphony-preflight`
    - [x] cheap gate: `same HEAD targeted proof completed`
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

  test "evaluate uses actionable_feedback_state as the review feedback gate when present" do
    assert {:error, manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-416",
               profile: "runtime",
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: %{
                 "all_checks_green" => true,
                 "has_pending_checks" => false,
                 "has_actionable_feedback" => false,
                 "actionable_feedback_state" => "changes_requested",
                 "merge_state_status" => "CLEAN",
                 "url" => "https://example.test/pr/999"
               },
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "pull request still has actionable feedback" in manifest["missing_items"]
    assert manifest["pull_request"]["actionable_feedback_state"] == "changes_requested"
  end

  test "evaluate blocks actionable_comments state even when legacy bool is false" do
    assert {:error, manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-416",
               profile: "runtime",
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: %{
                 "all_checks_green" => true,
                 "has_pending_checks" => false,
                 "has_actionable_feedback" => false,
                 "actionable_feedback_state" => "actionable_comments",
                 "merge_state_status" => "CLEAN",
                 "url" => "https://example.test/pr/1000"
               },
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "pull request still has actionable feedback" in manifest["missing_items"]
    assert manifest["pull_request"]["actionable_feedback_state"] == "actionable_comments"
  end

  test "evaluate falls back to legacy bool when actionable_feedback_state is invalid" do
    assert {:error, manifest} =
             HandoffCheck.evaluate(
               runtime_workpad(),
               issue_id: "LET-416",
               profile: "runtime",
               attachments: [%{"title" => "runtime-proof.log"}],
               pr_snapshot: %{
                 "all_checks_green" => true,
                 "has_pending_checks" => false,
                 "has_actionable_feedback" => true,
                 "actionable_feedback_state" => "unexpected",
                 "merge_state_status" => "CLEAN",
                 "url" => "https://example.test/pr/1001"
               },
               change_classes: ["runtime_contract"],
               git: git_metadata()
             )

    assert "pull request still has actionable feedback" in manifest["missing_items"]
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
