defmodule SymphonyElixir.ControllerFinalizerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{Config, ControllerFinalizer, HandoffCheck}
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

  test "eligible?/2 blocks repeat finalization when head is missing but fallback fingerprint matches" do
    issue = %Issue{id: "issue-fingerprint", identifier: "LET-462-FINGERPRINT", state: "In Progress"}

    checkpoint = %{
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"},
      "controller_finalizer" => %{
        "status" => "action_required",
        "reason" => "pull request has actionable feedback",
        "blocked_reason" => "pull request has actionable feedback",
        "blocked_pr_number" => 42,
        "blocked_head" => nil
      }
    }

    refute ControllerFinalizer.eligible?(issue, checkpoint)
  end

  test "eligible?/2 allows rerun when head is missing but fallback fingerprint does not match PR" do
    issue = %Issue{id: "issue-fingerprint-open", identifier: "LET-462-FINGERPRINT-OPEN", state: "In Progress"}

    checkpoint = %{
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"},
      "controller_finalizer" => %{
        "status" => "action_required",
        "reason" => "pull request has actionable feedback",
        "blocked_reason" => "pull request has actionable feedback",
        "blocked_pr_number" => 41,
        "blocked_head" => nil
      }
    }

    assert ControllerFinalizer.eligible?(issue, checkpoint)
  end

  test "eligible?/2 parses blocked PR fingerprints when blocked_pr_number is a string" do
    issue = %Issue{id: "issue-fingerprint-string", identifier: "LET-462-FINGERPRINT-STRING", state: "In Progress"}

    matching_checkpoint = %{
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"},
      "controller_finalizer" => %{
        "status" => "action_required",
        "reason" => "pull request has actionable feedback",
        "blocked_reason" => "pull request has actionable feedback",
        "blocked_pr_number" => "42",
        "blocked_head" => nil
      }
    }

    refute ControllerFinalizer.eligible?(issue, matching_checkpoint)

    invalid_checkpoint =
      put_in(
        matching_checkpoint,
        ["controller_finalizer", "blocked_pr_number"],
        "not-a-number"
      )

    assert ControllerFinalizer.eligible?(issue, invalid_checkpoint)
  end

  test "run/3 completes deterministic finalization and transitions issue state on success" do
    issue = %Issue{id: "issue-success", identifier: "LET-462-SUCCESS", state: "In Progress"}
    workspace = create_workspace!(issue.identifier)

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
        maybe_write_contract_lock(workspace, issue.id, "test-contract-revision")

        tool_success(%{
          "manifest" => %{
            "passed" => true,
            "summary" => "final gate is fresh",
            "contract_revision" => "test-contract-revision",
            "issue" => %{"id" => issue.id},
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

  test "run/3 uses default github_wait_for_checks poll interval when workflow omits override" do
    issue = %Issue{id: "issue-default-wait-poll", identifier: "LET-462-DEFAULT-WAIT", state: "In Progress"}
    workspace = create_workspace!(issue.identifier)
    test_pid = self()

    checkpoint = %{
      "head" => "head-default-wait",
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"}
    }

    executor = fn
      "sync_workpad", _args, _opts ->
        tool_success(%{"comment_id" => "workpad-comment"})

      "github_wait_for_checks", args, _opts ->
        send(test_pid, {:wait_for_checks_args, args})

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
        maybe_write_contract_lock(workspace, issue.id, "test-contract-revision")

        tool_success(%{
          "manifest" => %{
            "passed" => true,
            "summary" => "final gate is fresh",
            "contract_revision" => "test-contract-revision",
            "issue" => %{"id" => issue.id},
            "manifest_path" => ".symphony/verification/handoff-manifest.json"
          }
        })
    end

    assert {:ok, _payload} =
             ControllerFinalizer.run(
               issue,
               checkpoint,
               repo: "acme/symphony",
               tracker_module: TrackerStub,
               tool_executor: executor
             )

    assert_receive {:wait_for_checks_args, wait_args}
    assert wait_args["poll_interval_ms"] == 30_000
  end

  test "run/3 preserves issue description across struct/map issues and accepts git runner override" do
    checkpoint = %{
      "head" => "head-description-coverage",
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"}
    }

    git_runner = fn _args, _opts ->
      {:ok, ""}
    end

    struct_issue = %Issue{
      id: "issue-struct-description",
      identifier: "LET-462-DESC-STRUCT",
      state: "In Progress",
      description: "Struct issue description"
    }

    struct_workspace = create_workspace!(struct_issue.identifier)

    struct_executor = fn
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
        maybe_write_contract_lock(struct_workspace, struct_issue.id, "test-contract-revision")

        tool_success(%{
          "manifest" => %{
            "passed" => true,
            "summary" => "final gate is fresh",
            "contract_revision" => "test-contract-revision",
            "issue" => %{"id" => struct_issue.id},
            "manifest_path" => ".symphony/verification/handoff-manifest.json"
          }
        })
    end

    assert {:ok, _payload} =
             ControllerFinalizer.run(
               struct_issue,
               checkpoint,
               repo: "acme/symphony",
               tracker_module: TrackerStub,
               tool_executor: struct_executor,
               git_runner: git_runner
             )

    map_issue = %{
      "id" => "issue-map-description",
      "identifier" => "LET-462-DESC-MAP",
      "state" => "In Progress",
      "description" => "Map issue description",
      "labels" => []
    }

    map_workspace = create_workspace!(map_issue["identifier"])

    map_executor = fn
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
        maybe_write_contract_lock(map_workspace, map_issue["id"], "test-contract-revision")

        tool_success(%{
          "manifest" => %{
            "passed" => true,
            "summary" => "final gate is fresh",
            "contract_revision" => "test-contract-revision",
            "issue" => %{"id" => map_issue["id"]},
            "manifest_path" => ".symphony/verification/handoff-manifest.json"
          }
        })
    end

    assert {:ok, _payload} =
             ControllerFinalizer.run(
               map_issue,
               checkpoint,
               repo: "acme/symphony",
               tracker_module: TrackerStub,
               tool_executor: map_executor,
               git_runner: git_runner
             )
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

  test "run/3 blocks review transition when acceptance contract lock mismatches handoff manifest" do
    issue = %Issue{id: "issue-lock-mismatch", identifier: "LET-462-LOCK-MISMATCH", state: "In Progress"}
    workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-lock-mismatch",
      "open_pr" => %{"number" => 142, "url" => "https://github.com/acme/symphony/pull/142"}
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
          "url" => "https://github.com/acme/symphony/pull/142",
          "state" => "OPEN",
          "has_pending_checks" => false,
          "has_actionable_feedback" => false
        })

      "symphony_handoff_check", _args, _opts ->
        maybe_write_contract_lock(workspace, issue.id, "lock-revision-old")

        tool_success(%{
          "manifest" => %{
            "passed" => true,
            "summary" => "final gate is fresh",
            "contract_revision" => "lock-revision-new",
            "issue" => %{"id" => issue.id},
            "manifest_path" => ".symphony/verification/handoff-manifest.json"
          }
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

    assert payload.reason == "handoff manifest transition guard failed"
    assert payload.checkpoint["controller_finalizer"]["status"] == "action_required"
    assert payload.details["reason_code"] == "handoff_manifest_stale"
    refute_receive {:tracker_state_update, "issue-lock-mismatch", "In Review"}
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

  test "run/3 tolerates invalid UTF-8 in dynamic tool failure payloads" do
    issue = %Issue{id: "issue-invalid-utf8", identifier: "LET-462-UTF8", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier)

    checkpoint = %{
      "head" => "head-invalid-utf8",
      "open_pr" => %{"number" => 42, "url" => "https://github.com/acme/symphony/pull/42"}
    }

    invalid_json =
      <<
        208,
        189,
        208,
        181,
        32,
        209,
        130,
        209,
        128,
        208,
        181,
        208,
        177,
        209,
        131,
        208,
        181,
        209,
        130,
        209,
        129,
        209,
        143,
        44,
        32,
        208,
        145,
        208,
        148,
        47,
        209,
        129,
        209
      >>

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

      "github_pr_snapshot", args, tool_opts ->
        DynamicTool.execute(
          "github_pr_snapshot",
          args,
          gh_runner: fn gh_args, _opts ->
            case gh_args do
              ["pr", "view", "42", "-R", "acme/symphony", "--json", "state,url,labels,reviewDecision,mergeStateStatus,statusCheckRollup"] ->
                {:ok, invalid_json}
            end
          end,
          workspace: tool_opts[:workspace]
        )

      "symphony_handoff_check", _args, _opts ->
        flunk("handoff check should not run after a snapshot failure")
    end

    assert {:retry, payload} =
             ControllerFinalizer.run(
               issue,
               checkpoint,
               repo: "acme/symphony",
               tracker_module: TrackerStub,
               tool_executor: executor
             )

    assert payload.reason == "GitHub CLI returned invalid JSON."
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
           "has_actionable_feedback" => true,
           "feedback_digest" => "feedback-digest-102"
         }}
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "pull request has actionable feedback"
    assert payload.checkpoint["controller_finalizer"]["status"] == "action_required"
    assert payload.checkpoint["feedback_digest"] == "feedback-digest-102"
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

  test "run/3 fails fast before handoff when delivery:tdd red proof is missing" do
    issue = %Issue{
      id: "issue-proof-red",
      identifier: "LET-462-PROOF-RED",
      state: "In Progress",
      labels: ["delivery:tdd"]
    }

    _workspace = create_workspace!(issue.identifier, workpad_body: validation_workpad())

    checkpoint = %{
      "head" => "head-proof-red",
      "open_pr" => %{"number" => 204, "url" => "https://github.com/acme/symphony/pull/204"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/204",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, _opts ->
        flunk("handoff check should not run when required proof checks are missing")
      end
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "required proof checks are missing before handoff"

    assert %{"check" => "red_proof", "source" => "issue label `delivery:tdd`"} =
             hd(payload.details["proof_diagnostic"]["missing_checks"])
  end

  test "run/3 fails fast before handoff when runtime smoke proof is missing" do
    issue = %Issue{id: "issue-proof-runtime", identifier: "LET-462-PROOF-RUNTIME", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier, workpad_body: validation_workpad())

    checkpoint = %{
      "head" => "head-proof-runtime",
      "open_pr" => %{"number" => 205, "url" => "https://github.com/acme/symphony/pull/205"},
      "changed_files" => ["elixir/lib/symphony_elixir/validation_gate.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/205",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, _opts ->
        flunk("handoff check should not run when required proof checks are missing")
      end
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "required proof checks are missing before handoff"

    assert %{"check" => "runtime_smoke", "source" => "validation gate change class `runtime_contract`"} =
             hd(payload.details["proof_diagnostic"]["missing_checks"])
  end

  test "run/3 fails fast with both proof requirements when both are missing" do
    issue = %Issue{
      id: "issue-proof-both",
      identifier: "LET-462-PROOF-BOTH",
      state: "In Progress",
      labels: ["delivery:tdd"]
    }

    _workspace = create_workspace!(issue.identifier, workpad_body: validation_workpad())

    checkpoint = %{
      "head" => "head-proof-both",
      "open_pr" => %{"number" => 207, "url" => "https://github.com/acme/symphony/pull/207"},
      "changed_files" => ["elixir/lib/symphony_elixir/validation_gate.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/207",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, _opts ->
        flunk("handoff check should not run when required proof checks are missing")
      end
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "required proof checks are missing before handoff"
    assert Enum.map(payload.details["proof_diagnostic"]["missing_checks"], & &1["check"]) == ["red_proof", "runtime_smoke"]
  end

  test "run/3 fails fast before handoff when final validation gate checks are missing" do
    issue = %Issue{id: "issue-proof-final-gate", identifier: "LET-462-PROOF-FINAL-GATE", state: "In Progress"}

    _workspace =
      create_workspace!(
        issue.identifier,
        workpad_body: """
        ## Codex Workpad

        ### Validation
        - [x] preflight: `make symphony-preflight`
        - [x] targeted tests: `mix test test/symphony_elixir/controller_finalizer_test.exs`
        """
      )

    checkpoint = %{
      "head" => "head-proof-final-gate",
      "open_pr" => %{"number" => 2051, "url" => "https://github.com/acme/symphony/pull/2051"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/2051",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, _opts ->
        flunk("handoff check should not run when final validation checks are missing")
      end
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "required validation gate checks are missing before handoff"
    assert payload.details["proof_diagnostic"]["missing_final_checks"] == ["repo_validation"]
  end

  test "run/3 keeps backend-only scenario unblocked when proof checks are not required" do
    issue = %Issue{id: "issue-proof-backend", identifier: "LET-462-PROOF-BACKEND", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier, workpad_body: validation_workpad())

    checkpoint = %{
      "head" => "head-proof-backend",
      "open_pr" => %{"number" => 206, "url" => "https://github.com/acme/symphony/pull/206"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/206",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:ok, %{"manifest" => %{"passed" => true, "manifest_path" => ".symphony/verification/handoff-manifest.json"}}}
    }

    assert {:ok, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.checkpoint["controller_finalizer"]["status"] == "succeeded"
  end

  test "run/3 fails fast before handoff when proof mapping drifts from acceptance matrix" do
    issue = %Issue{
      id: "issue-proof-contract-drift",
      identifier: "LET-462-PROOF-CONTRACT-DRIFT",
      state: "In Progress",
      description: """
      ## Acceptance Matrix

      | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
      | -- | -- | -- | -- | -- | -- |
      | AM-1 | attachment proof | uploaded attachment mapping is required | artifact | runtime-proof.log | run_executed |
      """
    }

    _workspace = create_workspace!(issue.identifier, workpad_body: invalid_proof_mapping_workpad())

    checkpoint = %{
      "head" => "head-proof-contract-drift",
      "open_pr" => %{"number" => 2061, "url" => "https://github.com/acme/symphony/pull/2061"},
      "changed_files" => ["elixir/lib/symphony_elixir/handoff_check.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/2061",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, _opts ->
        flunk("handoff check should not run when proof contract is already inconsistent")
      end
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "proof contract is inconsistent before handoff"

    assert "acceptance matrix item `AM-1` expects artifact mapping `artifact:<title>`" in payload.details["proof_diagnostic"]["proof_contract_errors"]
  end

  test "run/3 fails fast before handoff when canonical linked PR attachment is missing" do
    issue = %Issue{
      id: "issue-proof-contract-pr-evidence",
      identifier: "LET-462-PROOF-CONTRACT-PR-EVIDENCE",
      state: "In Progress",
      description: """
      ## Acceptance Matrix

      | id | scenario | expected_outcome | proof_type | proof_target | proof_semantic |
      | -- | -- | -- | -- | -- | -- |
      | AM-1 | attachment proof | uploaded attachment mapping is required | artifact | runtime-proof.log | run_executed |
      """,
      attachments: [%{"title" => "runtime-proof.log", "url" => "https://uploads.linear.app/workspace/runtime-proof.log"}]
    }

    _workspace = create_workspace!(issue.identifier, workpad_body: valid_artifact_proof_mapping_workpad())

    checkpoint = %{
      "head" => "head-proof-contract-pr-evidence",
      "open_pr" => %{"number" => 2062, "url" => "https://github.com/acme/symphony/pull/2062"},
      "changed_files" => ["elixir/lib/symphony_elixir/handoff_check.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/2062",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, _opts ->
        flunk("handoff check should not run when PR evidence channel contract is inconsistent")
      end
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "proof contract is inconsistent before handoff"

    assert "evidence channel is missing canonical issue-linked PR URL attachment" in payload.details["proof_diagnostic"]["proof_contract_errors"]
  end

  test "run/3 supports map issues with mixed label types and enforces red proof from atom labels" do
    issue = %{
      "id" => "issue-map-labels",
      "identifier" => "LET-462-MAP-LABELS",
      "state" => "In Progress",
      "labels" => [:"delivery:tdd", 123]
    }

    _workspace = create_workspace!(issue["identifier"], workpad_body: validation_workpad())

    checkpoint = %{
      "head" => "head-map-labels",
      "open_pr" => %{"number" => 208, "url" => "https://github.com/acme/symphony/pull/208"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/208",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, _opts ->
        flunk("handoff check should not run when required proof checks are missing")
      end
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "required proof checks are missing before handoff"
    assert Enum.map(payload.details["proof_diagnostic"]["missing_checks"], & &1["check"]) == ["red_proof"]
  end

  test "run/3 handles map issues with malformed labels without false proof requirements" do
    issue = %{
      "id" => "issue-map-malformed-labels",
      "identifier" => "LET-462-MAP-MALFORMED-LABELS",
      "state" => "In Progress",
      "labels" => "delivery:tdd"
    }

    _workspace = create_workspace!(issue["identifier"], workpad_body: validation_workpad())

    checkpoint = %{
      "head" => "head-map-malformed-labels",
      "open_pr" => %{"number" => 209, "url" => "https://github.com/acme/symphony/pull/209"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/209",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:ok, %{"manifest" => %{"passed" => true, "manifest_path" => ".symphony/verification/handoff-manifest.json"}}}
    }

    assert {:ok, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.checkpoint["controller_finalizer"]["status"] == "succeeded"
  end

  test "run/3 normalizes map issue attachments with sourceType and ignores non-map entries" do
    issue = %{
      "id" => "issue-map-attachments",
      "identifier" => "LET-462-MAP-ATTACHMENTS",
      "state" => "In Progress",
      "description" => "Map issue with attachment normalization coverage.",
      "attachments" => [
        %{
          "title" => "PR #214",
          "url" => "https://github.com/acme/symphony/pull/214",
          "sourceType" => "github"
        },
        %{
          title: "PR #215",
          url: "https://github.com/acme/symphony/pull/215",
          sourceType: "github"
        },
        "noise"
      ]
    }

    _workspace = create_workspace!(issue["identifier"], workpad_body: validation_workpad())

    checkpoint = %{
      "head" => "head-map-attachments",
      "open_pr" => %{"number" => 214, "url" => "https://github.com/acme/symphony/pull/214"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/214",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:ok, %{"manifest" => %{"passed" => true, "manifest_path" => ".symphony/verification/handoff-manifest.json"}}}
    }

    assert {:ok, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.checkpoint["controller_finalizer"]["status"] == "succeeded"
  end

  test "run/3 keeps working when workpad disappears after sync and file read fails" do
    issue = %Issue{id: "issue-proof-workpad-gone", identifier: "LET-462-PROOF-WORKPAD-GONE", state: "In Progress"}
    workspace = create_workspace!(issue.identifier, workpad_body: validation_workpad())

    checkpoint = %{
      "head" => "head-proof-workpad-gone",
      "open_pr" => %{"number" => 210, "url" => "https://github.com/acme/symphony/pull/210"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => fn _args, _opts ->
        File.rm!(Path.join(workspace, "workpad.md"))
        {:ok, %{"comment_id" => "workpad-comment"}}
      end,
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/210",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:ok, %{"manifest" => %{"passed" => true, "manifest_path" => ".symphony/verification/handoff-manifest.json"}}}
    }

    assert {:ok, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.checkpoint["controller_finalizer"]["status"] == "succeeded"
  end

  test "run/3 treats whitespace-only workpad as empty and keeps pre-handoff non-blocking" do
    issue = %Issue{id: "issue-proof-workpad-whitespace", identifier: "LET-462-PROOF-WORKPAD-WS", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier, workpad_body: "\n   \n")

    checkpoint = %{
      "head" => "head-proof-workpad-whitespace",
      "open_pr" => %{"number" => 2101, "url" => "https://github.com/acme/symphony/pull/2101"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/2101",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:ok, %{"manifest" => %{"passed" => true, "manifest_path" => ".symphony/verification/handoff-manifest.json"}}}
    }

    assert {:ok, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.checkpoint["controller_finalizer"]["status"] == "succeeded"
  end

  test "run/3 parses validation commands without backticks and uses git diff/base-branch fallback" do
    issue = %Issue{id: "issue-proof-git-diff", identifier: "LET-462-PROOF-GIT-DIFF", state: "In Progress"}

    remote_repo = Path.join(System.tmp_dir!(), "controller-finalizer-remote-#{System.unique_integer([:positive])}")
    File.rm_rf!(remote_repo)
    File.mkdir_p!(remote_repo)
    {_output, 0} = System.cmd("git", ["init", "--bare"], cd: remote_repo)

    workspace =
      create_workspace!(
        issue.identifier,
        git_init: true,
        git_remote: remote_repo,
        workpad_body: validation_workpad_without_backticks()
      )

    write_file!(workspace, ".symphony-base-branch", "main\n")
    prepare_git_history!(workspace, "main")
    add_runtime_contract_change!(workspace)

    checkpoint = %{
      "head" => "head-proof-git-diff",
      "open_pr" => %{"number" => 211, "url" => "https://github.com/acme/symphony/pull/211"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/211",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, _opts ->
        flunk("handoff check should not run when required proof checks are missing")
      end
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "required proof checks are missing before handoff"
    assert Enum.map(payload.details["proof_diagnostic"]["missing_checks"], & &1["check"]) == ["runtime_smoke"]
    assert payload.details["proof_diagnostic"]["change_classes"] == ["runtime_contract"]
  end

  test "run/3 normalizes non-canonical validation labels before pre-handoff gate evaluation" do
    issue = %Issue{id: "issue-proof-canonical-labels", identifier: "LET-462-CANON-LABELS", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier, workpad_body: validation_workpad_with_prefixed_labels())

    checkpoint = %{
      "head" => "head-proof-canonical-labels",
      "open_pr" => %{"number" => 2111, "url" => "https://github.com/acme/symphony/pull/2111"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/2111",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:ok, %{"manifest" => %{"passed" => true, "manifest_path" => ".symphony/verification/handoff-manifest.json"}}}
    }

    assert {:ok, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.checkpoint["controller_finalizer"]["status"] == "succeeded"
  end

  test "run/3 tolerates unknown validation labels while keeping canonical checks intact" do
    issue = %Issue{id: "issue-proof-unknown-labels", identifier: "LET-462-UNKNOWN-LABELS", state: "In Progress"}

    _workspace =
      create_workspace!(
        issue.identifier,
        workpad_body: """
        ## Codex Workpad

        ### Validation
        - [x] custom gate marker: `echo marker`
        - [x] preflight: `make symphony-preflight`
        - [x] targeted tests: `mix test test/symphony_elixir/controller_finalizer_test.exs`
        - [x] repo validation: `make symphony-validate`
        """
      )

    checkpoint = %{
      "head" => "head-proof-unknown-labels",
      "open_pr" => %{"number" => 2112, "url" => "https://github.com/acme/symphony/pull/2112"},
      "changed_files" => ["elixir/lib/symphony_elixir/error_classifier.ex"]
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/2112",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => {:ok, %{"manifest" => %{"passed" => true, "manifest_path" => ".symphony/verification/handoff-manifest.json"}}}
    }

    assert {:ok, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.checkpoint["controller_finalizer"]["status"] == "succeeded"
  end

  test "run/3 defaults empty .symphony-base-branch to main" do
    issue = %Issue{id: "issue-proof-empty-base", identifier: "LET-462-PROOF-EMPTY-BASE", state: "In Progress"}

    remote_repo = Path.join(System.tmp_dir!(), "controller-finalizer-remote-#{System.unique_integer([:positive])}")
    File.rm_rf!(remote_repo)
    File.mkdir_p!(remote_repo)
    {_output, 0} = System.cmd("git", ["init", "--bare"], cd: remote_repo)

    workspace =
      create_workspace!(
        issue.identifier,
        git_init: true,
        git_remote: remote_repo,
        workpad_body: validation_workpad_without_backticks()
      )

    write_file!(workspace, ".symphony-base-branch", "\n")
    prepare_git_history!(workspace, "main")
    add_runtime_contract_change!(workspace)

    checkpoint = %{
      "head" => "head-proof-empty-base",
      "open_pr" => %{"number" => 212, "url" => "https://github.com/acme/symphony/pull/212"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/212",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, _opts ->
        flunk("handoff check should not run when required proof checks are missing")
      end
    }

    assert {:fallback, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "required proof checks are missing before handoff"
    assert Enum.map(payload.details["proof_diagnostic"]["missing_checks"], & &1["check"]) == ["runtime_smoke"]
    assert payload.details["proof_diagnostic"]["change_classes"] == ["runtime_contract"]
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
        assert args["phase"] == "review"

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

  test "run/3 does not source execution evidence run token from workpad" do
    issue = %Issue{id: "issue-run-token-forward", identifier: "LET-716-RUN-TOKEN", state: "In Progress"}

    _workspace =
      create_workspace!(
        issue.identifier,
        workpad_body: validation_workpad_with_execution_evidence("run-token-716")
      )

    checkpoint = %{
      "head" => "head-run-token-forward",
      "open_pr" => %{"number" => 207, "url" => "https://github.com/acme/symphony/pull/207"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/207",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn args, _opts ->
        refute Map.has_key?(args, "execution_evidence_run_token")
        assert args["execution_evidence_run_token"] == nil

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

    assert {:ok, payload} = run_finalizer(issue, checkpoint, script)
    assert payload.reason == "controller finalizer completed successfully"
  end

  test "run/3 forwards runtime execution attempt token to handoff check tool opts" do
    issue = %Issue{id: "issue-runtime-token-forward", identifier: "LET-716-RUNTIME-TOKEN", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier, workpad_body: validation_workpad())

    checkpoint = %{
      "head" => "head-runtime-token-forward",
      "open_pr" => %{"number" => 208, "url" => "https://github.com/acme/symphony/pull/208"}
    }

    script = %{
      "sync_workpad" => {:ok, %{"comment_id" => "workpad-comment"}},
      "github_wait_for_checks" => {:ok, %{"all_green" => true, "pending_checks" => [], "failed_checks" => [], "checks" => []}},
      "github_pr_snapshot" =>
        {:ok,
         %{
           "url" => "https://github.com/acme/symphony/pull/208",
           "state" => "OPEN",
           "has_pending_checks" => false,
           "has_actionable_feedback" => false
         }},
      "symphony_handoff_check" => fn _args, tool_opts ->
        assert tool_opts[:execution_attempt_token] == "run-token-208"

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

    assert {:ok, payload} =
             run_finalizer(
               issue,
               checkpoint,
               script,
               execution_attempt_token: "run-token-208"
             )

    assert payload.reason == "controller finalizer completed successfully"
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

  test "run/3 returns not_applicable when workpad.md is missing but .workpad-id is present" do
    issue = %Issue{id: "issue-workpad-benign-missing", identifier: "LET-530-WORKPAD-MISSING", state: "In Progress"}
    _workspace = create_workspace!(issue.identifier, with_workpad: false, with_workpad_ref: true)

    checkpoint = %{
      "head" => "head-workpad-benign-missing",
      "open_pr" => %{"number" => 112, "url" => "https://github.com/acme/symphony/pull/112"}
    }

    assert {:not_applicable, payload} =
             ControllerFinalizer.run(issue, checkpoint, repo: "acme/symphony")

    assert payload.reason == "workpad.md is missing for controller finalizer"
    assert payload.checkpoint["controller_finalizer"]["status"] == "not_applicable"
    assert payload.checkpoint["controller_finalizer"]["reason"] == "workpad.md is missing for controller finalizer"
    assert payload.checkpoint["controller_finalizer"]["blocked_head"] == nil
    assert payload.details["workpad_path"] =~ "workpad.md"
    assert payload.details["workpad_ref_path"] =~ ".workpad-id"
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
    workpad_body = Keyword.get(opts, :workpad_body, "## Codex Workpad\n\n- checkpoint\n")

    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    if with_workpad do
      File.write!(Path.join(workspace, "workpad.md"), workpad_body)
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
    passthrough_opts = Keyword.drop(opts, [:tracker_module, :repo])

    base_opts = [tracker_module: tracker_module, tool_executor: executor] ++ passthrough_opts

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
        {:ok, payload} ->
          payload
          |> maybe_materialize_handoff_contract(tool, args, tool_opts)
          |> tool_success()

        {:error, payload} ->
          tool_failure(payload)

        {:raw, response} ->
          response

        fun when is_function(fun, 2) ->
          fun.(args, tool_opts)
          |> encode_result()
          |> maybe_materialize_handoff_response(tool, args, tool_opts)

        nil ->
          raise "unexpected tool call: #{tool}"
      end
    end
  end

  defp encode_result({:ok, payload}), do: tool_success(payload)
  defp encode_result({:error, payload}), do: tool_failure(payload)
  defp encode_result(response) when is_map(response), do: response

  defp maybe_materialize_handoff_response(response, tool, args, tool_opts)
       when is_map(response) and tool == "symphony_handoff_check" do
    with true <- response["success"] == true,
         %{"contentItems" => [%{"text" => text} | _]} <- response,
         {:ok, payload} <- Jason.decode(text) do
      payload = maybe_materialize_handoff_contract(payload, tool, args, tool_opts)

      %{
        response
        | "contentItems" => [%{"type" => "inputText", "text" => Jason.encode!(payload)}]
      }
    else
      _ -> response
    end
  end

  defp maybe_materialize_handoff_response(response, _tool, _args, _tool_opts), do: response

  defp maybe_materialize_handoff_contract(payload, "symphony_handoff_check", args, tool_opts)
       when is_map(payload) and is_map(args) and is_list(tool_opts) do
    case payload["manifest"] do
      %{} = manifest ->
        workspace = Keyword.get(tool_opts, :workspace)
        issue_id = args["issue_id"]
        revision = manifest["contract_revision"] || get_in(manifest, ["acceptance_contract", "revision"]) || "test-contract-revision"

        normalized_manifest =
          manifest
          |> Map.put_new("contract_revision", revision)
          |> Map.put_new("issue", %{"id" => issue_id})

        maybe_write_contract_lock(workspace, issue_id, revision)

        Map.put(payload, "manifest", normalized_manifest)

      _ ->
        payload
    end
  end

  defp maybe_materialize_handoff_contract(payload, _tool, _args, _tool_opts), do: payload

  defp maybe_write_contract_lock(workspace, issue_id, revision)
       when is_binary(workspace) and workspace != "" and is_binary(revision) and revision != "" do
    lock_path = Path.join(workspace, HandoffCheck.default_contract_lock_path())

    lock_payload = %{
      "version" => 1,
      "issue" => %{"id" => issue_id},
      "contract_revision" => revision,
      "acceptance_contract" => %{"revision" => revision}
    }

    File.mkdir_p!(Path.dirname(lock_path))
    File.write!(lock_path, Jason.encode!(lock_payload, pretty: true))
  end

  defp maybe_write_contract_lock(_workspace, _issue_id, _revision), do: :ok

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

  defp validation_workpad do
    """
    ## Codex Workpad

    ### Validation
    - [x] preflight: `make symphony-preflight`
    - [x] targeted tests: `mix test test/symphony_elixir/controller_finalizer_test.exs`
    - [x] repo validation: `make symphony-validate`
    """
  end

  defp invalid_proof_mapping_workpad do
    """
    ## Codex Workpad

    ### Validation
    - [x] preflight: `make symphony-preflight`
    - [x] targeted tests: `mix test test/symphony_elixir/controller_finalizer_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts
    - [x] uploaded attachment: `runtime-proof.log` -> runtime proof log

    ### Proof Mapping
    - [x] `AM-1` -> `validation:targeted tests`
    """
  end

  defp valid_artifact_proof_mapping_workpad do
    """
    ## Codex Workpad

    ### Validation
    - [x] preflight: `make symphony-preflight`
    - [x] targeted tests: `mix test test/symphony_elixir/controller_finalizer_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Artifacts
    - [x] uploaded attachment: `runtime-proof.log` -> runtime proof log

    ### Proof Mapping
    - [x] `AM-1` -> `artifact:runtime-proof.log`
    """
  end

  defp validation_workpad_without_backticks do
    """
    ## Codex Workpad

    ### Validation
    - [x] preflight: make symphony-preflight
    - [x] targeted tests: mix test test/symphony_elixir/controller_finalizer_test.exs
    - [x] repo validation: make symphony-validate
    """
  end

  defp validation_workpad_with_execution_evidence(run_token) when is_binary(run_token) do
    """
    ## Codex Workpad

    ### Validation
    - [x] preflight: `make symphony-preflight`
    - [x] targeted tests: `mix test test/symphony_elixir/controller_finalizer_test.exs`
    - [x] repo validation: `make symphony-validate`

    ### Execution Evidence
    - `status`: `passed`
    - `run_token`: `#{run_token}`
    - `artifact_file`: `docs/reports/let-716-swarm-artifact.md`
    - `revision_pair.plan_revision`: `plan-rev-716`
    - `revision_pair.artifact_revision`: `plan-rev-716`
    - `consumed_sections`: `Residual Risks, Rollback`
    - `note`: `artifact is secondary, short plan is canonical`
    """
  end

  defp validation_workpad_with_prefixed_labels do
    """
    ## Codex Workpad

    ### Validation
    - [x] validation:preflight: `make symphony-preflight`
    - [x] validation:targeted tests: `mix test test/symphony_elixir/controller_finalizer_test.exs`
    - [x] validation:repo validation: `make symphony-validate`
    """
  end

  defp prepare_git_history!(workspace, base_branch) do
    {"", 0} = System.cmd("git", ["checkout", "-b", base_branch], cd: workspace)
    {"", 0} = System.cmd("git", ["config", "user.email", "controller-finalizer@example.test"], cd: workspace)
    {"", 0} = System.cmd("git", ["config", "user.name", "Controller Finalizer Test"], cd: workspace)

    write_file!(workspace, "README.md", "# Controller finalizer fixture\n")
    {"", 0} = System.cmd("git", ["add", "README.md"], cd: workspace)
    {_output, 0} = System.cmd("git", ["commit", "-m", "base"], cd: workspace)
    {_output, 0} = System.cmd("git", ["push", "-u", "origin", base_branch], cd: workspace)
  end

  defp add_runtime_contract_change!(workspace) do
    {"", 0} = System.cmd("git", ["checkout", "-b", "feature/proof-checks"], cd: workspace)
    write_file!(workspace, "elixir/lib/symphony_elixir/validation_gate.ex", "# runtime contract change\n")
    {"", 0} = System.cmd("git", ["add", "elixir/lib/symphony_elixir/validation_gate.ex"], cd: workspace)
    {_output, 0} = System.cmd("git", ["commit", "-m", "runtime contract"], cd: workspace)
  end

  defp write_file!(workspace, relative_path, content) do
    path = Path.join(workspace, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
