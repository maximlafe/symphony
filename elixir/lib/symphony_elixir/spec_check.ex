defmodule SymphonyElixir.SpecCheck do
  @moduledoc """
  Fail-closed spec gate used before execution transitions.
  """

  alias SymphonyElixir.{AcceptanceCapability, HandoffCheck, RiskyTaskClassifier}

  @default_manifest_path ".symphony/verification/spec-manifest.json"
  @default_contract_lock_path ".symphony/verification/spec-contract.lock.json"
  @default_execution_states ["In Progress"]
  @default_spec_review_states ["Spec Review"]
  @terminal_dependency_states MapSet.new([
                                "closed",
                                "cancelled",
                                "canceled",
                                "duplicate",
                                "done"
                              ])
  @pre_execution_states MapSet.new(["todo", "spec prep", "spec_prep"])

  @type result :: {:ok, map()} | {:error, map()}

  @spec default_manifest_path() :: String.t()
  def default_manifest_path, do: @default_manifest_path

  @spec default_contract_lock_path() :: String.t()
  def default_contract_lock_path, do: @default_contract_lock_path

  @spec default_execution_states() :: [String.t()]
  def default_execution_states, do: @default_execution_states

  @spec default_spec_review_states() :: [String.t()]
  def default_spec_review_states, do: @default_spec_review_states

  @spec execution_state?(String.t() | nil) :: boolean()
  def execution_state?(state_name) when is_binary(state_name) do
    normalized = normalize_state(state_name)

    Enum.any?(@default_execution_states, fn execution_state ->
      normalize_state(execution_state) == normalized
    end)
  end

  def execution_state?(_state_name), do: false

  @spec spec_review_state?(String.t() | nil) :: boolean()
  def spec_review_state?(state_name) when is_binary(state_name) do
    normalized = normalize_state(state_name)

    Enum.any?(@default_spec_review_states, fn review_state ->
      normalize_state(review_state) == normalized
    end)
  end

  def spec_review_state?(_state_name), do: false

  @spec contract_revision_from_description(String.t() | nil) :: String.t() | nil
  def contract_revision_from_description(issue_description) when is_binary(issue_description) do
    issue_description
    |> HandoffCheck.acceptance_contract_from_issue_description()
    |> Map.get("revision")
  end

  def contract_revision_from_description(_issue_description), do: nil

  @spec material_spec_change?(String.t() | nil, String.t() | nil) :: boolean()
  def material_spec_change?(before_description, after_description) do
    contract_revision_from_description(before_description) !=
      contract_revision_from_description(after_description)
  end

  @spec evaluate(String.t()) :: result()
  def evaluate(issue_description) when is_binary(issue_description) do
    evaluate(issue_description, [])
  end

  def evaluate(_issue_description) do
    {:error,
     %{
       "passed" => false,
       "summary" => "spec check failed: issue description must be a string",
       "missing_items" => ["issue description is required for `symphony_spec_check`"]
     }}
  end

  @spec evaluate(String.t(), keyword()) :: result()
  def evaluate(issue_description, opts) when is_binary(issue_description) and is_list(opts) do
    checked_at = Keyword.get(opts, :checked_at, DateTime.utc_now())
    issue_id = Keyword.get(opts, :issue_id)
    issue_identifier = Keyword.get(opts, :issue_identifier)
    issue_state = Keyword.get(opts, :issue_state)
    issue_labels = normalize_labels(Keyword.get(opts, :labels, []))
    blocked_by = normalize_blockers(Keyword.get(opts, :blocked_by, []))
    {required_capabilities, capability_parse_errors} = AcceptanceCapability.required_capabilities(issue_description)
    acceptance_matrix_errors = HandoffCheck.acceptance_matrix_parse_errors(issue_description)
    spec_contract = HandoffCheck.acceptance_contract_from_issue_description(issue_description)

    risk_classifier =
      RiskyTaskClassifier.classify(%{
        description: issue_description,
        labels: issue_labels,
        required_capabilities: required_capabilities,
        blocked_by: blocked_by
      })

    dependency_conflicts = dependency_conflicts(risk_classifier, blocked_by)

    missing_items =
      []
      |> Kernel.++(missing_contract_items(spec_contract))
      |> Kernel.++(acceptance_matrix_errors)
      |> Kernel.++(capability_parse_errors)
      |> Kernel.++(dependency_conflicts)
      |> Enum.uniq()

    passed = missing_items == []

    manifest = %{
      "contract_version" => 1,
      "checked_at" => DateTime.to_iso8601(checked_at),
      "passed" => passed,
      "summary" => summary_for_manifest(passed, missing_items),
      "target_state" => "In Progress",
      "contract_revision" => spec_contract["revision"],
      "spec_contract" => spec_contract,
      "risk_classifier" => risk_classifier,
      "dependency_graph_guard" => %{
        "stateful_migration" => RiskyTaskClassifier.stateful_migration?(risk_classifier),
        "blocked_by" => blocked_by,
        "blocking_dependencies" => non_terminal_blockers(blocked_by)
      },
      "issue" => %{
        "id" => issue_id,
        "identifier" => issue_identifier,
        "state" => issue_state,
        "labels" => issue_labels,
        "required_capabilities" => required_capabilities
      },
      "missing_items" => missing_items
    }

    if passed, do: {:ok, manifest}, else: {:error, manifest}
  end

  def evaluate(_issue_description, _opts) do
    {:error,
     %{
       "passed" => false,
       "summary" => "spec check failed: issue description must be a string",
       "missing_items" => ["issue description is required for `symphony_spec_check`"]
     }}
  end

  @spec write_manifest(map(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_manifest(manifest, path) when is_map(manifest) and is_binary(path) do
    expanded_path = Path.expand(path)

    with :ok <- File.mkdir_p(Path.dirname(expanded_path)),
         :ok <- File.write(expanded_path, Jason.encode!(manifest, pretty: true)) do
      {:ok, expanded_path}
    end
  end

  @spec write_contract_lock(map(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_contract_lock(manifest, path) when is_map(manifest) and is_binary(path) do
    expanded_path = Path.expand(path)

    lock_payload = %{
      "version" => 1,
      "locked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "issue" => %{
        "id" => get_in(manifest, ["issue", "id"]),
        "identifier" => get_in(manifest, ["issue", "identifier"])
      },
      "contract_revision" => manifest["contract_revision"],
      "spec_contract" => manifest["spec_contract"]
    }

    with :ok <- File.mkdir_p(Path.dirname(expanded_path)),
         :ok <- File.write(expanded_path, Jason.encode!(lock_payload, pretty: true)) do
      {:ok, expanded_path}
    end
  end

  @spec execution_transition_allowed?(Path.t(), String.t(), String.t() | nil) ::
          :ok | {:error, atom(), map()}
  def execution_transition_allowed?(manifest_path, issue_id, state_name) do
    execution_transition_allowed?(manifest_path, issue_id, state_name, [])
  end

  @spec execution_transition_allowed?(Path.t(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, atom(), map()}
  def execution_transition_allowed?(manifest_path, issue_id, state_name, opts)
      when is_binary(manifest_path) and is_binary(issue_id) and is_list(opts) do
    with {:ok, manifest} <- load_manifest(manifest_path),
         :ok <- validate_manifest_identity(manifest, issue_id, state_name),
         :ok <- validate_manifest_contract_revision(manifest, opts),
         :ok <- validate_manifest_contract_lock(manifest, opts),
         :ok <- validate_manifest_routing(manifest, opts) do
      validate_manifest_dependencies(manifest)
    end
  end

  def execution_transition_allowed?(_manifest_path, _issue_id, _state_name, _opts) do
    {:error, :spec_manifest_invalid, %{"reason" => "issue_id is required"}}
  end

  defp load_manifest(path) do
    expanded_path = Path.expand(path)

    with {:ok, body} <- File.read(expanded_path),
         {:ok, manifest} <- Jason.decode(body) do
      {:ok, manifest}
    else
      {:error, :enoent} ->
        {:error, :spec_manifest_missing, %{"reason" => "spec manifest file is missing", "manifest_path" => expanded_path}}

      {:error, reason} when is_atom(reason) ->
        {:error, :spec_manifest_invalid, %{"reason" => "cannot read spec manifest", "manifest_path" => expanded_path, "details" => inspect(reason)}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, :spec_manifest_invalid, %{"reason" => "spec manifest is not valid JSON", "manifest_path" => expanded_path, "details" => Exception.message(error)}}
    end
  end

  defp validate_manifest_identity(manifest, issue_id, state_name) do
    manifest_issue_id = get_in(manifest, ["issue", "id"])
    manifest_target_state = manifest["target_state"]

    cond do
      manifest["passed"] != true ->
        {:error, :spec_manifest_failed, %{"reason" => "spec manifest does not record a successful spec check", "manifest" => manifest}}

      manifest_issue_id not in [issue_id, nil] ->
        {:error, :spec_manifest_invalid, %{"reason" => "spec manifest belongs to a different issue", "manifest" => manifest}}

      is_binary(state_name) and state_name != "" and
        is_binary(manifest_target_state) and manifest_target_state != state_name ->
        {:error, :spec_manifest_invalid, %{"reason" => "spec manifest target state does not match requested execution state", "manifest" => manifest}}

      true ->
        :ok
    end
  end

  defp validate_manifest_contract_revision(manifest, opts) do
    manifest_revision = manifest["contract_revision"]
    issue_description = Keyword.get(opts, :issue_description)
    expected_revision = contract_revision_from_description(issue_description)

    cond do
      not (is_binary(manifest_revision) and String.trim(manifest_revision) != "") ->
        {:error, :spec_manifest_stale,
         %{
           "reason" => "spec manifest is missing contract revision",
           "details" => ["re-run `symphony_spec_check` to freeze the current spec revision"],
           "manifest" => manifest
         }}

      not is_binary(issue_description) ->
        {:error, :spec_manifest_stale,
         %{
           "reason" => "current issue description is unavailable for spec revision comparison",
           "details" => ["route to `Spec Review` and run `symphony_spec_check` again"],
           "manifest" => manifest
         }}

      expected_revision != manifest_revision ->
        {:error, :spec_manifest_stale,
         %{
           "reason" => "material spec change detected: execution must return to `Spec Review`",
           "details" => [
             "expected_revision=#{expected_revision}",
             "manifest_revision=#{manifest_revision}"
           ],
           "required_state" => "Spec Review",
           "manifest" => manifest
         }}

      true ->
        :ok
    end
  end

  defp validate_manifest_contract_lock(manifest, opts) do
    require_lock? = Keyword.get(opts, :require_contract_lock, true)
    contract_lock_path = resolve_contract_lock_path(opts)

    cond do
      not require_lock? ->
        :ok

      not is_binary(contract_lock_path) or String.trim(contract_lock_path) == "" ->
        {:error, :spec_manifest_stale,
         %{
           "reason" => "spec contract lock path is missing",
           "details" => ["run `symphony_spec_check` to write `spec-contract.lock.json` before execution"]
         }}

      not File.exists?(contract_lock_path) ->
        {:error, :spec_manifest_stale,
         %{
           "reason" => "spec contract lock file is missing",
           "contract_lock_path" => Path.expand(contract_lock_path),
           "details" => ["run `symphony_spec_check` to regenerate `spec-contract.lock.json`"]
         }}

      true ->
        compare_manifest_with_contract_lock(manifest, contract_lock_path)
    end
  end

  defp resolve_contract_lock_path(opts) when is_list(opts) do
    explicit_path = Keyword.get(opts, :contract_lock_path)
    repo_path = Keyword.get(opts, :repo_path)

    cond do
      is_binary(explicit_path) and String.trim(explicit_path) != "" ->
        explicit_path

      is_binary(repo_path) and String.trim(repo_path) != "" ->
        Path.join(Path.expand(repo_path), @default_contract_lock_path)

      true ->
        nil
    end
  end

  defp compare_manifest_with_contract_lock(manifest, contract_lock_path) do
    with {:ok, body} <- File.read(contract_lock_path),
         {:ok, contract_lock} <- Jason.decode(body) do
      manifest_revision = manifest["contract_revision"]
      lock_revision = contract_lock["contract_revision"]
      manifest_issue_id = get_in(manifest, ["issue", "id"])
      lock_issue_id = get_in(contract_lock, ["issue", "id"])

      cond do
        not (is_binary(lock_revision) and String.trim(lock_revision) != "") ->
          {:error, :spec_manifest_stale,
           %{
             "reason" => "spec contract lock revision is missing",
             "contract_lock_path" => Path.expand(contract_lock_path),
             "details" => ["run `symphony_spec_check` to rewrite the spec lock"]
           }}

        lock_revision != manifest_revision ->
          {:error, :spec_manifest_stale,
           %{
             "reason" => "spec contract lock revision does not match spec manifest",
             "contract_lock_path" => Path.expand(contract_lock_path),
             "details" => [
               "lock_revision=#{lock_revision}",
               "manifest_revision=#{manifest_revision}"
             ]
           }}

        is_binary(lock_issue_id) and is_binary(manifest_issue_id) and lock_issue_id != manifest_issue_id ->
          {:error, :spec_manifest_invalid,
           %{
             "reason" => "spec contract lock belongs to a different issue",
             "contract_lock_path" => Path.expand(contract_lock_path),
             "details" => [
               "lock_issue_id=#{lock_issue_id}",
               "manifest_issue_id=#{manifest_issue_id}"
             ]
           }}

        true ->
          :ok
      end
    else
      {:error, reason} ->
        {:error, :spec_manifest_invalid,
         %{
           "reason" => "cannot read spec contract lock file",
           "contract_lock_path" => Path.expand(contract_lock_path),
           "details" => inspect(reason)
         }}
    end
  end

  defp validate_manifest_routing(manifest, opts) do
    risk_classifier = manifest["risk_classifier"] || %{}
    issue_state = Keyword.get(opts, :issue_state)
    normalized_issue_state = normalize_state(issue_state)

    cond do
      not RiskyTaskClassifier.risky_task?(risk_classifier) ->
        :ok

      spec_review_state?(issue_state) ->
        :ok

      normalized_issue_state in @pre_execution_states ->
        {:error, :spec_manifest_stale,
         %{
           "reason" => "risky task requires explicit `Spec Review` before entering execution",
           "required_state" => "Spec Review",
           "details" => risk_classifier["reasons"] || []
         }}

      true ->
        :ok
    end
  end

  defp validate_manifest_dependencies(manifest) do
    blocking_dependencies =
      get_in(manifest, ["dependency_graph_guard", "blocking_dependencies"])
      |> normalize_blocking_dependencies()

    if blocking_dependencies == [] do
      :ok
    else
      {:error, :spec_manifest_stale,
       %{
         "reason" => "dependency graph guard blocked execution for stateful/migration spec",
         "blocking_dependencies" => blocking_dependencies,
         "details" => ["resolve blocking dependencies or return to `Spec Review` to re-sequence the rollout"]
       }}
    end
  end

  defp normalize_blocking_dependencies(blocking_dependencies) when is_list(blocking_dependencies) do
    Enum.flat_map(blocking_dependencies, fn
      %{} = blocker ->
        identifier = blocker["identifier"] || blocker[:identifier]
        state = blocker["state"] || blocker[:state]

        if is_binary(identifier) and String.trim(identifier) != "" do
          [%{"identifier" => identifier, "state" => state}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp normalize_blocking_dependencies(_blocking_dependencies), do: []

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> ""
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp normalize_labels(_labels), do: []

  defp normalize_blockers(blockers) when is_list(blockers) do
    Enum.flat_map(blockers, fn
      %{} = blocker ->
        identifier =
          blocker["identifier"] ||
            blocker[:identifier] ||
            blocker["id"] ||
            blocker[:id]

        if is_binary(identifier) and String.trim(identifier) != "" do
          [
            %{
              "id" => blocker["id"] || blocker[:id],
              "identifier" => identifier,
              "state" => blocker["state"] || blocker[:state]
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp normalize_blockers(_blockers), do: []

  defp non_terminal_blockers(blockers) when is_list(blockers) do
    blockers
    |> normalize_blockers()
    |> Enum.filter(fn blocker ->
      blocker
      |> Map.get("state")
      |> normalize_state()
      |> then(&(not MapSet.member?(@terminal_dependency_states, &1)))
    end)
  end

  defp dependency_conflicts(risk_classifier, blockers) do
    blocking_dependencies = non_terminal_blockers(blockers)

    if RiskyTaskClassifier.stateful_migration?(risk_classifier) and blocking_dependencies != [] do
      blocker_summary =
        Enum.map_join(blocking_dependencies, ", ", fn blocker ->
          "#{blocker["identifier"]}(#{blocker["state"] || "unknown"})"
        end)

      ["stateful/migration spec has unresolved blocking dependencies: #{blocker_summary}"]
    else
      []
    end
  end

  defp missing_contract_items(spec_contract) when is_map(spec_contract) do
    acceptance_matrix = get_in(spec_contract, ["payload", "acceptance_matrix"]) || []
    required_capabilities = get_in(spec_contract, ["payload", "required_capabilities"]) || []

    if acceptance_matrix == [] and required_capabilities == [] do
      ["spec contract is missing: add `Acceptance Matrix` and/or `Required capabilities` in the issue description"]
    else
      []
    end
  end

  defp missing_contract_items(_spec_contract) do
    ["spec contract is missing: add `Acceptance Matrix` and/or `Required capabilities` in the issue description"]
  end

  defp summary_for_manifest(true, _missing_items), do: "spec check passed"
  defp summary_for_manifest(false, missing_items), do: "spec check failed (#{length(missing_items)} issue(s))"

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state_name), do: ""
end
