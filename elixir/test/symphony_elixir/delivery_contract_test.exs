defmodule SymphonyElixir.DeliveryContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DeliveryContract

  test "parse normalizes rollout contract obligations" do
    description = """
    ## Rollout Contract

    delivery_class: runtime_repair

    | id | obligation_type | required_capability | proof_type | proof_target | required_before | unblock_action |
    | -- | -- | -- | -- | -- | -- | -- |
    | RO-1 | real_case_canary | runtime_smoke | runtime_smoke | production health canary | done | Run the canary and attach runtime proof. |
    """

    assert {contract, []} = DeliveryContract.parse(description)
    assert contract["present"] == true
    assert contract["delivery_class"] == "runtime_repair"

    assert [
             %{
               "id" => "RO-1",
               "obligation_type" => "real_case_canary",
               "required_capability" => "runtime_smoke",
               "proof_type" => "runtime_smoke",
               "proof_target" => "production health canary",
               "required_before" => "done",
               "unblock_action" => "Run the canary and attach runtime proof."
             }
           ] = contract["obligations"]
  end

  test "parse accepts code_only without obligations" do
    assert {contract, []} = DeliveryContract.parse("## Rollout Contract\n\ndelivery_class: code_only\n")
    assert contract["delivery_class"] == "code_only"
    assert contract["obligations"] == []
  end

  test "accessors and fallback branches are deterministic" do
    assert "code_only" in DeliveryContract.delivery_classes()
    assert DeliveryContract.sensitive_delivery_classes() == ["stateful_schema", "runtime_repair", "operator_flow"]
    assert DeliveryContract.sensitive_class?("runtime_repair")
    refute DeliveryContract.sensitive_class?("code_only")

    assert DeliveryContract.classify(:invalid)["delivery_class"] == "code_only"
    assert DeliveryContract.spec_check_errors(:invalid, :invalid, :invalid) == []
    assert {contract, []} = DeliveryContract.parse(nil)
    assert contract["present"] == false
  end

  test "parse rejects execution-only required capabilities" do
    description = """
    ## Rollout Contract

    delivery_class: stateful_schema
    obligation_type: migration_applied
    required_capability: migration_apply
    proof_type: test
    proof_target: mix test
    required_before: done
    unblock_action: Apply the migration.
    """

    assert {_contract, errors} = DeliveryContract.parse(description)
    assert "rollout obligation `RO-1` has unsupported required_capability `migration_apply`" in errors
  end

  test "parse reports invalid classes, code_only obligations, and missing obligation fields" do
    invalid_class_description = """
    ## Rollout Contract

    delivery_class: risky_runtime
    """

    assert {_contract, invalid_class_errors} = DeliveryContract.parse(invalid_class_description)
    assert "rollout contract has unsupported delivery_class `risky_runtime`" in invalid_class_errors

    missing_class_description = """
    ## Rollout Contract

    obligation_type: real_case_canary
    proof_type: runtime_smoke
    proof_target: production canary
    unblock_action: Run canary.
    """

    assert {_contract, missing_class_errors} = DeliveryContract.parse(missing_class_description)
    assert "rollout contract is missing `delivery_class`" in missing_class_errors

    code_only_with_obligation = """
    ## Rollout Contract

    delivery_class: code_only
    obligation_type: real_case_canary
    proof_type: runtime_smoke
    proof_target: production canary
    unblock_action: Run canary.
    """

    assert {_contract, code_only_errors} = DeliveryContract.parse(code_only_with_obligation)
    assert "delivery_class `code_only` must not declare rollout obligations" in code_only_errors

    missing_fields = """
    ## Rollout Contract

    delivery_class: runtime_repair

    | id | obligation_type | required_capability | proof_type | proof_target | required_before | unblock_action |
    | -- | -- | -- | -- | -- | -- | -- |
    | RO-9 |  | none |  |  | done |  |
    """

    assert {_contract, missing_errors} = DeliveryContract.parse(missing_fields)
    assert "rollout obligation `RO-9` is missing `obligation_type`" in missing_errors
    assert "rollout obligation `RO-9` is missing `proof_type`" in missing_errors
    assert "rollout obligation `RO-9` is missing `proof_target`" in missing_errors
    assert "rollout obligation `RO-9` is missing `unblock_action`" in missing_errors
  end

  test "classify maps deterministic delivery surfaces" do
    assert DeliveryContract.classify(description: "Add Ecto migration for schema change")["delivery_class"] ==
             "stateful_schema"

    assert DeliveryContract.classify(description: "Repair runtime worker and run canary")["delivery_class"] ==
             "runtime_repair"

    assert DeliveryContract.classify(labels: ["operator-flow"])["delivery_class"] == "operator_flow"

    assert DeliveryContract.classify(description: "small docs and code cleanup")["delivery_class"] == "code_only"
  end

  test "classify handles atom labels and non-string list values" do
    classification =
      DeliveryContract.classify(%{
        labels: [:db, "backend", 123],
        required_capabilities: [:runtime_smoke, 456]
      })

    assert classification["delivery_class"] == "stateful_schema"
    assert classification["delivery_ambiguous"] == true
  end

  test "spec_check_errors requires sensitive rollout contracts" do
    {contract, []} = DeliveryContract.parse("")
    classification = %{"delivery_class" => "runtime_repair"}

    assert "rollout contract is required for delivery-sensitive class `runtime_repair`" in DeliveryContract.spec_check_errors(contract, classification, [])
  end
end
