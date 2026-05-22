defmodule SymphonyElixir.HandoffFailure do
  @moduledoc """
  Shared classification for handoff contract failures.

  Recoverable drift means the run produced enough implementation evidence for an
  agent to reconcile metadata/workpad proof rows in a bounded retry. It never
  means the handoff may pass without the missing evidence.
  """

  @recoverable_validation_labels [
    "preflight",
    "targeted tests",
    "stateful proof",
    "runtime smoke",
    "repo validation",
    "docs review",
    "ui runtime proof",
    "visual artifact",
    "red proof"
  ]

  @recoverable_validation_label_pattern Enum.map_join(@recoverable_validation_labels, "|", &Regex.escape/1)

  @recoverable_drift_patterns [
    ~r/^acceptance matrix contains duplicate id `/,
    ~r/^acceptance matrix item `[^`]+` has multiple proof mapping entries; exactly one is required$/,
    ~r/^proof mapping references unknown acceptance matrix item `/,
    ~r/^proof mapping reference `[^`]+` is reused by multiple acceptance matrix items:/,
    ~r/^acceptance matrix item `[^`]+` maps to validation `[^`]+` that is not checked$/,
    ~r/^artifact manifest is missing a checked uploaded attachment entry$/,
    ~r/^required capability `artifact_upload` is missing a checked uploaded Linear attachment$/,
    ~r/^acceptance matrix item `[^`]+` maps to artifact `[^`]+` that is not checked in `Artifacts`$/,
    ~r/^acceptance matrix item `[^`]+` maps to artifact `[^`]+` that is not uploaded in Linear attachments$/,
    ~r/^acceptance matrix item `[^`]+` mapping drift: use canonical validation label /,
    ~r/^validation checklist is missing a checked `(#{@recoverable_validation_label_pattern})` item$/
  ]

  @spec classify(boolean(), term()) :: map()
  def classify(true, _missing_items) do
    %{
      "kind" => "none",
      "recoverable" => false,
      "reason" => "verification passed",
      "recoverable_items" => [],
      "hard_items" => []
    }
  end

  def classify(false, missing_items) when is_list(missing_items) do
    {recoverable_items, hard_items} =
      Enum.split_with(missing_items, &recoverable_drift_item?/1)

    {kind, reason} =
      if missing_items != [] and hard_items == [] do
        {"recoverable_drift", "metadata/proof sync drift detected"}
      else
        {"hard_contract_failure", "required handoff contract evidence is missing or invalid"}
      end

    %{
      "kind" => kind,
      "recoverable" => kind == "recoverable_drift",
      "reason" => reason,
      "recoverable_items" => recoverable_items,
      "hard_items" => hard_items
    }
  end

  def classify(false, _missing_items), do: classify(false, [])

  @spec recoverable_drift_item?(term()) :: boolean()
  def recoverable_drift_item?(item) when is_binary(item) do
    Enum.any?(@recoverable_drift_patterns, &Regex.match?(&1, item))
  end

  def recoverable_drift_item?(_item), do: false

  @spec recoverable_manifest?(term()) :: boolean()
  def recoverable_manifest?(manifest) when is_map(manifest) do
    case manifest["handoff_failure"] do
      %{"kind" => "recoverable_drift", "hard_items" => hard_items} when is_list(hard_items) ->
        hard_items == []

      %{"kind" => "recoverable_drift"} ->
        true

      %{"kind" => "hard_contract_failure"} ->
        false

      _ ->
        missing_items = normalize_missing_items(manifest["missing_items"])
        missing_items != [] and Enum.all?(missing_items, &recoverable_drift_item?/1)
    end
  end

  def recoverable_manifest?(_manifest), do: false

  defp normalize_missing_items(items) when is_list(items), do: items
  defp normalize_missing_items(_items), do: []
end
