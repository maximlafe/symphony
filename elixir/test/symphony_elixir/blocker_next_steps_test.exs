defmodule SymphonyElixir.BlockerNextStepsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.BlockerNextSteps
  alias SymphonyElixir.RetryFailoverDecision

  test "renders workspace make target rejection from structured details" do
    lines =
      BlockerNextSteps.render_blocker(%{
        failure_class: "process_error",
        reason:
          {:workspace_capability_rejected,
           %{
             reason: :missing_make_target,
             command_class: :validation,
             target: "symphony-validate",
             workspace_cwd: "/tmp/workspace",
             repo_root: "/tmp/workspace",
             manifest_path: "/tmp/workspace/.symphony/cache/workspace-capability-manifest.json"
           }}
      })

    joined = Enum.join(lines, "\n")

    assert joined =~ "make target `symphony-validate`"
    assert joined =~ "routing labels or workspace bootstrap state"
    assert joined =~ "move the issue back to `In Progress`"
  end

  test "renders acceptance capability report without relying on free-form summary" do
    lines =
      BlockerNextSteps.render_blocker(%{
        reason:
          {:acceptance_capability_preflight_failed,
           %{
             "required_capabilities" => ["vps_ssh", "repo_validation"],
             "missing" => ["vps_ssh requires env `PROD_VPS_HOST`", "repo_validation requires one Makefile target: `symphony-validate`"]
           }}
      })

    joined = Enum.join(lines, "\n")

    assert joined =~ "required capabilities: `vps_ssh`, `repo_validation`"
    assert joined =~ "missing: vps_ssh requires env `PROD_VPS_HOST`"
    assert joined =~ "Run `make symphony-acceptance-preflight`"
  end

  test "renders workspace tool, policy, and non-repo guidance" do
    missing_tool =
      BlockerNextSteps.render_blocker(%{
        reason: {:workspace_capability_rejected, %{reason: "missing_tool", command_class: "runtime", tool: "rg"}}
      })

    assert Enum.join(missing_tool, "\n") =~ "tool `rg`"

    unsupported_policy =
      BlockerNextSteps.render_blocker(%{
        reason:
          {:workspace_capability_rejected,
           %{
             "reason" => "unsupported_approval_policy",
             "approval_policy" => "reject",
             "supported_approval_policies" => ["never", "on-request"]
           }}
      })

    assert Enum.join(unsupported_policy, "\n") =~ "supported values: `never`, `on-request`"

    non_repo =
      BlockerNextSteps.render_blocker(%{
        reason: {:workspace_capability_rejected, %{"reason" => "repo_root_not_found", "repo_root" => nil}}
      })

    assert Enum.join(non_repo, "\n") =~ "workspace resolves to the intended git repository"
  end

  test "renders invalid workspace blocker guidance" do
    lines = BlockerNextSteps.render_blocker(%{failure_class: "invalid_workspace", reason: :enoent})

    assert Enum.join(lines, "\n") =~ "workspace is created inside the intended git repository"
  end

  test "renders verification guard decision guidance from canonical decision metadata" do
    decision =
      RetryFailoverDecision.decide(%{
        validation_env_mismatch: %{
          reason: "free-form wording may change",
          log_fields: %{
            validation_guard_name: "runtime",
            verification_missing_items: "validation:targeted tests, artifact:runtime evidence",
            handoff_failure_kind: "hard_contract_failure"
          }
        }
      })

    lines = BlockerNextSteps.render_decision(decision, %{failure_class: "verification_guard_failed"})
    joined = Enum.join(lines, "\n")

    assert joined =~ "guard `runtime`"
    assert joined =~ "`validation:targeted tests`, `artifact:runtime evidence`"
    assert joined =~ "rerun the verification guard"
  end

  test "renders hard retry failover rule guidance" do
    decision = RetryFailoverDecision.decide(%{stale_workspace_head: %{reason: "stale"}})

    lines = BlockerNextSteps.render_decision(decision, %{})

    assert Enum.join(lines, "\n") =~ "Refresh the workspace from the current base branch"
  end

  test "renders remaining hard retry failover rule guidance" do
    retry_dedupe = RetryFailoverDecision.decide(%{retry_dedupe_hit: true})
    continuation = RetryFailoverDecision.decide(%{continuation_attempt_limit: true})
    unsafe = RetryFailoverDecision.decide(%{unsafe_preemption_required: true})
    account = RetryFailoverDecision.decide(%{account_unhealthy: true, checkpoint_available: false})

    assert retry_dedupe |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~
             "repeated retry signature"

    assert continuation |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~
             "Review the continuation attempts"

    assert unsafe |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~
             "unsafe preemption condition"

    assert account |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~
             "healthy Codex account"
  end

  test "renders generic validation mismatch and malformed inputs safely" do
    generic_validation =
      RetryFailoverDecision.decide(%{validation_env_mismatch: %{reason: "validation env changed"}})

    assert generic_validation |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~
             "validation environment or proof contract"

    guard_without_missing =
      RetryFailoverDecision.decide(%{
        validation_env_mismatch: %{
          reason: "guard failed",
          log_fields: %{validation_guard_name: "handoff"}
        }
      })

    assert guard_without_missing |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~
             "guard `handoff`"

    default_decision = RetryFailoverDecision.decide(%{})

    assert default_decision |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~ "manual triage"

    assert BlockerNextSteps.render_blocker(:bad_input) |> Enum.join("\n") =~ "manual triage"
    assert BlockerNextSteps.render_decision(:bad_decision, %{}) |> Enum.join("\n") =~ "manual triage"

    malformed_verification = %RetryFailoverDecision{
      selected_rule: :validation_env_mismatch,
      log_fields: nil
    }

    assert malformed_verification
           |> BlockerNextSteps.render_decision(%{failure_class: "verification_guard_failed"})
           |> Enum.join("\n") =~ "`unknown`"
  end

  test "renders empty and malformed structured metadata conservatively" do
    acceptance =
      BlockerNextSteps.render_blocker(%{
        reason: {:acceptance_capability_preflight_failed, %{"required_capabilities" => [], "missing" => []}}
      })

    assert Enum.join(acceptance, "\n") =~ "required capabilities: `none`; missing: none"

    policy =
      BlockerNextSteps.render_blocker(%{
        reason: {:workspace_capability_rejected, %{"reason" => "unsupported_approval_policy"}}
      })

    assert Enum.join(policy, "\n") =~ "supported values: `none`"

    verification_with_list =
      RetryFailoverDecision.decide(%{
        validation_env_mismatch: %{
          reason: "list missing",
          log_fields: %{verification_missing_items: ["artifact:runtime evidence"]}
        }
      })

    assert verification_with_list |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~
             "`artifact:runtime evidence`"

    verification_with_empty_string =
      RetryFailoverDecision.decide(%{
        validation_env_mismatch: %{
          reason: "empty missing",
          log_fields: %{verification_missing_items: ""}
        }
      })

    assert verification_with_empty_string |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~
             "`unknown`"

    verification_with_bad_missing =
      RetryFailoverDecision.decide(%{
        validation_env_mismatch: %{
          reason: "bad missing",
          log_fields: %{verification_missing_items: 123}
        }
      })

    assert verification_with_bad_missing |> BlockerNextSteps.render_decision(%{}) |> Enum.join("\n") =~
             "`unknown`"
  end

  test "unknown blocker falls back to conservative triage without destructive remediation" do
    lines = BlockerNextSteps.render_blocker(%{reason: {:unknown_failure, "opaque"}})
    joined = Enum.join(lines, "\n")

    assert joined =~ "manual triage"
    assert joined =~ "Do not delete the workspace"
    refute joined =~ "reset --hard"
    refute joined =~ "close the PR"
  end
end
