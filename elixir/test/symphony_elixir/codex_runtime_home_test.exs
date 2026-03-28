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
end
