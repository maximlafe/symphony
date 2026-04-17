defmodule SymphonyElixir.AutoCompaction do
  @moduledoc """
  Deterministic safe-boundary auto-compaction policy for long edit sessions.
  """

  alias SymphonyElixir.Config

  @type decision :: :skip | {:compact, map()}

  @spec decide(map()) :: decision()
  def decide(context) when is_map(context) do
    settings = Config.settings!()
    token_threshold = normalize_threshold(settings.codex.auto_compaction_max_total_tokens)
    safe_steps_threshold = normalize_threshold(settings.codex.auto_compaction_max_safe_steps)
    run_phase_before = normalize_phase(Map.get(context, :run_phase_before))
    safe_boundary? = Map.get(context, :safe_boundary) == true
    attempt_tokens = non_negative_integer(Map.get(context, :attempt_tokens))
    safe_steps = non_negative_integer(Map.get(context, :safe_steps))

    token_exceeded? = threshold_exceeded?(attempt_tokens, token_threshold)
    safe_steps_exceeded? = threshold_exceeded?(safe_steps, safe_steps_threshold)

    cond do
      is_nil(token_threshold) and is_nil(safe_steps_threshold) ->
        :skip

      run_phase_before != :editing ->
        :skip

      not safe_boundary? ->
        :skip

      token_exceeded? ->
        {:compact,
         %{
           continuation_reason: "auto_compaction",
           auto_compaction_signal: "total_tokens",
           auto_compaction_threshold: token_threshold,
           auto_compaction_observed_total: attempt_tokens,
           auto_compaction_safe_steps: safe_steps
         }}

      safe_steps_exceeded? ->
        {:compact,
         %{
           continuation_reason: "auto_compaction",
           auto_compaction_signal: "safe_steps",
           auto_compaction_threshold: safe_steps_threshold,
           auto_compaction_observed_total: safe_steps,
           auto_compaction_safe_steps: safe_steps
         }}

      true ->
        :skip
    end
  end

  def decide(_context), do: :skip

  defp threshold_exceeded?(observed, threshold)
       when is_integer(observed) and is_integer(threshold) and threshold > 0,
       do: observed > threshold

  defp threshold_exceeded?(_observed, _threshold), do: false

  defp normalize_threshold(value) when is_integer(value) and value > 0, do: value
  defp normalize_threshold(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0

  defp normalize_phase(phase) when phase in [:editing], do: phase
  defp normalize_phase("editing"), do: :editing
  defp normalize_phase(_phase), do: nil
end
