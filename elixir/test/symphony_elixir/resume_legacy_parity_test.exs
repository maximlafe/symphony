defmodule SymphonyElixir.ResumeLegacyParityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ResumeCheckpoint, TelemetrySchema}

  @matrix_fixture Path.expand("../fixtures/parity/parity_03_resume_legacy_matrix.json", __DIR__)
  @live_fixture Path.expand("../fixtures/parity/parity_03_resume_legacy_live_sanitized.json", __DIR__)
  @allowed_resume_modes ["resume_checkpoint", "fallback_reread"]

  test "PARITY-03 deterministic legacy resume matrix cases pass" do
    payload = load_fixture!(@matrix_fixture)

    assert payload["ticket"] == "PARITY-03"

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    assert_resume_cases!(cases)
  end

  test "PARITY-03 live-sanitized legacy resume traces pass with no ambiguous recovery" do
    payload = load_fixture!(@live_fixture)

    assert payload["ticket"] == "PARITY-03"
    assert is_binary(payload["generated_at"])

    cases = Map.get(payload, "cases", [])
    refute Enum.empty?(cases)

    assert Enum.any?(cases, fn case_entry ->
             source_excerpt = get_in(case_entry, ["source", "sampled_trace_excerpt"]) || ""
             String.contains?(source_excerpt, "resume_mode=resume_checkpoint")
           end)

    assert Enum.any?(cases, fn case_entry ->
             source_excerpt = get_in(case_entry, ["source", "sampled_trace_excerpt"]) || ""
             String.contains?(source_excerpt, "resume_mode=fallback_reread")
           end)

    assert_resume_cases!(cases)
  end

  defp assert_resume_cases!(cases) when is_list(cases) do
    Enum.each(cases, fn case_entry ->
      case_id = case_entry["case_id"] || "UNKNOWN"
      checkpoint_input = Map.get(case_entry, "checkpoint_input", %{})
      expected = Map.get(case_entry, "expected", %{})
      normalized = ResumeCheckpoint.for_prompt(checkpoint_input)

      expected_mode = expected["resume_mode"]
      expected_reason = expected["resume_fallback_reason"]
      expected_ready = expected["resume_ready"]
      expected_ambiguous = expected["ambiguous_recovery"]

      assert normalized["resume_mode"] in @allowed_resume_modes,
             "case #{case_id}: resume_mode must be canonical"

      assert normalized["resume_mode"] == expected_mode,
             "case #{case_id}: resume_mode mismatch"

      assert normalized["resume_fallback_reason"] == expected_reason,
             "case #{case_id}: resume_fallback_reason mismatch"

      assert normalized["resume_ready"] == expected_ready,
             "case #{case_id}: resume_ready mismatch"

      assert ambiguous_recovery?(normalized) == expected_ambiguous,
             "case #{case_id}: ambiguous recovery mismatch"

      runtime_payload = TelemetrySchema.runtime_payload(normalized)

      assert runtime_payload["resume_mode"] == expected_mode,
             "case #{case_id}: runtime payload resume_mode mismatch"

      assert runtime_payload["resume_fallback_reason"] == expected_reason,
             "case #{case_id}: runtime payload resume_fallback_reason mismatch"
    end)
  end

  defp ambiguous_recovery?(checkpoint) when is_map(checkpoint) do
    mode = Map.get(checkpoint, "resume_mode")
    reason = Map.get(checkpoint, "resume_fallback_reason")
    ready = Map.get(checkpoint, "resume_ready")

    cond do
      mode not in @allowed_resume_modes ->
        true

      mode == "resume_checkpoint" and ready != true ->
        true

      mode == "fallback_reread" and not (is_binary(reason) and String.trim(reason) != "") ->
        true

      true ->
        false
    end
  end

  defp ambiguous_recovery?(_checkpoint), do: true

  defp load_fixture!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
