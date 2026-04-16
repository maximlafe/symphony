defmodule SymphonyElixir.ResumeCheckpoint do
  @moduledoc """
  Builds and validates a compact retry/handoff resume checkpoint for unattended runs.
  """

  alias SymphonyElixir.{Config, TelemetrySchema}

  @manifest_rel_path ".symphony/resume/checkpoint.json"
  @workpad_path "workpad.md"
  @workpad_ref_path ".workpad-id"
  @atom_key_aliases %{
    "id" => :id,
    "identifier" => :identifier,
    "number" => :number,
    "url" => :url,
    "state" => :state,
    "result" => :result,
    "summary" => :summary,
    "checked_at" => :checked_at,
    "workspace_diff_fingerprint" => :workspace_diff_fingerprint,
    "has_pending_checks" => :has_pending_checks,
    "has_actionable_feedback" => :has_actionable_feedback,
    "feedback_digest" => :feedback_digest,
    "active_validation_snapshot" => :active_validation_snapshot,
    "command" => :command,
    "external_step" => :external_step,
    "validation_bundle_fingerprint" => :validation_bundle_fingerprint,
    "wait_state" => :wait_state,
    "result_ref" => :result_ref
  }

  @spec manifest_path(map() | nil, keyword()) :: String.t() | nil
  def manifest_path(issue, opts \\ []) do
    with workspace when is_binary(workspace) <- workspace_for_issue(issue, opts) do
      Path.join(workspace, @manifest_rel_path)
    end
  end

  @spec capture(map() | nil, map(), keyword()) :: map()
  def capture(issue, running_entry, opts \\ [])
      when (is_map(issue) or is_nil(issue)) and is_map(running_entry) and is_list(opts) do
    checkpoint =
      base_checkpoint(issue)
      |> Map.put("captured_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
      |> Map.put("last_validation_status", validation_status_from_running_entry(running_entry))
      |> Map.put("active_validation_snapshot", active_validation_snapshot_from_context(running_entry))

    with workspace when is_binary(workspace) <- workspace_for_issue(issue, opts),
         true <- File.dir?(workspace) do
      checkpoint =
        checkpoint
        |> Map.put("available", true)
        |> Map.put("manifest_path", Path.join(workspace, @manifest_rel_path))
        |> Map.put("branch", git_trimmed(workspace, ["rev-parse", "--abbrev-ref", "HEAD"]))
        |> Map.put("head", git_trimmed(workspace, ["rev-parse", "HEAD"]))
        |> Map.put("changed_files", git_changed_files(workspace))
        |> Map.put("workspace_diff_fingerprint", git_workspace_diff_fingerprint(workspace))
        |> Map.put("workpad_ref", read_trimmed(Path.join(workspace, @workpad_ref_path)))
        |> Map.put("workpad_digest", sha256_file(Path.join(workspace, @workpad_path)))
        |> merge_pr_context(running_entry)
        |> Map.merge(TelemetrySchema.validation_guard_payload(running_entry))
        |> evaluate_readiness()

      persist_checkpoint(checkpoint)
    else
      _ ->
        checkpoint
        |> add_fallback_reason("workspace is unavailable for retry checkpoint capture")
        |> evaluate_readiness()
    end
  end

  @spec load(map() | nil, keyword()) :: map()
  def load(issue, opts \\ []) when is_list(opts) do
    with workspace when is_binary(workspace) <- workspace_for_issue(issue, opts),
         manifest_path when is_binary(manifest_path) <- Path.join(workspace, @manifest_rel_path),
         true <- File.exists?(manifest_path),
         {:ok, body} <- File.read(manifest_path),
         {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded) do
      decoded
      |> normalize_checkpoint()
      |> revalidate(workspace)
      |> evaluate_readiness()
      |> then(&Map.merge(&1, TelemetrySchema.checkpoint_payload(&1, "resume_checkpoint")))
      |> Map.put("available", true)
      |> Map.put("manifest_path", manifest_path)
    else
      _ ->
        base_checkpoint(issue)
        |> add_fallback_reason("resume checkpoint is unavailable")
        |> evaluate_readiness()
    end
  end

  @spec for_prompt(map() | nil) :: map()
  def for_prompt(checkpoint) when is_map(checkpoint) do
    checkpoint
    |> normalize_checkpoint()
    |> evaluate_readiness()
    |> then(&Map.merge(&1, TelemetrySchema.checkpoint_payload(&1, "resume_checkpoint")))
  end

  def for_prompt(_checkpoint), do: evaluate_readiness(base_checkpoint(nil))

  defp persist_checkpoint(%{"manifest_path" => path} = checkpoint) when is_binary(path) and path != "" do
    checkpoint
    |> ensure_checkpoint_dir(path)
    |> write_checkpoint_file(path)
    |> evaluate_readiness()
  end

  defp ensure_checkpoint_dir(checkpoint, path) when is_binary(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        checkpoint

      {:error, reason} ->
        add_fallback_reason(checkpoint, "resume checkpoint directory creation failed: #{inspect(reason)}")
    end
  end

  defp write_checkpoint_file(checkpoint, path) when is_binary(path) do
    case File.write(path, Jason.encode!(checkpoint, pretty: true)) do
      :ok ->
        checkpoint

      {:error, reason} ->
        add_fallback_reason(checkpoint, "resume checkpoint write failed: #{inspect(reason)}")
    end
  end

  defp normalize_checkpoint(%{} = checkpoint) do
    base = base_checkpoint(nil)

    checkpoint
    |> then(fn map -> Map.merge(base, map) end)
    |> Map.update("changed_files", [], &normalize_changed_files/1)
    |> Map.update("fallback_reasons", [], &normalize_reasons/1)
    |> Map.update("last_validation_status", base["last_validation_status"], &normalize_validation_status/1)
    |> Map.put("active_validation_snapshot", normalize_active_validation_snapshot(Map.get(checkpoint, "active_validation_snapshot")))
    |> Map.put("open_pr", normalize_open_pr(Map.get(checkpoint, "open_pr")))
    |> Map.put("feedback_digest", normalize_optional_string(Map.get(checkpoint, "feedback_digest")))
    |> Map.put("workspace_diff_fingerprint", normalize_optional_string(Map.get(checkpoint, "workspace_diff_fingerprint")))
    |> normalize_boolean("pending_checks")
    |> normalize_boolean("open_feedback")
  end

  defp normalize_checkpoint(_checkpoint), do: base_checkpoint(nil)

  defp revalidate(%{} = checkpoint, workspace) when is_binary(workspace) do
    current_branch = git_trimmed(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])
    current_head = git_trimmed(workspace, ["rev-parse", "HEAD"])
    current_workpad_digest = sha256_file(Path.join(workspace, @workpad_path))

    checkpoint
    |> maybe_add_mismatch_reason("branch", Map.get(checkpoint, "branch"), current_branch)
    |> maybe_add_mismatch_reason("head", Map.get(checkpoint, "head"), current_head)
    |> maybe_add_mismatch_reason("workpad_digest", Map.get(checkpoint, "workpad_digest"), current_workpad_digest)
  end

  defp evaluate_readiness(%{} = checkpoint) do
    reasons =
      checkpoint
      |> Map.get("fallback_reasons", [])
      |> normalize_reasons()
      |> Kernel.++(required_field_reasons(checkpoint))
      |> Enum.uniq()

    checkpoint
    |> Map.put("available", Map.get(checkpoint, "available") == true)
    |> Map.put("fallback_reasons", reasons)
    |> Map.put("resume_ready", reasons == [])
    |> then(&Map.merge(&1, TelemetrySchema.checkpoint_payload(&1, "resume_checkpoint")))
  end

  defp required_field_reasons(checkpoint) do
    []
    |> maybe_require_present(checkpoint, "branch")
    |> maybe_require_present(checkpoint, "head")
    |> maybe_require_present(checkpoint, "workpad_ref")
    |> maybe_require_present(checkpoint, "workpad_digest")
    |> maybe_require_pr_details(checkpoint)
  end

  defp maybe_require_present(reasons, checkpoint, field) do
    value = Map.get(checkpoint, field)

    if is_binary(value) and String.trim(value) != "" do
      reasons
    else
      reasons ++ ["missing `#{field}` in resume checkpoint"]
    end
  end

  defp maybe_require_pr_details(reasons, checkpoint) do
    case Map.get(checkpoint, "open_pr") do
      %{} ->
        reasons
        |> maybe_require_boolean(checkpoint, "pending_checks")
        |> maybe_require_boolean(checkpoint, "open_feedback")

      _ ->
        reasons
    end
  end

  defp maybe_require_boolean(reasons, checkpoint, key) do
    case Map.get(checkpoint, key) do
      value when is_boolean(value) -> reasons
      _ -> reasons ++ ["missing `#{key}` for open PR resume context"]
    end
  end

  defp maybe_add_mismatch_reason(checkpoint, _field, expected, current)
       when expected in [nil, ""] or current in [nil, ""],
       do: checkpoint

  defp maybe_add_mismatch_reason(checkpoint, field, expected, current) do
    if expected == current do
      checkpoint
    else
      add_fallback_reason(
        checkpoint,
        "resume checkpoint `#{field}` mismatch: expected `#{expected}`, current `#{current}`"
      )
    end
  end

  defp add_fallback_reason(%{} = checkpoint, reason) when is_binary(reason) do
    reasons =
      checkpoint
      |> Map.get("fallback_reasons", [])
      |> normalize_reasons()
      |> Kernel.++([reason])
      |> Enum.uniq()

    Map.put(checkpoint, "fallback_reasons", reasons)
  end

  defp merge_pr_context(%{} = checkpoint, running_entry) when is_map(running_entry) do
    snapshot =
      running_entry
      |> Map.get(:latest_pr_snapshot)
      |> normalize_open_pr_snapshot()

    ci_wait_result = Map.get(running_entry, :latest_ci_wait_result)
    resume_checkpoint = normalize_checkpoint(Map.get(running_entry, :resume_checkpoint))

    checkpoint
    |> Map.put("open_pr", open_pr_from_context(snapshot, resume_checkpoint))
    |> Map.put("pending_checks", pending_checks_from_context(snapshot, ci_wait_result, resume_checkpoint))
    |> Map.put("open_feedback", open_feedback_from_context(snapshot, resume_checkpoint))
    |> Map.put("feedback_digest", feedback_digest_from_context(snapshot, resume_checkpoint))
  end

  defp open_pr_from_context(%{"url" => url} = snapshot, _resume_checkpoint) when is_binary(url) do
    %{
      "number" => Map.get(snapshot, "number"),
      "url" => url,
      "state" => Map.get(snapshot, "state")
    }
  end

  defp open_pr_from_context(_snapshot, %{"open_pr" => %{} = open_pr}) do
    normalize_open_pr(open_pr)
  end

  defp open_pr_from_context(_snapshot, %{}), do: nil

  defp pending_checks_from_context(%{} = snapshot, _ci_wait_result, _resume_checkpoint) do
    value = snapshot["has_pending_checks"]

    if is_boolean(value), do: value
  end

  defp pending_checks_from_context(_snapshot, %{} = ci_wait_result, _resume_checkpoint) do
    if is_list(ci_wait_result["pending_checks"]), do: ci_wait_result["pending_checks"] != []
  end

  defp pending_checks_from_context(_snapshot, _ci_wait_result, %{} = resume_checkpoint) do
    case Map.get(resume_checkpoint, "pending_checks") do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  defp open_feedback_from_snapshot(%{} = snapshot) do
    value = snapshot["has_actionable_feedback"]

    if is_boolean(value), do: value
  end

  defp open_feedback_from_context(%{} = snapshot, _resume_checkpoint), do: open_feedback_from_snapshot(snapshot)

  defp open_feedback_from_context(_snapshot, %{} = resume_checkpoint) do
    case Map.get(resume_checkpoint, "open_feedback") do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  defp feedback_digest_from_context(%{} = snapshot, _resume_checkpoint) do
    normalize_optional_string(snapshot["feedback_digest"])
  end

  defp feedback_digest_from_context(_snapshot, %{} = resume_checkpoint) do
    normalize_optional_string(Map.get(resume_checkpoint, "feedback_digest"))
  end

  defp active_validation_snapshot_from_context(%{} = running_entry) do
    current_command = normalize_optional_string(Map.get(running_entry, :current_command))
    external_step = normalize_optional_string(Map.get(running_entry, :external_step))
    running_snapshot = normalize_active_validation_snapshot(Map.get(running_entry, :active_validation_snapshot))

    cond do
      is_map(running_snapshot) ->
        running_snapshot

      external_step == "exec_wait" ->
        validation_bundle_fingerprint_from_command(current_command)
        |> case do
          value when is_binary(value) and value != "" ->
            compact_map(%{
              "command" => current_command,
              "external_step" => external_step,
              "validation_bundle_fingerprint" => value
            })

          _ ->
            nil
        end

      true ->
        nil
    end
    |> case do
      %{} = snapshot ->
        snapshot

      _ ->
        running_entry
        |> Map.get(:resume_checkpoint)
        |> normalize_checkpoint()
        |> Map.get("active_validation_snapshot")
        |> normalize_active_validation_snapshot()
    end
  end

  defp normalize_open_pr_snapshot(%{} = snapshot) do
    url = map_get(snapshot, "url")
    state = map_get(snapshot, "state")
    number = extract_pr_number(url)
    has_pending_checks = map_get(snapshot, "has_pending_checks")
    has_actionable_feedback = map_get(snapshot, "has_actionable_feedback")
    feedback_digest = normalize_optional_string(map_get(snapshot, "feedback_digest"))

    if is_binary(url) and String.trim(url) != "" do
      %{
        "number" => number,
        "url" => url,
        "state" => state,
        "has_pending_checks" => has_pending_checks,
        "has_actionable_feedback" => has_actionable_feedback,
        "feedback_digest" => feedback_digest
      }
    end
  end

  defp normalize_open_pr_snapshot(_snapshot), do: nil

  defp normalize_open_pr(%{} = open_pr) do
    %{
      "number" => map_get(open_pr, "number"),
      "url" => map_get(open_pr, "url"),
      "state" => map_get(open_pr, "state")
    }
  end

  defp normalize_open_pr(_open_pr), do: nil

  defp normalize_changed_files(files) when is_list(files) do
    files
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_changed_files(_files), do: []

  defp normalize_reasons(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_reasons(_reasons), do: []

  defp normalize_active_validation_snapshot(%{} = snapshot) do
    command = normalize_optional_string(map_get(snapshot, "command"))
    external_step = normalize_optional_string(map_get(snapshot, "external_step"))
    validation_bundle_fingerprint = normalize_optional_string(map_get(snapshot, "validation_bundle_fingerprint"))
    wait_state = normalize_optional_string(map_get(snapshot, "wait_state"))
    result_ref = normalize_optional_string(map_get(snapshot, "result_ref"))

    if is_binary(validation_bundle_fingerprint) and validation_bundle_fingerprint != "" do
      compact_map(%{
        "command" => command,
        "external_step" => external_step,
        "validation_bundle_fingerprint" => validation_bundle_fingerprint,
        "wait_state" => wait_state,
        "result_ref" => result_ref
      })
    end
  end

  defp normalize_active_validation_snapshot(_snapshot), do: nil

  defp normalize_validation_status(%{} = status) do
    %{
      "result" => map_get(status, "result"),
      "summary" => map_get(status, "summary"),
      "checked_at" => map_get(status, "checked_at")
    }
    |> Map.put("result", map_get(status, "result") || "unknown")
    |> Map.put("summary", map_get(status, "summary"))
    |> Map.put("checked_at", map_get(status, "checked_at"))
  end

  defp normalize_validation_status(_status), do: %{"result" => "unknown", "summary" => nil, "checked_at" => nil}

  defp validation_status_from_running_entry(running_entry) do
    result = Map.get(running_entry, :verification_result) || "unknown"
    summary = Map.get(running_entry, :verification_summary)
    checked_at = Map.get(running_entry, :verification_checked_at)

    %{
      "result" => result,
      "summary" => summary,
      "checked_at" => datetime_to_iso8601(checked_at)
    }
  end

  defp datetime_to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_to_iso8601(_value), do: nil

  defp normalize_boolean(%{} = checkpoint, key) do
    value = Map.get(checkpoint, key)

    if is_boolean(value) do
      checkpoint
    else
      Map.put(checkpoint, key, nil)
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp validation_bundle_fingerprint_from_command(command) when is_binary(command) do
    normalized =
      command
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\s+/, " ")

    cond do
      Regex.match?(~r/^(mix test|make test)(\s|$)/, normalized) ->
        "validation:test"

      Regex.match?(~r/^make symphony-validate(\s|$)/, normalized) ->
        "validation:repo-validate"

      true ->
        nil
    end
  end

  defp validation_bundle_fingerprint_from_command(_command), do: nil

  defp git_trimmed(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp git_changed_files(workspace) do
    case System.cmd("git", ["-C", workspace, "status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_status_path/1)
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp git_workspace_diff_fingerprint(workspace) do
    status_lines = git_status_lines(workspace)

    if is_list(status_lines) do
      head = git_trimmed(workspace, ["rev-parse", "HEAD"]) || "unknown"

      entries =
        status_lines
        |> Enum.map(&parse_status_entry/1)
        |> Enum.reject(fn {_kind, _status, path} ->
          path == "" or internal_workspace_artifact?(path)
        end)

      entry_digests =
        entries
        |> Enum.sort_by(fn {_kind, status, path} -> {path, status} end)
        |> Enum.map(fn {kind, status, path} ->
          digest = sha256_file(Path.join(workspace, path)) || "missing"
          "#{kind}:#{status}:#{path}:#{digest}"
        end)

      ["head=#{head}" | entry_digests]
      |> Enum.join("\n---\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defp git_status_lines(workspace) do
    case System.cmd("git", ["-C", workspace, "status", "--porcelain=v1", "--untracked-files=all"], stderr_to_stdout: true) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> nil
    end
  end

  defp parse_status_entry(line) when is_binary(line) do
    status = String.slice(line, 0, 2)
    path = parse_status_path(line)

    kind = if status == "??", do: :untracked, else: :tracked
    {kind, status, path}
  end

  defp internal_workspace_artifact?(path) when is_binary(path) do
    path in [@manifest_rel_path, @workpad_path, @workpad_ref_path] or
      String.starts_with?(path, ".symphony/resume/")
  end

  defp parse_status_path(line) when is_binary(line) do
    trimmed =
      line
      |> String.slice(3..-1//1)
      |> to_string()
      |> String.trim()

    if String.contains?(trimmed, " -> ") do
      trimmed
      |> String.split(" -> ")
      |> List.last()
      |> String.trim()
    else
      trimmed
    end
  end

  defp read_trimmed(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> String.trim(body)
      _ -> nil
    end
  end

  defp sha256_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  defp extract_pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url, capture: :all_but_first) do
      [value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp extract_pr_number(_url), do: nil

  defp workspace_for_issue(issue, opts) do
    identifier = issue_identifier(issue)
    workspace_root = Keyword.get(opts, :workspace_root, Config.settings!().workspace.root)

    if is_binary(workspace_root) and is_binary(identifier) and String.trim(identifier) != "" do
      safe_id = String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
      Path.expand(Path.join(workspace_root, safe_id))
    end
  end

  defp issue_identifier(issue) when is_map(issue) do
    map_get(issue, "identifier") || map_get(issue, "id")
  end

  defp issue_identifier(_issue), do: nil

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Map.fetch!(@atom_key_aliases, key))
    end
  end

  defp base_checkpoint(issue) do
    %{
      "version" => 1,
      "available" => false,
      "resume_ready" => false,
      "fallback_reasons" => [],
      "manifest_path" => nil,
      "issue" => %{
        "id" => issue_id(issue),
        "identifier" => issue_identifier(issue)
      },
      "captured_at" => nil,
      "branch" => nil,
      "head" => nil,
      "changed_files" => [],
      "workspace_diff_fingerprint" => nil,
      "active_validation_snapshot" => nil,
      "last_validation_status" => %{
        "result" => "unknown",
        "summary" => nil,
        "checked_at" => nil
      },
      "open_pr" => nil,
      "pending_checks" => nil,
      "open_feedback" => nil,
      "feedback_digest" => nil,
      "workpad_ref" => nil,
      "workpad_digest" => nil
    }
  end

  defp issue_id(issue) when is_map(issue), do: map_get(issue, "id")
  defp issue_id(_issue), do: nil
end
