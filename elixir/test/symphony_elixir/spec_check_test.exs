defmodule SymphonyElixir.SpecCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SpecCheck

  @base_description """
  ## Acceptance Matrix

  | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
  | --- | --- | --- | --- | --- | --- |
  | AM-1 | baseline | baseline gate | test | mix test | run_executed |
  """

  @changed_description """
  ## Acceptance Matrix

  | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
  | --- | --- | --- | --- | --- | --- |
  | AM-1 | changed | changed gate | test | mix test | run_executed |
  """

  test "default helpers and state predicates" do
    assert SpecCheck.default_manifest_path() == ".symphony/verification/spec-manifest.json"
    assert SpecCheck.default_contract_lock_path() == ".symphony/verification/spec-contract.lock.json"
    assert SpecCheck.default_execution_states() == ["In Progress"]
    assert SpecCheck.default_spec_review_states() == ["Spec Review"]

    assert SpecCheck.execution_state?("In Progress")
    refute SpecCheck.execution_state?(nil)

    assert SpecCheck.spec_review_state?("Spec Review")
    refute SpecCheck.spec_review_state?(123)
  end

  test "contract revision helpers handle nil values and material drift detection" do
    assert SpecCheck.contract_revision_from_description(nil) == nil

    revision = SpecCheck.contract_revision_from_description(@base_description)
    assert is_binary(revision)
    refute SpecCheck.material_spec_change?(@base_description, @base_description)
    assert SpecCheck.material_spec_change?(@base_description, @changed_description)
  end

  test "evaluate guards invalid inputs and normalizes labels/blockers" do
    assert {:ok, payload} = SpecCheck.evaluate(@base_description)
    assert payload["passed"] == true

    assert {:error, payload} = SpecCheck.evaluate(123)
    assert payload["summary"] =~ "must be a string"

    assert {:error, payload} = SpecCheck.evaluate(@base_description, :invalid_opts)
    assert payload["summary"] =~ "must be a string"

    assert {:error, manifest} =
             SpecCheck.evaluate(
               @base_description,
               labels: [:migration, 123],
               blocked_by: [
                 %{"id" => "LET-A", "state" => "In Progress"},
                 %{id: "LET-B", state: "In Progress"},
                 :ignored
               ]
             )

    assert manifest["issue"]["labels"] == ["migration"]
    assert Enum.any?(manifest["missing_items"], &String.contains?(&1, "unresolved blocking dependencies"))

    assert {:ok, manifest} = SpecCheck.evaluate(@base_description, blocked_by: :invalid)
    assert manifest["dependency_graph_guard"]["blocked_by"] == []

    assert {:ok, manifest} = SpecCheck.evaluate(@base_description, labels: :invalid)
    assert manifest["issue"]["labels"] == []
  end

  test "evaluate fails closed for delivery-sensitive specs without rollout contract" do
    description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-1 | Migration path | Migration execution is covered | test | mix test | run_executed |

    ## Symphony

    Required capabilities: stateful_db
    """

    assert {:error, manifest} = SpecCheck.evaluate(description, labels: ["backend"])
    assert get_in(manifest, ["delivery", "classification", "delivery_class"]) == "stateful_schema"

    assert Enum.any?(
             manifest["missing_items"],
             &String.contains?(&1, "rollout contract is required for delivery-sensitive class `stateful_schema`")
           )
  end

  test "evaluate allows code_only specs without rollout overhead" do
    assert {:ok, manifest} = SpecCheck.evaluate(@base_description)
    assert get_in(manifest, ["delivery", "classification", "delivery_class"]) == "code_only"
    assert get_in(manifest, ["delivery", "contract", "present"]) == false
  end

  test "evaluate validates rollout obligation capabilities against Required capabilities" do
    description = """
    ## Acceptance Matrix

    | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
    | --- | --- | --- | --- | --- | --- |
    | AM-1 | Runtime repair | Review proof exists | test | mix test | run_executed |

    ## Rollout Contract

    delivery_class: runtime_repair
    obligation_type: real_case_canary
    required_capability: runtime_smoke
    proof_type: runtime_smoke
    proof_target: production canary
    required_before: done
    unblock_action: Run the canary and attach runtime proof.
    """

    assert {:error, manifest} = SpecCheck.evaluate(description)

    assert "rollout obligation `RO-1` requires capability `runtime_smoke`, but `Required capabilities` does not declare it" in manifest["missing_items"]
  end

  test "execution transition guard returns issue_id error for invalid arity input" do
    assert {:error, :spec_manifest_invalid, %{"reason" => "issue_id is required"}} =
             SpecCheck.execution_transition_allowed?("/tmp/manifest.json", 123, "In Progress", [])
  end

  @tag :tmp_dir
  test "execution transition guard handles manifest read/decode failures", %{tmp_dir: tmp_dir} do
    missing_path = Path.join(tmp_dir, "missing.json")

    assert {:error, :spec_manifest_missing, _} =
             SpecCheck.execution_transition_allowed?(missing_path, "LET-1", "In Progress")

    directory_path = Path.join(tmp_dir, "manifest_dir")
    File.mkdir_p!(directory_path)

    assert {:error, :spec_manifest_invalid, %{"reason" => "cannot read spec manifest"}} =
             SpecCheck.execution_transition_allowed?(directory_path, "LET-1", "In Progress")

    invalid_json_path = Path.join(tmp_dir, "invalid.json")
    File.write!(invalid_json_path, "{invalid")

    assert {:error, :spec_manifest_invalid, %{"reason" => "spec manifest is not valid JSON"}} =
             SpecCheck.execution_transition_allowed?(invalid_json_path, "LET-1", "In Progress")
  end

  @tag :tmp_dir
  test "execution transition guard validates manifest identity and revision branches", %{tmp_dir: tmp_dir} do
    revision = SpecCheck.contract_revision_from_description(@base_description)
    manifest_path = Path.join(tmp_dir, "manifest.json")
    lock_path = Path.join(tmp_dir, "spec-contract.lock.json")

    write_manifest!(manifest_path, base_manifest(revision, "LET-1"))
    write_lock!(lock_path, "LET-1", revision)

    assert :ok =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-1",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    assert {:error, :spec_manifest_invalid, %{"reason" => "spec manifest belongs to a different issue"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-999",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    write_manifest!(manifest_path, base_manifest(revision, "LET-1", %{"target_state" => "Spec Review"}))

    assert {:error, :spec_manifest_invalid, %{"reason" => "spec manifest target state does not match requested execution state"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-1",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    write_manifest!(manifest_path, base_manifest(revision, "LET-1", %{"passed" => false}))

    assert {:error, :spec_manifest_failed, %{"reason" => "spec manifest does not record a successful spec check"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-1",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    write_manifest!(manifest_path, base_manifest(nil, "LET-1"))

    assert {:error, :spec_manifest_stale, %{"reason" => "spec manifest is missing contract revision"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-1",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: false
             )

    write_manifest!(manifest_path, base_manifest(revision, "LET-1"))

    assert {:error, :spec_manifest_stale, %{"reason" => "current issue description is unavailable for spec revision comparison"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-1",
               "In Progress",
               issue_state: "Spec Review",
               require_contract_lock: false
             )
  end

  @tag :tmp_dir
  test "execution transition guard validates lock path branches", %{tmp_dir: tmp_dir} do
    revision = SpecCheck.contract_revision_from_description(@base_description)
    manifest_path = Path.join(tmp_dir, "manifest.json")
    write_manifest!(manifest_path, base_manifest(revision, "LET-2"))

    assert :ok =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-2",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: false
             )

    assert {:error, :spec_manifest_stale, %{"reason" => "spec contract lock path is missing"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-2",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: ""
             )

    missing_lock = Path.join(tmp_dir, "missing-lock.json")

    assert {:error, :spec_manifest_stale, %{"reason" => "spec contract lock file is missing"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-2",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: missing_lock
             )

    repo_path = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo_path)

    assert {:error, :spec_manifest_stale, %{"reason" => "spec contract lock file is missing", "contract_lock_path" => resolved_path}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-2",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               repo_path: repo_path
             )

    assert resolved_path == Path.expand(Path.join(repo_path, ".symphony/verification/spec-contract.lock.json"))
  end

  @tag :tmp_dir
  test "execution transition guard validates lock content mismatch branches", %{tmp_dir: tmp_dir} do
    revision = SpecCheck.contract_revision_from_description(@base_description)
    manifest_path = Path.join(tmp_dir, "manifest.json")
    lock_path = Path.join(tmp_dir, "lock.json")
    write_manifest!(manifest_path, base_manifest(revision, "LET-3"))

    write_json!(lock_path, %{"issue" => %{"id" => "LET-3"}})

    assert {:error, :spec_manifest_stale, %{"reason" => "spec contract lock revision is missing"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-3",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    write_lock!(lock_path, "LET-3", "other-revision")

    assert {:error, :spec_manifest_stale, %{"reason" => "spec contract lock revision does not match spec manifest"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-3",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    write_lock!(lock_path, "LET-999", revision)

    assert {:error, :spec_manifest_invalid, %{"reason" => "spec contract lock belongs to a different issue"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-3",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    File.write!(lock_path, "{bad")

    assert {:error, :spec_manifest_invalid, %{"reason" => "cannot read spec contract lock file"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-3",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )
  end

  @tag :tmp_dir
  test "execution transition guard validates risky routing and dependency guard branches", %{tmp_dir: tmp_dir} do
    revision = SpecCheck.contract_revision_from_description(@base_description)
    manifest_path = Path.join(tmp_dir, "manifest.json")
    lock_path = Path.join(tmp_dir, "lock.json")
    write_lock!(lock_path, "LET-4", revision)

    risky_manifest =
      base_manifest(revision, "LET-4", %{
        "risk_classifier" => %{"risky_task" => true, "reasons" => ["risky"]},
        "dependency_graph_guard" => %{"blocking_dependencies" => []}
      })

    write_manifest!(manifest_path, risky_manifest)

    assert :ok =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-4",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    assert :ok =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-4",
               "In Progress",
               issue_description: @base_description,
               issue_state: :todo,
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    assert {:error, :spec_manifest_stale, %{"reason" => "risky task requires explicit `Spec Review` before entering execution"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-4",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Todo",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    assert :ok =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-4",
               "In Progress",
               issue_description: @base_description,
               issue_state: "In Progress",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    dependency_manifest =
      base_manifest(revision, "LET-4", %{
        "risk_classifier" => %{"risky_task" => false},
        "dependency_graph_guard" => %{
          "blocking_dependencies" => [
            %{identifier: "LET-BLOCK", state: "In Progress"},
            %{state: "Todo"},
            :ignored
          ]
        }
      })

    write_manifest!(manifest_path, dependency_manifest)

    assert {:error, :spec_manifest_stale, %{"reason" => "dependency graph guard blocked execution for stateful/migration spec"}} =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-4",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )

    write_manifest!(manifest_path, base_manifest(revision, "LET-4", %{"dependency_graph_guard" => %{"blocking_dependencies" => :invalid}}))

    assert :ok =
             SpecCheck.execution_transition_allowed?(
               manifest_path,
               "LET-4",
               "In Progress",
               issue_description: @base_description,
               issue_state: "Spec Review",
               require_contract_lock: true,
               contract_lock_path: lock_path
             )
  end

  defp base_manifest(revision, issue_id, overrides \\ %{}) do
    %{
      "passed" => true,
      "target_state" => "In Progress",
      "contract_revision" => revision,
      "risk_classifier" => %{"risky_task" => false},
      "issue" => %{"id" => issue_id},
      "dependency_graph_guard" => %{"blocking_dependencies" => []}
    }
    |> Map.merge(overrides)
  end

  defp write_manifest!(path, manifest), do: write_json!(path, manifest)

  defp write_lock!(path, issue_id, revision) do
    write_json!(path, %{
      "issue" => %{"id" => issue_id},
      "contract_revision" => revision
    })
  end

  defp write_json!(path, payload) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload))
    path
  end
end
