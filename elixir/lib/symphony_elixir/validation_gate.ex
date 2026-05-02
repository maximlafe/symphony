defmodule SymphonyElixir.ValidationGate do
  @moduledoc """
  Pure contract for the Symphony two-tier validation gate policy.
  """

  @allowed_change_classes [
    "backend_only",
    "stateful",
    "ui",
    "runtime_contract",
    "docs_only"
  ]

  @gate_types ["cheap", "final"]

  @check_order [
    "preflight",
    "cheap_gate",
    "red_proof",
    "targeted_tests",
    "stateful_proof",
    "ui_runtime_proof",
    "visual_artifact",
    "runtime_smoke",
    "docs_review",
    "repo_validation"
  ]

  @strictness_rank %{
    "docs_only" => 0,
    "backend_only" => 1,
    "ui" => 2,
    "stateful" => 3,
    "runtime_contract" => 3
  }

  @requirements %{
    "backend_only" => %{
      "cheap" => ["preflight", "targeted_tests"],
      "final" => ["preflight", "cheap_gate", "targeted_tests", "repo_validation"]
    },
    "stateful" => %{
      "cheap" => ["preflight", "targeted_tests", "stateful_proof"],
      "final" => ["preflight", "cheap_gate", "targeted_tests", "stateful_proof", "repo_validation"]
    },
    "ui" => %{
      "cheap" => ["preflight", "targeted_tests", "ui_runtime_proof"],
      "final" => [
        "preflight",
        "cheap_gate",
        "targeted_tests",
        "ui_runtime_proof",
        "visual_artifact",
        "repo_validation"
      ]
    },
    "runtime_contract" => %{
      "cheap" => ["preflight", "targeted_tests", "runtime_smoke"],
      "final" => ["preflight", "cheap_gate", "targeted_tests", "runtime_smoke", "repo_validation"]
    },
    "docs_only" => %{
      "cheap" => ["docs_review"],
      "final" => ["docs_review"]
    }
  }

  @check_aliases %{
    "preflight" => "preflight",
    "cheap gate" => "cheap_gate",
    "cheap_gate" => "cheap_gate",
    "red proof" => "red_proof",
    "red_proof" => "red_proof",
    "targeted tests" => "targeted_tests",
    "targeted_tests" => "targeted_tests",
    "stateful proof" => "stateful_proof",
    "stateful_proof" => "stateful_proof",
    "migration proof" => "stateful_proof",
    "ui runtime proof" => "ui_runtime_proof",
    "ui_runtime_proof" => "ui_runtime_proof",
    "runtime proof" => "ui_runtime_proof",
    "visual artifact" => "visual_artifact",
    "visual_artifact" => "visual_artifact",
    "runtime smoke" => "runtime_smoke",
    "runtime_smoke" => "runtime_smoke",
    "docs review" => "docs_review",
    "docs_review" => "docs_review",
    "repo validation" => "repo_validation",
    "repo_validation" => "repo_validation"
  }
  @delivery_tdd_label "delivery:tdd"
  @proof_check_labels %{
    "red_proof" => "red proof",
    "runtime_smoke" => "runtime smoke"
  }
  @proof_check_actions %{
    "red_proof" => "Run a failing baseline command and mark the `red proof` validation item with that command.",
    "runtime_smoke" => "Run the runtime smoke command for the changed contract path and mark the `runtime smoke` validation item."
  }

  @runtime_contract_prefixes ["workflows/", ".agents/", ".github/"]
  @runtime_contract_suffixes ["workflow.md", "workflows.md", "makefile"]
  @runtime_contract_fragments [
    "/handoff_check",
    "/dynamic_tool",
    "/run_phase",
    "/validation_gate",
    "/workflow",
    "/config"
  ]
  @ui_path_prefixes ["assets/", "frontend/"]
  @ui_path_fragments ["_web/", "/web/"]
  @backend_javascript_extensions [".js", ".ts"]
  @ui_asset_extensions [".css", ".heex", ".html", ".jsx", ".scss", ".vue"]

  @type change_class :: String.t()
  @type gate_type :: String.t()

  @spec allowed_change_classes() :: [change_class()]
  def allowed_change_classes, do: @allowed_change_classes

  @spec gate_types() :: [gate_type()]
  def gate_types, do: @gate_types

  @spec normalize_check(term()) :: String.t() | nil
  def normalize_check(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[\s-]+/, "_")

    Map.get(@check_aliases, normalized) ||
      Map.get(@check_aliases, String.replace(normalized, "_", " ")) ||
      if(normalized in @check_order, do: normalized)
  end

  def normalize_check(_value), do: nil

  @spec normalize_checks(term()) :: [String.t()]
  def normalize_checks(values) when is_list(values) do
    values
    |> Enum.map(&normalize_check/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> sort_checks()
  end

  def normalize_checks(_values), do: []

  @spec checked_validation_checks(term()) :: [String.t()]
  def checked_validation_checks(validation_items) when is_list(validation_items) do
    validation_items
    |> Enum.flat_map(fn
      %{} = item ->
        checked = item["checked"] || item[:checked]
        label = item["label"] || item[:label]
        command = item["command"] || item[:command] || ""

        if checked == true and not placeholder_check_command?(command) and is_binary(label) do
          [label]
        else
          []
        end

      label when is_binary(label) ->
        [label]

      _ ->
        []
    end)
    |> normalize_checks()
  end

  def checked_validation_checks(_validation_items), do: []

  @spec required_proof_checks(term(), term()) :: [map()]
  def required_proof_checks(issue_labels, change_classes) do
    labels = normalize_issue_labels(issue_labels)
    canonical_classes = canonical_change_classes_or_empty(change_classes)

    []
    |> maybe_add_required_proof_check(
      delivery_tdd_enabled?(labels),
      "red_proof",
      "issue label `delivery:tdd`"
    )
    |> maybe_add_required_proof_check(
      "runtime_contract" in canonical_classes,
      "runtime_smoke",
      "validation gate change class `runtime_contract`"
    )
  end

  @spec missing_required_proof_checks(term(), term(), term()) :: map()
  def missing_required_proof_checks(validation_items, issue_labels, change_classes) do
    required_checks = required_proof_checks(issue_labels, change_classes)
    checked_checks = checked_validation_checks(validation_items)
    checked_set = MapSet.new(checked_checks)

    missing_checks =
      Enum.reject(required_checks, fn requirement ->
        MapSet.member?(checked_set, requirement["check"])
      end)

    %{
      "required_checks" => Enum.map(required_checks, & &1["check"]),
      "checked_checks" => checked_checks,
      "missing_checks" => missing_checks
    }
  end

  @spec canonical_change_classes(term()) :: {:ok, [change_class()]} | {:error, [String.t()]}
  def canonical_change_classes(classes) when is_list(classes) do
    normalized =
      classes
      |> Enum.map(&normalize_change_class/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> sort_change_classes()

    unsupported =
      classes
      |> Enum.map(&normalize_change_class/1)
      |> Enum.zip(classes)
      |> Enum.filter(fn {normalized, _original} -> is_nil(normalized) end)
      |> Enum.map(fn {_normalized, original} -> "unsupported change class `#{inspect(original)}`" end)

    cond do
      unsupported != [] ->
        {:error, unsupported}

      normalized == [] ->
        {:error, ["change_classes must be a non-empty list"]}

      true ->
        {:ok, normalized}
    end
  end

  def canonical_change_classes(_classes), do: {:error, ["change_classes must be a non-empty list"]}

  @spec classify_paths([String.t()]) :: {:ok, [change_class()]} | {:error, [String.t()]}
  def classify_paths(paths) when is_list(paths) do
    normalized_paths =
      paths
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if normalized_paths == [] do
      {:error, ["changed_paths must be a non-empty list"]}
    else
      classes =
        normalized_paths
        |> Enum.map(&class_for_path/1)
        |> Enum.uniq()
        |> sort_change_classes()

      {:ok, classes}
    end
  end

  def classify_paths(_paths), do: {:error, ["changed_paths must be a non-empty list"]}

  @spec requirements(term(), term()) :: {:ok, map()} | {:error, [String.t()]}
  def requirements(classes, gate) do
    with {:ok, canonical_classes} <- canonical_change_classes(classes),
         {:ok, canonical_gate} <- canonical_gate(gate) do
      requirement_classes = requirement_change_classes(canonical_classes)

      required_checks =
        requirement_classes
        |> Enum.flat_map(&get_in(@requirements, [&1, canonical_gate]))
        |> Enum.uniq()
        |> sort_checks()

      {:ok,
       %{
         "gate" => canonical_gate,
         "change_classes" => canonical_classes,
         "strictest_change_class" => strictest_change_class(canonical_classes),
         "requires_final_gate" => final_gate_required?(canonical_classes),
         "required_checks" => required_checks,
         "remote_finalization_allowed" => canonical_gate == "final" and final_gate_required?(canonical_classes)
       }}
    end
  end

  # When docs edits are bundled with executable/runtime changes, the stronger class
  # checks are authoritative. `docs_review` remains mandatory for docs-only tickets.
  defp requirement_change_classes(canonical_classes) when is_list(canonical_classes) do
    if Enum.any?(canonical_classes, &(&1 != "docs_only")) do
      Enum.reject(canonical_classes, &(&1 == "docs_only"))
    else
      canonical_classes
    end
  end

  @spec final_proof(term(), term(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def final_proof(classes, passed_checks, git_metadata) when is_map(git_metadata) do
    with {:ok, requirements} <- requirements(classes, "final") do
      {:ok,
       requirements
       |> Map.put("passed_checks", normalize_checks(passed_checks))
       |> Map.put("git", normalize_git_metadata(git_metadata))}
    end
  end

  def final_proof(_classes, _passed_checks, _git_metadata) do
    {:error, ["git metadata is required for final gate proof"]}
  end

  @spec validate_final_proof(map(), map()) :: :ok | {:error, [String.t()]}
  def validate_final_proof(proof, current_git_metadata) when is_map(proof) and is_map(current_git_metadata) do
    gate =
      if Map.has_key?(proof, "validation_gate") do
        Map.get(proof, "validation_gate") || %{}
      else
        proof
      end

    proof_git = Map.get(proof, "git") || Map.get(gate, "git") || %{}
    current_git = normalize_git_metadata(current_git_metadata)

    reasons =
      []
      |> Kernel.++(gate_metadata_reasons(gate))
      |> Kernel.++(git_freshness_reasons(proof_git, current_git))

    case reasons do
      [] -> :ok
      _ -> {:error, Enum.uniq(reasons)}
    end
  end

  def validate_final_proof(_proof, _current_git_metadata) do
    {:error, ["validation gate final proof metadata is missing"]}
  end

  @spec invalidation(map(), map()) :: map()
  def invalidation(proof, current_git_metadata) do
    case validate_final_proof(proof, current_git_metadata) do
      :ok -> %{"valid" => true, "reasons" => []}
      {:error, reasons} -> %{"valid" => false, "reasons" => reasons}
    end
  end

  @spec rerun_decision(map()) :: map()
  def rerun_decision(%{} = signal) do
    trigger = normalize_trigger(signal["trigger"] || signal[:trigger])
    fix_changes_shipped = truthy?(signal["fix_changes_shipped"] || signal[:fix_changes_shipped])
    remote_only = truthy?(signal["remote_only"] || signal[:remote_only])
    materially_new = truthy?(signal["materially_new"] || signal[:materially_new])
    start_with = rerun_start(trigger, remote_only)

    %{
      "start_with" => start_with,
      "requires_final_before_push" => start_with == "cheap" and fix_changes_shipped,
      "blind_rerun_counts_as_proof" => false,
      "auto_fix_counter" => auto_fix_counter(materially_new)
    }
  end

  def rerun_decision(_signal), do: rerun_decision(%{})

  defp gate_metadata_reasons(gate) when map_size(gate) == 0 do
    ["validation gate final proof metadata is missing"]
  end

  defp gate_metadata_reasons(gate) do
    gate_type = normalize_gate_value(Map.get(gate, "gate"))
    classes = Map.get(gate, "change_classes")
    required_checks = normalize_checks(Map.get(gate, "required_checks"))
    passed_checks = normalize_checks(Map.get(gate, "passed_checks"))

    base_reasons =
      []
      |> maybe_add(gate_type == "final", "validation gate must be `final`")

    case canonical_change_classes(classes) do
      {:ok, canonical_classes} ->
        {:ok, expected} = requirements(canonical_classes, "final")

        missing_checks =
          expected["required_checks"]
          |> Enum.reject(&(&1 in passed_checks))
          |> Enum.map(&"validation gate final proof is missing passed check `#{&1}`")

        required_mismatch =
          expected["required_checks"]
          |> Enum.reject(&(&1 in required_checks))
          |> Enum.map(&"validation gate final proof is missing required check `#{&1}`")

        base_reasons ++ missing_checks ++ required_mismatch

      {:error, reasons} ->
        base_reasons ++ reasons
    end
  end

  defp git_freshness_reasons(proof_git, current_git) do
    []
    |> maybe_add(non_empty_string?(proof_git["head_sha"]), "git.head_sha is missing from final proof")
    |> maybe_add(non_empty_string?(proof_git["tree_sha"]), "git.tree_sha is missing from final proof")
    |> maybe_add(proof_git["worktree_clean"] == true, "git.worktree_clean must be true for final proof")
    |> maybe_add(non_empty_string?(current_git["head_sha"]), "current git.head_sha is unavailable")
    |> maybe_add(non_empty_string?(current_git["tree_sha"]), "current git.tree_sha is unavailable")
    |> maybe_add(proof_git["head_sha"] == current_git["head_sha"], "final proof HEAD does not match current HEAD")
    |> maybe_add(proof_git["tree_sha"] == current_git["tree_sha"], "final proof tree does not match current HEAD tree")
    |> maybe_add(current_git["worktree_clean"] == true, "current worktree is not clean for shipped paths")
  end

  defp normalize_change_class(value) when is_atom(value), do: normalize_change_class(Atom.to_string(value))

  defp normalize_change_class(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[\s-]+/, "_")

    if normalized in @allowed_change_classes, do: normalized
  end

  defp normalize_change_class(_value), do: nil

  defp canonical_gate(gate) do
    case normalize_gate_value(gate) do
      gate when gate in @gate_types -> {:ok, gate}
      _ -> {:error, ["gate must be one of #{Enum.join(@gate_types, ", ")}"]}
    end
  end

  defp normalize_gate_value(value) when is_atom(value), do: normalize_gate_value(Atom.to_string(value))

  defp normalize_gate_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp normalize_gate_value(_value), do: nil

  defp normalize_issue_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> value |> Atom.to_string() |> String.trim()
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_issue_labels(_labels), do: []

  defp canonical_change_classes_or_empty(change_classes) do
    case canonical_change_classes(change_classes) do
      {:ok, classes} -> classes
      {:error, _reasons} -> []
    end
  end

  defp delivery_tdd_enabled?(issue_labels) when is_list(issue_labels) do
    @delivery_tdd_label in issue_labels
  end

  defp maybe_add_required_proof_check(requirements, false, _check, _source), do: requirements

  defp maybe_add_required_proof_check(requirements, true, check, source) do
    requirements ++
      [
        %{
          "check" => check,
          "label" => Map.fetch!(@proof_check_labels, check),
          "source" => source,
          "next_action" => Map.fetch!(@proof_check_actions, check)
        }
      ]
  end

  defp class_for_path(path) do
    normalized = path |> String.replace("\\", "/") |> String.downcase()

    cond do
      runtime_contract_path?(normalized) -> "runtime_contract"
      stateful_path?(normalized) -> "stateful"
      ui_path?(normalized) -> "ui"
      docs_path?(normalized) -> "docs_only"
      backend_path?(normalized) -> "backend_only"
      true -> "runtime_contract"
    end
  end

  defp runtime_contract_path?(path) do
    starts_with_any?(path, @runtime_contract_prefixes) or
      ends_with_any?(path, @runtime_contract_suffixes) or
      contains_any?(path, @runtime_contract_fragments)
  end

  defp stateful_path?(path) do
    String.contains?(path, "task_v3") or
      String.contains?(path, "stateful") or
      String.contains?(path, "migration") or
      String.contains?(path, "schema") or
      String.contains?(path, "/db/") or
      String.contains?(path, "database")
  end

  defp ui_path?(path) do
    ui_root_path?(path) or
      Path.extname(path) in @ui_asset_extensions
  end

  defp ui_root_path?(path) do
    starts_with_any?(path, @ui_path_prefixes) or
      contains_any?(path, @ui_path_fragments)
  end

  defp docs_path?(path) do
    Path.extname(path) in [".adoc", ".md", ".rst", ".txt"]
  end

  defp backend_path?(path) do
    Path.extname(path) in [".ex", ".exs", ".go", ".java", ".py", ".rb", ".rs"] or
      backend_javascript_path?(path)
  end

  defp backend_javascript_path?(path) do
    Path.extname(path) in @backend_javascript_extensions and not ui_root_path?(path)
  end

  defp final_gate_required?(classes) do
    Enum.any?(classes, &(&1 != "docs_only"))
  end

  defp strictest_change_class(classes) do
    Enum.max_by(classes, &Map.fetch!(@strictness_rank, &1))
  end

  defp sort_change_classes(classes) do
    Enum.sort_by(classes, &{Map.fetch!(@strictness_rank, &1), &1})
  end

  defp sort_checks(checks) do
    Enum.sort_by(checks, fn check ->
      {Enum.find_index(@check_order, &(&1 == check)) || 999, check}
    end)
  end

  defp normalize_git_metadata(metadata) when is_map(metadata) do
    %{
      "head_sha" => string_or_nil(metadata["head_sha"] || metadata[:head_sha]),
      "tree_sha" => string_or_nil(metadata["tree_sha"] || metadata[:tree_sha]),
      "worktree_clean" => metadata["worktree_clean"] || metadata[:worktree_clean] || false
    }
  end

  defp maybe_add(acc, true, _message), do: acc
  defp maybe_add(acc, false, message), do: acc ++ [message]

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp string_or_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp string_or_nil(_value), do: nil

  defp normalize_trigger(value) when is_atom(value), do: normalize_trigger(Atom.to_string(value))

  defp normalize_trigger(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp normalize_trigger(_value), do: nil

  defp truthy?(value), do: value in [true, "true", "yes", "1", 1]

  defp placeholder_check_command?(value) when is_binary(value) do
    trimmed = String.trim(value)
    normalized = String.downcase(trimmed)

    trimmed == "" or String.starts_with?(trimmed, "<") or String.contains?(normalized, "fill only") or normalized in ["n/a", "na", "none"]
  end

  defp placeholder_check_command?(_value), do: true

  defp rerun_start(trigger, true) when trigger in ["ci_failure", "review_feedback"], do: "blocked_decision"
  defp rerun_start(_trigger, _remote_only), do: "cheap"

  defp auto_fix_counter(true), do: "new_signal"
  defp auto_fix_counter(false), do: "same_signal"

  defp starts_with_any?(value, prefixes), do: Enum.any?(prefixes, &String.starts_with?(value, &1))
  defp ends_with_any?(value, suffixes), do: Enum.any?(suffixes, &String.ends_with?(value, &1))
  defp contains_any?(value, fragments), do: Enum.any?(fragments, &String.contains?(value, &1))
end
