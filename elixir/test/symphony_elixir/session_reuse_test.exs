defmodule SymphonyElixir.SessionReuseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ResumeCheckpoint, SessionReuse}

  test "session reuse launch decisions and checkpoint helpers stay deterministic" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-session-reuse-unit-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "LET-473-SESSION-UNIT")

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "/bin/sh app-server"
    )

    issue = %Issue{
      id: "issue-session-reuse-unit",
      identifier: "LET-473-SESSION-UNIT",
      title: "Session reuse",
      description: "Validate launch decisions",
      state: "In Progress",
      url: "https://example.org/issues/LET-473-SESSION-UNIT",
      labels: []
    }

    baseline =
      SessionReuse.build_launch_context(
        issue,
        workspace,
        account_id: "primary",
        resume_checkpoint: ResumeCheckpoint.for_prompt(%{})
      )

    assert baseline.disposition == "fresh"
    assert baseline.fresh_reason == "dead_session"
    assert is_binary(baseline.policy_fingerprint)
    assert baseline.policy_source == "cost_profile+runtime_settings"

    reused_checkpoint =
      ResumeCheckpoint.for_prompt(%{
        "continuation_session" => %{
          "thread_id" => "thread-existing",
          "account_id" => "primary",
          "policy_fingerprint" => baseline.policy_fingerprint,
          "policy_source" => baseline.policy_source,
          "disposition" => "reused"
        }
      })

    reused =
      SessionReuse.build_launch_context(
        issue,
        workspace,
        account_id: "primary",
        resume_checkpoint: reused_checkpoint
      )

    assert reused.disposition == "reused"
    assert reused.fresh_reason == nil
    assert reused.thread_id == "thread-existing"
    assert reused.account_transition == nil

    explicit_reset =
      SessionReuse.build_launch_context(
        issue,
        workspace,
        account_id: "primary",
        resume_checkpoint: Map.put(reused_checkpoint, "session_reset_requested", true)
      )

    assert explicit_reset.disposition == "fresh"
    assert explicit_reset.fresh_reason == "explicit_reset"
    assert explicit_reset.thread_id == nil

    account_failover =
      SessionReuse.build_launch_context(
        issue,
        workspace,
        account_id: "secondary",
        resume_checkpoint: reused_checkpoint
      )

    assert account_failover.disposition == "fresh"
    assert account_failover.fresh_reason == "account_failover"
    assert account_failover.account_transition == "primary->secondary"

    phase_boundary =
      SessionReuse.build_launch_context(
        issue,
        workspace,
        account_id: "primary",
        resume_checkpoint:
          put_in(
            reused_checkpoint["continuation_session"]["policy_fingerprint"],
            "stale-policy-fingerprint"
          )
      )

    assert phase_boundary.disposition == "fresh"
    assert phase_boundary.fresh_reason == "phase_boundary"

    assert SessionReuse.dead_session_fallback(reused) == %{
             reused
             | disposition: "fresh",
               fresh_reason: "dead_session",
               thread_id: nil
           }

    assert SessionReuse.checkpoint_carrier(%{
             "session_thread_id" => "thread-legacy",
             "session_account_id" => "primary",
             "session_policy_fingerprint" => "policy-legacy",
             "session_policy_source" => "legacy-source",
             "session_reuse_disposition" => "fresh",
             "fresh_reason" => "dead_session"
           }) == %{
             "account_id" => "primary",
             "disposition" => "fresh",
             "fresh_reason" => "dead_session",
             "policy_fingerprint" => "policy-legacy",
             "policy_source" => "legacy-source",
             "thread_id" => "thread-legacy"
           }

    assert SessionReuse.checkpoint_payload(%{
             "continuation_session" => %{
               "thread_id" => "thread-existing",
               "account_id" => "primary",
               "policy_fingerprint" => "policy-old",
               "policy_source" => "old-source",
               "disposition" => "reused"
             },
             session_policy_source: "new-source",
             session_reuse_disposition: "fresh",
             fresh_reason: :dead_session
           }) == %{
             "continuation_session" => %{
               "account_id" => "primary",
               "disposition" => "fresh",
               "fresh_reason" => "dead_session",
               "policy_fingerprint" => "policy-old",
               "policy_source" => "new-source",
               "thread_id" => "thread-existing"
             },
             "fresh_reason" => "dead_session",
             "session_account_id" => "primary",
             "session_policy_fingerprint" => "policy-old",
             "session_policy_source" => "new-source",
             "session_reuse_disposition" => "fresh",
             "session_thread_id" => "thread-existing"
           }

    assert SessionReuse.checkpoint_payload(nil) == %{}
    assert SessionReuse.checkpoint_carrier(nil) == %{}

    assert SessionReuse.checkpoint_carrier(%{
             continuation_session: %{
               thread_id: "thread-atom",
               account_id: "primary",
               policy_fingerprint: "policy-atom",
               policy_source: "source-atom",
               fresh_reason: :phase_boundary,
               disposition: "fresh"
             }
           }) == %{
             "account_id" => "primary",
             "disposition" => "fresh",
             "fresh_reason" => "phase_boundary",
             "policy_fingerprint" => "policy-atom",
             "policy_source" => "source-atom",
             "thread_id" => "thread-atom"
           }

    assert SessionReuse.checkpoint_payload(%{
             "continuation_session" => %{
               "thread_id" => "thread-existing",
               "account_id" => "primary",
               "policy_fingerprint" => "policy-old",
               "policy_source" => "old-source",
               "disposition" => "reused"
             },
             "session_thread_id" => 123,
             "session_account_id" => "   ",
             "session_policy_fingerprint" => nil,
             "session_policy_source" => "   ",
             "session_reuse_disposition" => "",
             "fresh_reason" => "invalid-reason"
           }) == %{
             "continuation_session" => %{
               "account_id" => "primary",
               "disposition" => "reused",
               "policy_fingerprint" => "policy-old",
               "policy_source" => "old-source",
               "thread_id" => "thread-existing"
             },
             "session_account_id" => "primary",
             "session_policy_fingerprint" => "policy-old",
             "session_policy_source" => "old-source",
             "session_reuse_disposition" => "reused",
             "session_thread_id" => "thread-existing"
           }

    nil_account =
      SessionReuse.build_launch_context(
        %{"identifier" => "LET-473-SESSION-UNIT", "state" => "In Progress"},
        workspace,
        account_id: "   ",
        cost_profile_key: "cheap_implementation",
        resume_checkpoint:
          ResumeCheckpoint.for_prompt(%{
            session_thread_id: "thread-existing",
            session_account_id: 123,
            session_policy_fingerprint: baseline.policy_fingerprint
          })
      )

    assert nil_account.disposition == "reused"
    assert nil_account.account_id == nil
    assert nil_account.account_transition == nil

    from_string_issue =
      SessionReuse.build_launch_context(
        "In Progress",
        workspace,
        account_id: "primary",
        resume_checkpoint: ResumeCheckpoint.for_prompt(%{})
      )

    assert from_string_issue.disposition == "fresh"
    assert from_string_issue.fresh_reason == "dead_session"
  end

  test "default entrypoint and invalid continuation carrier fall back deterministically" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-session-reuse-defaults-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "LET-473-SESSION-DEFAULTS")

    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "/bin/sh app-server"
    )

    issue = %Issue{
      id: "issue-session-reuse-defaults",
      identifier: "LET-473-SESSION-DEFAULTS",
      title: "Session reuse defaults",
      state: "In Progress",
      labels: []
    }

    launch_context = SessionReuse.build_launch_context(issue, workspace)
    assert launch_context.disposition == "fresh"
    assert launch_context.fresh_reason == "dead_session"

    assert SessionReuse.checkpoint_carrier(%{
             "continuation_session" => "invalid",
             "session_thread_id" => "thread-flat",
             "session_account_id" => "primary"
           }) == %{
             "account_id" => "primary",
             "thread_id" => "thread-flat"
           }
  end
end
