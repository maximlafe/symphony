defmodule SymphonyElixir.CodexSkillSyncTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.SkillSync

  test "sync_codex_homes copies bundled skills into each configured CODEX_HOME" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-skill-sync-#{System.unique_integer([:positive])}"
      )

    try do
      source_root = Path.join(test_root, "bundled-skills")
      ambient_home = Path.join(test_root, "ambient-home")
      explicit_home = Path.join(test_root, "explicit-home")

      write_skill!(source_root, "linear", "# linear\n")
      write_skill!(source_root, "pull", "# pull\n")

      File.mkdir_p!(Path.join([ambient_home, "skills", "custom"]))
      File.write!(Path.join([ambient_home, "skills", "custom", "SKILL.md"]), "# custom\n")

      assert :ok = SkillSync.sync_codex_homes([ambient_home, explicit_home], source_root)

      assert File.read!(Path.join([ambient_home, "skills", "linear", "SKILL.md"])) == "# linear\n"
      assert File.read!(Path.join([ambient_home, "skills", "pull", "SKILL.md"])) == "# pull\n"
      assert File.read!(Path.join([explicit_home, "skills", "linear", "SKILL.md"])) == "# linear\n"
      assert File.read!(Path.join([explicit_home, "skills", "pull", "SKILL.md"])) == "# pull\n"
      assert File.read!(Path.join([ambient_home, "skills", "custom", "SKILL.md"])) == "# custom\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "sync_configured_homes uses the ambient and explicit CODEX_HOME entries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-configured-skill-sync-#{System.unique_integer([:positive])}"
      )

    previous_codex_home = System.get_env("CODEX_HOME")

    on_exit(fn ->
      restore_env("CODEX_HOME", previous_codex_home)
    end)

    try do
      source_root = Path.join(test_root, "bundled-skills")
      ambient_home = Path.join(test_root, "ambient-home")
      explicit_home = Path.join(test_root, "explicit-home")

      write_skill!(source_root, "commit", "# commit\n")
      System.put_env("CODEX_HOME", ambient_home)

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_accounts: [%{id: "primary", codex_home: explicit_home}]
      )

      assert :ok = SkillSync.sync_configured_homes(source_root: source_root)

      assert File.read!(Path.join([ambient_home, "skills", "commit", "SKILL.md"])) == "# commit\n"
      assert File.read!(Path.join([explicit_home, "skills", "commit", "SKILL.md"])) == "# commit\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "sync_codex_homes returns an error when bundled skills are unavailable" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-bundled-skills-#{System.unique_integer([:positive])}"
      )

    assert {:error, {:bundled_skills_unavailable, ^missing_root, :enoent}} =
             SkillSync.sync_codex_homes([Path.join(System.tmp_dir!(), "unused-home")], missing_root)
  end

  test "sync_codex_homes returns an error when the bundled skills directory is empty" do
    empty_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-empty-bundled-skills-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(empty_root)

      assert {:error, {:no_bundled_skills, ^empty_root}} =
               SkillSync.sync_codex_homes([Path.join(System.tmp_dir!(), "unused-home")], empty_root)
    after
      File.rm_rf(empty_root)
    end
  end

  test "sync_codex_homes returns an error when the skills root cannot be created" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-skill-sync-root-error-#{System.unique_integer([:positive])}"
      )

    try do
      source_root = Path.join(test_root, "bundled-skills")
      blocked_home = Path.join(test_root, "blocked-home")

      write_skill!(source_root, "linear", "# linear\n")
      File.write!(blocked_home, "not a directory\n")

      assert {:error, {:skills_root_create_failed, _, _reason}} =
               SkillSync.sync_codex_homes([blocked_home], source_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "sync_codex_homes returns an error when copying a bundled skill fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-skill-sync-copy-error-#{System.unique_integer([:positive])}"
      )

    try do
      source_root = Path.join(test_root, "bundled-skills")
      explicit_home = Path.join(test_root, "explicit-home")
      skill_dir = Path.join(source_root, "pull")
      broken_fifo = Path.join(skill_dir, "broken_fifo")

      write_skill!(source_root, "pull", "# pull\n")
      assert {_, 0} = System.cmd("mkfifo", [broken_fifo])

      assert {:error, {:skill_copy_failed, _, _, _reason}} =
               SkillSync.sync_codex_homes([explicit_home], source_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "sync_configured_homes logs a warning when the bundled skills root is missing" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-bundled-source-#{System.unique_integer([:positive])}"
      )

    previous_source_root = System.get_env("SYMPHONY_BUNDLED_SKILLS_ROOT")

    on_exit(fn ->
      restore_env("SYMPHONY_BUNDLED_SKILLS_ROOT", previous_source_root)
    end)

    System.put_env("SYMPHONY_BUNDLED_SKILLS_ROOT", missing_root)

    log =
      capture_log(fn ->
        assert :ok = SkillSync.sync_configured_homes(codex_homes: [Path.join(System.tmp_dir!(), "unused-home")])
      end)

    assert log =~ "Bundled worker skill sync skipped"
    assert log =~ "bundled_skills_unavailable"
  end

  defp write_skill!(source_root, name, content) do
    skill_dir = Path.join([source_root, name])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), content)
  end
end
