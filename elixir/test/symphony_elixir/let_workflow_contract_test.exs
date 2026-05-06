defmodule SymphonyElixir.LetWorkflowContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  @let_workflow_path Path.expand("../../../workflows/letterl/maxime/let.WORKFLOW.md", __DIR__)
  @default_workflow_path Path.expand("../../WORKFLOW.md", __DIR__)
  @research_skill_path Path.expand("../../../.agents/skills/research-mode/SKILL.md", __DIR__)
  @plan_skill_path Path.expand("../../../.agents/skills/plan-mode/SKILL.md", __DIR__)
  @execute_skill_path Path.expand("../../../.agents/skills/execute-mode/SKILL.md", __DIR__)

  test "LET workflow routes todo by mode labels and keeps spec prep optional" do
    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(@let_workflow_path)

    assert get_in(config, ["tracker", "team_key"]) == "LET"

    assert get_in(config, ["tracker", "active_states"]) == [
             "Todo",
             "Spec Prep",
             "In Progress",
             "Merging",
             "Rework"
           ]

    refute "Spec Review" in get_in(config, ["tracker", "active_states"])

    assert prompt =~ "`mode:research`"
    assert prompt =~ "`mode:plan`"
    assert prompt =~ "`delivery:tdd`"
    assert prompt =~ "нормализовать `delivery:tdd`"
    assert prompt =~ "без `mode:*` и при execute-ready контракте -> сразу переводи в `In Progress`"
    assert prompt =~ "без `mode:*` и при неясной готовности к исполнению -> переводи в `Spec Prep` как legacy `plan-mode` путь"
    assert prompt =~ "Если на issue одновременно стоят `mode:research` и `mode:plan`, `mode:research` выигрывает."
    assert prompt =~ ".agents/skills/research-mode/SKILL.md"
    assert prompt =~ ".agents/skills/plan-mode/SKILL.md"
    assert prompt =~ ".agents/skills/execute-mode/SKILL.md"
    assert prompt =~ "$CODEX_HOME/skills/research-mode/SKILL.md"
    assert prompt =~ "$CODEX_HOME/skills/plan-mode/SKILL.md"
    assert prompt =~ "$CODEX_HOME/skills/execute-mode/SKILL.md"
    assert prompt =~ "Acceptance Matrix"
    assert prompt =~ "Proof Mapping"
    assert prompt =~ "validation:am-<am-id-lowercase>"
    assert prompt =~ "am-<id>:"
    assert prompt =~ "repo validation: `make symphony-validate`"
    assert prompt =~ "строки `вложение` используй только для реальных file attachments в Linear"
    assert prompt =~ "evidence по PR (`PR #...`, PR URL, `pull request`, `пулл-реквест`) должно оставаться в linked PR + `github_pr_snapshot`"
    assert prompt =~ "Required capabilities"
    assert prompt =~ "rollout contract"
    assert prompt =~ "delivery_class"
    assert prompt =~ "required_capability"
    assert prompt =~ "phase=done"
    assert prompt =~ "checkpoint_type: human-action"
    assert prompt =~ "vps_ssh"
    assert prompt =~ "Use only external prerequisite names: `stateful_db`, `runtime_smoke`, `ui_runtime`, `vps_ssh`, and `artifact_upload`"
    assert prompt =~ "do not include execution-only requirements (`repo_validation`, `pr_publication`, `pr_body_contract`)"
    refute prompt =~ "Use the canonical capability names `repo_validation`, `pr_publication`, `pr_body_contract`, `stateful_db`, `runtime_smoke`, `ui_runtime`, `vps_ssh`, and `artifact_upload`"
    assert prompt =~ "red proof"
    assert prompt =~ "не помечай `n/a`"
    assert prompt =~ "`codex.cost_profiles`"
    assert get_in(config, ["codex", "command_template"]) =~ "{{effort}}"
    assert get_in(config, ["codex", "command_template"]) =~ "{{model}}"
    assert get_in(config, ["codex", "cost_profiles", "cheap_planning", "model"]) == "gpt-5.4"
    assert get_in(config, ["codex", "cost_profiles", "cheap_planning", "effort"]) == "xhigh"
    assert get_in(config, ["codex", "cost_profiles", "cheap_implementation", "effort"]) == "medium"
    refute non_planning_default_profiles_have_xhigh?(get_in(config, ["codex", "cost_profiles"]))
    assert get_in(config, ["codex", "cost_policy", "signal_escalations", "rework"]) == "escalated_implementation"
    assert get_in(config, ["codex", "cost_policy", "signal_escalations", "risky_task"]) == "escalated_implementation"
    assert get_in(config, ["codex", "max_continuation_attempts"]) == 3
    assert prompt =~ "`mode:research` и `reasoning:implementation-xhigh` не эскалируют"
    assert prompt =~ "fail closed into `Spec Prep` and treat it as the legacy `plan-mode` path."
    refute prompt =~ "make test-unit"
  end

  test "LET workflow uses symphony validation target for repo validation contract" do
    assert {:ok, %{prompt: prompt}} = Workflow.load(@let_workflow_path)

    assert prompt =~ "Backend-only changes: run targeted tests for the touched modules and at least `make symphony-validate`."
    assert prompt =~ "- [ ] repo validation: `make symphony-validate`"
    refute prompt =~ "make test-unit"
    refute prompt =~ "<repo-owned final validation command>"
  end

  test "default workflow documents the same stage-aware cost profile contract" do
    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(@default_workflow_path)

    assert get_in(config, ["codex", "command_template"]) =~ "{{effort}}"
    assert get_in(config, ["codex", "cost_profiles", "cheap_planning", "model"]) == "gpt-5.4"
    assert get_in(config, ["codex", "cost_profiles", "cheap_planning", "effort"]) == "xhigh"
    assert get_in(config, ["codex", "cost_profiles", "cheap_implementation", "effort"]) == "medium"
    assert get_in(config, ["codex", "max_continuation_attempts"]) == 3
    refute non_planning_default_profiles_have_xhigh?(get_in(config, ["codex", "cost_profiles"]))
    assert prompt =~ "`codex.cost_policy`"
    assert prompt =~ "never mark this item as `n/a`"
  end

  test "LET workflow keeps secondary codex homes under the mounted primary CODEX_HOME" do
    assert {:ok, %{config: config}} = Workflow.load(@let_workflow_path)

    accounts = get_in(config, ["codex", "accounts"])

    assert [
             %{"codex_home" => "/root/.codex/.codex-furrow"},
             %{"codex_home" => "/root/.codex/.codex-deborah"}
           ] = Enum.map(accounts, &Map.take(&1, ["codex_home"]))
  end

  test "research, plan, and execute mode skills exist with the expected guardrails" do
    research_skill = File.read!(@research_skill_path)
    plan_skill = File.read!(@plan_skill_path)
    execute_skill = File.read!(@execute_skill_path)

    assert research_skill =~ "name: research-mode"
    assert research_skill =~ "Do not edit product code as a shipped fix."
    assert research_skill =~ "root cause"
    assert research_skill =~ "Separate symptoms from causes."
    assert research_skill =~ "top hypotheses ranked by confidence"
    assert research_skill =~ "Update Linear in Russian"
    assert research_skill =~ "`delivery:tdd`"
    assert research_skill =~ "cheap deterministic"
    assert research_skill =~ "remove stale `delivery:tdd`"
    assert research_skill =~ "branch, PR, checks, and review context"
    assert research_skill =~ "Apply `DRY`, `KISS`, and `YAGNI`"
    assert research_skill =~ "The final research output should be ordered as follows"
    assert research_skill =~ "exact problem location in code, data, and/or runtime"
    assert research_skill =~ "risks, unknowns, and what still needs checking"
    assert research_skill =~ "../../design-policy.md"
    assert research_skill =~ "Choose one explicit MVP"
    assert research_skill =~ "critique pass 1"
    assert research_skill =~ "critique pass 2"
    assert research_skill =~ "positive and negative proof cases"

    assert plan_skill =~ "name: plan-mode"
    assert plan_skill =~ "Do not edit product code as a shipped fix."
    assert plan_skill =~ "implementation-ready"
    assert plan_skill =~ "Apply `DRY`, `KISS`, and `YAGNI`"
    assert plan_skill =~ "`delivery:tdd`"
    assert plan_skill =~ "cheap deterministic"
    assert plan_skill =~ "remove stale `delivery:tdd`"
    assert plan_skill =~ "Ограничения и инварианты"
    assert plan_skill =~ "План валидации"
    assert plan_skill =~ "Acceptance Matrix"
    assert plan_skill =~ "proof"
    assert plan_skill =~ "Update Linear in Russian"
    assert plan_skill =~ "The final planning output should be ordered as follows"
    assert plan_skill =~ "../../design-policy.md"
    assert plan_skill =~ "Choose one explicit MVP"
    assert plan_skill =~ "critique pass 1"
    assert plan_skill =~ "critique pass 2"
    assert plan_skill =~ "positive and negative proof cases"

    assert execute_skill =~ "name: execute-mode"
    assert execute_skill =~ "Finish an execution-ready task"
    assert execute_skill =~ "Run `make symphony-preflight`"
    assert execute_skill =~ "repo/task acceptance preflight"
    assert execute_skill =~ "Do not use CI green as a substitute"
    assert execute_skill =~ "Acceptance Matrix"
    assert execute_skill =~ "Proof Mapping"
    assert execute_skill =~ "proof_type"
    assert execute_skill =~ "proof_semantic"
    assert execute_skill =~ "required_before=review"
    assert execute_skill =~ "rollout obligations"
    assert execute_skill =~ "done-phase"
    assert execute_skill =~ "phase=done"
    assert execute_skill =~ "code_only"
    assert execute_skill =~ "exactly one checked `Proof Mapping` entry"
    assert execute_skill =~ "validation:am-<am-id-lowercase>"
    assert execute_skill =~ "Do not use prose references after `validation:`"
    assert execute_skill =~ "validation:runtime smoke"
    assert execute_skill =~ "Update Linear in Russian"
    assert execute_skill =~ "Blocked"
  end

  test "workflows document delivery rollout closure without code-only overhead" do
    assert {:ok, %{prompt: let_prompt}} = Workflow.load(@let_workflow_path)
    assert {:ok, %{prompt: default_prompt}} = Workflow.load(@default_workflow_path)

    for prompt <- [let_prompt, default_prompt] do
      assert prompt =~ "rollout contract"
      assert prompt =~ "delivery_class"
      assert prompt =~ "code_only"
      assert prompt =~ "phase=done"
      assert prompt =~ "Blocked"
      assert prompt =~ "checkpoint_type: human-action"
    end
  end

  defp non_planning_default_profiles_have_xhigh?(profiles) when is_map(profiles) do
    Enum.any?(profiles, fn {key, profile} -> key != "cheap_planning" and Map.get(profile, "effort") == "xhigh" end)
  end
end
