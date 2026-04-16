defmodule SymphonyElixir.ValidationGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ValidationGate

  test "exposes the canonical change classes and gate types" do
    assert ValidationGate.allowed_change_classes() == [
             "backend_only",
             "stateful",
             "ui",
             "runtime_contract",
             "docs_only"
           ]

    assert ValidationGate.gate_types() == ["cheap", "final"]
  end

  test "classifies changed paths deterministically and fails closed for unknown paths" do
    assert {:ok, ["backend_only"]} =
             ValidationGate.classify_paths(["elixir/lib/symphony_elixir/error_classifier.ex"])

    assert {:ok, ["stateful"]} =
             ValidationGate.classify_paths(["tests/integration/test_task_v3_stateful_repeatability.py"])

    assert {:ok, ["ui"]} =
             ValidationGate.classify_paths(["elixir/lib/symphony_elixir_web/controllers/page_controller.ex"])

    assert {:ok, ["runtime_contract"]} =
             ValidationGate.classify_paths(["workflows/letterl/maxime/let.WORKFLOW.md"])

    assert {:ok, ["docs_only"]} = ValidationGate.classify_paths(["docs/operator-note.md"])
    assert {:ok, ["runtime_contract"]} = ValidationGate.classify_paths(["unknown.lockfile"])
    assert {:error, ["changed_paths must be a non-empty list"]} = ValidationGate.classify_paths([])
  end

  test "computes cheap and final requirements for backend-only changes" do
    assert {:ok, cheap} = ValidationGate.requirements(["backend_only"], "cheap")

    assert cheap["required_checks"] == ["preflight", "targeted_tests"]
    assert cheap["remote_finalization_allowed"] == false

    assert {:ok, final} = ValidationGate.requirements(["backend_only"], "final")

    assert final["required_checks"] == ["preflight", "cheap_gate", "targeted_tests", "repo_validation"]
    assert final["requires_final_gate"] == true
    assert final["remote_finalization_allowed"] == true
  end

  test "keeps stateful and runtime-contract classes strict" do
    assert {:ok, stateful} = ValidationGate.requirements(["stateful"], "final")
    assert "stateful_proof" in stateful["required_checks"]
    assert stateful["strictest_change_class"] == "stateful"

    assert {:ok, runtime} = ValidationGate.requirements(["runtime_contract"], "final")
    assert "runtime_smoke" in runtime["required_checks"]
    assert runtime["strictest_change_class"] == "runtime_contract"
  end

  test "docs-only changes do not require the local full gate" do
    assert {:ok, docs} = ValidationGate.requirements(["docs_only"], "final")

    assert docs["requires_final_gate"] == false
    assert docs["remote_finalization_allowed"] == false
    assert docs["required_checks"] == ["docs_review"]
  end

  test "mixed changes use union requirements and the strictest affected class" do
    assert {:ok, mixed} = ValidationGate.requirements(["docs_only", "backend_only", "runtime_contract"], "final")

    assert mixed["change_classes"] == ["docs_only", "backend_only", "runtime_contract"]
    assert mixed["strictest_change_class"] == "runtime_contract"
    assert mixed["requires_final_gate"] == true

    assert mixed["required_checks"] == [
             "preflight",
             "cheap_gate",
             "targeted_tests",
             "runtime_smoke",
             "docs_review",
             "repo_validation"
           ]
  end

  test "normalizes proof labels from workpad-style text" do
    assert ValidationGate.normalize_checks([
             "preflight",
             "cheap gate",
             "targeted tests",
             "repo validation",
             "runtime-smoke",
             "ignored"
           ]) == ["preflight", "cheap_gate", "targeted_tests", "runtime_smoke", "repo_validation"]
  end

  test "derives required proof checks from delivery:tdd and runtime contract sources" do
    assert ValidationGate.required_proof_checks(["delivery:tdd"], ["backend_only"]) == [
             %{
               "check" => "red_proof",
               "label" => "red proof",
               "source" => "issue label `delivery:tdd`",
               "next_action" => "Run a failing baseline command and mark the `red proof` validation item with that command."
             }
           ]

    assert ValidationGate.required_proof_checks([], ["runtime_contract"]) == [
             %{
               "check" => "runtime_smoke",
               "label" => "runtime smoke",
               "source" => "validation gate change class `runtime_contract`",
               "next_action" => "Run the runtime smoke command for the changed contract path and mark the `runtime smoke` validation item."
             }
           ]

    assert ValidationGate.required_proof_checks(["delivery:tdd"], ["runtime_contract"]) == [
             %{
               "check" => "red_proof",
               "label" => "red proof",
               "source" => "issue label `delivery:tdd`",
               "next_action" => "Run a failing baseline command and mark the `red proof` validation item with that command."
             },
             %{
               "check" => "runtime_smoke",
               "label" => "runtime smoke",
               "source" => "validation gate change class `runtime_contract`",
               "next_action" => "Run the runtime smoke command for the changed contract path and mark the `runtime smoke` validation item."
             }
           ]
  end

  test "reports missing required proof checks without backend-only false positives" do
    validation_items = [
      %{"checked" => true, "label" => "red proof", "command" => "mix test test/app_test.exs:12"},
      %{"checked" => true, "label" => "runtime smoke", "command" => "n/a"},
      %{"checked" => true, "label" => "targeted tests", "command" => "mix test test/app_test.exs"}
    ]

    both_missing =
      ValidationGate.missing_required_proof_checks(
        validation_items,
        ["delivery:tdd"],
        ["runtime_contract"]
      )

    assert Enum.map(both_missing["missing_checks"], & &1["check"]) == ["runtime_smoke"]
    assert "red_proof" in both_missing["checked_checks"]

    backend_only =
      ValidationGate.missing_required_proof_checks(
        validation_items,
        [],
        ["backend_only"]
      )

    assert backend_only["missing_checks"] == []
  end

  test "checked validation helpers normalize label-only entries and reject invalid placeholders" do
    assert ValidationGate.checked_validation_checks(["preflight"]) == ["preflight"]

    assert ValidationGate.checked_validation_checks([
             %{"checked" => true, "label" => "runtime smoke", "command" => 123},
             %{"checked" => true, "label" => 123, "command" => "mix test"},
             456
           ]) == []

    assert ValidationGate.checked_validation_checks(:invalid) == []
  end

  test "required proof checks normalize mixed issue label types" do
    assert Enum.map(ValidationGate.required_proof_checks([:"delivery:tdd", 123], ["backend_only"]), & &1["check"]) == [
             "red_proof"
           ]

    assert ValidationGate.required_proof_checks("delivery:tdd", ["runtime_contract"]) == [
             %{
               "check" => "runtime_smoke",
               "label" => "runtime smoke",
               "source" => "validation gate change class `runtime_contract`",
               "next_action" => "Run the runtime smoke command for the changed contract path and mark the `runtime smoke` validation item."
             }
           ]
  end

  test "fails closed for invalid change class, path, gate, and rerun inputs" do
    assert ValidationGate.normalize_check(:ignored) == nil
    assert ValidationGate.normalize_checks(:ignored) == []

    assert {:error, ["unsupported change class `123`"]} =
             ValidationGate.canonical_change_classes([123])

    assert {:error, ["change_classes must be a non-empty list"]} =
             ValidationGate.canonical_change_classes("backend_only")

    assert {:error, ["changed_paths must be a non-empty list"]} =
             ValidationGate.classify_paths(:invalid)

    assert {:error, ["gate must be one of cheap, final"]} =
             ValidationGate.requirements([:backend_only], :publish)

    assert {:error, ["gate must be one of cheap, final"]} =
             ValidationGate.requirements([:backend_only], 123)

    assert ValidationGate.rerun_decision(:invalid) == %{
             "start_with" => "cheap",
             "requires_final_before_push" => false,
             "blind_rerun_counts_as_proof" => false,
             "auto_fix_counter" => "same_signal"
           }

    assert ValidationGate.rerun_decision(%{trigger: 123}) == %{
             "start_with" => "cheap",
             "requires_final_before_push" => false,
             "blind_rerun_counts_as_proof" => false,
             "auto_fix_counter" => "same_signal"
           }
  end

  test "validates final proof freshness against current HEAD and tree" do
    git = %{"head_sha" => "abc", "tree_sha" => "tree", "worktree_clean" => true}

    assert {:ok, proof} =
             ValidationGate.final_proof(
               ["runtime_contract"],
               ["preflight", "cheap_gate", "targeted_tests", "runtime_smoke", "repo_validation"],
               git
             )

    assert :ok = ValidationGate.validate_final_proof(proof, git)

    assert {:error, stale_head_reasons} =
             ValidationGate.validate_final_proof(proof, %{
               "head_sha" => "def",
               "tree_sha" => "tree",
               "worktree_clean" => true
             })

    assert "final proof HEAD does not match current HEAD" in stale_head_reasons

    assert {:error, dirty_reasons} =
             ValidationGate.validate_final_proof(proof, %{
               "head_sha" => "abc",
               "tree_sha" => "tree",
               "worktree_clean" => false
             })

    assert "current worktree is not clean for shipped paths" in dirty_reasons
  end

  test "rejects dirty or incomplete final proof" do
    dirty_git = %{"head_sha" => "abc", "tree_sha" => "tree", "worktree_clean" => false}

    assert {:ok, proof} =
             ValidationGate.final_proof(
               ["backend_only"],
               ["preflight", "targeted_tests", "repo_validation"],
               dirty_git
             )

    assert {:error, reasons} = ValidationGate.validate_final_proof(proof, dirty_git)

    assert "git.worktree_clean must be true for final proof" in reasons
    assert "validation gate final proof is missing passed check `cheap_gate`" in reasons
  end

  test "final proof helpers report invalidation, missing required checks, and unsupported classes" do
    git = %{"head_sha" => "abc", "tree_sha" => "tree", "worktree_clean" => true}

    assert {:ok, valid_proof} =
             ValidationGate.final_proof(
               ["backend_only"],
               ["preflight", "cheap_gate", "targeted_tests", "repo_validation"],
               git
             )

    assert %{"valid" => true, "reasons" => []} = ValidationGate.invalidation(valid_proof, git)

    assert {:error, ["git metadata is required for final gate proof"]} =
             ValidationGate.final_proof(["backend_only"], [], :invalid)

    assert {:error, ["validation gate final proof metadata is missing"]} =
             ValidationGate.validate_final_proof(:invalid, git)

    assert %{"valid" => false, "reasons" => ["validation gate final proof metadata is missing"]} =
             ValidationGate.invalidation(:invalid, git)

    assert {:error, missing_required_reasons} =
             ValidationGate.validate_final_proof(
               %{
                 "validation_gate" => %{
                   "gate" => "final",
                   "change_classes" => ["backend_only"],
                   "required_checks" => ["preflight"],
                   "passed_checks" => [
                     "preflight",
                     "cheap_gate",
                     "targeted_tests",
                     "repo_validation"
                   ]
                 },
                 "git" => git
               },
               git
             )

    assert "validation gate final proof is missing required check `cheap_gate`" in missing_required_reasons
    assert "validation gate final proof is missing required check `targeted_tests`" in missing_required_reasons

    assert {:error, invalid_class_reasons} =
             ValidationGate.validate_final_proof(
               %{
                 "validation_gate" => %{
                   "gate" => "final",
                   "change_classes" => ["unsupported"],
                   "required_checks" => [],
                   "passed_checks" => []
                 },
                 "git" => %{"worktree_clean" => true}
               },
               git
             )

    assert "unsupported change class `\"unsupported\"`" in invalid_class_reasons
    assert "git.head_sha is missing from final proof" in invalid_class_reasons
    assert "git.tree_sha is missing from final proof" in invalid_class_reasons
  end

  test "rerun policy starts rework from cheap proof and blocks blind remote-only reruns" do
    assert ValidationGate.rerun_decision(%{
             trigger: :ci_failure,
             fix_changes_shipped: true
           }) == %{
             "start_with" => "cheap",
             "requires_final_before_push" => true,
             "blind_rerun_counts_as_proof" => false,
             "auto_fix_counter" => "same_signal"
           }

    assert ValidationGate.rerun_decision(%{
             "trigger" => "ci_failure",
             "remote_only" => true,
             "materially_new" => true
           }) == %{
             "start_with" => "blocked_decision",
             "requires_final_before_push" => false,
             "blind_rerun_counts_as_proof" => false,
             "auto_fix_counter" => "new_signal"
           }
  end
end
