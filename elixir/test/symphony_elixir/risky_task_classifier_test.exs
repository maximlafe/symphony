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

    assert classification["risk_class"] == "risky"
    assert "persistence_migration_or_identifier" in classification["risk_signals"]
    assert "security_or_destructive_change" in classification["risk_signals"]
    assert "stateful_proof" in classification["required_validation_families"]
    assert "repo_validation" in classification["required_validation_families"]
    assert classification["risky_task"] == true
    assert classification["stateful_migration"] == true
    assert classification["cost_signals"] == ["risky_task"]
    assert Enum.any?(classification["reasons"], &String.contains?(&1, "stateful"))
    assert Enum.any?(classification["reasons"], &String.contains?(&1, "high-risk"))
  end

  test "classify detects canonical risk signals required for workflow routing" do
    classification =
      RiskyTaskClassifier.classify(%{
        "description" => "Staged rollout with backward compatibility, retry state machine ordering, and adjacent ticket ambiguity.",
        "labels" => ["rollout", "state-machine"],
        "blocked_by" => [%{"identifier" => "LET-900", "state" => "In Progress"}]
      })

    assert classification["risk_class"] == "risky"
    assert "backward_compatibility_or_staged_rollout" in classification["risk_signals"]
    assert "retry_state_machine_or_ordering_sensitive_logic" in classification["risk_signals"]
    assert "adjacent_ticket_ambiguity_or_neighboring_active_work" in classification["risk_signals"]
    assert "runtime_smoke" in classification["required_validation_families"]
    assert "Dependencies" in classification["required_spec_sections"]
  end

  test "classify handles mixed blockers and non-string blocker state safely" do
    adjacent_classification =
      RiskyTaskClassifier.classify(%{
        "description" => "adjacent ticket review",
        "labels" => ["adjacent"],
        "blocked_by" => [%{"state" => 123}, :ignored]
      })

    assert adjacent_classification["risk_class"] == "risky"
    assert "adjacent_ticket_ambiguity_or_neighboring_active_work" in adjacent_classification["risk_signals"]

    fallback_state_classification =
      RiskyTaskClassifier.classify(%{
        "description" => "plain update",
        "labels" => [],
        "blocked_by" => [%{"state" => 123}]
      })

    assert fallback_state_classification["risk_class"] == "standard"
  end

  test "classify handles non-map input via fail-closed defaults" do
    classification = RiskyTaskClassifier.classify(:invalid)
    assert classification["risk_class"] == "standard"
    assert classification["risk_signals"] == []
    assert classification["required_validation_families"] == []
    assert classification["required_spec_sections"] == []
    assert classification["risky_task"] == false
    assert classification["stateful_migration"] == false
    assert classification["cost_signals"] == []
    assert classification["reasons"] == []
  end

  test "classify handles plain low-risk input" do
    classification =
      RiskyTaskClassifier.classify(%{
        "description" => "documentation update",
        "labels" => "not-a-list",
        "required_capabilities" => "not-a-list"
      })

    assert classification["risk_class"] == "standard"
    assert classification["risk_signals"] == []
    assert classification["risky_task"] == false
    assert classification["stateful_migration"] == false
    assert classification["cost_signals"] == []
    assert classification["reasons"] == []
  end

  test "risky_task? and stateful_migration? cover map and non-map branches" do
    assert RiskyTaskClassifier.risky_task?(%{"risky_task" => "yes"})
    refute RiskyTaskClassifier.risky_task?(:invalid)

    assert RiskyTaskClassifier.stateful_migration?(%{stateful_migration: 1})
    refute RiskyTaskClassifier.stateful_migration?(:invalid)
  end
end
