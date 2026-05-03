defmodule Mix.Tasks.AcceptanceCapability.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.AcceptanceCapability.Check

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("acceptance_capability.check")
    :ok
  end

  test "prints help" do
    output = capture_io(fn -> Check.run(["--help"]) end)
    assert output =~ "mix acceptance_capability.check"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Check.run(["--wat"])
    end
  end

  test "passes with no explicit capabilities from environment" do
    in_temp_workspace(fn workspace ->
      output =
        capture_io(fn ->
          Check.run(["--workspace", workspace])
        end)

      assert output =~ "Acceptance capability preflight passed: no explicit required capabilities"
    end)
  end

  test "uses description files and fails missing declared capability" do
    in_temp_workspace(fn workspace ->
      description_path = Path.join(workspace, "issue.md")
      File.write!(description_path, "Required capabilities: runtime_smoke")

      assert_raise Mix.Error, ~r/runtime_smoke requires one Makefile target/, fn ->
        Check.run(["--workspace", workspace, "--description-file", description_path])
      end
    end)
  end

  test "prints declared capabilities when preflight passes" do
    in_temp_workspace(fn workspace ->
      File.mkdir_p!(Path.join(workspace, ".git"))
      File.write!(Path.join(workspace, "Makefile"), "symphony-runtime-smoke:\n\t@true\n")
      description_path = Path.join(workspace, "issue.md")
      File.write!(description_path, "Required capabilities: runtime_smoke")

      output =
        capture_io(fn ->
          Check.run(["--workspace", workspace, "--description-file", description_path])
        end)

      assert output =~ "Acceptance capability preflight passed: runtime_smoke"
    end)
  end

  test "ignores execution-only required capability values" do
    in_temp_workspace(fn workspace ->
      File.mkdir_p!(Path.join(workspace, ".git"))
      description_path = Path.join(workspace, "issue.md")
      File.write!(description_path, "Required capabilities: repo_validation, pr_publication, pr_body_contract")

      output =
        capture_io(fn ->
          Check.run(["--workspace", workspace, "--description-file", description_path])
        end)

      assert output =~ "Acceptance capability preflight passed: no explicit required capabilities"
      assert output =~ "ignored execution-only values: repo_validation, pr_publication, pr_body_contract"
    end)
  end

  test "prints required and ignored capabilities together" do
    in_temp_workspace(fn workspace ->
      File.mkdir_p!(Path.join(workspace, ".git"))
      File.write!(Path.join(workspace, "Makefile"), "symphony-runtime-smoke:\n\t@true\n")
      description_path = Path.join(workspace, "issue.md")
      File.write!(description_path, "Required capabilities: runtime_smoke, repo_validation")

      output =
        capture_io(fn ->
          Check.run(["--workspace", workspace, "--description-file", description_path])
        end)

      assert output =~ "Acceptance capability preflight passed: runtime_smoke; ignored execution-only values: repo_validation"
    end)
  end

  defp in_temp_workspace(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    workspace = Path.join(System.tmp_dir!(), "acceptance-capability-task-test-#{unique}")

    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    try do
      fun.(workspace)
    after
      File.rm_rf!(workspace)
    end
  end
end
