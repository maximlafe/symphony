defmodule SymphonyElixir.DeliveryContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DeliveryContract

  @rollout_contract """
  ## Rollout Contract

  | delivery_class | obligation_type | required_capability | proof_type | proof_target | required_before | unblock_action |
  | -- | -- | -- | -- | -- | -- | -- |
  | stateful_schema | migration_applied | stateful_db | artifact | migration-proof.log | done | Apply the migration and attach the migration proof. |
  """

  test "parses rollout contract table into deterministic obligations" do
    {contract, errors} = DeliveryContract.parse(@rollout_contract)

    assert errors == []
    assert contract["present"] == true
    assert contract["delivery_class"] == "stateful_schema"
    assert [obligation] = contract["obligations"]
    assert obligation["id"] == "RO-1"
    assert obligation["obligation_type"] == "migration_applied"
    assert obligation["required_capability"] == "stateful_db"
    assert obligation["proof_type"] == "artifact"
    assert obligation["required_before"] == "done"
  end

  test "exposes canonical values and helper predicates" do
    assert DeliveryContract.delivery_classes() == ["code_only", "stateful_schema", "runtime_repair", "operator_flow"]
    assert DeliveryContract.sensitive_delivery_classes() == ["stateful_schema", "runtime_repair", "operator_flow"]
    assert "stateful_db" in DeliveryContract.required_capabilities()

    assert DeliveryContract.delivery_sensitive?(%{delivery_class: "operator_flow"})
    refute DeliveryContract.delivery_sensitive?(:invalid)
    assert [%{"id" => "RO-1"}] = DeliveryContract.done_obligations(elem(DeliveryContract.parse(@rollout_contract), 0))
    assert DeliveryContract.done_obligations(:invalid) == []
    assert DeliveryContract.has_done_obligations?(elem(DeliveryContract.parse(@rollout_contract), 0))
    refute DeliveryContract.has_done_obligations?(:invalid)
  end

  test "evaluates missing capability references separately from obligations" do
    diagnostic = DeliveryContract.evaluate(@rollout_contract, required_capabilities: [])

    assert diagnostic["classification"]["delivery_class"] == "stateful_schema"

    assert "rollout obligation `RO-1` requires capability `stateful_db` but `Required capabilities` does not declare it" in diagnostic["missing_items"]
  end

  test "classifies code-only descriptions without rollout overhead" do
    diagnostic = DeliveryContract.evaluate("## Acceptance Matrix\n\nPlain backend copy update.")

    assert diagnostic["contract"]["present"] == false
    assert diagnostic["classification"]["delivery_class"] == "code_only"
    assert diagnostic["missing_items"] == []
  end

  test "supports keyword input, atom labels, and invalid classifier input" do
    keyword_classification =
      DeliveryContract.classify(
        description: "Operator cutover runbook",
        labels: [:operator_flow, 123],
        required_capabilities: [:artifact_upload]
      )

    assert keyword_classification["delivery_class"] == "operator_flow"
    assert DeliveryContract.classify(:invalid)["delivery_class"] == "code_only"
    assert {empty_contract, []} = DeliveryContract.parse(nil)
    assert empty_contract["present"] == false
  end

  test "parses key-value rollout contract variants" do
    code_only = """
    ## Rollout Contract

    delivery_class: code_only
    """

    {code_only_contract, []} = DeliveryContract.parse(code_only)
    assert code_only_contract["present"] == true
    assert code_only_contract["obligations"] == []

    single_obligation = """
    ## Delivery Contract

    id: RO-CUTOVER
    delivery_class: operator_flow
    obligation_type: operator_cutover_verified
    required_capability: none
    proof_type: test
    proof_target: mix test test/symphony_elixir/delivery_contract_test.exs
    required_before: review
    unblock_action: Verify operator cutover.
    ignored line without delimiter
    """

    {contract, []} = DeliveryContract.parse(single_obligation)
    assert [%{"id" => "RO-CUTOVER", "required_before" => "review"}] = contract["obligations"]
  end

  test "reports malformed rollout contract rows fail-closed" do
    malformed = """
    ## Rollout Contract

    | delivery_class | obligation_type | required_capability | proof_type | proof_target | required_before | unblock_action |
    | -- | -- | -- | -- | -- | -- | -- |
    | stateful_schema | not_real | secret_room | unsupported |  | tomorrow |  |
    | runtime_repair | real_case_canary | none | artifact | canary.log | done | Attach canary proof. |
    """

    {contract, errors} = DeliveryContract.parse(malformed)

    assert contract["delivery_class"] == "runtime_repair"
    assert Enum.any?(errors, &String.contains?(&1, "unsupported obligation_type"))
    assert Enum.any?(errors, &String.contains?(&1, "unsupported required_capability"))
    assert Enum.any?(errors, &String.contains?(&1, "unsupported proof_type"))
    assert Enum.any?(errors, &String.contains?(&1, "unsupported required_before"))
    assert Enum.any?(errors, &String.contains?(&1, "missing required proof_target"))
    assert Enum.any?(errors, &String.contains?(&1, "missing required unblock_action"))
  end

  test "reports malformed key-value rollout obligations" do
    malformed = """
    ## Delivery Contract

    delivery_class: runtime_repair
    obligation_type: real_case_canary
    required_capability: none
    proof_type: artifact
    required_before: done
    unblock_action: Attach canary proof.
    """

    {contract, errors} = DeliveryContract.parse(malformed)

    assert contract["present"] == true
    assert Enum.any?(errors, &String.contains?(&1, "missing required proof_target"))

    missing_class = """
    ## Delivery Contract

    obligation_type: real_case_canary
    required_capability: none
    proof_type: artifact
    proof_target: canary.log
    required_before: done
    unblock_action: Attach canary proof.
    """

    {fallback_contract, fallback_errors} = DeliveryContract.parse(missing_class)

    assert fallback_contract["delivery_class"] == "code_only"
    assert Enum.any?(fallback_errors, &String.contains?(&1, "unsupported delivery_class"))
  end

  test "reports inconsistent sensitive explicit contract without obligations" do
    diagnostic =
      DeliveryContract.evaluate("""
      ## Rollout Contract

      delivery_class: runtime_repair
      """)

    assert "delivery_class=runtime_repair requires at least one rollout obligation" in diagnostic["missing_items"]
  end

  test "reports multiple delivery classes in one table" do
    mixed = """
    ## Rollout Contract

    | delivery_class | obligation_type | required_capability | proof_type | proof_target | required_before | unblock_action |
    | -- | -- | -- | -- | -- | -- | -- |
    | stateful_schema | migration_applied | none | artifact | migration.log | done | Attach migration proof. |
    | operator_flow | operator_cutover_verified | none | artifact | cutover.log | done | Attach cutover proof. |
    """

    {_contract, errors} = DeliveryContract.parse(mixed)
    assert "rollout contract has multiple delivery_class values; use exactly one delivery_class per issue" in errors
  end
end
