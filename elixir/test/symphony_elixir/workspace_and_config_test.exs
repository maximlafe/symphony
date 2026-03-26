defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.Linear.Client

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace hooks receive issue metadata in environment variables" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-env-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: """
        {
          printf 'id=%s\\n' "$SYMPHONY_ISSUE_IDENTIFIER"
          printf 'title=%s\\n' "$SYMPHONY_ISSUE_TITLE"
          printf 'project_slug=%s\\n' "$SYMPHONY_ISSUE_PROJECT_SLUG"
          printf 'project_name=%s\\n' "$SYMPHONY_ISSUE_PROJECT_NAME"
          printf 'branch=%s\\n' "$SYMPHONY_ISSUE_BRANCH_NAME"
          printf 'state=%s\\n' "$SYMPHONY_ISSUE_STATE"
          printf 'url=%s\\n' "$SYMPHONY_ISSUE_URL"
        } > issue-env.txt
        printf '%s' "$SYMPHONY_ISSUE_DESCRIPTION" > issue-description.txt
        printf '%s' "$SYMPHONY_ISSUE_LABELS" > issue-labels.txt
        """
      )

      issue = %Issue{
        id: "issue-branch",
        identifier: "LET-188",
        title: "Branch marker test",
        description: "## Symphony\nBase branch: feature/tg-source\n",
        project_slug: "izvlechenie-zadach-8209c2018e76",
        project_name: "Извлечение задач",
        state: "Todo",
        branch_name: "feature/worker-head",
        url: "https://linear.example/LET-188",
        labels: ["repo:lead_status", "backend"]
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert File.read!(Path.join(workspace, "issue-env.txt")) ==
               """
               id=LET-188
               title=Branch marker test
               project_slug=izvlechenie-zadach-8209c2018e76
               project_name=Извлечение задач
               branch=feature/worker-head
               state=Todo
               url=https://linear.example/LET-188
               """

      assert File.read!(Path.join(workspace, "issue-description.txt")) ==
               "## Symphony\nBase branch: feature/tg-source\n"

      assert File.read!(Path.join(workspace, "issue-labels.txt")) ==
               "repo:lead_status\nbackend"
    after
      File.rm_rf(test_root)
    end
  end

  test "before_run hooks can refresh issue metadata in a reused workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-before-run-env-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '%s' \"$SYMPHONY_ISSUE_DESCRIPTION\" > issue-description.txt",
        hook_before_run: """
        {
          printf 'id=%s\\n' "$SYMPHONY_ISSUE_IDENTIFIER"
          printf 'branch=%s\\n' "$SYMPHONY_ISSUE_BRANCH_NAME"
        } > issue-env.txt
        printf '%s' "$SYMPHONY_ISSUE_DESCRIPTION" > issue-description.txt
        """
      )

      initial_issue = %Issue{
        id: "issue-branch",
        identifier: "LET-188",
        title: "Branch marker test",
        description: "## Symphony\nBase branch: feature/tg-source\n",
        state: "Todo",
        branch_name: "feature/worker-head",
        url: "https://linear.example/LET-188"
      }

      updated_issue = %{
        initial_issue
        | description: "## Symphony\nBase branch: feature/tg-target\n",
          branch_name: "feature/worker-refresh"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(initial_issue)

      assert File.read!(Path.join(workspace, "issue-description.txt")) ==
               "## Symphony\nBase branch: feature/tg-source\n"

      assert :ok = Workspace.run_before_run_hook(workspace, initial_issue)

      assert File.read!(Path.join(workspace, "issue-env.txt")) ==
               """
               id=LET-188
               branch=feature/worker-head
               """

      assert {:ok, ^workspace} = Workspace.create_for_issue(updated_issue)

      assert File.read!(Path.join(workspace, "issue-description.txt")) ==
               "## Symphony\nBase branch: feature/tg-source\n"

      assert :ok = Workspace.run_before_run_hook(workspace, updated_issue)

      assert File.read!(Path.join(workspace, "issue-env.txt")) ==
               """
               id=LET-188
               branch=feature/worker-refresh
               """

      assert File.read!(Path.join(workspace, "issue-description.txt")) ==
               "## Symphony\nBase branch: feature/tg-target\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      refute File.exists?(Path.join([second_workspace, "tmp", "scratch.txt"]))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "Rework recreates the issue workspace as a fresh attempt" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-rework-refresh-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '%s' \"$SYMPHONY_ISSUE_STATE\" > bootstrap-state.txt"
      )

      issue = %Issue{
        id: "issue-rework",
        identifier: "MT-REWORK",
        title: "Rework fresh attempt",
        description: "## Symphony\nBase branch: main\n",
        state: "In Progress",
        branch_name: "feature/old-attempt"
      }

      rework_issue = %{issue | state: "Rework", branch_name: "feature/new-attempt"}

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "bootstrap-state.txt")) == "In Progress"

      File.write!(Path.join(workspace, "local-progress.txt"), "stale local state\n")

      assert {:ok, ^workspace} = Workspace.create_for_issue(rework_issue)
      assert File.read!(Path.join(workspace, "bootstrap-state.txt")) == "Rework"
      refute File.exists?(Path.join(workspace, "local-progress.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace recreates stale failed bootstrap directories before rerunning after_create" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-bootstrap-recovery-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '%s' \"$SYMPHONY_ISSUE_STATE\" > bootstrap-state.txt"
      )

      issue = %Issue{
        id: "issue-bootstrap-recovery",
        identifier: "MT-BOOTSTRAP-RECOVERY",
        title: "Bootstrap recovery",
        description: "## Symphony\nBase branch: main\n",
        state: "In Progress",
        branch_name: "feature/bootstrap-recovery"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      File.write!(Path.join(workspace, ".symphony-base-branch-error"), "old bootstrap blocker\n")
      File.write!(Path.join(workspace, "local-progress.txt"), "stale bootstrap residue\n")

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "bootstrap-state.txt")) == "In Progress"
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
      refute File.exists?(Path.join(workspace, "local-progress.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace recreates stale failed bootstrap clones before rerunning after_create" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-bootstrap-clone-recovery-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: """
        mkdir -p .git
        printf '%s' "$SYMPHONY_ISSUE_STATE" > bootstrap-state.txt
        """
      )

      issue = %Issue{
        id: "issue-bootstrap-clone-recovery",
        identifier: "MT-BOOTSTRAP-CLONE-RECOVERY",
        title: "Bootstrap clone recovery",
        description: "## Symphony\nBase branch: main\n",
        state: "In Progress",
        branch_name: "feature/bootstrap-clone-recovery"
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.dir?(Path.join(workspace, ".git"))

      File.write!(Path.join(workspace, ".symphony-base-branch-error"), "old bootstrap blocker\n")
      File.write!(Path.join(workspace, "local-progress.txt"), "stale bootstrap residue\n")

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "bootstrap-state.txt")) == "In Progress"
      assert File.dir?(Path.join(workspace, ".git"))
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
      refute File.exists?(Path.join(workspace, "local-progress.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "repository routing script can bootstrap a fixed repository from project slug" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-repository-marker-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")
      File.mkdir_p!(workspace)

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_routing_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_PROJECT_SLUG", "telegram-full-export-v2-a6212aeb565c"},
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Telegram Full Export v2"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, "BOOTSTRAP_REPO.txt")) == "tg_live_export\n"
      assert File.read!(Path.join(workspace, ".symphony-source-repository")) == "maximlafe/tg_live_export\n"
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing script can bootstrap the requested base branch when it satisfies the bootstrap contract" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-requested-base-branch-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_branch_ref!(lead_status_repo, "feature/symphony-ready")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")
      File.mkdir_p!(workspace)

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_routing_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Извлечение задач"},
                   {"SYMPHONY_ISSUE_DESCRIPTION", "## Symphony\nBase branch: feature/symphony-ready\n"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, "BOOTSTRAP_REPO.txt")) == "lead_status\n"
      assert File.read!(Path.join(workspace, ".symphony-source-repository")) == "maximlafe/lead_status\n"
      assert File.read!(Path.join(workspace, ".symphony-base-branch")) == "feature/symphony-ready\n"
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing script writes blocker file when the requested base branch lacks symphony-bootstrap" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-missing-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_branch_without_bootstrap!(lead_status_repo, "feature/stale-contract")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")
      File.mkdir_p!(workspace)

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_routing_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Извлечение задач"},
                   {"SYMPHONY_ISSUE_DESCRIPTION", "## Symphony\nBase branch: feature/stale-contract\n"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, ".symphony-base-branch")) == "feature/stale-contract\n"

      assert File.read!(Path.join(workspace, ".symphony-base-branch-error")) ==
               "Base branch 'feature/stale-contract' in maximlafe/lead_status does not define make symphony-bootstrap.\n"

      refute File.exists?(Path.join(workspace, "BOOTSTRAP_REPO.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing script writes blocker file when the requested base branch fails symphony-bootstrap" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-broken-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")

      create_branch_with_failing_bootstrap!(
        lead_status_repo,
        "feature/broken-bootstrap",
        "bootstrap dependency failed"
      )

      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")
      File.mkdir_p!(workspace)

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_routing_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Извлечение задач"},
                   {"SYMPHONY_ISSUE_DESCRIPTION", "## Symphony\nBase branch: feature/broken-bootstrap\n"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, ".symphony-base-branch")) == "feature/broken-bootstrap\n"

      assert File.read!(Path.join(workspace, ".symphony-base-branch-error")) ==
               "Base branch 'feature/broken-bootstrap' in maximlafe/lead_status failed make symphony-bootstrap: bootstrap dependency failed\n"

      refute File.exists?(Path.join(workspace, "BOOTSTRAP_REPO.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing script maps the Symphony project to the Symphony repository" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symphony-project-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")
      File.mkdir_p!(workspace)

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_routing_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_PROJECT_SLUG", "symphony-bd5bc5b51675"},
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Symphony"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, "BOOTSTRAP_REPO.txt")) == "symphony\n"
      assert File.read!(Path.join(workspace, ".symphony-source-repository")) == "maximlafe/symphony\n"
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing script can bootstrap Symphony from project name when project slug is missing" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symphony-project-name-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")
      File.mkdir_p!(workspace)

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_routing_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Symphony"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, "BOOTSTRAP_REPO.txt")) == "symphony\n"
      assert File.read!(Path.join(workspace, ".symphony-source-repository")) == "maximlafe/symphony\n"
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing script can bootstrap a fixed repository from project name when slug format changes" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-repository-project-name-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")
      File.mkdir_p!(workspace)

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_routing_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_PROJECT_SLUG", "a6212aeb565c"},
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Telegram Full Export v2"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, "BOOTSTRAP_REPO.txt")) == "tg_live_export\n"
      assert File.read!(Path.join(workspace, ".symphony-source-repository")) == "maximlafe/tg_live_export\n"
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing script uses repo label for ambiguous platform project" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-repository-blocker-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")
      File.mkdir_p!(workspace)

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_routing_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_PROJECT_SLUG", "platforma-i-integraciya-448570ee6438"},
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Платформа и интеграция"},
                   {"SYMPHONY_ISSUE_LABELS", "repo:symphony"}
                 ]
               )

      assert File.read!(Path.join(workspace, "BOOTSTRAP_REPO.txt")) == "symphony\n"
      assert File.read!(Path.join(workspace, ".symphony-source-repository")) == "maximlafe/symphony\n"
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing script writes blocker file when ambiguous platform project has no repo label" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-repository-blocker-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")
      File.mkdir_p!(workspace)

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_routing_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_PROJECT_SLUG", "platforma-i-integraciya-448570ee6438"},
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Платформа и интеграция"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, ".symphony-base-branch-error")) ==
               "Project 'Платформа и интеграция' requires one repo label: repo:lead_status, repo:symphony, or repo:tg_live_export.\n"

      refute File.exists?(Path.join(workspace, ".git"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository retry script reuses the stored repository when ambiguous project has no repo label" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-repository-retry-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")

      System.cmd("git", ["clone", "--depth", "1", symphony_repo, workspace])
      File.write!(Path.join(workspace, ".symphony-source-repository"), "maximlafe/symphony\n")
      File.write!(Path.join(workspace, ".symphony-base-branch"), "main\n")

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_retry_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_DESCRIPTION", ""},
                   {"SYMPHONY_ISSUE_PROJECT_SLUG", "platforma-i-integraciya-448570ee6438"},
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Платформа и интеграция"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, ".symphony-source-repository")) == "maximlafe/symphony\n"
      assert File.read!(Path.join(workspace, ".symphony-base-branch")) == "main\n"
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository retry script preserves the stored base branch when Base branch marker is absent" do
    previous_lead_status_repo = System.get_env("TEST_LEAD_STATUS_REPO_URL")
    previous_symphony_repo = System.get_env("TEST_SYMPHONY_REPO_URL")
    previous_tg_live_export_repo = System.get_env("TEST_TG_LIVE_EXPORT_REPO_URL")

    on_exit(fn ->
      restore_env("TEST_LEAD_STATUS_REPO_URL", previous_lead_status_repo)
      restore_env("TEST_SYMPHONY_REPO_URL", previous_symphony_repo)
      restore_env("TEST_TG_LIVE_EXPORT_REPO_URL", previous_tg_live_export_repo)
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-base-branch-retry-#{System.unique_integer([:positive])}"
      )

    try do
      lead_status_repo = Path.join(test_root, "lead_status")
      symphony_repo = Path.join(test_root, "symphony")
      tg_live_export_repo = Path.join(test_root, "tg_live_export")
      workspace = Path.join(test_root, "workspace")

      create_bootstrap_repo!(lead_status_repo, "lead_status")
      create_bootstrap_repo!(symphony_repo, "symphony")
      create_bootstrap_repo!(tg_live_export_repo, "tg_live_export")

      System.cmd("git", ["clone", "--depth", "1", lead_status_repo, workspace])
      File.write!(Path.join(workspace, ".symphony-source-repository"), "maximlafe/lead_status\n")
      File.write!(Path.join(workspace, ".symphony-base-branch"), "release/42\n")

      System.put_env("TEST_LEAD_STATUS_REPO_URL", lead_status_repo)
      System.put_env("TEST_SYMPHONY_REPO_URL", symphony_repo)
      System.put_env("TEST_TG_LIVE_EXPORT_REPO_URL", tg_live_export_repo)

      assert {_output, 0} =
               System.cmd("sh", ["-lc", repository_retry_hook()],
                 cd: workspace,
                 env: [
                   {"SYMPHONY_ISSUE_DESCRIPTION", ""},
                   {"SYMPHONY_ISSUE_PROJECT_SLUG", "master-komand-dfbe2b1b972e"},
                   {"SYMPHONY_ISSUE_PROJECT_NAME", "Мастер команд"},
                   {"SYMPHONY_ISSUE_LABELS", ""}
                 ]
               )

      assert File.read!(Path.join(workspace, ".symphony-source-repository")) == "maximlafe/lead_status\n"
      assert File.read!(Path.join(workspace, ".symphony-base-branch")) == "release/42\n"
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-error"))
      refute File.exists?(Path.join(workspace, ".symphony-base-branch-note"))
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "workspace reports recursive disk usage bytes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-usage-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace_root, "nested"))
      File.write!(Path.join(workspace_root, "root.txt"), "abcd")
      File.write!(Path.join(workspace_root, "nested/child.txt"), "123456")

      assert {:ok, usage_bytes} = Workspace.total_usage_bytes(workspace_root)
      assert usage_bytes >= 10
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup keeps the five most recent completed workspaces" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-retention-#{System.unique_integer([:positive])}"
      )

    now = DateTime.utc_now()

    issues =
      for index <- 1..7 do
        %Issue{
          id: "issue-#{index}",
          identifier: "MT-#{index}",
          state: "Done",
          updated_at: DateTime.add(now, -index * 60, :second)
        }
      end

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      Enum.each(issues, fn issue ->
        workspace = Path.join(workspace_root, issue.identifier)
        File.mkdir_p!(workspace)
        File.write!(Path.join(workspace, "marker.txt"), issue.identifier)
      end)

      assert {:ok, %{kept: kept, removed: removed}} =
               Workspace.cleanup_completed_issue_workspaces(issues, keep_recent: 5)

      assert kept == ["MT-1", "MT-2", "MT-3", "MT-4", "MT-5"]
      assert removed == ["MT-6", "MT-7"]
      assert File.exists?(Path.join(workspace_root, "MT-1"))
      assert File.exists?(Path.join(workspace_root, "MT-5"))
      refute File.exists?(Path.join(workspace_root, "MT-6"))
      refute File.exists?(Path.join(workspace_root, "MT-7"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "project" => %{"slugId" => "master-komand-dfbe2b1b972e", "name" => "Мастер команд"},
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.project_slug == "master-komand-dfbe2b1b972e"
    assert issue.project_name == "Мастер команд"
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client queries Linear team scope when tracker.team_key is configured" do
    graphql_fun = fn query, variables ->
      send(self(), {:linear_team_scope_query, query, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-team-1",
                 "identifier" => "LET-1",
                 "title" => "Team scoped task",
                 "description" => "Scoped by team key",
                 "project" => %{"slugId" => "izvlechenie-zadach-8209c2018e76", "name" => "Извлечение задач"},
                 "state" => %{"name" => "Todo"},
                 "labels" => %{"nodes" => []},
                 "inverseRelations" => %{"nodes" => []},
                 "createdAt" => "2026-01-01T00:00:00Z",
                 "updatedAt" => "2026-01-02T00:00:00Z"
               }
             ],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, [issue]} = Client.fetch_issues_by_states_for_test({:team, "LET"}, ["Todo"], graphql_fun)
    assert issue.identifier == "LET-1"
    assert issue.project_slug == "izvlechenie-zadach-8209c2018e76"
    assert issue.project_name == "Извлечение задач"

    expected_variables = %{
      teamKey: "LET",
      stateNames: ["Todo"],
      first: 50,
      relationFirst: 50,
      after: nil
    }

    assert_receive {:linear_team_scope_query, query, ^expected_variables}

    assert query =~ "SymphonyLinearTeamPoll"
    assert query =~ "team: {key: {eq: $teamKey}}"
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace before_run and after_run hooks receive SYMPHONY_TRACE_ID" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-trace-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_run_trace = Path.join(test_root, "before_run.trace")
      after_run_trace = Path.join(test_root, "after_run.trace")
      trace_id = "trace-hook-123"

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: "printf '%s' \"$SYMPHONY_TRACE_ID\" > \"#{before_run_trace}\"",
        hook_after_run: "printf '%s' \"$SYMPHONY_TRACE_ID\" > \"#{after_run_trace}\""
      )

      issue = %Issue{id: "issue-hook-trace", identifier: "MT-HOOK-TRACE"}

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert :ok = Workspace.run_before_run_hook(workspace, issue, trace_id: trace_id)
      assert :ok = Workspace.run_after_run_hook(workspace, issue, trace_id: trace_id)
      assert File.read!(before_run_trace) == trace_id
      assert File.read!(after_run_trace) == trace_id
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_team_key: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.team_key == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.codex.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server --model gpt-5.3-codex")
    assert Config.settings!().codex.command == "codex app-server --model gpt-5.3-codex"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_manual_intervention_state: "   ")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.manual_intervention_state"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_manual_intervention_state: %{blocked: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == Path.expand("env:#{workspace_env_var}")
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "config expands codex account homes and exposes multi-account getters" do
    codex_home_env = "SYMPHONY_CODEX_HOME_#{System.unique_integer([:positive])}"
    env_codex_home = Path.join(System.tmp_dir!(), "symphony-codex-home-primary")
    previous_codex_home_env = System.get_env(codex_home_env)
    previous_ambient_codex_home = System.get_env("CODEX_HOME")

    System.put_env(codex_home_env, env_codex_home)
    System.put_env("CODEX_HOME", Path.join(System.tmp_dir!(), "ambient-codex-home"))

    on_exit(fn ->
      restore_env(codex_home_env, previous_codex_home_env)
      restore_env("CODEX_HOME", previous_ambient_codex_home)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_accounts: [
        %{id: "primary", codex_home: "$#{codex_home_env}"},
        %{id: "secondary", codex_home: "~/.codex-secondary"}
      ],
      codex_minimum_remaining_percent: 7,
      codex_monitored_windows_mins: [300, 10_080]
    )

    assert Config.codex_accounts() == [
             %{id: "primary", codex_home: Path.expand(env_codex_home), explicit?: true},
             %{id: "secondary", codex_home: Path.expand("~/.codex-secondary"), explicit?: true}
           ]

    assert Config.codex_minimum_remaining_percent() == 7
    assert Config.codex_monitored_windows_mins() == [300, 10_080]
  end

  test "config preserves legacy single-account behavior from ambient CODEX_HOME" do
    previous_ambient_codex_home = System.get_env("CODEX_HOME")
    ambient_codex_home = Path.join(System.tmp_dir!(), "ambient-codex-home-legacy")

    System.put_env("CODEX_HOME", ambient_codex_home)

    on_exit(fn ->
      restore_env("CODEX_HOME", previous_ambient_codex_home)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), codex_accounts: [])

    assert Config.codex_accounts() == [
             %{id: "default", codex_home: Path.expand(ambient_codex_home), explicit?: false}
           ]
  end

  test "config rejects duplicate and invalid codex account homes" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_accounts: [
        %{id: "dup", codex_home: "/tmp/codex-a"},
        %{id: "dup", codex_home: "/tmp/codex-b"}
      ]
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "codex.accounts"
    assert message =~ "duplicate codex account id"

    missing_env = "SYMPHONY_CODEX_HOME_MISSING_#{System.unique_integer([:positive])}"
    previous_missing_env = System.get_env(missing_env)
    System.delete_env(missing_env)

    on_exit(fn ->
      restore_env(missing_env, previous_missing_env)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_accounts: [%{id: "missing", codex_home: "$#{missing_env}"}]
    )

    assert {:error, {:invalid_workflow_config, missing_message}} = Config.settings()
    assert missing_message =~ "codex.accounts.0.codex_home"
    assert missing_message =~ "env-backed path is missing"
  end

  defp create_bootstrap_repo!(repo_path, repo_name) do
    File.mkdir_p!(repo_path)
    File.write!(Path.join(repo_path, "README.md"), "#{repo_name}\n")

    File.write!(
      Path.join(repo_path, "Makefile"),
      "symphony-bootstrap:\n\tprintf '%s\\n' '#{repo_name}' > BOOTSTRAP_REPO.txt\n"
    )

    System.cmd("git", ["-C", repo_path, "init", "-b", "main"])
    System.cmd("git", ["-C", repo_path, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", repo_path, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", repo_path, "add", "README.md", "Makefile"])
    System.cmd("git", ["-C", repo_path, "commit", "-m", "initial"])
  end

  defp create_branch_ref!(repo_path, branch_name) do
    System.cmd("git", ["-C", repo_path, "branch", branch_name, "main"])
  end

  defp create_branch_without_bootstrap!(repo_path, branch_name) do
    System.cmd("git", ["-C", repo_path, "checkout", "-b", branch_name, "main"])
    File.write!(Path.join(repo_path, "Makefile"), "check:\n\t@true\n")
    System.cmd("git", ["-C", repo_path, "add", "Makefile"])
    System.cmd("git", ["-C", repo_path, "commit", "-m", "remove bootstrap target"])
    System.cmd("git", ["-C", repo_path, "checkout", "main"])
  end

  defp create_branch_with_failing_bootstrap!(repo_path, branch_name, failure_message) do
    System.cmd("git", ["-C", repo_path, "checkout", "-b", branch_name, "main"])

    File.write!(
      Path.join(repo_path, "Makefile"),
      """
      symphony-bootstrap:
      \t@printf '%s\\n' '#{failure_message}' >&2
      \t@exit 1
      """
    )

    System.cmd("git", ["-C", repo_path, "add", "Makefile"])
    System.cmd("git", ["-C", repo_path, "commit", "-m", "break bootstrap target"])
    System.cmd("git", ["-C", repo_path, "checkout", "main"])
  end

  defp repository_routing_hook do
    ~S"""
    extract_symphony_marker() {
      marker_name=$1
      printf '%s\n' "${SYMPHONY_ISSUE_DESCRIPTION:-}" | awk -v marker="$marker_name" '
        BEGIN { in_section = 0 }
        /^[[:space:]]*##[[:space:]]+Symphony[[:space:]]*$/ {
          in_section = 1
          next
        }
        in_section && /^[[:space:]]*##[[:space:]]+/ { exit }
        in_section {
          prefix = "^[[:space:]]*" marker ":[[:space:]]*"
          if ($0 ~ prefix) {
            line = $0
            sub(prefix, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (length(line) == 0) {
              print "__EMPTY__"
            } else {
              print line
            }
          }
        }
      '
    }
    resolve_repo_url() {
      case "$1" in
        maximlafe/lead_status) printf '%s\n' "${TEST_LEAD_STATUS_REPO_URL:?}" ;;
        maximlafe/symphony) printf '%s\n' "${TEST_SYMPHONY_REPO_URL:?}" ;;
        maximlafe/tg_live_export) printf '%s\n' "${TEST_TG_LIVE_EXPORT_REPO_URL:?}" ;;
        *) return 1 ;;
      esac
    }
    resolve_repo_labels() {
      printf '%s\n' "${SYMPHONY_ISSUE_LABELS:-}" | awk '
        {
          label = tolower($0)
          if (label == "repo:lead_status") {
            print "maximlafe/lead_status"
          } else if (label == "repo:symphony") {
            print "maximlafe/symphony"
          } else if (label == "repo:tg_live_export") {
            print "maximlafe/tg_live_export"
          }
        }
      '
    }
    resolve_project_repository() {
      project_slug=$1
      project_name=$2
      case "$project_slug" in
        symphony-bd5bc5b51675) printf '%s\n' "maximlafe/symphony"; return 0 ;;
        a6212aeb565c|telegram-full-export-v2-a6212aeb565c) printf '%s\n' "maximlafe/tg_live_export"; return 0 ;;
        dfbe2b1b972e|master-komand-dfbe2b1b972e|8209c2018e76|izvlechenie-zadach-8209c2018e76) printf '%s\n' "maximlafe/lead_status"; return 0 ;;
        448570ee6438|platforma-i-integraciya-448570ee6438) return 2 ;;
      esac
      case "$project_name" in
        "Symphony") printf '%s\n' "maximlafe/symphony" ;;
        "Telegram Full Export v2") printf '%s\n' "maximlafe/tg_live_export" ;;
        "Мастер команд"|"Извлечение задач") printf '%s\n' "maximlafe/lead_status" ;;
        "Платформа и интеграция") return 2 ;;
        *) return 1 ;;
      esac
    }
    detect_repo_default_branch() {
      branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
      if [ -z "$branch" ]; then
        branch=main
      fi
      printf '%s\n' "$branch"
    }
    append_note() {
      if [ -z "${setup_note:-}" ]; then
        setup_note=$1
      else
        setup_note=$(printf '%s\n%s' "$setup_note" "$1")
      fi
    }
    summarize_bootstrap_failure() {
      failure_log=$1
      awk '
        NF {
          last=$0
          if ($0 !~ /^make(\[[0-9]+\])?: / && $0 !~ /^Makefile:[0-9]+: warning:/ && $0 !~ /^Cloning into /) {
            preferred=$0
          }
        }
        END {
          if (preferred != "") {
            print preferred
          } else {
            print last
          }
        }
      ' "$failure_log"
    }
    write_bootstrap_blocker() {
      failure_log=$1
      failure_summary=$(summarize_bootstrap_failure "$failure_log")
      if printf '%s' "$failure_summary" | grep -Fq "No rule to make target" &&
         printf '%s' "$failure_summary" | grep -Fq "symphony-bootstrap"; then
        printf "Base branch '%s' in %s does not define make symphony-bootstrap.\n" "$base_branch" "$source_repository" > .symphony-base-branch-error
      else
        if [ -z "$failure_summary" ]; then
          failure_summary="unknown bootstrap failure"
        fi
        printf "Base branch '%s' in %s failed make symphony-bootstrap: %s\n" "$base_branch" "$source_repository" "$failure_summary" > .symphony-base-branch-error
      fi
    }
    issue_project_slug=${SYMPHONY_ISSUE_PROJECT_SLUG:-}
    issue_project_name=${SYMPHONY_ISSUE_PROJECT_NAME:-}
    if [ -n "$issue_project_name" ]; then
      project_display=$issue_project_name
    elif [ -n "$issue_project_slug" ]; then
      project_display=$issue_project_slug
    else
      project_display=unknown-project
    fi
    repo_labels=$(resolve_repo_labels)
    repo_label_count=$(printf '%s\n' "$repo_labels" | sed '/^$/d' | wc -l | tr -d ' ')
    requested_base_branches=$(extract_symphony_marker "Base branch")
    base_branch_marker_count=$(printf '%s\n' "$requested_base_branches" | sed '/^$/d' | wc -l | tr -d ' ')
    repo_override=
    resolved_project_repository=
    source_repository=
    source_repo_url=
    requested_base_branch=
    base_branch=
    setup_note=
    rm -f .symphony-base-branch-error .symphony-base-branch-note .symphony-source-repository .symphony-base-branch .symphony-bootstrap-error.log
    if [ "$repo_label_count" -gt 1 ]; then
      printf '%s\n' "Multiple repo:* labels found on the Linear issue." > .symphony-base-branch-error
      exit 0
    fi
    if [ "$repo_label_count" -eq 1 ]; then
      repo_override=$repo_labels
    fi
    resolved_project_repository=$(resolve_project_repository "$issue_project_slug" "$issue_project_name")
    project_resolution_status=$?
    case "$project_resolution_status" in
      0)
        source_repository=$resolved_project_repository
        if [ -n "$repo_override" ] && [ "$repo_override" != "$source_repository" ]; then
          printf "Project '%s' routes to '%s'; repo label points to '%s'.\n" "$project_display" "$source_repository" "$repo_override" > .symphony-base-branch-error
          exit 0
        fi
        ;;
      2)
        if [ -n "$repo_override" ]; then
          source_repository=$repo_override
        else
          printf "Project '%s' requires one repo label: repo:lead_status, repo:symphony, or repo:tg_live_export.\n" "$project_display" > .symphony-base-branch-error
          exit 0
        fi
        ;;
      *)
        printf "Project '%s' is not mapped to a repository for this workflow.\n" "$project_display" > .symphony-base-branch-error
        exit 0
        ;;
    esac
    source_repo_url=$(resolve_repo_url "$source_repository") || {
      printf "Repository '%s' is not in the allowlist.\n" "$source_repository" > .symphony-base-branch-error
      exit 0
    }
    if [ "$base_branch_marker_count" -gt 1 ]; then
      printf '%s\n' "Multiple Base branch: lines found in ## Symphony." > .symphony-base-branch-error
      exit 0
    elif [ "$base_branch_marker_count" -eq 1 ]; then
      requested_base_branch=$requested_base_branches
      if [ "$requested_base_branch" = "__EMPTY__" ] || printf '%s' "$requested_base_branch" | grep -Eq '[[:space:]]'; then
        printf '%s\n' "Base branch: in ## Symphony is empty or contains whitespace." > .symphony-base-branch-error
        exit 0
      fi
    fi
    if [ -n "$requested_base_branch" ]; then
      if git ls-remote --exit-code --heads "$source_repo_url" "$requested_base_branch" >/dev/null 2>&1; then
        git clone --depth 1 --single-branch --branch "$requested_base_branch" "$source_repo_url" .
        base_branch=$requested_base_branch
      else
        printf "Branch '%s' from Base branch: was not found in origin for %s.\n" "$requested_base_branch" "$source_repository" > .symphony-base-branch-error
        exit 0
      fi
    fi
    if [ -z "$base_branch" ]; then
      git clone --depth 1 "$source_repo_url" .
      base_branch=$(detect_repo_default_branch)
      append_note "Base branch marker is missing; using the repository default branch $base_branch."
    fi
    printf '%s\n' "$source_repository" > .symphony-source-repository
    printf '%s\n' "$base_branch" > .symphony-base-branch
    if [ -n "$setup_note" ]; then
      printf '%s\n' "$setup_note" > .symphony-base-branch-note
    fi
    if ! make -n symphony-bootstrap > .symphony-bootstrap-error.log 2>&1; then
      write_bootstrap_blocker .symphony-bootstrap-error.log
      exit 0
    fi
    if ! make symphony-bootstrap > .symphony-bootstrap-error.log 2>&1; then
      write_bootstrap_blocker .symphony-bootstrap-error.log
      exit 0
    fi
    rm -f .symphony-bootstrap-error.log
    """
  end

  defp repository_retry_hook do
    ~S"""
    extract_symphony_marker() {
      marker_name=$1
      printf '%s\n' "${SYMPHONY_ISSUE_DESCRIPTION:-}" | awk -v marker="$marker_name" '
        BEGIN { in_section = 0 }
        /^[[:space:]]*##[[:space:]]+Symphony[[:space:]]*$/ {
          in_section = 1
          next
        }
        in_section && /^[[:space:]]*##[[:space:]]+/ { exit }
        in_section {
          prefix = "^[[:space:]]*" marker ":[[:space:]]*"
          if ($0 ~ prefix) {
            line = $0
            sub(prefix, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (length(line) == 0) {
              print "__EMPTY__"
            } else {
              print line
            }
          }
        }
      '
    }
    resolve_repo_url() {
      case "$1" in
        maximlafe/lead_status) printf '%s\n' "${TEST_LEAD_STATUS_REPO_URL:?}" ;;
        maximlafe/symphony) printf '%s\n' "${TEST_SYMPHONY_REPO_URL:?}" ;;
        maximlafe/tg_live_export) printf '%s\n' "${TEST_TG_LIVE_EXPORT_REPO_URL:?}" ;;
        *) return 1 ;;
      esac
    }
    resolve_repo_labels() {
      printf '%s\n' "${SYMPHONY_ISSUE_LABELS:-}" | awk '
        {
          label = tolower($0)
          if (label == "repo:lead_status") {
            print "maximlafe/lead_status"
          } else if (label == "repo:symphony") {
            print "maximlafe/symphony"
          } else if (label == "repo:tg_live_export") {
            print "maximlafe/tg_live_export"
          }
        }
      '
    }
    resolve_project_repository() {
      project_slug=$1
      project_name=$2
      case "$project_slug" in
        symphony-bd5bc5b51675) printf '%s\n' "maximlafe/symphony"; return 0 ;;
        a6212aeb565c|telegram-full-export-v2-a6212aeb565c) printf '%s\n' "maximlafe/tg_live_export"; return 0 ;;
        dfbe2b1b972e|master-komand-dfbe2b1b972e|8209c2018e76|izvlechenie-zadach-8209c2018e76) printf '%s\n' "maximlafe/lead_status"; return 0 ;;
        448570ee6438|platforma-i-integraciya-448570ee6438) return 2 ;;
      esac
      case "$project_name" in
        "Symphony") printf '%s\n' "maximlafe/symphony" ;;
        "Telegram Full Export v2") printf '%s\n' "maximlafe/tg_live_export" ;;
        "Мастер команд"|"Извлечение задач") printf '%s\n' "maximlafe/lead_status" ;;
        "Платформа и интеграция") return 2 ;;
        *) return 1 ;;
      esac
    }
    detect_repo_default_branch() {
      branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
      if [ -z "$branch" ]; then
        branch=main
      fi
      printf '%s\n' "$branch"
    }
    resolve_current_repository() {
      previous_repository=$(cat .symphony-source-repository 2>/dev/null || true)
      if [ -n "$previous_repository" ]; then
        printf '%s\n' "$previous_repository"
        return 0
      fi
      git remote get-url origin 2>/dev/null | sed -E \
        -e 's#^git@github.com:##' \
        -e 's#^ssh://git@github.com/##' \
        -e 's#^https?://([^@/]+@)?github.com/##' \
        -e 's#\.git$##'
    }
    append_note() {
      if [ -z "${setup_note:-}" ]; then
        setup_note=$1
      else
        setup_note=$(printf '%s\n%s' "$setup_note" "$1")
      fi
    }
    issue_project_slug=${SYMPHONY_ISSUE_PROJECT_SLUG:-}
    issue_project_name=${SYMPHONY_ISSUE_PROJECT_NAME:-}
    if [ -n "$issue_project_name" ]; then
      project_display=$issue_project_name
    elif [ -n "$issue_project_slug" ]; then
      project_display=$issue_project_slug
    else
      project_display=unknown-project
    fi
    repo_labels=$(resolve_repo_labels)
    repo_label_count=$(printf '%s\n' "$repo_labels" | sed '/^$/d' | wc -l | tr -d ' ')
    requested_base_branches=$(extract_symphony_marker "Base branch")
    base_branch_marker_count=$(printf '%s\n' "$requested_base_branches" | sed '/^$/d' | wc -l | tr -d ' ')
    repo_override=
    resolved_project_repository=
    source_repository=
    source_repo_url=
    requested_base_branch=
    previous_base_branch=
    base_branch=
    base_branch_error=
    current_repository=
    setup_note=
    rm -f .symphony-base-branch-error .symphony-base-branch-note
    current_repository=$(resolve_current_repository)
    previous_base_branch=$(cat .symphony-base-branch 2>/dev/null || true)
    if [ "$repo_label_count" -gt 1 ]; then
      base_branch_error="Multiple repo:* labels found on the Linear issue."
    elif [ "$repo_label_count" -eq 1 ]; then
      repo_override=$repo_labels
    fi
    if [ -z "$base_branch_error" ]; then
      resolved_project_repository=$(resolve_project_repository "$issue_project_slug" "$issue_project_name")
      project_resolution_status=$?
      case "$project_resolution_status" in
        0)
          source_repository=$resolved_project_repository
          if [ -n "$repo_override" ] && [ "$repo_override" != "$source_repository" ]; then
            base_branch_error="Project '$project_display' routes to '$source_repository'; repo label points to '$repo_override'."
          fi
          ;;
        2)
          if [ -n "$repo_override" ]; then
            source_repository=$repo_override
          elif [ -n "$current_repository" ]; then
            source_repository=$current_repository
            append_note "Repo label is missing; reusing the bound repository $current_repository."
          else
            base_branch_error="Project '$project_display' requires one repo label: repo:lead_status, repo:symphony, or repo:tg_live_export."
          fi
          ;;
        *)
          base_branch_error="Project '$project_display' is not mapped to a repository for this workflow."
          ;;
      esac
    fi
    if [ -z "$base_branch_error" ] && [ -n "$current_repository" ] && [ "$current_repository" != "$source_repository" ]; then
      base_branch_error="Workspace is already bound to '$current_repository' but the ticket routes to '$source_repository'. A fresh workspace is required."
    fi
    if [ -z "$base_branch_error" ]; then
      source_repo_url=$(resolve_repo_url "$source_repository") || {
        base_branch_error="Repository '$source_repository' is not in the allowlist."
      }
    fi
    if [ -z "$base_branch_error" ] && [ "$base_branch_marker_count" -gt 1 ]; then
      base_branch_error="Multiple Base branch: lines found in ## Symphony."
    elif [ -z "$base_branch_error" ] && [ "$base_branch_marker_count" -eq 1 ]; then
      requested_base_branch=$requested_base_branches
      if [ "$requested_base_branch" = "__EMPTY__" ] || printf '%s' "$requested_base_branch" | grep -Eq '[[:space:]]'; then
        base_branch_error="Base branch: in ## Symphony is empty or contains whitespace."
      elif git ls-remote --exit-code --heads origin "$requested_base_branch" >/dev/null 2>&1; then
        base_branch=$requested_base_branch
      else
        base_branch_error="Branch '$requested_base_branch' from Base branch: was not found in origin for $source_repository."
      fi
    elif [ -n "$previous_base_branch" ]; then
      base_branch=$previous_base_branch
    fi
    if [ -n "$base_branch_error" ]; then
      printf '%s\n' "$base_branch_error" > .symphony-base-branch-error
      exit 0
    fi
    if [ -z "$base_branch" ]; then
      base_branch=$(detect_repo_default_branch)
      append_note "Base branch marker is missing; using the repository default branch $base_branch."
    fi
    printf '%s\n' "$source_repository" > .symphony-source-repository
    printf '%s\n' "$base_branch" > .symphony-base-branch
    if [ -n "$setup_note" ]; then
      printf '%s\n' "$setup_note" > .symphony-base-branch-note
    fi
    """
  end
end
