defmodule SymphonyElixir.LetWorkflowContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  @let_workflow_path Path.expand("../../../workflows/letterl/maxime/let.WORKFLOW.md", __DIR__)
  @research_skill_path Path.expand("../../../.agents/skills/research-mode/SKILL.md", __DIR__)
  @plan_skill_path Path.expand("../../../.agents/skills/plan-mode/SKILL.md", __DIR__)

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
    assert prompt =~ "без `mode:*` -> сразу переводи в `In Progress`"
    assert prompt =~ "Если на issue одновременно стоят `mode:research` и `mode:plan`, `mode:research` выигрывает."
    assert prompt =~ ".agents/skills/research-mode/SKILL.md"
    assert prompt =~ ".agents/skills/plan-mode/SKILL.md"
    assert prompt =~ "$CODEX_HOME/skills/research-mode/SKILL.md"
    assert prompt =~ "$CODEX_HOME/skills/plan-mode/SKILL.md"
    refute prompt =~ "`Todo` -> сразу переводи в `Spec Prep`."
  end

  test "LET workflow keeps secondary codex homes under the mounted primary CODEX_HOME" do
    assert {:ok, %{config: config}} = Workflow.load(@let_workflow_path)

    accounts = get_in(config, ["codex", "accounts"])

    assert [
             %{"codex_home" => "/root/.codex"},
             %{"codex_home" => "/root/.codex/.codex-furrow"},
             %{"codex_home" => "/root/.codex/.codex-rebecca"},
             %{"codex_home" => "/root/.codex/.codex-deborah"},
             %{"codex_home" => "/root/.codex/.codex-kjfdn41739"},
             %{"codex_home" => "/root/.codex/.codex-xvnza54743"},
             %{"codex_home" => "/root/.codex/.codex-tatonkasperski8844"}
           ] = Enum.map(accounts, &Map.take(&1, ["codex_home"]))
  end

  test "research and plan mode skills exist with no-implementation guardrails" do
    research_skill = File.read!(@research_skill_path)
    plan_skill = File.read!(@plan_skill_path)

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

    assert plan_skill =~ "name: plan-mode"
    assert plan_skill =~ "Do not edit product code as a shipped fix."
    assert plan_skill =~ "implementation-ready"
    assert plan_skill =~ "Apply `DRY`, `KISS`, and `YAGNI`"
    assert plan_skill =~ "`delivery:tdd`"
    assert plan_skill =~ "cheap deterministic"
    assert plan_skill =~ "remove stale `delivery:tdd`"
    assert plan_skill =~ "Ограничения и инварианты"
    assert plan_skill =~ "План валидации"
    assert plan_skill =~ "Update Linear in Russian"
    assert plan_skill =~ "The final planning output should be ordered as follows"
  end
end
