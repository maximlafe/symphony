defmodule SymphonyElixir.HandoffFailureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HandoffFailure

  test "classify reports passed manifests as non-recoverable none" do
    assert HandoffFailure.classify(true, []) == %{
             "kind" => "none",
             "recoverable" => false,
             "reason" => "verification passed",
             "recoverable_items" => [],
             "hard_items" => []
           }
  end

  test "classify marks canonical validation checklist drift as recoverable" do
    missing = ["validation checklist is missing a checked `stateful proof` item"]

    assert %{
             "kind" => "recoverable_drift",
             "recoverable" => true,
             "recoverable_items" => ^missing,
             "hard_items" => []
           } = HandoffFailure.classify(false, missing)
  end

  test "classify treats LET-759 proof row drift as recoverable" do
    missing = [
      "validation checklist is missing a checked `red proof` item",
      "acceptance matrix item `AM-1` maps to validation `am-1` that is not checked",
      "acceptance matrix item `AM-1` mapping drift: use canonical validation label `am-1` in `Validation` and map via `validation:am-1`",
      "acceptance matrix item `AM-5` maps to validation `am-5` that is not checked",
      "acceptance matrix item `AM-5` mapping drift: use canonical validation label `am-5` in `Validation` and map via `validation:am-5`"
    ]

    assert %{
             "kind" => "recoverable_drift",
             "recoverable" => true,
             "recoverable_items" => ^missing,
             "hard_items" => []
           } = HandoffFailure.classify(false, missing)

    assert HandoffFailure.recoverable_manifest?(%{"missing_items" => missing})
  end

  test "classify keeps mixed hard and recoverable items hard" do
    recoverable = "validation checklist is missing a checked `stateful proof` item"
    hard = "blocking divergence: enabled mode:plan two-layer contract failed fail-closed validation"

    assert %{
             "kind" => "hard_contract_failure",
             "recoverable" => false,
             "recoverable_items" => [^recoverable],
             "hard_items" => [^hard]
           } = HandoffFailure.classify(false, [recoverable, hard])
  end

  test "classify handles malformed missing item input as hard" do
    assert %{
             "kind" => "hard_contract_failure",
             "recoverable" => false,
             "recoverable_items" => [],
             "hard_items" => []
           } = HandoffFailure.classify(false, :invalid)
  end

  test "recoverable_manifest? trusts recoverable kind only when hard items are absent" do
    assert HandoffFailure.recoverable_manifest?(%{
             "handoff_failure" => %{
               "kind" => "recoverable_drift",
               "hard_items" => []
             }
           })

    refute HandoffFailure.recoverable_manifest?(%{
             "handoff_failure" => %{
               "kind" => "recoverable_drift",
               "hard_items" => ["hard"]
             }
           })

    refute HandoffFailure.recoverable_manifest?(%{
             "handoff_failure" => %{
               "kind" => "hard_contract_failure"
             }
           })
  end

  test "recoverable_manifest? falls back to missing items when kind metadata is absent" do
    assert HandoffFailure.recoverable_manifest?(%{
             "missing_items" => ["validation checklist is missing a checked `runtime smoke` item"]
           })

    refute HandoffFailure.recoverable_manifest?(%{"missing_items" => ["hard"]})
    refute HandoffFailure.recoverable_manifest?(%{"missing_items" => []})
    refute HandoffFailure.recoverable_manifest?(%{"missing_items" => :invalid})
    refute HandoffFailure.recoverable_manifest?(:invalid)
  end

  test "recoverable_drift_item? rejects non-binary values" do
    refute HandoffFailure.recoverable_drift_item?(nil)
    refute HandoffFailure.recoverable_drift_item?(123)
  end
end
