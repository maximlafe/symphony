defmodule SymphonyElixir.RunPhaseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunPhase

  test "phase helpers normalize strings, nils, and reportable flags" do
    assert RunPhase.phase_label(nil) == nil
    assert RunPhase.phase_label("waiting ci") == "waiting CI"
    assert RunPhase.phase_label(:full_validate) == "full validate"
    assert RunPhase.phase_label(:verification) == "verification"
    assert RunPhase.reportable_phase?("publishing PR")
    assert RunPhase.reportable_phase?("verification")
    refute RunPhase.reportable_phase?("editing")

    assert RunPhase.transition_reportable?(
             %{run_phase: :editing},
             %{run_phase: :waiting_ci}
           )

    refute RunPhase.transition_reportable?(
             %{run_phase: :waiting_ci},
             %{run_phase: :waiting_ci}
           )
  end

  test "apply_update classifies commands across run phases" do
    timestamp = DateTime.utc_now()

    assert apply_update_for_command("   ", timestamp).run_phase == :editing
    assert apply_update_for_command("echo hi", timestamp).run_phase == :editing
    assert apply_update_for_command("make symphony-live-e2e", timestamp).run_phase == :waiting_external
    assert apply_update_for_command("launch-app --headless", timestamp).run_phase == :runtime_proof
    assert apply_update_for_command("pytest tests/unit/test_run_phase.py", timestamp).run_phase == :targeted_tests
    assert apply_update_for_command("echo ok && make test", timestamp).run_phase == :full_validate
    assert apply_update_for_command("git push origin HEAD", timestamp).run_phase == :publishing_pr
  end

  test "apply_update parses command payload variants and resets steps on completion" do
    timestamp = DateTime.utc_now()

    approval_update = %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "item/commandExecution/requestApproval",
        "params" => %{
          "command" => %{"parsedCmd" => "git", "args" => ["push", "origin", "HEAD"]}
        }
      }
    }

    list_update = %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "execCommandApproval",
        "params" => %{
          "args" => ["pytest", "tests/smoke/test_run_phase.py"]
        }
      }
    }

    invalid_command_update = %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"cmd" => 123}
      }
    }

    invalid_args_update = %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"args" => [123]}
      }
    }

    mapped_command_update = %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "item/commandExecution/requestApproval",
        "params" => %{
          "command" => %{"command" => "make symphony-live-e2e"}
        }
      }
    }

    approval_entry = RunPhase.apply_update(base_entry(), approval_update)
    assert approval_entry.run_phase == :publishing_pr
    assert approval_entry.current_command == "git push origin HEAD"

    list_entry = RunPhase.apply_update(base_entry(), list_update)
    assert list_entry.run_phase == :targeted_tests
    assert list_entry.current_command == "pytest tests/smoke/test_run_phase.py"

    invalid_command_entry = RunPhase.apply_update(base_entry(), invalid_command_update)
    assert invalid_command_entry.run_phase == :editing
    assert invalid_command_entry.current_command == nil

    invalid_args_entry = RunPhase.apply_update(base_entry(), invalid_args_update)
    assert invalid_args_entry.run_phase == :editing
    assert invalid_args_entry.current_command == nil

    mapped_command_entry = RunPhase.apply_update(base_entry(), mapped_command_update)
    assert mapped_command_entry.run_phase == :waiting_external
    assert mapped_command_entry.current_command == "make symphony-live-e2e"

    tool_started =
      RunPhase.apply_update(base_entry(), %{
        event: :tool_call_started,
        timestamp: timestamp,
        payload: %{"params" => %{"tool" => "mcp__playwright__browser_wait_for"}}
      })

    assert tool_started.run_phase == :waiting_external
    assert tool_started.current_command == nil
    assert tool_started.external_step == "mcp__playwright__browser_wait_for"

    tool_finished =
      RunPhase.apply_update(tool_started, %{
        event: :unsupported_tool_call,
        timestamp: DateTime.add(timestamp, 1, :second)
      })

    assert tool_finished.run_phase == :editing
    assert tool_finished.external_step == nil

    command_finished =
      RunPhase.apply_update(
        %{base_entry() | current_command: "make symphony-validate", run_phase: :full_validate},
        %{
          event: :notification,
          timestamp: DateTime.add(timestamp, 2, :second),
          payload: %{"method" => "codex/event/exec_command_end"}
        }
      )

    assert command_finished.run_phase == :editing
    assert command_finished.current_command == nil
  end

  test "snapshot_fields derives heartbeat state and phase fallbacks" do
    now = DateTime.utc_now()

    assert RunPhase.snapshot_fields(%{started_at: now}, now, 0).activity_state == "alive"

    assert RunPhase.snapshot_fields(
             %{started_at: now, last_codex_timestamp: DateTime.add(now, -3, :second)},
             now,
             1_000
           ).activity_state == "stalled"

    assert RunPhase.snapshot_fields(%{}, now, 1_000).activity_state == "alive"

    assert RunPhase.snapshot_fields(
             %{started_at: now, external_step: "mcp__playwright__browser_wait_for"},
             now,
             1_000
           ).run_phase == "waiting external"

    assert RunPhase.snapshot_fields(
             %{started_at: now, external_step: "symphony_handoff_check"},
             now,
             1_000
           ).run_phase == "verification"

    assert RunPhase.snapshot_fields(
             %{started_at: now, external_step: "exec_wait"},
             now,
             1_000
           ).run_phase == "waiting external"

    assert RunPhase.snapshot_fields(
             %{started_at: now, external_step: "linear_graphql"},
             now,
             1_000
           ).run_phase == "editing"

    assert RunPhase.snapshot_fields(
             %{started_at: now, current_command: 123, external_step: 456},
             now,
             1_000
           ).run_phase == "editing"

    assert RunPhase.snapshot_fields(
             %{started_at: now, current_command: "   "},
             now,
             1_000
           ).run_phase == "editing"
  end

  test "phase comments include details and notices survive until phase change" do
    timestamp = DateTime.utc_now()

    update_with_notice = %{
      event: :notification,
      timestamp: timestamp,
      raw: "launch-app missing, using local HTTP/UI fallback",
      payload: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{
          "msg" => %{
            "command" => "launch-app",
            "payload" => %{"delta" => %{"ignored" => true}}
          }
        }
      }
    }

    entry_with_notice = RunPhase.apply_update(base_entry(), update_with_notice)
    assert entry_with_notice.run_phase == :runtime_proof
    assert entry_with_notice.operational_notice == "launch-app missing, using local HTTP/UI fallback"

    comment =
      RunPhase.phase_signal_comment(%{
        run_phase: :runtime_proof,
        current_command: "launch-app",
        external_step: "mcp__playwright__browser_wait_for",
        operational_notice: entry_with_notice.operational_notice
      })

    assert comment =~ "runtime proof"
    assert comment =~ "command"
    assert comment =~ "external_step"
    assert comment =~ "notice"

    assert RunPhase.mark_phase_reported(%{run_phase: :runtime_proof}).last_reported_phase == :runtime_proof
    assert RunPhase.phase_signal_comment(%{run_phase: :editing}) == nil

    cleared_notice =
      RunPhase.apply_update(entry_with_notice, %{
        event: :notification,
        timestamp: DateTime.add(timestamp, 1, :second),
        payload: %{
          "method" => "codex/event/exec_command_begin",
          "params" => %{"msg" => %{"command" => "git push origin HEAD"}}
        }
      })

    assert cleared_notice.run_phase == :publishing_pr
    assert cleared_notice.operational_notice == nil
  end

  test "milestone helpers classify transitions and normalize milestone inputs" do
    assert RunPhase.transition_milestones(%{run_phase: :editing}, %{run_phase: :verification}) ==
             [:code_ready, :validation_running]

    assert RunPhase.transition_milestones(%{run_phase: :targeted_tests}, %{run_phase: :full_validate}) ==
             [:validation_running]

    assert RunPhase.transition_milestones(%{run_phase: :editing}, %{run_phase: :publishing_pr}) ==
             [:pr_opened]

    assert RunPhase.transition_milestones(:bad, :shape) == []

    assert RunPhase.sort_milestones([:handoff_ready, :code_ready, :unknown, :code_ready]) ==
             [:code_ready, :handoff_ready]

    assert RunPhase.sort_milestones(:not_a_list) == []

    assert RunPhase.milestone_label(nil) == nil
    assert RunPhase.milestone_label("PR-opened") == "PR-opened"
    assert RunPhase.milestone_label(123) == nil

    milestone_comment = RunPhase.milestone_comment(:code_ready, %{current_command: "mix test"})
    assert milestone_comment =~ "Symphony milestone"
    assert milestone_comment =~ "code-ready"
    assert milestone_comment =~ "mix test"

    default_comment = RunPhase.milestone_comment(:validation_running)
    assert default_comment =~ "validation-running"
  end

  test "milestone reported and pending sets handle invalid and legacy shapes" do
    base = %{
      reported_milestones: [:code_ready],
      pending_milestones: [:validation_running]
    }

    assert RunPhase.milestone_reported?(base, :code_ready)
    refute RunPhase.milestone_reported?(%{reported_milestones: :bad_shape}, :code_ready)

    updated = RunPhase.mark_milestone_reported(base, :pr_opened)
    assert RunPhase.milestone_reported?(updated, :pr_opened)

    unchanged_reported = RunPhase.mark_milestone_reported(updated, :unknown)
    assert unchanged_reported == updated

    pending = RunPhase.mark_milestone_pending(base, :ci_failed)
    assert MapSet.member?(pending.pending_milestones, :ci_failed)

    unchanged_pending = RunPhase.mark_milestone_pending(pending, :unknown)
    assert unchanged_pending == pending

    cleared = RunPhase.clear_pending_milestone(pending, :validation_running)
    refute MapSet.member?(cleared.pending_milestones, :validation_running)

    unchanged_clear = RunPhase.clear_pending_milestone(cleared, :unknown)
    assert unchanged_clear == cleared
  end

  defp apply_update_for_command(command, timestamp) do
    RunPhase.apply_update(base_entry(), %{
      event: :notification,
      timestamp: timestamp,
      payload: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => command}}
      }
    })
  end

  defp base_entry do
    RunPhase.initialize(%{started_at: DateTime.utc_now()})
  end
end
