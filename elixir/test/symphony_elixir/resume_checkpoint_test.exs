defmodule SymphonyElixir.ResumeCheckpointTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ResumeCheckpoint

  test "capture writes a compact ready checkpoint and load detects stale workpad digest" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-resume-checkpoint-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "issue-resume-checkpoint", identifier: "LET-461", state: "In Progress"}
    workspace = Path.join(workspace_root, issue.identifier)

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nInitial state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-123")
    File.write!(Path.join(workspace, "tracked.txt"), "hello")

    init_git_repo!(workspace)
    {_, 0} = System.cmd("git", ["-C", workspace, "mv", "tracked.txt", "renamed.txt"])
    File.write!(Path.join(workspace, "new.txt"), "new")

    running_entry = %{
      verification_result: "passed",
      verification_summary: "handoff check passed",
      verification_checked_at: DateTime.utc_now(),
      latest_pr_snapshot: %{
        "url" => "https://github.com/maximlafe/symphony/pull/77",
        "state" => "OPEN",
        "has_pending_checks" => false,
        "has_actionable_feedback" => false,
        "feedback_digest" => "feedback-digest-77"
      }
    }

    checkpoint = ResumeCheckpoint.capture(issue, running_entry, workspace_root: workspace_root)

    assert checkpoint["available"] == true
    assert checkpoint["resume_ready"] == true
    assert checkpoint["branch"] == "main"
    assert is_binary(checkpoint["head"])
    assert checkpoint["changed_files"] == ["new.txt", "renamed.txt"]
    assert is_binary(checkpoint["workspace_diff_fingerprint"])
    assert checkpoint["workpad_ref"] == "comment-123"
    assert is_binary(checkpoint["workpad_digest"])
    assert checkpoint["last_validation_status"]["result"] == "passed"
    assert checkpoint["open_pr"]["number"] == 77
    assert checkpoint["pending_checks"] == false
    assert checkpoint["open_feedback"] == false
    assert checkpoint["feedback_digest"] == "feedback-digest-77"
    assert checkpoint["checkpoint_quality"] == "ready"
    assert checkpoint["checkpoint_origin"] == "resume_checkpoint"
    assert checkpoint["checkpoint_fallback_reasons"] == []
    assert checkpoint["validation_guard_result"] == "passed"
    assert File.exists?(checkpoint["manifest_path"])

    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nChanged")
    loaded = ResumeCheckpoint.load(issue, workspace_root: workspace_root)

    assert loaded["available"] == true
    assert loaded["resume_ready"] == false
    assert loaded["checkpoint_quality"] == "fallback"
    assert Enum.any?(loaded["fallback_reasons"], &String.contains?(&1, "workpad_digest"))
  end

  test "capture preserves feedback_digest from resume checkpoint when fresh PR snapshot is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-resume-checkpoint-feedback-fallback-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "issue-resume-feedback", identifier: "LET-461-FB", state: "In Progress"}
    workspace = Path.join(workspace_root, issue.identifier)

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nFeedback retry state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-feedback-fallback")
    File.write!(Path.join(workspace, "tracked.txt"), "tracked\n")
    init_git_repo!(workspace)

    running_entry = %{
      resume_checkpoint: %{
        "open_pr" => %{
          "number" => 78,
          "url" => "https://github.com/maximlafe/symphony/pull/78",
          "state" => "OPEN"
        },
        "pending_checks" => false,
        "open_feedback" => true,
        "feedback_digest" => "checkpoint-feedback-digest"
      }
    }

    checkpoint = ResumeCheckpoint.capture(issue, running_entry, workspace_root: workspace_root)

    assert checkpoint["open_pr"]["number"] == 78
    assert checkpoint["pending_checks"] == false
    assert checkpoint["open_feedback"] == true
    assert checkpoint["feedback_digest"] == "checkpoint-feedback-digest"
    assert checkpoint["checkpoint_quality"] == "pending_review"
  end

  test "capture stores active validation snapshot while exec_wait is in flight" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-resume-checkpoint-active-validation-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "issue-resume-active-validation", identifier: "LET-461-ACTIVE", state: "In Progress"}
    workspace = Path.join(workspace_root, issue.identifier)

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nValidation wait state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-active-validation")
    File.write!(Path.join(workspace, "tracked.txt"), "tracked\n")
    init_git_repo!(workspace)

    checkpoint =
      ResumeCheckpoint.capture(
        issue,
        %{
          current_command: "make symphony-validate",
          external_step: "exec_wait"
        },
        workspace_root: workspace_root
      )

    assert checkpoint["active_validation_snapshot"] == %{
             "command" => "make symphony-validate",
             "external_step" => "exec_wait",
             "validation_bundle_fingerprint" => "validation:repo-validate"
           }
  end

  test "capture normalizes active validation snapshot sources and command variants" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-resume-checkpoint-active-validation-variants-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "issue-resume-active-variants", identifier: "LET-461-ACTIVE-VARIANTS", state: "In Progress"}
    workspace = Path.join(workspace_root, issue.identifier)

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nValidation wait state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-active-validation-variants")
    File.write!(Path.join(workspace, "tracked.txt"), "tracked\n")
    init_git_repo!(workspace)

    from_mix_test =
      ResumeCheckpoint.capture(
        issue,
        %{
          current_command: "mix test test/symphony_elixir/core_test.exs",
          external_step: "exec_wait"
        },
        workspace_root: workspace_root
      )

    assert from_mix_test["active_validation_snapshot"] == %{
             "command" => "mix test test/symphony_elixir/core_test.exs",
             "external_step" => "exec_wait",
             "validation_bundle_fingerprint" => "validation:test"
           }

    from_dialyzer =
      ResumeCheckpoint.capture(
        issue,
        %{
          current_command: "mix dialyzer --format short",
          external_step: "exec_wait"
        },
        workspace_root: workspace_root
      )

    assert from_dialyzer["active_validation_snapshot"] == %{
             "command" => "mix dialyzer --format short",
             "external_step" => "exec_wait",
             "validation_bundle_fingerprint" => "validation:dialyzer"
           }

    from_running_snapshot =
      ResumeCheckpoint.capture(
        issue,
        %{
          active_validation_snapshot: %{
            "command" => "make symphony-validate",
            "external_step" => "exec_wait",
            "validation_bundle_fingerprint" => "validation:repo-validate",
            "wait_state" => "running",
            "result_ref" => "exec-123"
          }
        },
        workspace_root: workspace_root
      )

    assert from_running_snapshot["active_validation_snapshot"] == %{
             "command" => "make symphony-validate",
             "external_step" => "exec_wait",
             "validation_bundle_fingerprint" => "validation:repo-validate",
             "wait_state" => "running",
             "result_ref" => "exec-123"
           }

    from_resume_checkpoint =
      ResumeCheckpoint.capture(
        issue,
        %{
          current_command: "echo ok",
          external_step: "exec_wait",
          resume_checkpoint: %{
            "active_validation_snapshot" => %{
              "command" => "make symphony-validate",
              "external_step" => "exec_wait",
              "validation_bundle_fingerprint" => "validation:repo-validate",
              "wait_state" => "running",
              "result_ref" => "exec-456"
            }
          }
        },
        workspace_root: workspace_root
      )

    assert from_resume_checkpoint["active_validation_snapshot"] == %{
             "command" => "make symphony-validate",
             "external_step" => "exec_wait",
             "validation_bundle_fingerprint" => "validation:repo-validate",
             "wait_state" => "running",
             "result_ref" => "exec-456"
           }

    no_snapshot =
      ResumeCheckpoint.capture(
        issue,
        %{current_command: "   ", external_step: "exec_wait"},
        workspace_root: workspace_root
      )

    assert no_snapshot["active_validation_snapshot"] == nil

    no_snapshot_without_command =
      ResumeCheckpoint.capture(
        issue,
        %{external_step: "exec_wait"},
        workspace_root: workspace_root
      )

    assert no_snapshot_without_command["active_validation_snapshot"] == nil

    non_wait_external_step =
      ResumeCheckpoint.capture(
        issue,
        %{current_command: "make symphony-validate", external_step: "github_wait_for_checks"},
        workspace_root: workspace_root
      )

    assert non_wait_external_step["active_validation_snapshot"] == nil

    invalid_running_snapshot =
      ResumeCheckpoint.capture(
        issue,
        %{
          active_validation_snapshot: %{
            "command" => "make symphony-validate",
            "external_step" => "exec_wait"
          }
        },
        workspace_root: workspace_root
      )

    assert invalid_running_snapshot["active_validation_snapshot"] == nil
  end

  test "workspace_diff_fingerprint ignores internal workpad/checkpoint artifacts but detects real code diff" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-resume-checkpoint-diff-fingerprint-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "issue-resume-workspace-diff", identifier: "LET-461-DIFF", state: "In Progress"}
    workspace = Path.join(workspace_root, issue.identifier)

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nInitial state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-diff")
    File.write!(Path.join(workspace, "tracked.txt"), "hello")
    init_git_repo!(workspace)

    first = ResumeCheckpoint.capture(issue, %{}, workspace_root: workspace_root)
    assert is_binary(first["workspace_diff_fingerprint"])

    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nChanged locally")
    second = ResumeCheckpoint.capture(issue, %{}, workspace_root: workspace_root)
    assert second["workspace_diff_fingerprint"] == first["workspace_diff_fingerprint"]

    File.write!(Path.join(workspace, "tracked.txt"), "code change")
    third = ResumeCheckpoint.capture(issue, %{}, workspace_root: workspace_root)
    refute third["workspace_diff_fingerprint"] == first["workspace_diff_fingerprint"]
  end

  test "for_prompt trims blank feedback_digest to nil" do
    checkpoint = ResumeCheckpoint.for_prompt(%{"feedback_digest" => "   "})

    assert checkpoint["feedback_digest"] == nil
  end

  test "capture returns fallback checkpoint when workspace is missing" do
    issue = %Issue{id: "missing-workspace", identifier: "LET-462", state: "In Progress"}

    checkpoint =
      ResumeCheckpoint.capture(issue, %{}, workspace_root: Path.join(System.tmp_dir!(), "does-not-exist"))

    assert checkpoint["available"] == false
    assert checkpoint["resume_ready"] == false
    assert Enum.any?(checkpoint["fallback_reasons"], &String.contains?(&1, "workspace is unavailable"))
  end

  test "load falls back when checkpoint file is missing, unreadable, or invalid" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-resume-checkpoint-load-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "resume-load", identifier: "LET-463", state: "In Progress"}
    workspace = Path.join(workspace_root, issue.identifier)
    manifest_path = Path.join(workspace, ".symphony/resume/checkpoint.json")

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)

    missing = ResumeCheckpoint.load(issue, workspace_root: workspace_root)
    assert missing["available"] == false
    assert missing["resume_ready"] == false

    File.mkdir_p!(Path.dirname(manifest_path))
    File.write!(manifest_path, "{not-json")
    invalid_json = ResumeCheckpoint.load(issue, workspace_root: workspace_root)
    assert invalid_json["available"] == false
    assert invalid_json["resume_ready"] == false

    File.write!(manifest_path, "[]")
    invalid_shape = ResumeCheckpoint.load(issue, workspace_root: workspace_root)
    assert invalid_shape["available"] == false
    assert invalid_shape["resume_ready"] == false

    File.rm!(manifest_path)
    File.mkdir_p!(manifest_path)
    unreadable = ResumeCheckpoint.load(issue, workspace_root: workspace_root)
    assert unreadable["available"] == false
    assert unreadable["resume_ready"] == false
  end

  test "capture records checkpoint persistence failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-resume-checkpoint-persist-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "resume-persist", identifier: "LET-464", state: "In Progress"}
    workspace = Path.join(workspace_root, issue.identifier)

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\nInitial state")
    File.write!(Path.join(workspace, ".workpad-id"), "comment-456")
    File.write!(Path.join(workspace, "tracked.txt"), "hello")
    init_git_repo!(workspace)

    File.write!(Path.join(workspace, ".symphony"), "not-a-directory")
    checkpoint = ResumeCheckpoint.capture(issue, %{}, workspace_root: workspace_root)
    assert checkpoint["resume_ready"] == false
    assert Enum.any?(checkpoint["fallback_reasons"], &String.contains?(&1, "directory creation failed"))

    File.rm!(Path.join(workspace, ".symphony"))
    File.mkdir_p!(Path.join(workspace, ".symphony/resume/checkpoint.json"))
    checkpoint = ResumeCheckpoint.capture(issue, %{}, workspace_root: workspace_root)
    assert checkpoint["resume_ready"] == false
    assert Enum.any?(checkpoint["fallback_reasons"], &String.contains?(&1, "write failed"))
  end

  test "manifest_path and for_prompt normalize mixed checkpoint shapes" do
    assert ResumeCheckpoint.manifest_path(nil) == nil

    issue = %Issue{id: "issue-466", identifier: "LET-466", state: "In Progress"}
    assert is_binary(ResumeCheckpoint.manifest_path(issue, workspace_root: "/tmp"))

    checkpoint =
      ResumeCheckpoint.for_prompt(%{
        "available" => true,
        "changed_files" => "not-a-list",
        "fallback_reasons" => "single-reason",
        "last_validation_status" => "invalid",
        "open_pr" => %{"url" => "https://example.org/pull/1", "state" => "OPEN"},
        "pending_checks" => "yes",
        "open_feedback" => 1
      })

    assert checkpoint["changed_files"] == []
    assert is_list(checkpoint["fallback_reasons"])
    assert checkpoint["fallback_reasons"] != []
    assert checkpoint["last_validation_status"]["result"] == "unknown"
    assert checkpoint["pending_checks"] == nil
    assert checkpoint["open_feedback"] == nil
    assert checkpoint["resume_ready"] == false
    assert checkpoint["checkpoint_quality"] == "fallback"
  end

  test "for_prompt normalizes missing checkpoint shape" do
    checkpoint = ResumeCheckpoint.for_prompt(nil)

    assert checkpoint["available"] == false
    assert checkpoint["resume_ready"] == false
    assert is_list(checkpoint["fallback_reasons"])
    assert checkpoint["last_validation_status"]["result"] == "unknown"
    assert checkpoint["changed_files"] == []
  end

  test "capture on non-git workspace keeps fallback context compact" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-resume-checkpoint-non-git-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "resume-non-git", identifier: "LET-467", state: "In Progress"}
    workspace = Path.join(workspace_root, issue.identifier)

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)

    checkpoint =
      ResumeCheckpoint.capture(
        issue,
        %{latest_ci_wait_result: %{"pending_checks" => ["build"]}},
        workspace_root: workspace_root
      )

    assert checkpoint["available"] == true
    assert checkpoint["resume_ready"] == false
    assert checkpoint["branch"] == nil
    assert checkpoint["head"] == nil
    assert checkpoint["changed_files"] == []
    assert checkpoint["workspace_diff_fingerprint"] == nil
    assert checkpoint["workpad_ref"] == nil
    assert checkpoint["workpad_digest"] == nil
    assert checkpoint["open_pr"] == nil
    assert checkpoint["pending_checks"] == true
    assert checkpoint["open_feedback"] == nil
    assert checkpoint["checkpoint_quality"] == "fallback"
    assert Enum.any?(checkpoint["fallback_reasons"], &String.contains?(&1, "missing `branch`"))
  end

  test "capture normalizes PR snapshot edge cases and load revalidates sparse checkpoint" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-resume-checkpoint-edge-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "resume-edge", identifier: "LET-468", state: "In Progress"}
    workspace = Path.join(workspace_root, issue.identifier)
    manifest_path = Path.join(workspace, ".symphony/resume/checkpoint.json")

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.dirname(manifest_path))

    url_without_pull =
      ResumeCheckpoint.capture(
        issue,
        %{latest_pr_snapshot: %{"url" => "https://example.org/pr/abc", "state" => "OPEN"}},
        workspace_root: workspace_root
      )

    assert url_without_pull["open_pr"]["url"] == "https://example.org/pr/abc"
    assert url_without_pull["open_pr"]["number"] == nil
    assert url_without_pull["resume_ready"] == false

    non_binary_url =
      ResumeCheckpoint.capture(
        issue,
        %{latest_pr_snapshot: %{"url" => 123, "state" => "OPEN"}},
        workspace_root: workspace_root
      )

    assert non_binary_url["open_pr"] == nil

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "available" => true,
        "branch" => nil,
        "head" => nil,
        "workpad_digest" => nil,
        "fallback_reasons" => []
      })
    )

    loaded = ResumeCheckpoint.load(issue, workspace_root: workspace_root)
    assert loaded["available"] == true
    assert loaded["resume_ready"] == false
    assert Enum.any?(loaded["fallback_reasons"], &String.contains?(&1, "missing `branch`"))
  end

  defp init_git_repo!(workspace) do
    {_, 0} = System.cmd("git", ["-C", workspace, "init", "-b", "main"])
    {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.name", "Resume Checkpoint"])
    {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.email", "resume@example.com"])
    {_, 0} = System.cmd("git", ["-C", workspace, "add", "tracked.txt", "workpad.md", ".workpad-id"])
    {_, 0} = System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
  end
end
