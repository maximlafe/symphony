defmodule SymphonyElixir.IssueTraceParityTest do
  use SymphonyElixir.TestSupport

  @matrix_fixture Path.expand("../fixtures/parity/parity_02_issue_trace_matrix.json", __DIR__)
  @live_fixture Path.expand("../fixtures/parity/parity_02_issue_trace_live_sanitized.json", __DIR__)

  test "PARITY-02 deterministic issue trace matrix cases pass" do
    payload = load_fixture!(@matrix_fixture)

    assert payload["ticket"] == "PARITY-02"
    assert payload["scope"]["team_key"] == "LET"

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    assert_trace_cases!(cases)
  end

  test "PARITY-02 live-sanitized issue trace cases pass the same contract runner" do
    payload = load_fixture!(@live_fixture)

    assert payload["ticket"] == "PARITY-02"
    assert is_binary(payload["generated_at"])

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    assert_trace_cases!(cases)
  end

  defp assert_trace_cases!(cases) when is_list(cases) do
    Enum.each(cases, fn case_entry ->
      case_id = case_entry["case_id"] || "UNKNOWN"
      comments = Map.get(case_entry, "comments", [])
      attachments = Map.get(case_entry, "attachments", [])
      expected = Map.get(case_entry, "expected", %{})

      if expected["requires_workpad_signal"] do
        assert has_workpad_signal?(comments), "case #{case_id}: expected workpad trace signal"
      end

      if expected["requires_artifact_signal"] do
        assert has_artifact_signal?(attachments), "case #{case_id}: expected artifact trace signal"
      end

      if expected["requires_handoff_decision"] do
        assert has_handoff_decision_signal?(comments),
               "case #{case_id}: expected handoff decision signal"
      end

      if expected["requires_handoff_milestone"] do
        assert has_handoff_milestone_signal?(comments),
               "case #{case_id}: expected handoff milestone signal"
      end

      if expected["requires_valid_timing"] do
        assert valid_trace_timing?(comments, attachments), "case #{case_id}: invalid trace timing"
      end
    end)
  end

  defp has_workpad_signal?(comments) when is_list(comments) do
    Enum.any?(comments, fn comment ->
      channel = normalize_text(Map.get(comment, "channel"))
      body = normalize_text(Map.get(comment, "body"))

      channel == "workpad_comment" or
        String.contains?(body, "codex workpad") or
        String.contains?(body, "рабочий журнал codex")
    end)
  end

  defp has_workpad_signal?(_comments), do: false

  defp has_artifact_signal?(attachments) when is_list(attachments) do
    Enum.any?(attachments, fn attachment ->
      title = Map.get(attachment, "title")
      is_binary(title) and String.trim(title) != ""
    end)
  end

  defp has_artifact_signal?(_attachments), do: false

  defp has_handoff_decision_signal?(comments) when is_list(comments) do
    Enum.any?(comments, fn comment ->
      body = Map.get(comment, "body", "")

      has_selected_action =
        is_binary(Map.get(comment, "selected_action")) or
          (is_binary(body) and Regex.match?(~r/selected_action\s*:/i, body))

      has_checkpoint_type =
        is_binary(Map.get(comment, "checkpoint_type")) or
          (is_binary(body) and Regex.match?(~r/checkpoint_type\s*:/i, body))

      has_selected_action and has_checkpoint_type
    end)
  end

  defp has_handoff_decision_signal?(_comments), do: false

  defp has_handoff_milestone_signal?(comments) when is_list(comments) do
    Enum.any?(comments, fn comment ->
      milestone = Map.get(comment, "milestone")
      body = normalize_text(Map.get(comment, "body"))

      (is_binary(milestone) and String.trim(milestone) == "handoff-ready") or
        (String.contains?(body, "symphony milestone") and String.contains?(body, "handoff-ready"))
    end)
  end

  defp has_handoff_milestone_signal?(_comments), do: false

  defp valid_trace_timing?(comments, attachments) do
    comments =
      if is_list(comments),
        do: comments,
        else: []

    attachments =
      if is_list(attachments),
        do: attachments,
        else: []

    timestamps =
      comments
      |> Enum.map(&Map.get(&1, "created_at"))
      |> Kernel.++(Enum.map(attachments, &Map.get(&1, "created_at")))

    parsed =
      Enum.reduce_while(timestamps, [], fn timestamp, acc ->
        case parse_timestamp(timestamp) do
          {:ok, value} -> {:cont, acc ++ [value]}
          :error -> {:halt, :error}
        end
      end)

    case parsed do
      :error ->
        false

      values when is_list(values) ->
        not Enum.empty?(values)
    end
  end

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, value, _offset} -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_timestamp(_timestamp), do: :error

  defp normalize_text(value) when is_binary(value), do: String.downcase(value)
  defp normalize_text(_value), do: ""

  defp load_fixture!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
