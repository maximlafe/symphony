defmodule SymphonyElixir.ControllerFinalizerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, ControllerFinalizer}
  alias SymphonyElixir.Linear.Issue

  defmodule TrackerStub do
    def update_issue_state(issue_id, state_name) do
      case Application.get_env(:symphony_elixir, :controller_finalizer_tracker_recipient) do
        pid when is_pid(pid) -> send(pid, {:tracker_state_update, issue_id, state_name})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule TrackerFailStub do
    def update_issue_state(_issue_id, _state_name), do: {:error, :transition_denied}
  end

  setup do
    Application.put_env(:symphony_elixir, :controller_finalizer_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :controller_finalizer_tracker_recipient)
    end)

    :ok
  end

  test "eligible?/2 blocks repeat finalization for an action-required checkpoint head" do
    issue = %Issue{id: "issue-1", identifier: "LET-462", state: "In Progress"}

    checkpoint = %{
      "head" => "abc123",
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"},
      "controller_finalizer" => %{"status" => "action_required", "blocked_head" => "abc123"}
    }

    refute ControllerFinalizer.eligible?(issue, checkpoint)
  end

  test "eligible?/2 rejects issues outside active states" do
    issue = %Issue{id: "issue-2", identifier: "LET-462", state: "Done"}
    checkpoint = %{"open_pr" => %{"number" => 42}}

    refute ControllerFinalizer.eligible?(issue, checkpoint)
  end

  test "eligible?/2 handles map issues and malformed field types" do
    checkpoint = %{"open_pr" => %{"number" => 42}}

    assert ControllerFinalizer.eligible?(
             %{"state" => "In Progress", "id" => "issue-3", "identifier" => "LET-462"},
             checkpoint
           )

    refute ControllerFinalizer.eligible?(%{"state" => 123, "id" => "issue-3", "identifier" => "LET-462"}, checkpoint)

    refute ControllerFinalizer.eligible?(%{"state" => "In Progress", "id" => 123, "identifier" => "LET-462"}, checkpoint)

    refute ControllerFinalizer.eligible?(%{"state" => "In Progress", "id" => "issue-3", "identifier" => 456}, checkpoint)

    refute ControllerFinalizer.eligible?("In Progress", checkpoint)
  end

  test "run/3 returns not_applicable for missing checkpoint context" do
    issue = %Issue{id: "issue-not-applicable", identifier: "LET-462-NO-CHECKPOINT", state: "In Progress"}

    assert {:not_applicable, payload} = ControllerFinalizer.run(issue, nil)
    assert payload.reason =~ "prerequisites are not satisfied"

    refute ControllerFinalizer.eligible?(
             issue,
             %{"open_pr" => %{"url" => "https://github.com/acme/symphony/pull/0"}}
           )

    refute ControllerFinalizer.eligible?(
             issue,
             %{"open_pr" => %{"url" => "https://github.com/acme/symphony/compare/main"}}
           )
  end

  test "eligible?/2 tolerates non-binary head while checking blocked checkpoint" do
    issue = %Issue{id: "issue-head", identifier: "LET-462-HEAD", state: "In Progress"}

    checkpoint = %{
      "head" => 123,
      "open_pr" => %{"number" => 42},
      "controller_finalizer" => %{"status" => "action_required", "blocked_head" => "abc123"}
    }

    assert ControllerFinalizer.eligible?(issue, checkpoint)
  end

  test "run/3 completes deterministic finalization and transitions issue state on success" do
    issue = %Issue{id: "issue-success", identifier: "LET-462-SUCCESS", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-success",
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"}
    }

    executor = fn
      "sync_workpad", _args, _opts ->
        tool_success(%{"comment_id" => "workpad-comment"})

      "github_wait_for_checks", _args, _opts ->
        tool_success(%{
          "all_green" => true,
          "pending_checks" => [],
          "failed_checks" => [],
          "checks" => []
        })

      "github_pr_snapshot", _args, _opts ->
        tool_success(%{
          "url" => "https://github.com/acme/symphony/pull/42",
          "state" => "OPEN",
          "has_pending_checks" => false,
          "has_actionable_feedback" => false
        })

      "symphony_handoff_check", _args, _opts ->
        tool_success(%{
          "manifest" => %{
            "passed" => true,
            "summary" => "final gate is fresh",
            "manifest_path" => ".symphony/verification/handoff-manifest.json"
          }
        })
    end

    assert {:ok, payload} =
             ControllerFinalizer.run(
               issue,
               checkpoint,
               repo: "acme/symphony",
               tracker_module: TrackerStub,
               tool_executor: executor
             )

    assert payload.checkpoint["controller_finalizer"]["status"] == "succeeded"
    assert payload.checkpoint["pending_checks"] == false
    assert payload.checkpoint["open_feedback"] == false
    assert_receive {:tracker_state_update, "issue-success", "In Review"}
  end

  test "run/3 returns fallback when controller context cannot be built" do
    issue = %Issue{id: "issue-context", identifier: "LET-462-MISSING-WORKSPACE", state: "In Progress"}

    checkpoint = %{
      "head" => "head-context",
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"}
    }

    assert {:fallback, payload} =
             ControllerFinalizer.run(
               issue,
               checkpoint,
               repo: "acme/symphony",
               tool_executor: fn _tool, _args, _opts -> raise "tool should not be called" end
             )

    assert payload.reason =~ "workspace is unavailable"
    assert payload.checkpoint["controller_finalizer"]["status"] == "action_required"
  end

  test "run/3 returns retry when sync_workpad fails transiently" do
    issue = %Issue{id: "issue-sync-fail", identifier: "LET-462-SYNC-FAIL", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-sync-fail",
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"}
    }

    script = %{
      "sync_workpad" => {:error, %{"error" => %{"message" => "workpad sync failed"}}}
    }

    assert {:retry, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "workpad sync failed"
    assert payload.checkpoint["controller_finalizer"]["status"] == "waiting"
  end

  test "run/3 returns fallback when checks are complete but failed" do
    issue = %Issue{id: "issue-failed-checks", identifier: "LET-462-FAILED", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-failed",
      "open_pr" => %{"number" => 52, "url" => "https://github.com/acme/symphony/pull/52"}
    }

    executor = fn
      "sync_workpad", _args, _opts ->
        tool_success(%{"comment_id" => "workpad-comment"})

      "github_wait_for_checks", _args, _opts ->
        tool_success(%{
          "all_green" => false,
          "pending_checks" => [],
          "failed_checks" => [%{"name" => "test", "status" => "COMPLETED", "conclusion" => "FAILURE"}],
          "checks" => []
        })
    end

    assert {:fallback, payload} =
             ControllerFinalizer.run(
               issue,
               checkpoint,
               repo: "acme/symphony",
               tracker_module: TrackerStub,
               tool_executor: executor
             )

    assert payload.reason == "pull request checks failed"
    assert payload.checkpoint["controller_finalizer"]["status"] == "action_required"
    assert payload.checkpoint["controller_finalizer"]["blocked_head"] == "head-failed"
  end

  test "run/3 returns retry on wait-for-checks timeout without losing checkpoint context" do
    issue = %Issue{id: "issue-timeout", identifier: "LET-462-TIMEOUT", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-timeout",
      "open_pr" => %{"number" => 99, "url" => "https://github.com/acme/symphony/pull/99"}
    }

    executor = fn
      "sync_workpad", _args, _opts ->
        tool_success(%{"comment_id" => "workpad-comment"})

      "github_wait_for_checks", _args, _opts ->
        tool_failure(%{
          "error" => %{
            "message" => "github_wait_for_checks: timed out before checks reached a terminal state."
          }
        })
    end

    assert {:retry, payload} =
             ControllerFinalizer.run(
               issue,
               checkpoint,
               repo: "acme/symphony",
               tracker_module: TrackerStub,
               tool_executor: executor
             )

    assert payload.checkpoint["controller_finalizer"]["status"] == "waiting"
    assert payload.checkpoint["controller_finalizer"]["reason"] =~ "timed out"
    assert payload.reason =~ "timed out"
  end

  test "run/3 returns retry when snapshot call fails transiently" do
    issue = %Issue{id: "issue-snapshot-fail", identifier: "LET-462-SNAPSHOT-FAIL", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-snapshot-fail",
      "open_pr" => %{"number" => 99, "url" => "https://github.com/acme/symphony/pull/99"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" => {:error, %{"error" => %{"message" => "snapshot unavailable"}}}
    }

    assert {:retry, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "snapshot unavailable"
  end

  test "run/3 returns retry when snapshot still reports pending checks" do
    issue = %Issue{id: "issue-snapshot-pending", identifier: "LET-462-SNAPSHOT-PENDING", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-snapshot-pending",
      "open_pr" => %{"number" => 101, "url" => "https://github.com/acme/symphony/pull/101"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/101",
           "state" => "OPEN",
           "has_pending_checks" => true,
           "has_actionable_feedback" => false
         }}
    }

    assert {:retry, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "pull request checks are still pending"
    assert payload.checkpoint["pending_checks"] == true
  end

  test "run/3 returns fallback when snapshot reports actionable feedback" do
    issue = %Issue{id: "issue-snapshot-feedback", identifier: "LET-462-SNAPSHOT-FEEDBACK", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-snapshot-feedback",
      "open_pr" => %{"number" => 102, "url" => "https://github.com/acme/symphony/pull/102"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/102",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => true
         }}
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "pull request has actionable feedback"
    assert payload.checkpoint["controller_finalizer"]["status"] == "action_required"
  end

  test "run/3 returns fallback when handoff tool execution fails" do
    issue = %Issue{id: "issue-handoff-error", identifier: "LET-462-HANDOFF-ERROR", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-handoff-error",
      "open_pr" => %{"number" => 103, "url" => "https://github.com/acme/symphony/pull/103"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/103",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:error, %{error: %{message: "handoff failed"}}}
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "handoff failed"
    assert payload.checkpoint["controller_finalizer"]["status"] == "action_required"
  end

  test "run/3 returns fallback when handoff manifest fails" do
    issue = %Issue{id: "issue-handoff-manifest", identifier: "LET-462-HANDOFF-MANIFEST", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-handoff-manifest",
      "open_pr" => %{"number" => 104, "url" => "https://github.com/acme/symphony/pull/104"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/104",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:ok, %{"passed" => false, "summary" => "missing proof", "missing_items" => ["check"]}}
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "symphony_handoff_check failed"
  end

  test "run/3 returns retry when issue state transition fails" do
    issue = %Issue{id: "issue-transition-fail", identifier: "LET-462-TRANSITION-FAIL", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-transition-fail",
      "open_pr" => %{"number" => 105, "url" => "https://github.com/acme/symphony/pull/105"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/105",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:ok, %{"manifest" => %{"passed" => true, "manifest_path" => ".symphony/verification/handoff-manifest.json"}}}
    }

    assert {:retry, payload} =
             run_finalizer(issue, checkpoint, script, tracker_module: TrackerFailStub)

    assert payload.reason == "failed to transition issue state"
    assert payload.checkpoint["controller_finalizer"]["status"] == "waiting"
  end

  test "run/3 handles malformed dynamic tool responses" do
    issue = %Issue{id: "issue-malformed", identifier: "LET-462-MALFORMED", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-malformed",
      "open_pr" => %{"number" => 106, "url" => "https://github.com/acme/symphony/pull/106"}
    }

    malformed_responses = [
      %{"unexpected" => true},
      %{"success" => true, "contentItems" => [%{"type" => "inputText", "text" => "not-json"}]},
      %{"success" => true, "contentItems" => [%{"type" => "inputText", "text" => "[]"}]},
      %{"success" => true, "contentItems" => []}
    ]

    for response <- malformed_responses do
      script = %{"sync_workpad" => {:raw, response}}
      assert {:retry, payload} = run_finalizer(issue, checkpoint, script)
      assert payload.reason =~ "invalid"
    end

    script = %{"sync_workpad" => {:error, %{"status" => "boom"}}}
    assert {:retry, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason =~ "dynamic tool failed"
  end

  test "run/3 resolves repo from git origin when repo option is omitted" do
    issue = %Issue{id: "issue-git-origin", identifier: "LET-462-GIT-ORIGIN", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier, git_init: true, git_remote: "git@github.com:acme/symphony.git")

    checkpoint = %{
      "head" => "head-git-origin",
      "open_pr" => %{"number" => 107, "url" => "https://github.com/acme/symphony/pull/107"}
    }

    script = %{
      "sync_workpad" => fn args, _opts ->
        assert args["issue_id"] == "issue-git-origin"
        {:ok, %{"comment_id" => "workpad-comment"}}
      end,
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/107",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn args, _opts ->
        assert args["repo"] == "acme/symphony"

        {:ok,
         %{
           "manifest" => %{
             "passed" => true,
             "summary" => "ok",
             "manifest_path" => ".symphony/verification/handoff-manifest.json"
           }
         }}
      end
    }

    assert {:ok, payload} = run_finalizer(issue, checkpoint, script, repo: :omit)
    assert payload.details["repo"] == "acme/symphony"
  end

  test "run/3 returns fallback when git remote origin is missing or unparsable" do
    issue_missing = %Issue{id: "issue-git-missing", identifier: "LET-462-GIT-MISSING", state: "In Progress"}
    _workspace_missing = create_workspace!(issue_missing.identifier, git_init: true)

    checkpoint_missing = %{
      "head" => "head-git-missing",
      "open_pr" => %{"number" => 108, "url" => "https://github.com/acme/symphony/pull/108"}
    }

    assert {:fallback, payload_missing} =
             run_finalizer(issue_missing, checkpoint_missing, %{}, repo: :omit)

    assert payload_missing.reason == "cannot resolve git remote origin url"

    issue_bad = %Issue{id: "issue-git-bad", identifier: "LET-462-GIT-BAD", state: "In Progress"}
    _workspace_bad = create_workspace!(issue_bad.identifier, git_init: true, git_remote: "origin-invalid")

    checkpoint_bad = %{
      "head" => "head-git-bad",
      "open_pr" => %{"number" => 109, "url" => "https://github.com/acme/symphony/pull/109"}
    }

    assert {:fallback, payload_bad} =
             run_finalizer(issue_bad, checkpoint_bad, %{}, repo: :omit)

    assert payload_bad.reason == "cannot parse OWNER/REPO from remote url"
  end

  test "run/3 handles open_pr url parsing edge cases" do
    issue = %Issue{id: "issue-url", identifier: "LET-462-URL", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-url",
      "open_pr" => %{"url" => "https://github.com/acme/symphony/pull/110"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => 123,
           "state" => "OPEN",
           "has_pending_checks" => true,
           "has_actionable_feedback" => false
         }}
    }

    assert {:retry, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.checkpoint["open_pr"]["number"] == nil

    refute ControllerFinalizer.eligible?(
             issue,
             %{"open_pr" => %{"url" => "https://github.com/acme/symphony/pull/abc"}}
           )
  end

  test "run/3 returns fallback when workpad files are missing" do
    issue = %Issue{id: "issue-workpad-missing", identifier: "LET-462-WORKPAD-MISSING", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier, with_workpad_ref: false)

    checkpoint = %{
      "head" => "head-workpad-missing",
      "open_pr" => %{"number" => 111, "url" => "https://github.com/acme/symphony/pull/111"}
    }

    assert {:fallback, payload} =
             ControllerFinalizer.run(issue, checkpoint, repo: "acme/symphony")

    assert payload.reason =~ ".workpad-id is missing"
  end

  defp create_workspace!(identifier) do
    create_workspace!(identifier, [])
  end

  defp create_workspace!(identifier, opts) do
    root = Config.settings!().workspace.root
    workspace = Path.join(root, identifier)
    git_init? = Keyword.get(opts, :git_init, false)
    git_remote = Keyword.get(opts, :git_remote)
    with_workpad = Keyword.get(opts, :with_workpad, true)
    with_workpad_ref = Keyword.get(opts, :with_workpad_ref, true)

    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    if with_workpad do
      File.write!(Path.join(workspace, "workpad.md"), "## Codex Workpad\n\n- checkpoint\n")
    end

    if with_workpad_ref do
      File.write!(Path.join(workspace, ".workpad-id"), "workpad-comment\n")
    end

    if git_init? or is_binary(git_remote) do
      {"", 0} = System.cmd("git", ["init", "-q"], cd: workspace)

      if is_binary(git_remote) do
        {"", 0} = System.cmd("git", ["remote", "add", "origin", git_remote], cd: workspace)
      end
    end

    workspace
  end

  defp run_finalizer(issue, checkpoint, script, opts \\ []) do
    tracker_module = Keyword.get(opts, :tracker_module, TrackerStub)
    repo_opt = Keyword.get(opts, :repo, "acme/symphony")
    executor = script_executor(script)

    base_opts = [tracker_module: tracker_module, tool_executor: executor]

    final_opts =
      case repo_opt do
        :omit -> base_opts
        repo -> Keyword.put(base_opts, :repo, repo)
      end

    ControllerFinalizer.run(issue, checkpoint, final_opts)
  end

  defp script_executor(script) when is_map(script) do
    fn tool, args, tool_opts ->
      case Map.get(script, tool) do
        {:ok, payload} -> tool_success(payload)
        {:error, payload} -> tool_failure(payload)
        {:raw, response} -> response
        fun when is_function(fun, 2) -> encode_result(fun.(args, tool_opts))
        nil -> raise "unexpected tool call: #{tool}"
      end
    end
  end

  defp encode_result({:ok, payload}), do: tool_success(payload)
  defp encode_result({:error, payload}), do: tool_failure(payload)
  defp encode_result(response) when is_map(response), do: response

  defp tool_success(payload) when is_map(payload) do
    %{
      "success" => true,
      "contentItems" => [%{"type" => "inputText", "text" => Jason.encode!(payload)}]
    }
  end

  defp tool_failure(payload) when is_map(payload) do
    %{
      "success" => false,
      "contentItems" => [%{"type" => "inputText", "text" => Jason.encode!(payload)}]
    }
  end
end
