defmodule SymphonyElixir.ControllerFinalizer do
  @moduledoc """
  Executes deterministic post-implementation PR/CI/handoff finalization from the controller side.
  """

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @eligible_issue_states MapSet.new(["in progress", "rework"])
  @workpad_file "workpad.md"
  @workpad_ref_file ".workpad-id"
  @default_wait_timeout_ms 3_600_000
  @default_wait_poll_interval_ms 10_000
  @default_review_ready_state "In Review"

  @type checkpoint :: map()
  @type details :: map()
  @type outcome_payload :: %{checkpoint: checkpoint(), reason: String.t(), details: details()}
  @type outcome ::
          {:ok, outcome_payload()}
          | {:retry, outcome_payload()}
          | {:fallback, outcome_payload()}
          | {:not_applicable, outcome_payload()}

  @spec eligible?(Issue.t() | map(), map() | nil) :: boolean()
  def eligible?(issue, checkpoint) do
    checkpoint = normalize_checkpoint(checkpoint)

    cond do
      not eligible_issue_state?(issue) ->
        false

      not non_empty_binary?(issue_id(issue)) ->
        false

      not non_empty_binary?(issue_identifier(issue)) ->
        false

      not (is_integer(checkpoint_pr_number(checkpoint)) and checkpoint_pr_number(checkpoint) > 0) ->
        false

      blocked_for_current_head?(checkpoint) ->
        false

      true ->
        true
    end
  end

  @spec run(Issue.t() | map(), map() | nil, keyword()) :: outcome()
  def run(issue, checkpoint, opts \\ []) when is_list(opts) do
    checkpoint = normalize_checkpoint(checkpoint)

    if eligible?(issue, checkpoint) do
      do_run(issue, checkpoint, opts)
    else
      {:not_applicable,
       %{
         checkpoint: checkpoint,
         reason: "controller finalizer prerequisites are not satisfied",
         details: %{}
       }}
    end
  end

  defp do_run(issue, checkpoint, opts) do
    case build_context(issue, checkpoint, opts) do
      {:ok, context} ->
        run_pipeline(context, checkpoint, opts)

      {:error, %{message: message} = error} ->
        fallback_checkpoint = checkpoint_status(checkpoint, "action_required", message, checkpoint["head"])

        {:fallback,
         %{
           checkpoint: fallback_checkpoint,
           reason: message,
           details: Map.drop(error, [:message])
         }}
    end
  end

  defp run_pipeline(context, checkpoint, opts) do
    case call_tool("sync_workpad", sync_workpad_args(context), context.workspace, opts) do
      {:error, error} ->
        retry_or_fallback(checkpoint, error)

      {:ok, _payload} ->
        run_wait_for_checks(context, checkpoint, opts)
    end
  end

  defp run_wait_for_checks(context, checkpoint, opts) do
    case call_tool("github_wait_for_checks", wait_for_checks_args(context, opts), context.workspace, opts) do
      {:error, error} ->
        retry_or_fallback(checkpoint, error)

      {:ok, payload} ->
        wait_result = normalize_wait_result(payload)
        checkpoint = checkpoint_after_wait(checkpoint, wait_result)

        if wait_result["all_green"] == false do
          fallback_checkpoint =
            checkpoint_status(
              checkpoint,
              "action_required",
              "pull request checks failed",
              checkpoint["head"]
            )

          {:fallback,
           %{
             checkpoint: fallback_checkpoint,
             reason: "pull request checks failed",
             details: %{"wait_result" => wait_result}
           }}
        else
          run_snapshot(context, checkpoint, opts)
        end
    end
  end

  defp run_snapshot(context, checkpoint, opts) do
    case call_tool(
           "github_pr_snapshot",
           %{
             "repo" => context.repo,
             "pr_number" => context.pr_number,
             "include_feedback_details" => true
           },
           context.workspace,
           opts
         ) do
      {:error, error} ->
        retry_or_fallback(checkpoint, error)

      {:ok, payload} ->
        snapshot = normalize_snapshot(payload)
        checkpoint = checkpoint_after_snapshot(checkpoint, snapshot)

        cond do
          snapshot["has_pending_checks"] == true ->
            retry_checkpoint =
              checkpoint_status(
                checkpoint,
                "waiting",
                "pull request checks are still pending",
                nil
              )

            {:retry,
             %{
               checkpoint: retry_checkpoint,
               reason: "pull request checks are still pending",
               details: %{"snapshot" => snapshot}
             }}

          snapshot["has_actionable_feedback"] == true ->
            fallback_checkpoint =
              checkpoint_status(
                checkpoint,
                "action_required",
                "pull request has actionable feedback",
                checkpoint["head"]
              )

            {:fallback,
             %{
               checkpoint: fallback_checkpoint,
               reason: "pull request has actionable feedback",
               details: %{"snapshot" => snapshot}
             }}

          true ->
            run_handoff_check(context, checkpoint, snapshot, opts)
        end
    end
  end

  defp run_handoff_check(context, checkpoint, snapshot, opts) do
    case call_tool("symphony_handoff_check", handoff_args(context), context.workspace, opts) do
      {:error, error} ->
        retry_or_fallback(checkpoint, error)

      {:ok, payload} ->
        handle_handoff_manifest(context, checkpoint, snapshot, extract_manifest(payload), opts)
    end
  end

  defp handle_handoff_manifest(context, checkpoint, snapshot, manifest, opts) when is_map(manifest) do
    if manifest["passed"] == true do
      finalize_handoff_success(context, checkpoint, snapshot, manifest, opts)
    else
      fallback_checkpoint =
        checkpoint_status(
          checkpoint,
          "action_required",
          "symphony_handoff_check failed",
          checkpoint["head"]
        )

      {:fallback,
       %{
         checkpoint: fallback_checkpoint,
         reason: "symphony_handoff_check failed",
         details: %{
           "summary" => manifest["summary"],
           "missing_items" => manifest["missing_items"]
         }
       }}
    end
  end

  defp finalize_handoff_success(context, checkpoint, snapshot, manifest, opts) do
    case transition_issue_state(context.issue_id, opts) do
      :ok ->
        final_checkpoint = checkpoint_status(checkpoint, "succeeded", nil, nil)

        {:ok,
         %{
           checkpoint: final_checkpoint,
           reason: "controller finalizer completed successfully",
           details: %{
             "repo" => context.repo,
             "pr_number" => context.pr_number,
             "pr_url" => snapshot["url"],
             "manifest_path" => manifest["manifest_path"]
           }
         }}

      {:error, reason} ->
        retry_checkpoint =
          checkpoint_status(
            checkpoint,
            "waiting",
            "failed to transition issue state",
            nil
          )

        {:retry,
         %{
           checkpoint: retry_checkpoint,
           reason: "failed to transition issue state",
           details: %{"error" => inspect(reason)}
         }}
    end
  end

  defp retry_or_fallback(checkpoint, %{transient?: true, message: message} = error) do
    retry_checkpoint = checkpoint_status(checkpoint, "waiting", message, nil)

    {:retry,
     %{
       checkpoint: retry_checkpoint,
       reason: message,
       details: Map.drop(error, [:message, :transient?])
     }}
  end

  defp retry_or_fallback(checkpoint, %{message: message} = error) do
    fallback_checkpoint = checkpoint_status(checkpoint, "action_required", message, checkpoint["head"])

    {:fallback,
     %{
       checkpoint: fallback_checkpoint,
       reason: message,
       details: Map.drop(error, [:message, :transient?])
     }}
  end

  defp build_context(issue, checkpoint, opts) do
    issue_id = issue_id(issue)
    identifier = issue_identifier(issue)
    workspace = resolve_workspace_path(identifier)
    pr_number = checkpoint_pr_number(checkpoint)

    if File.dir?(workspace) do
      with {:ok, workpad_path, comment_id} <- resolve_workpad_paths(workspace),
           {:ok, repo} <- resolve_repo(workspace, opts) do
        {:ok,
         %{
           issue_id: issue_id,
           issue_identifier: identifier,
           workspace: workspace,
           workpad_path: workpad_path,
           comment_id: comment_id,
           pr_number: pr_number,
           repo: repo
         }}
      else
        {:error, message} ->
          {:error, %{message: message, transient?: false}}
      end
    else
      {:error, %{message: "workspace is unavailable for controller finalizer", transient?: false}}
    end
  end

  defp sync_workpad_args(context) do
    %{
      "issue_id" => context.issue_id,
      "file_path" => context.workpad_path,
      "comment_id" => context.comment_id
    }
  end

  defp wait_for_checks_args(context, opts) do
    %{
      "repo" => context.repo,
      "pr_number" => context.pr_number,
      "timeout_ms" => Keyword.get(opts, :wait_timeout_ms, @default_wait_timeout_ms),
      "poll_interval_ms" => Keyword.get(opts, :wait_poll_interval_ms, @default_wait_poll_interval_ms)
    }
  end

  defp handoff_args(context) do
    %{
      "issue_id" => context.issue_id,
      "file_path" => context.workpad_path,
      "repo" => context.repo,
      "pr_number" => context.pr_number
    }
  end

  defp transition_issue_state(issue_id, opts) do
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)

    if non_empty_binary?(issue_id) do
      tracker_module.update_issue_state(issue_id, review_ready_state())
    else
      {:error, :missing_issue_id}
    end
  end

  defp review_ready_state do
    Config.settings!().verification.review_ready_states
    |> Enum.find(@default_review_ready_state, &non_empty_binary?/1)
  end

  defp call_tool(tool, arguments, workspace, opts) do
    executor = Keyword.get(opts, :tool_executor, &DynamicTool.execute/3)
    tool_opts = Keyword.get(opts, :tool_opts, [])
    tool_opts = Keyword.put(tool_opts, :workspace, workspace)
    response = executor.(tool, arguments, tool_opts)

    case decode_tool_response(response) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, payload} ->
        {:error, classify_tool_error(tool, payload)}
    end
  end

  defp decode_tool_response(%{"success" => success} = response) when is_boolean(success) do
    case decode_tool_payload(response) do
      {:ok, payload} ->
        if success, do: {:ok, payload}, else: {:error, payload}

      {:error, reason} ->
        {:error, %{"error" => %{"message" => "invalid dynamic tool response: #{inspect(reason)}"}}}
    end
  end

  defp decode_tool_response(response), do: {:error, %{"error" => %{"message" => "invalid tool response: #{inspect(response)}"}}}

  defp decode_tool_payload(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _payload} -> {:error, :payload_must_be_json_object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_tool_payload(_response), do: {:error, :missing_content_items}

  defp classify_tool_error(tool, payload) do
    message = payload_error_message(payload)

    %{
      message: message,
      transient?:
        case tool do
          "symphony_handoff_check" -> false
          _ -> true
        end,
      tool: tool,
      payload: payload
    }
  end

  defp payload_error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp payload_error_message(payload), do: "dynamic tool failed: #{inspect(payload)}"

  defp normalize_wait_result(payload) do
    pending_checks = if is_list(payload["pending_checks"]), do: payload["pending_checks"], else: []
    failed_checks = if is_list(payload["failed_checks"]), do: payload["failed_checks"], else: []
    checks = if is_list(payload["checks"]), do: payload["checks"], else: []

    %{
      "all_green" => payload["all_green"] == true,
      "pending_checks" => pending_checks,
      "failed_checks" => failed_checks,
      "checks" => checks
    }
  end

  defp normalize_snapshot(payload) do
    %{
      "url" => payload["url"],
      "state" => payload["state"],
      "has_pending_checks" => payload["has_pending_checks"] == true,
      "has_actionable_feedback" => payload["has_actionable_feedback"] == true
    }
  end

  defp extract_manifest(%{"manifest" => manifest}) when is_map(manifest), do: manifest
  defp extract_manifest(payload), do: payload

  defp checkpoint_after_wait(checkpoint, wait_result) do
    Map.put(checkpoint, "pending_checks", wait_result["pending_checks"] != [])
  end

  defp checkpoint_after_snapshot(checkpoint, snapshot) do
    open_pr = normalize_open_pr(checkpoint["open_pr"], snapshot)

    checkpoint
    |> Map.put("open_pr", open_pr)
    |> Map.put("pending_checks", snapshot["has_pending_checks"])
    |> Map.put("open_feedback", snapshot["has_actionable_feedback"])
  end

  defp normalize_open_pr(existing, snapshot) do
    number =
      case existing do
        %{"number" => value} when is_integer(value) and value > 0 -> value
        _ -> extract_pr_number(snapshot["url"])
      end

    %{
      "number" => number,
      "url" => snapshot["url"] || (is_map(existing) && existing["url"]),
      "state" => snapshot["state"] || (is_map(existing) && existing["state"])
    }
  end

  defp checkpoint_status(checkpoint, status, reason, blocked_head) do
    checkpoint
    |> Map.put(
      "controller_finalizer",
      %{
        "status" => status,
        "reason" => reason,
        "blocked_reason" => reason,
        "blocked_pr_number" => checkpoint_pr_number(checkpoint),
        "blocked_head" => blocked_head,
        "checked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }
    )
  end

  defp resolve_workspace_path(identifier) do
    safe_identifier =
      identifier
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")

    Path.join(Config.settings!().workspace.root, safe_identifier) |> Path.expand()
  end

  defp resolve_workpad_paths(workspace) when is_binary(workspace) do
    workpad_path = Path.join(workspace, @workpad_file)
    comment_id_path = Path.join(workspace, @workpad_ref_file)

    with true <- File.exists?(workpad_path) or {:error, "workpad.md is missing for controller finalizer"},
         true <- non_empty_binary?(read_trimmed(comment_id_path)) or {:error, ".workpad-id is missing for controller finalizer"} do
      {:ok, workpad_path, read_trimmed(comment_id_path)}
    else
      {:error, message} -> {:error, message}
    end
  end

  defp resolve_repo(workspace, opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) ->
        trimmed = String.trim(repo)

        if trimmed == "" do
          {:error, "cannot resolve git remote origin url"}
        else
          {:ok, trimmed}
        end

      _ ->
        case System.cmd("git", ["-C", workspace, "config", "--get", "remote.origin.url"], stderr_to_stdout: true) do
          {url, 0} -> parse_remote_repo(url)
          _ -> {:error, "cannot resolve git remote origin url"}
        end
    end
  end

  defp parse_remote_repo(url) when is_binary(url) do
    normalized = String.trim(url)

    case Regex.named_captures(~r/github\.com[:\/](?<owner>[^\/]+)\/(?<repo>[^\/]+?)(?:\.git)?$/, normalized) do
      %{"owner" => owner, "repo" => repo} when owner != "" and repo != "" ->
        {:ok, "#{owner}/#{repo}"}

      _ ->
        {:error, "cannot parse OWNER/REPO from remote url"}
    end
  end

  defp checkpoint_pr_number(checkpoint) when is_map(checkpoint) do
    case checkpoint["open_pr"] do
      %{"number" => number} when is_integer(number) and number > 0 ->
        number

      %{"url" => url} when is_binary(url) ->
        extract_pr_number(url)

      _ ->
        nil
    end
  end

  defp extract_pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url, capture: :all_but_first) do
      [value] ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_pr_number(_url), do: nil

  defp eligible_issue_state?(%Issue{state: state}), do: eligible_issue_state?(state)
  defp eligible_issue_state?(%{} = issue), do: eligible_issue_state?(issue[:state] || issue["state"])

  defp eligible_issue_state?(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> then(&MapSet.member?(@eligible_issue_states, &1))
  end

  defp eligible_issue_state?(_state), do: false

  defp blocked_for_current_head?(checkpoint) when is_map(checkpoint) do
    head = normalize_string(checkpoint["head"])
    current_pr_number = normalize_pr_number(checkpoint_pr_number(checkpoint))

    case checkpoint["controller_finalizer"] do
      %{"status" => "action_required"} = finalizer ->
        blocked_for_matching_head?(finalizer, head, current_pr_number)

      _ ->
        false
    end
  end

  defp blocked_for_matching_head?(finalizer, head, current_pr_number) do
    blocked_head = normalize_string(finalizer["blocked_head"])
    blocked_reason = normalize_string(finalizer["blocked_reason"] || finalizer["reason"])
    blocked_pr_number = normalize_pr_number(finalizer["blocked_pr_number"])

    cond do
      is_binary(head) and is_binary(blocked_head) ->
        head == blocked_head

      is_nil(head) and is_nil(blocked_head) ->
        not is_nil(blocked_reason) and blocked_pr_number == current_pr_number

      true ->
        false
    end
  end

  defp issue_id(%Issue{id: issue_id}) when is_binary(issue_id), do: issue_id

  defp issue_id(%{} = issue) do
    case issue[:id] || issue["id"] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp issue_id(_issue), do: nil

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier

  defp issue_identifier(%{} = issue) do
    case issue[:identifier] || issue["identifier"] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp normalize_checkpoint(%{} = checkpoint), do: checkpoint
  defp normalize_checkpoint(_checkpoint), do: %{}

  defp read_trimmed(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.trim()
        |> normalize_string()

      _ ->
        nil
    end
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil

  defp normalize_pr_number(value) when is_integer(value) and value > 0, do: value

  defp normalize_pr_number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_pr_number(_value), do: nil

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""
end
