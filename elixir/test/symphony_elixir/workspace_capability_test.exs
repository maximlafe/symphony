defmodule SymphonyElixir.WorkspaceCapabilityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkspaceCapability

  test "prelaunch gate rejects repo workspaces missing required validation targets" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-missing-target-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-498")

      File.mkdir_p!(Path.join(workspace, ".git"))
      write_makefile!(workspace, ["symphony-preflight", "symphony-handoff-check"])

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_capability_rejected, details}} =
               WorkspaceCapability.prelaunch_gate(workspace, tool_probe: &always_available_tool/1)

      assert details.reason == :missing_make_target
      assert details.command_class == :validation
      assert details.target == "symphony-validate"
      assert is_binary(details.manifest_path)
    after
      File.rm_rf(test_root)
    end
  end

  test "capability manifest cache invalidates when root Makefile changes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-cache-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-499")

      File.mkdir_p!(Path.join(workspace, ".git"))
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      write_makefile!(workspace, ["symphony-preflight", "symphony-validate", "symphony-handoff-check"])

      assert {:ok, first_manifest} =
               WorkspaceCapability.load_or_probe(workspace, tool_probe: &always_available_tool/1)

      assert File.exists?(first_manifest["manifest_path"])

      write_makefile!(workspace, ["symphony-preflight", "symphony-handoff-check"])

      assert {:ok, second_manifest} =
               WorkspaceCapability.load_or_probe(workspace, tool_probe: &always_available_tool/1)

      refute second_manifest["cache_key"] == first_manifest["cache_key"]

      assert {:error, {:workspace_capability_rejected, details}} =
               WorkspaceCapability.prelaunch_gate(workspace, tool_probe: &always_available_tool/1)

      assert details.reason == :missing_make_target
      assert details.target == "symphony-validate"
    after
      File.rm_rf(test_root)
    end
  end

  test "prelaunch gate rejects runtime class when required tools are missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-missing-tool-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-500")

      File.mkdir_p!(Path.join(workspace, ".git"))
      write_makefile!(workspace, ["symphony-preflight", "symphony-validate", "symphony-handoff-check"])
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_capability_rejected, details}} =
               WorkspaceCapability.prelaunch_gate(workspace, tool_probe: &tool_probe_without_rg/1)

      assert details.reason == :missing_tool
      assert details.command_class == :runtime
      assert details.tool == "rg"
    after
      File.rm_rf(test_root)
    end
  end

  test "prelaunch gate skips capability enforcement for non-repo workspaces" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-non-repo-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-501")

      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, manifest} = WorkspaceCapability.prelaunch_gate(workspace)
      assert manifest["mode"] == "non_repo_workspace"
      assert manifest["reason"] == "repo_root_not_found"
    after
      File.rm_rf(test_root)
    end
  end

  test "prelaunch gate accepts repo workspaces when all command classes are available" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-happy-path-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-502")

      File.mkdir_p!(Path.join(workspace, ".git"))
      write_makefile!(workspace, ["symphony-preflight", "symphony-validate", "symphony-handoff-check"], ["NOT_A_RULE"])
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, manifest} =
               WorkspaceCapability.prelaunch_gate(workspace, tool_probe: &always_available_tool/1)

      assert manifest["mode"] == "repo_workspace"
      assert String.ends_with?(manifest["workspace"]["repo_root"], "/workspaces/MT-502")
      assert is_binary(manifest["captured_at"])
    after
      File.rm_rf(test_root)
    end
  end

  test "prelaunch gate rejects validation class when make is unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-missing-make-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-503")

      File.mkdir_p!(Path.join(workspace, ".git"))
      write_makefile!(workspace, ["symphony-preflight", "symphony-validate", "symphony-handoff-check"])
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_capability_rejected, details}} =
               WorkspaceCapability.prelaunch_gate(workspace, tool_probe: &tool_probe_without_make/1)

      assert details.reason == :missing_tool
      assert details.command_class == :validation
      assert details.tool == "make"
    after
      File.rm_rf(test_root)
    end
  end

  test "prelaunch gate rejects pr_tail class when gh is unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-missing-gh-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-504")

      File.mkdir_p!(Path.join(workspace, ".git"))
      write_makefile!(workspace, ["symphony-preflight", "symphony-validate", "symphony-handoff-check"])
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_capability_rejected, details}} =
               WorkspaceCapability.prelaunch_gate(workspace, tool_probe: &tool_probe_without_gh/1)

      assert details.reason == :missing_tool
      assert details.command_class == :pr_tail
      assert details.tool == "gh"
    after
      File.rm_rf(test_root)
    end
  end

  test "manifest probe handles missing and unreadable makefile paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-makefile-paths-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      missing_makefile_workspace = Path.join(workspace_root, "MT-505")
      directory_makefile_workspace = Path.join(workspace_root, "MT-506")

      File.mkdir_p!(Path.join(missing_makefile_workspace, ".git"))
      File.mkdir_p!(Path.join(directory_makefile_workspace, ".git"))
      File.mkdir_p!(Path.join(directory_makefile_workspace, "Makefile"))

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_capability_rejected, missing_details}} =
               WorkspaceCapability.prelaunch_gate(
                 missing_makefile_workspace,
                 tool_probe: &always_available_tool/1
               )

      assert missing_details.reason == :missing_make_target

      assert {:error, {:workspace_capability_rejected, unreadable_details}} =
               WorkspaceCapability.prelaunch_gate(
                 directory_makefile_workspace,
                 tool_probe: &always_available_tool/1
               )

      assert unreadable_details.reason == :missing_make_target
    after
      File.rm_rf(test_root)
    end
  end

  test "load_or_probe handles cache edge cases and default arities" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-cache-edges-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-507")

      File.mkdir_p!(Path.join(workspace, ".git"))
      write_makefile!(workspace, ["symphony-preflight", "symphony-validate", "symphony-handoff-check"])
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, manifest} = WorkspaceCapability.load_or_probe(workspace)
      assert manifest["mode"] == "repo_workspace"

      assert {:ok, timed_manifest} =
               WorkspaceCapability.load_or_probe(
                 workspace,
                 tool_probe: &always_available_tool/1,
                 time_source: fn -> :not_a_datetime end
               )

      assert is_binary(timed_manifest["captured_at"])

      cache_path = timed_manifest["manifest_path"]

      corrupted_cache =
        timed_manifest
        |> Map.put("validation_entrypoints", [%{"available" => true}, %{"unexpected" => true}])
        |> Map.put("captured_at", "invalid")

      File.write!(cache_path, Jason.encode!(corrupted_cache))

      assert {:ok, _} =
               WorkspaceCapability.prelaunch_gate(workspace, tool_probe: &always_available_tool/1)

      assert {:error, {:invalid_workspace, 123}} = WorkspaceCapability.load_or_probe(123, [])
    after
      File.rm_rf(test_root)
    end
  end

  test "prelaunch gate rejects unsupported approval policy before runtime launch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-capability-approval-policy-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-508")

      File.mkdir_p!(Path.join(workspace, ".git"))
      write_makefile!(workspace, ["symphony-preflight", "symphony-validate", "symphony-handoff-check"])
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_capability_rejected, details}} =
               WorkspaceCapability.prelaunch_gate(
                 workspace,
                 tool_probe: &always_available_tool/1,
                 approval_policy: %{"reject" => %{"sandbox_approval" => true}}
               )

      assert details.reason == :unsupported_approval_policy
      assert details.command_class == :runtime
      assert details.approval_policy == "reject"
      assert "never" in details.supported_approval_policies
    after
      File.rm_rf(test_root)
    end
  end

  defp write_makefile!(workspace, targets, extra_lines \\ [])
       when is_binary(workspace) and is_list(targets) and is_list(extra_lines) do
    phony = ".PHONY: " <> Enum.join(targets, " ")

    bodies =
      Enum.map(targets, fn target ->
        """
        #{target}:
        \t@echo #{target}
        """
      end)

    File.write!(Path.join(workspace, "Makefile"), Enum.join([phony | bodies] ++ extra_lines, "\n"))
  end

  defp always_available_tool(tool), do: "/tmp/tools/#{tool}"

  defp tool_probe_without_rg("rg"), do: nil
  defp tool_probe_without_rg(tool), do: always_available_tool(tool)

  defp tool_probe_without_make("make"), do: nil
  defp tool_probe_without_make(tool), do: always_available_tool(tool)

  defp tool_probe_without_gh("gh"), do: nil
  defp tool_probe_without_gh(tool), do: always_available_tool(tool)
end
