defmodule SymphonyElixir.AutoCompactionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AutoCompaction

  test "config parses disabled and enabled auto-compaction thresholds" do
    config = Config.settings!()
    assert config.codex.auto_compaction_max_total_tokens == nil
    assert config.codex.auto_compaction_max_safe_steps == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auto_compaction_max_total_tokens: 120_000,
      codex_auto_compaction_max_safe_steps: 12
    )

    config = Config.settings!()
    assert config.codex.auto_compaction_max_total_tokens == 120_000
    assert config.codex.auto_compaction_max_safe_steps == 12
  end

  test "decide compacts editing runs when total token threshold is exceeded at safe boundary" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_auto_compaction_max_total_tokens: 100)

    assert {:compact, decision} =
             AutoCompaction.decide(%{
               run_phase_before: :editing,
               safe_boundary: true,
               attempt_tokens: 101,
               safe_steps: 3
             })

    assert decision == %{
             continuation_reason: "auto_compaction",
             auto_compaction_signal: "total_tokens",
             auto_compaction_threshold: 100,
             auto_compaction_observed_total: 101,
             auto_compaction_safe_steps: 3
           }
  end

  test "decide compacts editing runs when safe-step threshold is exceeded at safe boundary" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_auto_compaction_max_safe_steps: 5)

    assert {:compact, decision} =
             AutoCompaction.decide(%{
               run_phase_before: :editing,
               safe_boundary: true,
               attempt_tokens: 1,
               safe_steps: 6
             })

    assert decision == %{
             continuation_reason: "auto_compaction",
             auto_compaction_signal: "safe_steps",
             auto_compaction_threshold: 5,
             auto_compaction_observed_total: 6,
             auto_compaction_safe_steps: 6
           }
  end

  test "decide skips outside editing safe boundaries" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auto_compaction_max_total_tokens: 100,
      codex_auto_compaction_max_safe_steps: 2
    )

    assert :skip =
             AutoCompaction.decide(%{
               run_phase_before: :waiting_external,
               safe_boundary: true,
               attempt_tokens: 999,
               safe_steps: 999
             })

    assert :skip =
             AutoCompaction.decide(%{
               run_phase_before: :editing,
               safe_boundary: false,
               attempt_tokens: 999,
               safe_steps: 999
             })
  end

  test "decide keeps running when thresholds are configured but not exceeded" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auto_compaction_max_total_tokens: 100,
      codex_auto_compaction_max_safe_steps: 5
    )

    assert :skip =
             AutoCompaction.decide(%{
               run_phase_before: "editing",
               safe_boundary: true,
               attempt_tokens: 100,
               safe_steps: 5
             })
  end

  test "decide skips non-map contexts and invalid observed counters" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_auto_compaction_max_total_tokens: 100)

    assert :skip = AutoCompaction.decide("not-a-map")

    assert :skip =
             AutoCompaction.decide(%{
               run_phase_before: :editing,
               safe_boundary: true,
               attempt_tokens: -10,
               safe_steps: -2
             })
  end
end
