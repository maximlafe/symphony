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

  test "classifies test and git push failures as semi_permanent" do
    assert ErrorClassifier.classify("mix test failed") == :semi_permanent
    assert ErrorClassifier.classify("git push rejected (non-fast-forward)") == :semi_permanent
    assert ErrorClassifier.classify({%{message: "tests failed in CI"}, []}) == :semi_permanent
  end

  test "classifies rate limits and timeouts as transient" do
    assert ErrorClassifier.classify("HTTP 429 rate limit exhausted") == :transient
    assert ErrorClassifier.classify({:workspace_hook_timeout, "before_run", 5_000}) == :transient
    assert ErrorClassifier.classify({:issue_state_refresh_failed, :timeout}) == :transient
    assert ErrorClassifier.classify({:turn_timeout}) == :transient
    assert ErrorClassifier.classify({:turn_timeout, %{}}) == :transient
    assert ErrorClassifier.classify({:turn_cancelled, %{message: "cancelled"}}) == :transient
    assert ErrorClassifier.classify({:turn_failed, %{message: "request timed out"}}) == :transient
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

    assert ErrorClassifier.classify(%{error_class: :permanent}) == :permanent
    assert ErrorClassifier.classify("some completely novel failure") == :transient

    assert ErrorClassifier.summarize_reason(%{message: "short"}) == "%{message: \"short\"}"

    summary =
      ErrorClassifier.summarize_reason("line one\nline two with a lot of trailing detail", 18)

    assert String.ends_with?(summary, "...")
    assert String.length(summary) == 18
  end
end
