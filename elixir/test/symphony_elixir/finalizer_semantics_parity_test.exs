defmodule SymphonyElixir.FinalizerSemanticsParityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, ControllerFinalizer}

  @matrix_fixture Path.expand("../fixtures/parity/parity_05_finalizer_semantics_matrix.json", __DIR__)
  @live_fixture Path.expand("../fixtures/parity/parity_05_finalizer_semantics_live_sanitized.json", __DIR__)
  @contract_doc Path.expand("../../../docs/symphony-next/contracts/PARITY-05_FINALIZER_SEMANTICS_CONTRACT.md", __DIR__)

  @required_acceptance_ids [
    "PARITY-05-AM-01",
    "PARITY-05-AM-02",
    "PARITY-05-AM-03",
    "PARITY-05-AM-04",
    "PARITY-05-AM-05",
    "PARITY-05-AM-06",
    "PARITY-05-AM-07",
    "PARITY-05-AM-08",
    "PARITY-05-AM-09",
    "PARITY-05-AM-10"
  ]

  defmodule TrackerOk do
    def update_issue_state(_issue_id, _state_name), do: :ok
  end

  defmodule TrackerFail do
    def update_issue_state(_issue_id, _state_name), do: {:error, :transition_denied}
  end

  test "PARITY-05 deterministic finalizer semantics matrix cases pass" do
    payload = load_fixture!(@matrix_fixture)

    assert payload["ticket"] == "PARITY-05"
    assert payload["source"]["kind"] == "deterministic_matrix"

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    assert_deterministic_cases!(cases)
  end

  test "PARITY-05 live-sanitized finalizer traces match canonical decision mapping" do
    payload = load_fixture!(@live_fixture)

    assert payload["ticket"] == "PARITY-05"
    assert is_binary(payload["generated_at"])

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    expected_outcomes =
      cases
      |> Enum.map(&get_in(&1, ["expected", "outcome"]))
      |> MapSet.new()

    assert MapSet.member?(expected_outcomes, "fallback")
    assert MapSet.member?(expected_outcomes, "ok")

    assert_live_cases!(cases)
  end

  test "PARITY-05 contract doc maps AM ids to executable suite" do
    body = File.read!(@contract_doc)

    Enum.each(@required_acceptance_ids, fn id ->
      assert String.contains?(body, id), "missing acceptance id #{id} in contract doc"
    end)

    Enum.each(
      ["pull request checks failed", "pull request has actionable feedback", "controller finalizer completed successfully"],
      fn marker ->
        assert String.contains?(body, marker), "missing contract marker #{marker}"
      end
    )
  end

  defp assert_deterministic_cases!(cases) do
    Enum.each(cases, fn case_entry ->
      case case_entry["kind"] do
        "runtime" -> assert_runtime_case!(case_entry)
        "eligibility" -> assert_eligibility_case!(case_entry)
        kind -> flunk("unsupported deterministic case kind: #{inspect(kind)}")
      end
    end)
  end

  defp assert_runtime_case!(case_entry) do
    case_id = case_entry["case_id"] || "UNKNOWN"
    issue = Map.get(case_entry, "issue", %{})
    checkpoint = Map.get(case_entry, "checkpoint", %{})
    workspace_opts = Map.get(case_entry, "workspace", %{})
    script = Map.get(case_entry, "tool_script", %{})
    expected = Map.get(case_entry, "expected", %{})
    tracker_mode = Map.get(case_entry, "tracker_mode", "ok")
    repo = get_in(checkpoint, ["open_pr", "url"]) |> repo_from_url() || "maximlafe/symphony"

    create_workspace!(issue["identifier"], workspace_opts)

    tracker_module =
      case tracker_mode do
        "error" -> TrackerFail
        _ -> TrackerOk
      end

    result =
      ControllerFinalizer.run(
        issue,
        checkpoint,
        repo: repo,
        tracker_module: tracker_module,
        tool_executor: script_executor(script)
      )

    expected_outcome = outcome_atom(expected["outcome"])
    assert {^expected_outcome, payload} = result
    assert payload.reason == expected["reason"], "case #{case_id}: reason mismatch"

    assert get_in(payload, [:checkpoint, "controller_finalizer", "status"]) == expected["controller_status"],
           "case #{case_id}: controller status mismatch"

    assert get_in(payload, [:checkpoint, "controller_finalizer", "blocked_head"]) == expected["blocked_head"],
           "case #{case_id}: blocked_head mismatch"
  end

  defp assert_eligibility_case!(case_entry) do
    case_id = case_entry["case_id"] || "UNKNOWN"
    issue = Map.get(case_entry, "issue", %{})
    checkpoint = Map.get(case_entry, "checkpoint", %{})
    expected = Map.get(case_entry, "expected", %{})

    assert ControllerFinalizer.eligible?(issue, checkpoint) == expected["eligible"],
           "case #{case_id}: eligibility mismatch"
  end

  defp assert_live_cases!(cases) do
    Enum.each(cases, fn case_entry ->
      case_id = case_entry["case_id"] || "UNKNOWN"
      observed = Map.get(case_entry, "observed", %{})
      expected = Map.get(case_entry, "expected", %{})

      normalized = normalize_live_observation(observed)

      assert normalized["outcome"] == expected["outcome"], "case #{case_id}: outcome mismatch"
      assert normalized["controller_status"] == expected["controller_status"], "case #{case_id}: status mismatch"

      if is_binary(expected["reason"]) do
        assert normalized["reason"] == expected["reason"], "case #{case_id}: reason mismatch"
      end
    end)
  end

  defp normalize_live_observation(observed) when is_map(observed) do
    reason = Map.get(observed, "reason")
    status = Map.get(observed, "status") |> normalize_live_status()
    normalized_reason = normalize_live_reason(reason)

    if normalized_reason["outcome"] != "unknown" do
      normalized_reason
    else
      case status do
        "action_required" ->
          %{"outcome" => "fallback", "controller_status" => "action_required", "reason" => "controller_finalizer.status=action_required"}

        "waiting" ->
          %{"outcome" => "retry", "controller_status" => "waiting", "reason" => "controller_finalizer.status=waiting"}

        "succeeded" ->
          %{"outcome" => "ok", "controller_status" => "succeeded", "reason" => "controller finalizer completed successfully"}

        "not_applicable" ->
          %{
            "outcome" => "not_applicable",
            "controller_status" => "not_applicable",
            "reason" => "controller finalizer prerequisites are not satisfied"
          }

        _ ->
          %{"outcome" => "unknown", "controller_status" => "unknown", "reason" => "unknown"}
      end
    end
  end

  defp normalize_live_observation(_observed), do: %{"outcome" => "unknown", "controller_status" => "unknown", "reason" => "unknown"}

  defp normalize_live_reason(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    canonical_live_reason(normalized) ||
      status_marker_reason(normalized) ||
      merge_marker_reason(normalized) ||
      unknown_live_reason()
  end

  defp normalize_live_reason(_reason), do: unknown_live_reason()

  defp canonical_live_reason(normalized) do
    cond do
      String.contains?(normalized, "pull request checks failed") ->
        %{"outcome" => "fallback", "controller_status" => "action_required", "reason" => "pull request checks failed"}

      String.contains?(normalized, "pull request checks are still pending") ->
        %{"outcome" => "retry", "controller_status" => "waiting", "reason" => "pull request checks are still pending"}

      String.contains?(normalized, "pull request has actionable feedback") ->
        %{"outcome" => "fallback", "controller_status" => "action_required", "reason" => "pull request has actionable feedback"}

      String.contains?(normalized, "symphony_handoff_check failed") ->
        %{"outcome" => "fallback", "controller_status" => "action_required", "reason" => "symphony_handoff_check failed"}

      String.contains?(normalized, "required proof checks are missing before handoff") ->
        %{"outcome" => "fallback", "controller_status" => "action_required", "reason" => "required proof checks are missing before handoff"}

      String.contains?(normalized, "controller finalizer completed successfully") ->
        %{"outcome" => "ok", "controller_status" => "succeeded", "reason" => "controller finalizer completed successfully"}

      true ->
        nil
    end
  end

  defp status_marker_reason(normalized) do
    cond do
      String.contains?(normalized, "controller_finalizer.status=action_required") ->
        %{"outcome" => "fallback", "controller_status" => "action_required", "reason" => "controller_finalizer.status=action_required"}

      String.contains?(normalized, "controller_finalizer.status=waiting") ->
        %{"outcome" => "retry", "controller_status" => "waiting", "reason" => "controller_finalizer.status=waiting"}

      String.contains?(normalized, "controller_finalizer.status=not_applicable") ->
        %{
          "outcome" => "not_applicable",
          "controller_status" => "not_applicable",
          "reason" => "controller finalizer prerequisites are not satisfied"
        }

      true ->
        nil
    end
  end

  defp merge_marker_reason(normalized) do
    if String.contains?(normalized, "merge commit observed in live task report") do
      %{"outcome" => "ok", "controller_status" => "succeeded", "reason" => "merge commit observed in live task report"}
    else
      nil
    end
  end

  defp unknown_live_reason, do: %{"outcome" => "unknown", "controller_status" => "unknown", "reason" => "unknown"}

  defp normalize_live_status(status) when is_binary(status), do: String.downcase(status)
  defp normalize_live_status(_status), do: ""

  defp create_workspace!(identifier, opts) do
    workspace = Path.join(Config.settings!().workspace.root, identifier)

    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    with_workpad = Map.get(opts, "with_workpad", true)
    with_workpad_ref = Map.get(opts, "with_workpad_ref", true)
    workpad_body = Map.get(opts, "workpad_body", "## Codex Workpad\n\n- parity\n")

    if with_workpad do
      File.write!(Path.join(workspace, "workpad.md"), workpad_body)
    end

    if with_workpad_ref do
      File.write!(Path.join(workspace, ".workpad-id"), "workpad-comment\n")
    end

    workspace
  end

  defp script_executor(script) when is_map(script) do
    fn tool, _args, _tool_opts ->
      case Map.get(script, tool) do
        %{"ok" => payload} when is_map(payload) -> tool_success(payload)
        %{"error" => payload} when is_map(payload) -> tool_failure(payload)
        nil -> raise "unexpected tool call: #{tool}"
        other -> raise "unsupported tool script entry: #{inspect(other)}"
      end
    end
  end

  defp tool_success(payload) do
    %{
      "success" => true,
      "contentItems" => [%{"type" => "inputText", "text" => Jason.encode!(payload)}]
    }
  end

  defp tool_failure(payload) do
    %{
      "success" => false,
      "contentItems" => [%{"type" => "inputText", "text" => Jason.encode!(payload)}]
    }
  end

  defp outcome_atom("ok"), do: :ok
  defp outcome_atom("retry"), do: :retry
  defp outcome_atom("fallback"), do: :fallback
  defp outcome_atom("not_applicable"), do: :not_applicable
  defp outcome_atom(other), do: flunk("unsupported outcome #{inspect(other)}")

  defp repo_from_url(url) when is_binary(url) do
    case Regex.named_captures(~r{https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/pull/\d+}, url) do
      %{"owner" => owner, "repo" => repo} -> "#{owner}/#{repo}"
      _ -> nil
    end
  end

  defp repo_from_url(_url), do: nil

  defp load_fixture!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
