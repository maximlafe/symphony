defmodule SymphonyElixir.OrchestratorRoutingMetadataTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.RoutingMetadata

  test "returns original entry when routing metadata inputs are invalid" do
    assert :not_a_map == RoutingMetadata.apply(:not_a_map, %{})
    assert %{} == RoutingMetadata.apply(%{}, :not_a_map)
  end

  test "keeps parity fields unset when intended metadata is absent" do
    entry = %{existing: true}
    update = %{"payload" => %{"params" => %{}}}

    updated = RoutingMetadata.apply(entry, update)

    assert updated.existing
    refute Map.has_key?(updated, :routing_parity_status)
    refute Map.has_key?(updated, :routing_parity_reason)
    refute Map.has_key?(updated, :observed_model)
    refute Map.has_key?(updated, :observed_effort)
  end

  test "marks routing parity as observed_unavailable when intended metadata is present without observed values" do
    updated =
      RoutingMetadata.apply(%{}, %{
        "codex_model" => "gpt-5.3-codex",
        "codex_effort" => "medium"
      })

    assert updated.codex_model == "gpt-5.3-codex"
    assert updated.codex_effort == "medium"
    assert updated.routing_parity_status == "observed_unavailable"
    assert updated.routing_parity_reason == "observed routing metadata unavailable"
  end

  test "uses explicit observed metadata and reports parity ok when intended and observed match" do
    updated =
      RoutingMetadata.apply(%{}, %{
        codex_model: "gpt-5.3-codex",
        codex_effort: "medium",
        observed_model: " gpt-5.3-codex ",
        observed_effort: " medium ",
        observed_signal_source: "update",
        cost_signals: [" latency_guard ", :routing_lock, "", 123]
      })

    assert updated.observed_model == "gpt-5.3-codex"
    assert updated.observed_effort == "medium"
    assert updated.observed_signal_source == "update"
    assert updated.cost_signals == ["latency_guard", "routing_lock"]
    assert updated.routing_parity_status == "ok"
    assert updated.routing_parity_reason == "observed routing matches intended model/effort"
  end

  test "extracts observed model and effort from payload paths and reports mismatch details" do
    updated =
      RoutingMetadata.apply(%{}, %{
        "codex_model" => "gpt-5.3-codex",
        "codex_effort" => "medium",
        "payload" => %{
          "params" => %{
            "usage" => %{
              "model" => "gpt-5.4",
              "reasoning_effort" => "high"
            }
          }
        },
        "command_source" => " cost_profile "
      })

    assert updated.command_source == "cost_profile"
    assert updated.observed_model == "gpt-5.4"
    assert updated.observed_effort == "high"
    assert updated.observed_signal_source == "payload"
    assert updated.routing_parity_status == "mismatch"

    assert updated.routing_parity_reason ==
             "model expected=gpt-5.3-codex observed=gpt-5.4; effort expected=medium observed=high"
  end

  test "falls back to usage source and supports mixed atom/binary key access" do
    updated =
      RoutingMetadata.apply(%{}, %{
        :cost_profile_key => "cheap_implementation",
        "cost_profile_reason" => "stage_default:implementation",
        "cost_stage" => "implementation",
        "cost_signals" => "not-a-list",
        "codex_model" => "gpt-5.4",
        "codex_effort" => "high",
        "payload" => :not_a_map,
        :usage => %{
          :model => "gpt-5.4",
          :model_reasoning_effort => "high"
        }
      })

    assert updated.cost_profile_key == "cheap_implementation"
    assert updated.cost_profile_reason == "stage_default:implementation"
    assert updated.cost_stage == "implementation"
    refute Map.has_key?(updated, :cost_signals)
    assert updated.observed_model == "gpt-5.4"
    assert updated.observed_effort == "high"
    assert updated.observed_signal_source == "usage"
    assert updated.routing_parity_status == "ok"
  end

  test "uses update source when observed metadata is present directly on update payload" do
    updated =
      RoutingMetadata.apply(%{}, %{
        "codex_model" => "gpt-5.4",
        "observed_model" => "gpt-5.4",
        "observed_effort" => "high",
        "observed_signal_source" => " "
      })

    assert updated.observed_model == "gpt-5.4"
    assert updated.observed_effort == "high"
    assert updated.observed_signal_source == "update"
    assert updated.routing_parity_status == "ok"
  end

  test "reports mismatch only for intended model when intended effort is absent" do
    updated =
      RoutingMetadata.apply(%{}, %{
        "codex_model" => "gpt-5.3-codex",
        "payload" => %{"model_slug" => "gpt-5.4"}
      })

    assert updated.observed_model == "gpt-5.4"
    assert updated.observed_signal_source == "payload"
    assert updated.routing_parity_status == "mismatch"
    assert updated.routing_parity_reason == "model expected=gpt-5.3-codex observed=gpt-5.4"
  end
end
