defmodule SymphonyElixir.RiskyTaskClassifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RiskyTaskClassifier

  test "classify supports keyword input and stateful/risky detection" do
    classification =
      RiskyTaskClassifier.classify(
        description: "Migration includes DDL and possible auth impact",
        labels: [:db, "risk:high", 123],
        required_capabilities: [:stateful_db, "vps_ssh", 456]
      )

    assert classification["risky_task"] == true
    assert classification["stateful_migration"] == true
    assert classification["delivery_class"] == "stateful_schema"
    assert classification["cost_signals"] == ["risky_task"]
    assert Enum.any?(classification["reasons"], &String.contains?(&1, "stateful"))
    assert Enum.any?(classification["reasons"], &String.contains?(&1, "high-risk"))
  end

  test "classify handles non-map input via fail-closed defaults" do
    classification = RiskyTaskClassifier.classify(:invalid)

    assert classification == %{
             "risky_task" => false,
             "stateful_migration" => false,
             "delivery_class" => "code_only",
             "delivery_sensitive" => false,
             "delivery_ambiguous" => false,
             "cost_signals" => [],
             "reasons" => []
           }
  end

  test "classify handles plain low-risk input" do
    classification =
      RiskyTaskClassifier.classify(%{
        "description" => "documentation update",
        "labels" => "not-a-list",
        "required_capabilities" => "not-a-list"
      })

    assert classification["risky_task"] == false
    assert classification["stateful_migration"] == false
    assert classification["delivery_class"] == "code_only"
    assert classification["cost_signals"] == []
    assert classification["reasons"] == []
  end

  test "classify emits deterministic delivery classes" do
    assert RiskyTaskClassifier.classify(description: "runtime repair requires canary smoke")["delivery_class"] ==
             "runtime_repair"

    assert RiskyTaskClassifier.classify(labels: ["operator-flow"])["delivery_class"] == "operator_flow"
  end

  test "risky_task? and stateful_migration? cover map and non-map branches" do
    assert RiskyTaskClassifier.risky_task?(%{"risky_task" => "yes"})
    refute RiskyTaskClassifier.risky_task?(:invalid)

    assert RiskyTaskClassifier.stateful_migration?(%{stateful_migration: 1})
    refute RiskyTaskClassifier.stateful_migration?(:invalid)
  end
end
