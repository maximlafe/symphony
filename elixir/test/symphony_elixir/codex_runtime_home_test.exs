defmodule SymphonyElixir.CodexRuntimeHomeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.RuntimeHome

  test "prepare builds a filtered runtime home without plugin config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-home-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      source_home = Path.join(test_root, "source-home")
      source_skills = Path.join([source_home, "skills", "custom"])
      source_config = Path.join(source_home, "config.toml")

      File.mkdir_p!(source_skills)
      File.write!(Path.join(source_home, "auth.json"), "{\"token\":\"secret\"}\n")
      File.write!(Path.join(source_skills, "SKILL.md"), "# custom\n")

      File.write!(source_config, """
      model = "gpt-5.4"

      [mcp_servers.linear]
      url = "https://mcp.linear.app/mcp"

      [plugins."github@openai-curated"]
      enabled = true

      [plugins."linear@openai-curated"]
      enabled = true

      [projects."/tmp/project"]
      trust_level = "trusted"
      """)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, runtime_home} = RuntimeHome.prepare(source_home)
      refute runtime_home == source_home
      assert String.starts_with?(runtime_home, Path.join(workspace_root, ".codex-runtime/homes/"))

      assert File.read!(Path.join(runtime_home, "auth.json")) == "{\"token\":\"secret\"}\n"
      assert {:ok, source_skills_root} = File.read_link(Path.join(runtime_home, "skills"))
      assert source_skills_root == Path.join(source_home, "skills")

      filtered_config = File.read!(Path.join(runtime_home, "config.toml"))

      refute filtered_config =~ "[plugins."
      assert filtered_config =~ "[mcp_servers.linear]"
      assert filtered_config =~ ~s([projects."/tmp/project"])
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare reuses runtime homes and rejects invalid inputs" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-home-existing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      runtime_home = Path.join([workspace_root, ".codex-runtime", "homes", "existing-home"])

      File.mkdir_p!(runtime_home)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, ^runtime_home} = RuntimeHome.prepare(runtime_home)
      assert {:error, :invalid_codex_home} = RuntimeHome.prepare(:invalid)
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare refreshes managed runtime files when source contents change" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-home-refresh-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      source_home = Path.join(test_root, "source-home")
      source_skills = Path.join([source_home, "skills", "custom"])
      source_auth = Path.join(source_home, "auth.json")
      source_config = Path.join(source_home, "config.toml")

      File.mkdir_p!(source_skills)
      File.write!(source_auth, "{\"token\":\"before\"}\n")
      File.write!(Path.join(source_skills, "SKILL.md"), "# custom\n")

      File.write!(source_config, """
      [mcp_servers.linear]
      url = "https://mcp.linear.app/mcp"
      """)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, runtime_home} = RuntimeHome.prepare(source_home)

      File.write!(source_auth, "{\"token\":\"after\"}\n")

      File.write!(source_config, """
      [plugins."github@openai-curated"]
      enabled = true
      """)

      {:ok, _paths} = File.rm_rf(Path.join(source_home, "skills"))

      assert {:ok, ^runtime_home} = RuntimeHome.prepare(source_home)
      assert File.read!(Path.join(runtime_home, "auth.json")) == "{\"token\":\"after\"}\n"
      refute File.exists?(Path.join(runtime_home, "config.toml"))
      refute File.exists?(Path.join(runtime_home, "skills"))
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare surfaces source read failures for managed auth and config files" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-home-source-errors-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      auth_error_home = Path.join(test_root, "auth-error-home")
      config_error_home = Path.join(test_root, "config-error-home")

      File.mkdir_p!(Path.join(auth_error_home, "auth.json"))
      File.mkdir_p!(Path.join(config_error_home, "config.toml"))
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:runtime_home_file_read_failed, auth_path, :eisdir}} =
               RuntimeHome.prepare(auth_error_home)

      assert auth_path == Path.join(auth_error_home, "auth.json")

      assert {:error, {:runtime_home_config_read_failed, config_path, :eisdir}} =
               RuntimeHome.prepare(config_error_home)

      assert config_path == Path.join(config_error_home, "config.toml")
    after
      File.rm_rf(test_root)
    end
  end

  test "prepare surfaces managed runtime write and cleanup failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-home-target-errors-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      read_error_home = Path.join(test_root, "read-error-home")
      File.mkdir_p!(read_error_home)
      File.write!(Path.join(read_error_home, "auth.json"), "{\"token\":\"secret\"}\n")

      assert {:ok, read_error_runtime_home} = RuntimeHome.prepare(read_error_home)
      File.rm!(Path.join(read_error_runtime_home, "auth.json"))
      File.mkdir_p!(Path.join(read_error_runtime_home, "auth.json"))

      assert {:error, {:runtime_home_file_read_failed, target_path, :eisdir}} =
               RuntimeHome.prepare(read_error_home)

      assert target_path == Path.join(read_error_runtime_home, "auth.json")

      symlink_error_home = Path.join(test_root, "symlink-error-home")
      symlink_source_skills = Path.join([symlink_error_home, "skills", "custom"])

      File.mkdir_p!(symlink_source_skills)
      File.write!(Path.join(symlink_source_skills, "SKILL.md"), "# custom\n")

      assert {:ok, symlink_runtime_home} = RuntimeHome.prepare(symlink_error_home)
      {:ok, _paths} = File.rm_rf(Path.join(symlink_runtime_home, "skills"))
      File.chmod!(symlink_runtime_home, 0o500)

      try do
        assert {:error, {:runtime_home_symlink_failed, source, target, symlink_reason}} =
                 RuntimeHome.prepare(symlink_error_home)

        assert source == Path.join(symlink_error_home, "skills")
        assert target == Path.join(symlink_runtime_home, "skills")
        assert symlink_reason in [:eacces, :eperm]
      after
        File.chmod!(symlink_runtime_home, 0o700)
      end

      remove_error_home = Path.join(test_root, "remove-error-home")
      remove_source_auth = Path.join(remove_error_home, "auth.json")

      File.mkdir_p!(remove_error_home)
      File.write!(remove_source_auth, "{\"token\":\"secret\"}\n")

      assert {:ok, remove_runtime_home} = RuntimeHome.prepare(remove_error_home)
      File.rm!(remove_source_auth)
      File.chmod!(remove_runtime_home, 0o500)

      try do
        assert {:error, {:runtime_home_remove_failed, remove_path, remove_reason}} =
                 RuntimeHome.prepare(remove_error_home)

        assert remove_path == Path.join(remove_runtime_home, "auth.json")
        assert remove_reason in [:eacces, :eperm]
      after
        File.chmod!(remove_runtime_home, 0o700)
      end
    after
      File.rm_rf(test_root)
    end
  end
end
