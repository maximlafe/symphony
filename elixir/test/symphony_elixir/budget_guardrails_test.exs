defmodule SymphonyElixir.BudgetGuardrailsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.BudgetGuardrails

  test "config requires and parses token budget thresholds" do
    config = Config.settings!()
    assert config.codex.max_total_tokens == 300_000
    assert config.codex.max_tokens_per_attempt == 120_000

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_max_total_tokens: nil
    )

    assert_raise ArgumentError, ~r/codex.max_total_tokens can't be blank/, fn ->
      Config.settings!()
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_max_total_tokens: 120_000,
      codex_max_tokens_per_attempt: nil
    )

    assert_raise ArgumentError, ~r/codex.max_tokens_per_attempt can't be blank/, fn ->
      Config.settings!()
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_max_total_tokens: 120_000,
      codex_max_tokens_per_attempt: 45_000
    )

    config = Config.settings!()
    assert config.codex.max_total_tokens == 120_000
    assert config.codex.max_tokens_per_attempt == 45_000
  end

  test "per-issue budget wins over per-attempt budget and requires decision handoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_max_total_tokens: 100,
      codex_max_tokens_per_attempt: 10
    )

    assert {:handoff, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-472", state: "Rework"},
               attempt: 2,
               delay_type: nil,
               attempt_tokens: 50,
               issue_tokens_before_attempt: 75
             })

    assert decision.budget_reason == :max_total_tokens_exceeded
    assert decision.budget_threshold == 100
    assert decision.budget_observed_total == 125
    assert decision.budget_issue_total_tokens == 125
    assert decision.budget_decision == "handoff"
    assert decision.checkpoint_type == "decision"
    assert decision.risk_level == "medium"
  end

  test "per-attempt budget downshifts implementation to configured cheaper implementation default" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_implementation: %{model: "gpt-5.3-codex", effort: "medium"},
        escalated_implementation: %{model: "gpt-5.3-codex", effort: "high"}
      },
      codex_cost_policy: %{
        stage_defaults: %{implementation: "cheap_implementation"}
      }
    )

    assert {:downshift, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-472", state: "In Progress"},
               attempt: 1,
               delay_type: nil,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               current_cost_profile_key: "escalated_implementation"
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.budget_threshold == 10
    assert decision.budget_observed_total == 12
    assert decision.cost_stage == "implementation"
    assert decision.budget_current_cost_profile_key == "escalated_implementation"
    assert decision.budget_next_cost_profile_key == "cheap_implementation"
    assert decision.budget_downshift_rule == "implementation_to_implementation_default"
    assert decision.budget_decision == "downshift"
  end

  test "per-attempt budget in rework stage does not downshift to implementation default" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_implementation: %{model: "gpt-5.3-codex", effort: "medium"},
        escalated_implementation: %{model: "gpt-5.3-codex", effort: "high"}
      },
      codex_cost_policy: %{
        stage_defaults: %{implementation: "cheap_implementation", rework: "escalated_implementation"},
        signal_escalations: %{rework: "escalated_implementation"}
      }
    )

    assert {:handoff, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-472", state: "Rework"},
               attempt: 1,
               delay_type: nil,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.cost_stage == "rework"
    assert decision.budget_current_cost_profile_key == "escalated_implementation"
    assert decision.budget_decision == "handoff"
    refute Map.has_key?(decision, :budget_next_cost_profile_key)
    refute Map.has_key?(decision, :budget_downshift_rule)
  end

  test "per-attempt budget in rework stage downshifts only to explicit cheaper rework default" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_implementation: %{model: "gpt-5.3-codex", effort: "medium"},
        cheap_rework: %{model: "gpt-5.3-codex", effort: "medium"},
        escalated_rework: %{model: "gpt-5.3-codex", effort: "high"}
      },
      codex_cost_policy: %{
        stage_defaults: %{implementation: "cheap_implementation", rework: "cheap_rework"},
        signal_escalations: %{rework: "escalated_rework"}
      }
    )

    assert {:downshift, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-472", state: "Rework"},
               attempt: 1,
               delay_type: nil,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.cost_stage == "rework"
    assert decision.budget_current_cost_profile_key == "escalated_rework"
    assert decision.budget_next_cost_profile_key == "cheap_rework"
    assert decision.budget_downshift_rule == "rework_to_rework_default"
    assert decision.budget_decision == "downshift"
  end

  test "first over-budget planning attempt on cheapest profile gets bootstrap retry chance" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_implementation: %{model: "gpt-5.3-codex", effort: "medium"},
        cheap_planning: %{model: "gpt-5.4", effort: "xhigh"},
        handoff_profile: %{model: "gpt-5.3-codex", effort: "high"}
      },
      codex_cost_policy: %{
        stage_defaults: %{
          planning: "cheap_planning",
          implementation: "cheap_implementation",
          handoff: "handoff_profile"
        }
      }
    )

    assert {:allow, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-472", state: "Spec Review"},
               attempt: 1,
               delay_type: nil,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               current_cost_profile_key: "cheap_planning"
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.cost_stage == "planning"
    assert decision.budget_current_cost_profile_key == "cheap_planning"
    assert decision.budget_decision == "allow"
    assert decision.budget_signal_role == "bootstrap"
    refute Map.has_key?(decision, :budget_next_cost_profile_key)
    refute Map.has_key?(decision, :budget_downshift_rule)
  end

  test "first over-budget planning attempt with explicit unavailable checkpoint still gets bootstrap retry chance" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_planning: %{model: "gpt-5.4", effort: "xhigh"}
      },
      codex_cost_policy: %{
        stage_defaults: %{planning: "cheap_planning"}
      }
    )

    unavailable_checkpoint =
      progress_checkpoint(
        resume_ready: false,
        workpad_digest: "workpad-bootstrap",
        workspace_diff_fingerprint: "workspace-bootstrap",
        validation_bundle_fingerprint: "validation:bootstrap",
        changed_files: ["workpad.md"]
      )

    assert {:allow, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-567", state: "Spec Review"},
               attempt: 1,
               delay_type: nil,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               current_cost_profile_key: "cheap_planning",
               previous_resume_checkpoint: unavailable_checkpoint,
               resume_checkpoint: unavailable_checkpoint
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.cost_stage == "planning"
    assert decision.budget_current_cost_profile_key == "cheap_planning"
    assert decision.budget_decision == "allow"
    assert decision.budget_signal_role == "bootstrap"
    assert decision.progress_status == "unavailable"
    assert decision.progress_repeat_count == 0
    refute Map.has_key?(decision, :budget_next_cost_profile_key)
    refute Map.has_key?(decision, :budget_downshift_rule)
  end

  test "per-attempt budget in handoff stage does not downshift to implementation default" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_implementation: %{model: "gpt-5.3-codex", effort: "medium"},
        cheap_planning: %{model: "gpt-5.4", effort: "xhigh"},
        handoff_profile: %{model: "gpt-5.3-codex", effort: "high"}
      },
      codex_cost_policy: %{
        stage_defaults: %{
          planning: "cheap_planning",
          implementation: "cheap_implementation",
          handoff: "handoff_profile"
        }
      }
    )

    assert {:handoff, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-472", state: "Merging"},
               attempt: 1,
               delay_type: nil,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.cost_stage == "handoff"
    assert decision.budget_current_cost_profile_key == "handoff_profile"
    assert decision.budget_decision == "handoff"
    refute Map.has_key?(decision, :budget_next_cost_profile_key)
    refute Map.has_key?(decision, :budget_downshift_rule)
  end

  test "first over-budget implementation attempt on cheapest profile gets bootstrap retry chance" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_implementation: %{model: "gpt-5.3-codex", effort: "medium"}
      },
      codex_cost_policy: %{
        stage_defaults: %{implementation: "cheap_implementation"}
      }
    )

    assert {:allow, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-472", state: "In Progress"},
               attempt: 1,
               delay_type: nil,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               current_cost_profile_key: "cheap_implementation"
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.cost_stage == "implementation"
    assert decision.budget_current_cost_profile_key == "cheap_implementation"
    assert decision.budget_decision == "allow"
    assert decision.budget_signal_role == "bootstrap"
    refute Map.has_key?(decision, :budget_next_cost_profile_key)
    refute Map.has_key?(decision, :budget_downshift_rule)
  end

  test "bootstrap retry chance is consumed after first over-budget implementation attempt" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_implementation: %{model: "gpt-5.3-codex", effort: "medium"}
      },
      codex_cost_policy: %{
        stage_defaults: %{implementation: "cheap_implementation"}
      }
    )

    assert {:handoff, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-472", state: "In Progress"},
               attempt: 2,
               delay_type: :continuation,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               current_cost_profile_key: "cheap_implementation"
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.cost_stage == "implementation"
    assert decision.budget_current_cost_profile_key == "cheap_implementation"
    assert decision.budget_decision == "handoff"
    refute Map.has_key?(decision, :budget_next_cost_profile_key)
    refute Map.has_key?(decision, :budget_downshift_rule)
  end

  test "bootstrap retry chance is consumed after first over-budget planning attempt" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_planning: %{model: "gpt-5.4", effort: "xhigh"}
      },
      codex_cost_policy: %{
        stage_defaults: %{planning: "cheap_planning"}
      }
    )

    assert {:handoff, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-472", state: "Spec Review"},
               attempt: 2,
               delay_type: :continuation,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               current_cost_profile_key: "cheap_planning"
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.cost_stage == "planning"
    assert decision.budget_current_cost_profile_key == "cheap_planning"
    assert decision.budget_decision == "handoff"
    refute Map.has_key?(decision, :budget_next_cost_profile_key)
    refute Map.has_key?(decision, :budget_downshift_rule)
  end

  test "bootstrap retry chance is consumed after first over-budget planning attempt with explicit unavailable checkpoint" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_planning: %{model: "gpt-5.4", effort: "xhigh"}
      },
      codex_cost_policy: %{
        stage_defaults: %{planning: "cheap_planning"}
      }
    )

    unavailable_checkpoint =
      progress_checkpoint(
        resume_ready: false,
        workpad_digest: "workpad-bootstrap",
        workspace_diff_fingerprint: "workspace-bootstrap",
        validation_bundle_fingerprint: "validation:bootstrap",
        changed_files: ["workpad.md"]
      )

    assert {:handoff, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-567", state: "Spec Review"},
               attempt: 2,
               delay_type: :continuation,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               current_cost_profile_key: "cheap_planning",
               previous_resume_checkpoint: unavailable_checkpoint,
               resume_checkpoint: unavailable_checkpoint
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.cost_stage == "planning"
    assert decision.budget_current_cost_profile_key == "cheap_planning"
    assert decision.budget_decision == "handoff"
    assert decision.progress_status == "unavailable"
    assert decision.progress_repeat_count == 0
    refute Map.has_key?(decision, :budget_next_cost_profile_key)
    refute Map.has_key?(decision, :budget_downshift_rule)
  end

  test "per-attempt budget with changed workpad surface becomes allow signal" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_max_tokens_per_attempt: 10
    )

    assert {:allow, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-560", state: "In Progress"},
               attempt: 2,
               delay_type: :continuation,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               previous_resume_checkpoint:
                 progress_checkpoint(
                   workpad_digest: "workpad-old",
                   workspace_diff_fingerprint: "workspace-stable",
                   validation_bundle_fingerprint: "validation:test",
                   changed_files: ["elixir/lib/symphony_elixir/orchestrator.ex"]
                 ),
               resume_checkpoint:
                 progress_checkpoint(
                   workpad_digest: "workpad-new",
                   workspace_diff_fingerprint: "workspace-stable",
                   validation_bundle_fingerprint: "validation:test",
                   changed_files: ["elixir/lib/symphony_elixir/orchestrator.ex"]
                 )
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.budget_decision == "allow"
    assert decision.budget_signal_role == "signal"
    assert decision.progress_status == "changed"
    assert decision.progress_repeat_count == 1
    assert is_binary(decision.progress_fingerprint)
  end

  test "per-attempt budget with changed validation surface becomes allow signal" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_max_tokens_per_attempt: 10
    )

    assert {:allow, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-560", state: "In Progress"},
               attempt: 3,
               delay_type: nil,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               previous_resume_checkpoint:
                 progress_checkpoint(
                   workpad_digest: "workpad-stable",
                   workspace_diff_fingerprint: "workspace-stable",
                   validation_bundle_fingerprint: "validation:test",
                   changed_files: ["elixir/lib/symphony_elixir/retry_failover_decision.ex"]
                 ),
               resume_checkpoint:
                 progress_checkpoint(
                   workpad_digest: "workpad-stable",
                   workspace_diff_fingerprint: "workspace-stable",
                   validation_bundle_fingerprint: "validation:repo-validate",
                   changed_files: ["elixir/lib/symphony_elixir/retry_failover_decision.ex"]
                 )
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.budget_decision == "allow"
    assert decision.progress_status == "changed"
    assert decision.progress_repeat_count == 1
    assert is_binary(decision.progress_fingerprint)
  end

  test "per-attempt budget with repeated explicit surface remains handoff even when cheaper profile exists" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command_template: "codex --config model_reasoning_effort={{effort}} --model {{model}} app-server",
      codex_max_tokens_per_attempt: 10,
      codex_cost_profiles: %{
        cheap_implementation: %{model: "gpt-5.3-codex", effort: "medium"},
        escalated_implementation: %{model: "gpt-5.3-codex", effort: "high"}
      },
      codex_cost_policy: %{
        stage_defaults: %{implementation: "cheap_implementation"}
      }
    )

    previous_checkpoint =
      progress_checkpoint(
        workpad_digest: "workpad-stable",
        workspace_diff_fingerprint: "workspace-stable",
        validation_bundle_fingerprint: "validation:test",
        changed_files: ["elixir/lib/symphony_elixir/budget_guardrails.ex"]
      )

    assert {:handoff, decision} =
             BudgetGuardrails.decide(%{
               issue: %Issue{id: "issue-budget", identifier: "LET-560", state: "In Progress"},
               attempt: 2,
               delay_type: :continuation,
               attempt_tokens: 12,
               issue_tokens_before_attempt: 0,
               current_cost_profile_key: "escalated_implementation",
               previous_resume_checkpoint: previous_checkpoint,
               resume_checkpoint: previous_checkpoint
             })

    assert decision.budget_reason == :max_tokens_per_attempt_exceeded
    assert decision.budget_decision == "handoff"
    assert decision.progress_status == "repeated"
    assert decision.progress_repeat_count == 2
    assert is_binary(decision.progress_fingerprint)
  end

  test "normal continuation exit over per-attempt budget blocks without retrying" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-budget-continuation"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_max_tokens_per_attempt: 10
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :ContinuationBudgetOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "LET-472",
        issue: %Issue{id: issue_id, identifier: "LET-472", state: "In Progress"},
        codex_total_tokens: 12,
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 1_500
      assert blocker_body =~ "selected_rule: `budget_exceeded_per_attempt_handoff`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "checkpoint_type: `decision`"
      assert blocker_body =~ "risk_level: `medium`"
      assert blocker_body =~ "max_tokens_per_attempt_exceeded"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      state =
        wait_for_orchestrator_state(pid, fn state ->
          not Map.has_key?(state.retry_attempts, issue_id) and not MapSet.member?(state.claimed, issue_id)
        end)

      refute Map.has_key?(state.retry_attempts, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "rework retry over cumulative issue budget blocks without adding retry entry" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-budget-rework"
    ref = make_ref()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_max_total_tokens: 20
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :ReworkBudgetOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "LET-472",
        issue: %Issue{id: issue_id, identifier: "LET-472", state: "Rework"},
        codex_total_tokens: 12,
        issue_token_total: 10,
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {:DOWN, ref, :process, self(), :boom})

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 1_500
      assert blocker_body =~ "selected_rule: `budget_exceeded_cumulative`"
      assert blocker_body =~ "selected_action: `stop_with_classified_handoff`"
      assert blocker_body =~ "max_total_tokens_exceeded"
      assert blocker_body =~ "observed_total: `22`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      state =
        wait_for_orchestrator_state(pid, fn state ->
          not Map.has_key?(state.retry_attempts, issue_id) and not MapSet.member?(state.claimed, issue_id)
        end)

      refute Map.has_key?(state.retry_attempts, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "token usage update over issue budget preempts running worker and blocks" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-budget-token-update"
    worker = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(worker)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_max_total_tokens: 15
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :TokenUpdateBudgetOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: worker,
        ref: ref,
        identifier: "LET-472",
        issue: %Issue{id: issue_id, identifier: "LET-472", state: "In Progress"},
        session_id: nil,
        codex_total_tokens: 0,
        issue_token_total: 10,
        codex_last_reported_total_tokens: 0,
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, {
        :codex_worker_update,
        issue_id,
        %{
          event: "thread/tokenUsage/updated",
          timestamp: DateTime.utc_now(),
          tokenUsage: %{total: %{total_tokens: 8}}
        }
      })

      assert_receive {:memory_tracker_comment, ^issue_id, blocker_body}, 1_500
      assert blocker_body =~ "max_total_tokens_exceeded"
      assert blocker_body =~ "observed_total: `18`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Blocked"}, 500

      state =
        wait_for_orchestrator_state(pid, fn state ->
          not Map.has_key?(state.running, issue_id) and not Map.has_key?(state.retry_attempts, issue_id)
        end)

      refute Map.has_key?(state.running, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(worker) do
        Process.exit(worker, :kill)
      end
    end
  end

  defp wait_for_orchestrator_state(pid, predicate, attempts \\ 40)

  defp wait_for_orchestrator_state(pid, predicate, attempts) when attempts > 0 do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      Process.sleep(25)
      wait_for_orchestrator_state(pid, predicate, attempts - 1)
    end
  end

  defp wait_for_orchestrator_state(pid, _predicate, 0), do: :sys.get_state(pid)

  defp progress_checkpoint(opts) do
    %{
      "resume_ready" => Keyword.get(opts, :resume_ready, true),
      "workpad_digest" => Keyword.get(opts, :workpad_digest),
      "workspace_diff_fingerprint" => Keyword.get(opts, :workspace_diff_fingerprint),
      "changed_files" => Keyword.get(opts, :changed_files, []),
      "active_validation_snapshot" => %{
        "validation_bundle_fingerprint" => Keyword.get(opts, :validation_bundle_fingerprint)
      }
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
