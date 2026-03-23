defmodule SymphonyElixir.ErrorClassifierTest do
  use ExUnit.Case

  alias SymphonyElixir.ErrorClassifier

  test "classifies compile errors as permanent" do
    reason = {:agent_run_failed, {:workspace_hook_failed, "before_run", 1, "CompileError: undefined function"}}
    assert ErrorClassifier.classify(reason) == :permanent
  end

  test "classifies explicit permanent tuple failures" do
    assert ErrorClassifier.classify({:turn_input_required, %{}}) == :permanent
    assert ErrorClassifier.classify({:approval_required, %{}}) == :permanent
    assert ErrorClassifier.classify({:invalid_workspace_cwd, :enoent, "/tmp/workspace"}) == :permanent
    assert ErrorClassifier.classify({:invalid_workspace_cwd, :enoent, "/tmp/workspace", "/tmp"}) == :permanent
    assert ErrorClassifier.classify({:workspace_equals_root, "/tmp/workspace", "/tmp/workspace"}) == :permanent
    assert ErrorClassifier.classify({:workspace_symlink_escape, "/tmp/workspace", "/tmp"}) == :permanent
    assert ErrorClassifier.classify({:workspace_outside_root, "/tmp/workspace", "/tmp"}) == :permanent
    assert ErrorClassifier.classify({:workspace_path_unreadable, "/tmp/workspace", :eacces}) == :permanent
  end

  test "classifies unattended auth and bootstrap blockers as permanent" do
    assert ErrorClassifier.classify({:workspace_hook_failed, "after_create", 1, "GH_TOKEN is required for unattended lead_status clone/push access."}) ==
             :permanent

    assert ErrorClassifier.classify({:workspace_hook_failed, "after_create", 1, "GitHub auth is unavailable. Export GH_TOKEN in /etc/symphony/symphony.env."}) ==
             :permanent
  end

  test "preserves retry class for workspace hook output" do
    assert ErrorClassifier.classify({:workspace_hook_failed, "before_run", 1, "git push rejected (non-fast-forward)"}) ==
             :semi_permanent

    assert ErrorClassifier.classify({:workspace_hook_failed, "before_run", 1, "request timed out while installing deps"}) ==
             :transient
  end

  test "classifies explicit turn_failed account metadata as an account switch blocker" do
    failure =
      ErrorClassifier.classify_details(
        {:turn_failed,
         %{
           "error" => %{"message" => "Login required for this account"},
           "error_class" => "semi_permanent",
           "failure_class" => "auth_failure",
           "retry_action" => "switch_account",
           "account_state" => "broken"
         }}
      )

    assert failure.error_class == :semi_permanent
    assert failure.failure_class == :auth_failure
    assert failure.retry_action == :switch_account
    assert failure.account_state == :broken

    atom_failure =
      ErrorClassifier.classify_details(
        {:turn_failed,
         %{
           error: %{message: "RESOURCE_EXHAUSTED: requests per day limit reached"},
           error_class: :semi_permanent,
           failure_class: :quota_exhausted,
           retry_action: :switch_account,
           account_state: :cooldown,
           summary: "quota exhausted"
         }}
      )

    assert atom_failure.failure_class == :quota_exhausted
    assert atom_failure.retry_action == :switch_account
    assert atom_failure.account_state == :cooldown
  end

  test "does not apply account health actions to untrusted turn_failed text" do
    failure =
      ErrorClassifier.classify_details({:turn_failed, %{"error" => %{"message" => "invalid api key returned by a downstream API"}}})

    assert failure.error_class == :semi_permanent
    assert failure.failure_class == :semi_permanent_failure
    assert failure.retry_action == :retry_same_account
    assert failure.account_state == :ready
  end

  test "falls back when explicit turn_failed metadata is incomplete or invalid" do
    assert ErrorClassifier.classify({:turn_failed, %{message: "request timed out", error_class: :semi_permanent, failure_class: 123}}) ==
             :transient

    assert ErrorClassifier.classify(
             {:turn_failed,
              %{
                message: "request timed out",
                error_class: :semi_permanent,
                failure_class: :auth_failure,
                retry_action: 123
              }}
           ) == :transient

    assert ErrorClassifier.classify(
             {:turn_failed,
              %{
                message: "request timed out",
                error_class: :semi_permanent,
                failure_class: :auth_failure,
                retry_action: :switch_account,
                account_state: %{}
              }}
           ) == :transient
  end

  test "classifies test and git push failures as semi_permanent" do
    assert ErrorClassifier.classify("mix test failed") == :semi_permanent
    assert ErrorClassifier.classify("git push rejected (non-fast-forward)") == :semi_permanent
    assert ErrorClassifier.classify({%{message: "tests failed in CI"}, []}) == :semi_permanent
  end

  test "classifies quota exhaustion separately from transient throttling" do
    quota = ErrorClassifier.classify_details("RESOURCE_EXHAUSTED: requests per day limit reached")
    assert quota.error_class == :semi_permanent
    assert quota.failure_class == :quota_exhausted
    assert quota.retry_action == :switch_account
    assert quota.account_state == :cooldown

    throttled = ErrorClassifier.classify_details("HTTP 429 rate limit exhausted")
    assert throttled.error_class == :transient
    assert throttled.failure_class == :transient_worker_failure
    assert throttled.retry_action == :retry_same_account
    assert throttled.account_state == :ready

    assert ErrorClassifier.classify("HTTP 429 rate limit hit, retry again in 10 seconds") == :transient
  end

  test "overrides nested reason error class when explicit metadata is present" do
    assert ErrorClassifier.classify_details(%{
             reason: %{message: "request timed out"},
             error_class: "semi_permanent"
           }).error_class == :semi_permanent

    assert ErrorClassifier.classify_details(%{
             reason: %{message: "request timed out"},
             error_class: "transient"
           }).error_class == :transient

    assert ErrorClassifier.classify_details(%{
             reason: %{message: "request timed out"},
             error_class: "permanent"
           }).error_class == :permanent

    assert ErrorClassifier.classify_details(%{
             reason: %{message: "request timed out"},
             error_class: :semi_permanent
           }).error_class == :semi_permanent

    assert ErrorClassifier.classify_details(%{
             reason: %{message: "request timed out"},
             error_class: "unknown"
           }).error_class == :transient
  end

  test "derives fallback metadata from explicit error classes" do
    semi_permanent = ErrorClassifier.classify_details(%{error_class: :semi_permanent})
    assert semi_permanent.failure_class == :semi_permanent_failure
    assert semi_permanent.retry_action == :retry_same_account
    assert semi_permanent.account_state == :ready

    transient = ErrorClassifier.classify_details(%{error_class: :transient})
    assert transient.failure_class == :transient_worker_failure
    assert transient.retry_action == :retry_same_account
    assert transient.account_state == :ready
  end

  test "classifies timeouts and transport failures as transient" do
    assert ErrorClassifier.classify({:workspace_hook_timeout, "before_run", 5_000}) == :transient
    assert ErrorClassifier.classify({:issue_state_refresh_failed, :timeout}) == :transient
    assert ErrorClassifier.classify({:turn_timeout}) == :transient
    assert ErrorClassifier.classify({:turn_timeout, %{}}) == :transient
    assert ErrorClassifier.classify({:turn_cancelled, %{message: "cancelled"}}) == :transient
    assert ErrorClassifier.classify({:turn_failed, %{error: %{message: "request timed out"}}}) == :transient
    assert ErrorClassifier.classify({:turn_failed, %{message: "request timed out"}}) == :transient
    assert ErrorClassifier.classify({:turn_failed, :timeout}) == :transient
    assert ErrorClassifier.classify({:response_timeout}) == :transient
    assert ErrorClassifier.classify({:port_exit, 143}) == :transient
  end

  test "enforces semi-permanent retry limit" do
    assert ErrorClassifier.retry_allowed?(:transient, 999)
    assert ErrorClassifier.retry_allowed?(:semi_permanent, 1)
    assert ErrorClassifier.retry_allowed?(:semi_permanent, 3)
    refute ErrorClassifier.retry_allowed?(:semi_permanent, 4)
    refute ErrorClassifier.retry_allowed?(:permanent, 1)
  end

  test "formats classifier metadata and summaries" do
    assert ErrorClassifier.retry_limit() == 3
    assert ErrorClassifier.to_string(:transient) == "transient"
    assert ErrorClassifier.to_string(:permanent) == "permanent"
    assert ErrorClassifier.to_string(:semi_permanent) == "semi_permanent"
    assert ErrorClassifier.to_string(nil) == "transient"
    assert ErrorClassifier.failure_class_to_string(:approval_required) == "approval_required"
    assert ErrorClassifier.failure_class_to_string(:auth_failure) == "auth_failure"
    assert ErrorClassifier.failure_class_to_string(:invalid_workspace) == "invalid_workspace"
    assert ErrorClassifier.failure_class_to_string(:process_error) == "process_error"
    assert ErrorClassifier.failure_class_to_string(:turn_input_required) == "turn_input_required"
    assert ErrorClassifier.failure_class_to_string(nil) == "transient_worker_failure"

    assert ErrorClassifier.classify(%{error_class: :permanent}) == :permanent
    assert ErrorClassifier.classify("some completely novel failure") == :transient

    assert ErrorClassifier.summarize_reason(%{message: "short"}) == "%{message: \"short\"}"

    summary =
      ErrorClassifier.summarize_reason("line one\nline two with a lot of trailing detail", 18)

    assert String.ends_with?(summary, "...")
    assert String.length(summary) == 18
  end
end
