defmodule SymphonyElixir.LetWorkflowContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  @let_workflow_path Path.expand("../../../workflows/letterl/maxime/let.WORKFLOW.md", __DIR__)
  @default_workflow_path Path.expand("../../WORKFLOW.md", __DIR__)
  @project_contract_path Path.expand("../../../docs/policy/project-contract.md", __DIR__)
  @research_skill_path Path.expand("../../../.agents/skills/research-mode/SKILL.md", __DIR__)
  @plan_skill_path Path.expand("../../../.agents/skills/plan-mode/SKILL.md", __DIR__)
  @execute_skill_path Path.expand("../../../.agents/skills/execute-mode/SKILL.md", __DIR__)
  @zoom_out_skill_path Path.expand("../../../.agents/skills/zoom-out/SKILL.md", __DIR__)
  @diagnose_skill_path Path.expand("../../../.agents/skills/diagnose/SKILL.md", __DIR__)
  @tdd_skill_path Path.expand("../../../.agents/skills/tdd/SKILL.md", __DIR__)
  @worker_setup_skill_path Path.expand("../../../.agents/skills/symphony-setup/SKILL.md", __DIR__)
  @onboarding_setup_doc_path Path.expand("../../../docs/onboarding/symphony-setup.md", __DIR__)

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
    assert prompt =~ "docs/policy/project-contract.md"
    assert prompt =~ "Task-spec issue description"
    assert prompt =~ "## Acceptance Matrix"
    assert prompt =~ "## Proof Mapping"
    assert prompt =~ "- AM-1 -> validation:am-1"
    assert prompt =~ "- AM-2 -> runtime:runtime smoke"
    assert prompt =~ "must use hyphen bullets"
    assert prompt =~ "runtime_smoke:*"
    assert prompt =~ "Workpad template"
    assert prompt =~ "repo validation: `make symphony-validate`"
    assert prompt =~ "Required capabilities"
    assert prompt =~ "vps_ssh"
    assert prompt =~ "Use only external prerequisite names: `stateful_db`, `runtime_smoke`, `ui_runtime`, `vps_ssh`, and `artifact_upload`"
    assert prompt =~ "do not include execution-only requirements (`repo_validation`, `pr_publication`, `pr_body_contract`)"
    refute prompt =~ "Use the canonical capability names `repo_validation`, `pr_publication`, `pr_body_contract`, `stateful_db`, `runtime_smoke`, `ui_runtime`, `vps_ssh`, and `artifact_upload`"
    assert prompt =~ "`codex.cost_profiles`"
    assert get_in(config, ["codex", "command_template"]) =~ "{{effort}}"
    assert get_in(config, ["codex", "command_template"]) =~ "{{model}}"
    assert get_in(config, ["codex", "cost_profiles", "cheap_planning", "model"]) == "gpt-5.4"
    assert get_in(config, ["codex", "cost_profiles", "cheap_planning", "effort"]) == "xhigh"
    assert get_in(config, ["codex", "cost_profiles", "cheap_implementation", "effort"]) == "medium"
    assert get_in(config, ["planning", "swarm_assist_enabled"]) == true
    refute non_planning_default_profiles_have_xhigh?(get_in(config, ["codex", "cost_profiles"]))
    assert get_in(config, ["codex", "cost_policy", "signal_escalations", "rework"]) == "escalated_implementation"
    assert get_in(config, ["codex", "cost_policy", "signal_escalations", "risky_task"]) == "escalated_implementation"
    assert get_in(config, ["codex", "max_continuation_attempts"]) == 3
    assert prompt =~ "`mode:research` и `reasoning:implementation-xhigh` не эскалируют"
    assert prompt =~ "fail closed into `Spec Prep` and treat it as the legacy `plan-mode` path."
    assert prompt =~ "Plan swarm gate contract:"
    assert prompt =~ "`planning.swarm_assist_enabled` (default `true`)"
    assert prompt =~ "when gate is `false`, keep legacy `plan-mode` path unchanged"
    assert prompt =~ "enabled gate output is two-layer: canonical short plan (SSOT) +"
    assert prompt =~ "`plan_revision`, `artifact_path`, and `artifact_revision`"
    assert prompt =~ "`provisional` output is not review-ready"
    assert prompt =~ ".agents/skills/swarm-iterate/SKILL.md"
    assert prompt =~ "$CODEX_HOME/skills/swarm-iterate/SKILL.md"
    assert prompt =~ "if workflow gate `planning.swarm_assist_enabled` is `true`, additionally run `swarm-iterate`"
    assert prompt =~ "if the gate is `true` but `swarm-iterate` is unavailable, fail closed"
    assert prompt =~ "blocking divergence"
    assert prompt =~ "keep machine-readable lines for `plan_revision`, `artifact_path`, and `artifact_revision`"
    assert prompt =~ "for `mode:plan` issue description, keep canonical `## Proof Mapping` as"
    assert prompt =~ "hyphen bullets only (`- AM-1 -> validation:am-1`), not `*` bullets and not"
    assert prompt =~ "for `mode:plan`, in issue-description mapping allow only `validation:`,"
    assert prompt =~ "never use `test:` or"
    assert prompt =~ "issue-description mapping is a spec contract reservation and does not"
    assert prompt =~ "For `mode:plan` with `planning.swarm_assist_enabled=true`, run two-layer execution preflight before code edits"
    assert prompt =~ "`Execution Evidence` section in workpad"
    assert prompt =~ "artifact file body and Linear attachment text are supporting context only"
    assert prompt =~ "generic `targeted tests` does not satisfy that AM-specific target"
    assert prompt =~ "root-level `.md` smoke artifact"
    assert prompt =~ "AM-specific rows do not replace `docs review`"
    assert prompt =~ "- [ ] `AM-<id>` -> `validation:am-<id>`"
    assert prompt =~ "- [ ] docs review: `<command>`"
    refute prompt =~ "continue without blocking"
    refute prompt =~ ".agents/skills/plan-swarm-mode/SKILL.md"
    refute prompt =~ "make test-unit"
  end

  test "LET workflow uses symphony validation target for repo validation contract" do
    assert {:ok, %{prompt: prompt}} = Workflow.load(@let_workflow_path)

    assert prompt =~ "Backend-only changes: run targeted tests for the touched modules and at least `make symphony-validate`."
    assert prompt =~ "checked `targeted tests` for the touched module"
    assert prompt =~ "checked label `targeted tests`"
    assert prompt =~ "any extra proof explanation belongs in that row text, not in the label"
    assert prompt =~ "checked `runtime smoke`"
    assert prompt =~ "Do not add capabilities or matrix rows solely to force this proof."
    assert prompt =~ "Не перечисляй pull request"
    assert prompt =~ "PR-доказательства остаются"
    assert prompt =~ "Не объединяй"
    assert prompt =~ "`revision_pair.plan_revision` и `revision_pair.artifact_revision`"
    assert prompt =~ "- [ ] repo validation: `make symphony-validate`"
    assert prompt =~ "Use `docs/policy/project-contract.md` as the canonical definition for:"
    refute prompt =~ "make test-unit"
    refute prompt =~ "<repo-owned final validation command>"
  end

  test "default workflow documents the same stage-aware cost profile contract" do
    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(@default_workflow_path)

    assert get_in(config, ["codex", "command_template"]) =~ "{{effort}}"
    assert get_in(config, ["codex", "cost_profiles", "cheap_planning", "model"]) == "gpt-5.4"
    assert get_in(config, ["codex", "cost_profiles", "cheap_planning", "effort"]) == "xhigh"
    assert get_in(config, ["codex", "cost_profiles", "cheap_implementation", "effort"]) == "medium"
    assert get_in(config, ["planning", "swarm_assist_enabled"]) == true
    assert get_in(config, ["codex", "max_continuation_attempts"]) == 3
    refute non_planning_default_profiles_have_xhigh?(get_in(config, ["codex", "cost_profiles"]))
    assert prompt =~ "`codex.cost_policy`"
    assert prompt =~ "docs/policy/project-contract.md"
    assert prompt =~ "two-layer planning contract"
    assert prompt =~ "`artifact_revision` must match `plan_revision`"
    assert prompt =~ "checked label `targeted tests`"
    assert prompt =~ "Do not add capabilities or"
    assert prompt =~ "PR evidence stays"
    assert prompt =~ "Do not combine"
    assert prompt =~ "Attachment excerpts are prompt context only"
    assert prompt =~ "Artifact file body and Linear `attachment.content_text` are supporting"
    assert prompt =~ "- [ ] `AM-<id>` -> `validation:am-<id>`"
  end

  test "LET workflow keeps secondary codex homes under the mounted primary CODEX_HOME" do
    assert {:ok, %{config: config}} = Workflow.load(@let_workflow_path)

    accounts = get_in(config, ["codex", "accounts"])

    assert [
             %{"codex_home" => "/root/.codex/.codex-furrow"},
             %{"codex_home" => "/root/.codex/.codex-deborah"}
           ] = Enum.map(accounts, &Map.take(&1, ["codex_home"]))
  end

  test "research, plan, and execute mode skills are thin entrypoints and use canonical contract" do
    research_skill = File.read!(@research_skill_path)
    plan_skill = File.read!(@plan_skill_path)
    execute_skill = File.read!(@execute_skill_path)

    assert research_skill =~ "name: research-mode"
    assert research_skill =~ "Do not edit product code as a shipped fix."
    assert research_skill =~ "Entry-point skill for `Spec Prep` research passes."
    assert research_skill =~ "docs/policy/project-contract.md"
    assert research_skill =~ "[`diagnose`](../diagnose/SKILL.md)"
    assert research_skill =~ "[`zoom-out`](../zoom-out/SKILL.md)"
    assert research_skill =~ "Update Linear in Russian"
    assert research_skill =~ "`delivery:tdd`"
    assert research_skill =~ "deterministic proof feasibility"

    assert plan_skill =~ "name: plan-mode"
    assert plan_skill =~ "Do not edit product code as a shipped fix."
    assert plan_skill =~ "Entry-point skill for `Spec Prep` planning passes."
    assert plan_skill =~ "docs/policy/project-contract.md"
    assert plan_skill =~ "implementation-ready"
    assert plan_skill =~ "`delivery:tdd`"
    assert plan_skill =~ "Acceptance Matrix"
    assert plan_skill =~ "Proof Mapping"
    assert plan_skill =~ "## Pre-write checklist for `mode:plan` description"
    assert plan_skill =~ "| id | scenario | expected_outcome | proof_type | proof_target | proof_semantic | required_before |"
    assert plan_skill =~ "- AM-1 -> validation:am-1"
    assert plan_skill =~ "- AM-2 -> runtime:runtime smoke"
    assert plan_skill =~ "Use hyphen bullets only"
    assert plan_skill =~ "Do not use `test:` or `runtime_smoke:` as mapping prefixes."
    assert plan_skill =~ "reserve future proof targets"
    assert plan_skill =~ "Update Linear in Russian"
    assert plan_skill =~ "choose one explicit MVP"
    assert plan_skill =~ "`planning.swarm_assist_enabled`"
    assert plan_skill =~ "`swarm-iterate`"
    assert plan_skill =~ "owned by this stage"
    assert plan_skill =~ "issue description metadata"
    assert plan_skill =~ "artifact file body; artifact body is supporting context only"
    assert plan_skill =~ "Guarded swarm-assisted path"
    assert plan_skill =~ "emit a two-layer plan"
    assert plan_skill =~ "`plan_revision`"
    assert plan_skill =~ "`artifact_path`"
    assert plan_skill =~ "`artifact_revision`"
    assert plan_skill =~ "`provisional`"
    assert plan_skill =~ "`blocking divergence`"
    refute plan_skill =~ "plan-swarm-mode"

    assert execute_skill =~ "name: execute-mode"
    assert execute_skill =~ "Entry-point skill for `In Progress` execution passes."
    assert execute_skill =~ "docs/policy/project-contract.md"
    assert execute_skill =~ "Acceptance Matrix"
    assert execute_skill =~ "Proof Mapping"
    assert execute_skill =~ "[`tdd`](../tdd/SKILL.md)"
    assert execute_skill =~ "[`diagnose`](../diagnose/SKILL.md)"
    assert execute_skill =~ "Update Linear in Russian"
    assert execute_skill =~ "Blocked"
    assert execute_skill =~ "`planning.swarm_assist_enabled=true`"
    assert execute_skill =~ "Execution Evidence"
    assert execute_skill =~ "never as scope,"
    assert execute_skill =~ "do not require `plan_revision` / `artifact_revision` fields inside the"
    assert execute_skill =~ "issue `## Proof Mapping` is canonical"
    assert execute_skill =~ "PR evidence stays in linked PR"
  end

  test "worker method skills exist and setup lives outside worker bundle" do
    zoom_out_skill = File.read!(@zoom_out_skill_path)
    diagnose_skill = File.read!(@diagnose_skill_path)
    tdd_skill = File.read!(@tdd_skill_path)
    project_contract = File.read!(@project_contract_path)
    onboarding_doc = File.read!(@onboarding_setup_doc_path)

    assert zoom_out_skill =~ "name: zoom-out"
    assert zoom_out_skill =~ "Do not edit product code in this mode."

    assert diagnose_skill =~ "name: diagnose"
    assert diagnose_skill =~ "reproduce -> minimize -> hypothesize -> instrument ->"
    assert diagnose_skill =~ "In `Spec Prep`, this skill is analysis-only"

    assert tdd_skill =~ "name: tdd"
    assert tdd_skill =~ "red -> green"
    assert tdd_skill =~ "`delivery:tdd`"

    assert project_contract =~ "# Project Contract"
    assert project_contract =~ "Acceptance Matrix"
    assert project_contract =~ "Spec Prep Planning Contract (Two-Layer, Swarm-Assisted)"
    assert project_contract =~ "`planning.swarm_assist_enabled`"
    assert project_contract =~ "Compatibility proof (gate disabled)"
    assert project_contract =~ "`artifact_path`"
    assert project_contract =~ "`artifact_revision`"
    assert project_contract =~ "`plan_revision`"
    assert project_contract =~ "`blocking divergence`"
    assert project_contract =~ "Execution-Time Secondary Artifact Contract"
    assert project_contract =~ "`Execution Evidence`"
    assert project_contract =~ "`run_token`"
    assert project_contract =~ "Linear attachment `content_text` and artifact file body are prompt context"
    assert project_contract =~ "must not require `plan_revision` or"
    assert project_contract =~ "`artifact_revision` inside the artifact file body"

    refute File.exists?(Path.expand("../../../.agents/skills/plan-swarm-mode/SKILL.md", __DIR__))
    refute File.exists?(@worker_setup_skill_path)
    assert onboarding_doc =~ "Symphony Setup (Onboarding)"
    assert onboarding_doc =~ "intentionally not a worker runtime skill"
  end

  defp non_planning_default_profiles_have_xhigh?(profiles) when is_map(profiles) do
    Enum.any?(profiles, fn {key, profile} -> key != "cheap_planning" and Map.get(profile, "effort") == "xhigh" end)
  end
end
