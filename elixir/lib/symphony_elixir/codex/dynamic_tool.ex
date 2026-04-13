defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, HandoffCheck, Linear.Client, PathSafety, ValidationGate}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @sync_workpad_tool "sync_workpad"
  @sync_workpad_description "Create or update a workpad comment on a Linear issue. Reads the body from a local file to keep the conversation context small."
  @sync_workpad_create "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success comment { id url } } }"
  @sync_workpad_update "mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success comment { id url } } }"
  @sync_workpad_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "file_path"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier (e.g. \"ENG-123\") or internal UUID."
      },
      "file_path" => %{
        "type" => "string",
        "description" => "Path to a local markdown file whose contents become the comment body."
      },
      "comment_id" => %{
        "type" => "string",
        "description" => "Existing comment ID to update. Omit to create a new comment."
      }
    }
  }

  @linear_upload_issue_attachment_tool "linear_upload_issue_attachment"
  @linear_upload_issue_attachment_description """
  Upload a local file to Linear storage on the server and create a durable issue attachment for review evidence or handoff artifacts.
  """
  @linear_upload_issue_attachment_file_upload """
  mutation($filename: String!, $contentType: String!, $size: Int!) {
    fileUpload(filename: $filename, contentType: $contentType, size: $size) {
      success
      uploadFile {
        uploadUrl
        assetUrl
        headers {
          key
          value
        }
      }
    }
  }
  """
  @linear_upload_issue_attachment_create """
  mutation($input: AttachmentCreateInput!) {
    attachmentCreate(input: $input) {
      success
      attachment {
        id
        title
        subtitle
        url
      }
    }
  }
  """
  @linear_upload_issue_attachment_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "file_path"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier (e.g. \"ENG-123\") or internal UUID."
      },
      "file_path" => %{
        "type" => "string",
        "description" => "Absolute or workspace-relative path to the local file to upload."
      },
      "title" => %{
        "type" => "string",
        "description" => "Attachment title shown in the Linear issue UI. Defaults to the file name."
      },
      "subtitle" => %{
        "type" => "string",
        "description" => "Optional attachment subtitle shown under the title in the Linear issue UI."
      },
      "content_type" => %{
        "type" => "string",
        "description" => "Optional MIME type override for the uploaded file."
      },
      "metadata" => %{
        "type" => ["object", "null"],
        "description" => "Optional attachment metadata recorded via the Linear API.",
        "additionalProperties" => true
      }
    }
  }

  @github_pr_snapshot_tool "github_pr_snapshot"
  @github_pr_snapshot_description """
  Fetch a compact snapshot of a GitHub pull request, including status checks and normalized review feedback counts.
  """
  @github_pr_snapshot_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["repo", "pr_number"],
    "properties" => %{
      "repo" => %{
        "type" => "string",
        "description" => "GitHub repository in OWNER/REPO format."
      },
      "pr_number" => %{
        "type" => ["integer", "string"],
        "description" => "Pull request number."
      },
      "include_feedback_details" => %{
        "type" => "boolean",
        "description" => "When true, include normalized actionable feedback items."
      }
    }
  }

  @github_wait_for_checks_tool "github_wait_for_checks"
  @github_wait_for_checks_description """
  Wait for GitHub pull request checks to finish outside the model loop and return a compact result.
  """
  @github_wait_for_checks_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["repo", "pr_number"],
    "properties" => %{
      "repo" => %{
        "type" => "string",
        "description" => "GitHub repository in OWNER/REPO format."
      },
      "pr_number" => %{
        "type" => ["integer", "string"],
        "description" => "Pull request number."
      },
      "timeout_ms" => %{
        "type" => ["integer", "null"],
        "description" => "Maximum wait time in milliseconds. Defaults to 3600000."
      },
      "poll_interval_ms" => %{
        "type" => ["integer", "null"],
        "description" => "Polling interval in milliseconds. Defaults to 10000."
      }
    }
  }

  @symphony_handoff_check_tool "symphony_handoff_check"
  @symphony_handoff_check_description """
  Run Symphony's fail-closed handoff contract against the current workpad, issue attachments, and pull request state.
  """
  @symphony_handoff_check_issue_query """
  query SymphonyHandoffCheckIssue($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
      state {
        name
      }
      labels {
        nodes {
          name
        }
      }
      attachments(first: 100) {
        nodes {
          title
          url
        }
      }
    }
  }
  """
  @symphony_handoff_check_state_query """
  query SymphonyHandoffCheckState($issueId: String!) {
    issue(id: $issueId) {
      team {
        states(first: 100) {
          nodes {
            id
            name
          }
        }
      }
    }
  }
  """
  @symphony_handoff_check_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "file_path", "repo", "pr_number"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier (e.g. \"ENG-123\") or internal UUID."
      },
      "file_path" => %{
        "type" => "string",
        "description" => "Absolute or workspace-relative path to the local workpad markdown file."
      },
      "repo" => %{
        "type" => "string",
        "description" => "GitHub repository in OWNER/REPO format."
      },
      "pr_number" => %{
        "type" => ["integer", "string"],
        "description" => "Pull request number."
      },
      "profile" => %{
        "type" => ["string", "null"],
        "description" => "Optional explicit verification profile override."
      },
      "manifest_path" => %{
        "type" => ["string", "null"],
        "description" => "Optional workspace-relative path for the verification manifest JSON file."
      }
    }
  }

  @default_github_wait_timeout_ms 3_600_000
  @default_github_wait_poll_interval_ms 10_000
  @success_check_conclusions MapSet.new(["SUCCESS", "SUCCESSFUL", "NEUTRAL", "SKIPPED"])
  @pending_check_statuses MapSet.new(["EXPECTED", "PENDING", "IN_PROGRESS", "QUEUED", "REQUESTED", "WAITING"])
  @failing_check_conclusions MapSet.new(["ACTION_REQUIRED", "CANCELLED", "ERROR", "FAILURE", "FAILED", "STALE", "STARTUP_FAILURE", "TIMED_OUT"])
  @non_actionable_pr_comment_authors MapSet.new(["github-actions", "linear"])

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @sync_workpad_tool ->
        execute_sync_workpad(arguments, opts)

      @linear_upload_issue_attachment_tool ->
        execute_linear_upload_issue_attachment(arguments, opts)

      @github_pr_snapshot_tool ->
        execute_github_pr_snapshot(arguments, opts)

      @github_wait_for_checks_tool ->
        execute_github_wait_for_checks(arguments, opts)

      @symphony_handoff_check_tool ->
        execute_symphony_handoff_check(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @sync_workpad_tool,
        "description" => @sync_workpad_description,
        "inputSchema" => @sync_workpad_input_schema
      },
      %{
        "name" => @linear_upload_issue_attachment_tool,
        "description" => @linear_upload_issue_attachment_description,
        "inputSchema" => @linear_upload_issue_attachment_input_schema
      },
      %{
        "name" => @github_pr_snapshot_tool,
        "description" => @github_pr_snapshot_description,
        "inputSchema" => @github_pr_snapshot_input_schema
      },
      %{
        "name" => @github_wait_for_checks_tool,
        "description" => @github_wait_for_checks_description,
        "inputSchema" => @github_wait_for_checks_input_schema
      },
      %{
        "name" => @symphony_handoff_check_tool,
        "description" => @symphony_handoff_check_description,
        "inputSchema" => @symphony_handoff_check_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         :ok <- maybe_guard_review_ready_issue_update(query, variables, linear_client, opts),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_sync_workpad(args, opts) do
    with {:ok, issue_id, file_path, comment_id} <- normalize_sync_workpad_args(args),
         {:ok, body} <- read_workpad_file(file_path, :sync_workpad) do
      {query, variables} =
        if comment_id,
          do: {@sync_workpad_update, %{"id" => comment_id, "body" => body}},
          else: {@sync_workpad_create, %{"issueId" => issue_id, "body" => body}}

      execute_linear_graphql(%{"query" => query, "variables" => variables}, opts)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_upload_issue_attachment(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    upload_request_fun = Keyword.get(opts, :upload_request_fun, &default_linear_upload_request/4)

    with {:ok, upload} <- normalize_linear_upload_issue_attachment_arguments(arguments, opts),
         {:ok, body} <- read_upload_file(upload.file_path),
         {:ok, upload_target} <-
           request_linear_upload_target(upload.file_path, upload.content_type, byte_size(body), linear_client),
         {:ok, _response} <-
           upload_request_fun.(
             upload_target.upload_url,
             build_linear_upload_headers(upload_target.headers, upload.content_type),
             body,
             []
           ),
         {:ok, attachment} <-
           create_linear_issue_attachment(upload, upload_target.asset_url, linear_client) do
      success_response(%{
        "artifact" => %{
          "issue_id" => upload.issue_id,
          "file_name" => Path.basename(upload.file_path),
          "file_path" => upload.file_path,
          "content_type" => upload.content_type,
          "size_bytes" => byte_size(body)
        },
        "attachment" => attachment
      })
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_github_pr_snapshot(arguments, opts) do
    with {:ok, repo, pr_number, include_feedback_details} <-
           normalize_github_pr_snapshot_arguments(arguments),
         {:ok, snapshot} <- build_github_pr_snapshot(repo, pr_number, include_feedback_details, opts) do
      success_response(snapshot)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_github_wait_for_checks(arguments, opts) do
    with {:ok, repo, pr_number, timeout_ms, poll_interval_ms} <-
           normalize_github_wait_for_checks_arguments(arguments),
         {:ok, result} <- wait_for_github_checks(repo, pr_number, timeout_ms, poll_interval_ms, opts) do
      success_response(result)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_symphony_handoff_check(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, issue_id, workpad_path, repo, pr_number, profile, manifest_path} <-
           normalize_symphony_handoff_check_arguments(arguments, opts),
         {:ok, workpad_body} <- read_workpad_file(workpad_path, :symphony_handoff_check),
         {:ok, issue_context} <- fetch_handoff_issue_context(issue_id, linear_client),
         {:ok, pr_snapshot} <- build_github_pr_snapshot(repo, pr_number, true, opts) do
      validation_context = build_handoff_validation_context(opts)

      result =
        HandoffCheck.evaluate(
          workpad_body,
          issue_id: issue_id,
          issue_identifier: Map.get(issue_context, "identifier"),
          workpad_path: workpad_path,
          repo: repo,
          pr_number: pr_number,
          profile: profile || Config.settings!().verification.profile,
          labels: Map.get(issue_context, "labels", []),
          attachments: Map.get(issue_context, "attachments", []),
          pr_snapshot: pr_snapshot,
          profile_labels: Config.settings!().verification.profile_labels,
          change_classes: validation_context.change_classes,
          git: validation_context.git,
          validation_gate_errors: validation_context.errors
        )

      handoff_check_response(result, manifest_path)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp handoff_check_response({:ok, manifest}, manifest_path) do
    manifest = prepare_handoff_manifest(manifest, manifest_path)

    case persist_handoff_manifest(manifest, manifest_path) do
      {:ok, persisted_manifest} ->
        success_response(persisted_manifest)

      {:error, reason} ->
        failure_response(%{
          "error" => %{
            "message" => "symphony_handoff_check: failed to write verification manifest.",
            "reason" => inspect(reason)
          },
          "manifest" => manifest
        })
    end
  end

  defp handoff_check_response({:error, manifest}, manifest_path) do
    manifest = prepare_handoff_manifest(manifest, manifest_path)

    case persist_handoff_manifest(manifest, manifest_path) do
      {:ok, persisted_manifest} ->
        failure_response(%{
          "error" => %{
            "message" => "symphony_handoff_check: verification contract failed.",
            "summary" => manifest["summary"],
            "missing_items" => manifest["missing_items"],
            "manifest_path" => persisted_manifest["manifest_path"]
          },
          "manifest" => persisted_manifest
        })

      {:error, reason} ->
        failure_response(%{
          "error" => %{
            "message" => "symphony_handoff_check: verification contract failed and the manifest could not be written.",
            "reason" => inspect(reason)
          },
          "manifest" => manifest
        })
    end
  end

  defp prepare_handoff_manifest(manifest, manifest_path) do
    manifest
    |> Map.put("manifest_path", manifest_path)
    |> Map.put("target_state", nil)
  end

  defp persist_handoff_manifest(manifest, manifest_path) do
    case HandoffCheck.write_manifest(manifest, manifest_path) do
      {:ok, persisted_path} -> {:ok, Map.put(manifest, "manifest_path", persisted_path)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_handoff_validation_context(opts) do
    workspace = Keyword.get(opts, :workspace) || File.cwd!()

    {git_metadata, git_errors} = build_current_git_metadata(workspace, opts)
    {changed_paths, path_errors} = build_changed_paths(workspace, opts)

    {change_classes, class_errors} =
      case ValidationGate.classify_paths(changed_paths) do
        {:ok, classes} -> {classes, []}
        {:error, reasons} -> {[], reasons}
      end

    %{
      git: Map.put(git_metadata, "changed_paths", changed_paths),
      change_classes: change_classes,
      errors: Enum.uniq(git_errors ++ path_errors ++ class_errors)
    }
  end

  defp build_current_git_metadata(workspace, opts) do
    runner = Keyword.get(opts, :git_runner, &default_git_runner/2)

    with {:ok, head_sha} <- run_git(runner, workspace, ["rev-parse", "HEAD"]),
         {:ok, tree_sha} <- run_git(runner, workspace, ["rev-parse", "HEAD^{tree}"]),
         {:ok, status} <- run_git(runner, workspace, ["status", "--porcelain", "--untracked-files=no"]) do
      {
        %{
          "head_sha" => String.trim(head_sha),
          "tree_sha" => String.trim(tree_sha),
          "worktree_clean" => String.trim(status) == ""
        },
        []
      }
    else
      {:error, reason} ->
        {%{}, ["validation gate git metadata unavailable: #{inspect(reason)}"]}
    end
  end

  defp build_changed_paths(workspace, opts) do
    runner = Keyword.get(opts, :git_runner, &default_git_runner/2)
    base_branch = base_branch(workspace)

    case run_git(runner, workspace, ["diff", "--name-only", "origin/#{base_branch}...HEAD"]) do
      {:ok, output} ->
        paths = split_git_lines(output)
        {paths, if(paths == [], do: ["validation gate changed_paths is empty"], else: [])}

      {:error, reason} ->
        {[], ["validation gate changed_paths unavailable: #{inspect(reason)}"]}
    end
  end

  defp base_branch(workspace) do
    case File.read(Path.join(workspace, ".symphony-base-branch")) do
      {:ok, body} ->
        body
        |> String.trim()
        |> case do
          "" -> "main"
          branch -> branch
        end

      _ ->
        "main"
    end
  end

  defp split_git_lines(output) when is_binary(output) do
    output
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp run_git(runner, workspace, args) when is_function(runner, 2) do
    runner.(args, workspace: workspace)
  end

  defp default_git_runner(args, opts) do
    workspace = Keyword.get(opts, :workspace)

    cmd_opts =
      [stderr_to_stdout: true]
      |> maybe_put_cd(workspace)

    try do
      case System.cmd("git", args, cmd_opts) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, {:git_status, status, String.trim(output)}}
      end
    rescue
      error in ErlangError ->
        {:error, {:git_unavailable, error.original}}
    end
  end

  defp normalize_sync_workpad_args(%{} = args) do
    with {:ok, issue_id} <- required_sync_workpad_arg(args, "issue_id"),
         {:ok, file_path} <- required_sync_workpad_arg(args, "file_path") do
      {:ok, issue_id, file_path, optional_sync_workpad_comment_id(args)}
    end
  end

  defp normalize_sync_workpad_args(_args) do
    {:error, {:sync_workpad, "`issue_id` and `file_path` are required"}}
  end

  defp normalize_linear_upload_issue_attachment_arguments(arguments, opts) when is_map(arguments) do
    workspace = Keyword.get(opts, :workspace)

    with {:ok, issue_id} <- required_upload_attachment_arg(arguments, "issue_id"),
         {:ok, file_path} <- required_upload_attachment_arg(arguments, "file_path"),
         {:ok, resolved_path} <- normalize_upload_attachment_file_path(file_path, workspace),
         {:ok, title} <- normalize_upload_attachment_title(arguments, resolved_path),
         {:ok, subtitle} <-
           normalize_optional_string_arg(
             arguments,
             "subtitle",
             :linear_upload_issue_attachment
           ),
         {:ok, content_type} <- normalize_upload_attachment_content_type(arguments, resolved_path),
         {:ok, metadata} <- normalize_optional_metadata_arg(arguments) do
      {:ok,
       %{
         issue_id: issue_id,
         file_path: resolved_path,
         title: title,
         subtitle: subtitle,
         content_type: content_type,
         metadata: metadata
       }}
    end
  end

  defp normalize_linear_upload_issue_attachment_arguments(_arguments, _opts) do
    {:error, {:linear_upload_issue_attachment, "`issue_id` and `file_path` are required"}}
  end

  defp required_sync_workpad_arg(args, key) when is_map(args) and is_binary(key) do
    atom_key = String.to_atom(key)

    case Map.get(args, key) || Map.get(args, atom_key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:sync_workpad, "`#{key}` is required"}}
    end
  end

  defp required_upload_attachment_arg(args, key) when is_map(args) and is_binary(key) do
    case get_argument(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:linear_upload_issue_attachment, "`#{key}` is required"}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:linear_upload_issue_attachment, "`#{key}` is required"}}
    end
  end

  defp required_handoff_check_arg(args, key) when is_map(args) and is_binary(key) do
    case get_argument(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:symphony_handoff_check, "`#{key}` is required"}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:symphony_handoff_check, "`#{key}` is required"}}
    end
  end

  defp optional_sync_workpad_comment_id(args) when is_map(args) do
    case Map.get(args, "comment_id") || Map.get(args, :comment_id) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp normalize_github_pr_snapshot_arguments(arguments) when is_map(arguments) do
    with {:ok, repo} <- normalize_repo(arguments, :github_pr_snapshot),
         {:ok, pr_number} <- normalize_pr_number(arguments, :github_pr_snapshot),
         {:ok, include_feedback_details} <-
           normalize_boolean(arguments, "include_feedback_details", false, :github_pr_snapshot) do
      {:ok, repo, pr_number, include_feedback_details}
    end
  end

  defp normalize_github_pr_snapshot_arguments(_arguments) do
    {:error, {:github_pr_snapshot, "`repo` and `pr_number` are required"}}
  end

  defp normalize_github_wait_for_checks_arguments(arguments) when is_map(arguments) do
    with {:ok, repo} <- normalize_repo(arguments, :github_wait_for_checks),
         {:ok, pr_number} <- normalize_pr_number(arguments, :github_wait_for_checks),
         {:ok, timeout_ms} <-
           normalize_positive_integer(
             arguments,
             "timeout_ms",
             @default_github_wait_timeout_ms,
             :github_wait_for_checks
           ),
         {:ok, poll_interval_ms} <-
           normalize_positive_integer(
             arguments,
             "poll_interval_ms",
             @default_github_wait_poll_interval_ms,
             :github_wait_for_checks
           ) do
      {:ok, repo, pr_number, timeout_ms, poll_interval_ms}
    end
  end

  defp normalize_github_wait_for_checks_arguments(_arguments) do
    {:error, {:github_wait_for_checks, "`repo` and `pr_number` are required"}}
  end

  defp normalize_symphony_handoff_check_arguments(arguments, opts) when is_map(arguments) do
    workspace = Keyword.get(opts, :workspace)
    verification = Config.settings!().verification

    with {:ok, issue_id} <- required_handoff_check_arg(arguments, "issue_id"),
         {:ok, file_path} <- required_handoff_check_arg(arguments, "file_path"),
         {:ok, repo} <- normalize_repo(arguments, :symphony_handoff_check),
         {:ok, pr_number} <- normalize_pr_number(arguments, :symphony_handoff_check),
         {:ok, resolved_workpad_path} <-
           normalize_workspace_file_path(file_path, workspace, :symphony_handoff_check),
         {:ok, profile} <-
           normalize_optional_string_arg(arguments, "profile", :symphony_handoff_check),
         {:ok, manifest_path} <-
           normalize_workspace_manifest_path(
             get_argument(arguments, "manifest_path") || verification.manifest_path,
             workspace,
             :symphony_handoff_check
           ) do
      {:ok, issue_id, resolved_workpad_path, repo, pr_number, profile, manifest_path}
    end
  end

  defp normalize_symphony_handoff_check_arguments(_arguments, _opts) do
    {:error, {:symphony_handoff_check, "`issue_id`, `file_path`, `repo`, and `pr_number` are required"}}
  end

  defp normalize_repo(arguments, tool) do
    repo = get_argument(arguments, "repo")

    cond do
      not is_binary(repo) or String.trim(repo) == "" ->
        {:error, {tool, "`repo` must be a non-empty OWNER/REPO string"}}

      match?([_, _], String.split(String.trim(repo), "/", parts: 2)) ->
        {:ok, String.trim(repo)}

      true ->
        {:error, {tool, "`repo` must be in OWNER/REPO format"}}
    end
  end

  defp normalize_pr_number(arguments, tool) do
    case get_argument(arguments, "pr_number") do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, {tool, "`pr_number` must be a positive integer"}}
        end

      _ ->
        {:error, {tool, "`pr_number` must be a positive integer"}}
    end
  end

  defp normalize_boolean(arguments, key, default, tool) do
    case get_argument(arguments, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {tool, "`#{key}` must be a boolean when provided"}}
    end
  end

  defp normalize_positive_integer(arguments, key, default, tool) do
    case get_argument(arguments, key) do
      nil ->
        {:ok, default}

      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, {tool, "`#{key}` must be a positive integer when provided"}}
        end

      _ ->
        {:error, {tool, "`#{key}` must be a positive integer when provided"}}
    end
  end

  defp get_argument(arguments, key) when is_map(arguments) and is_binary(key) do
    Map.get(arguments, key) || Map.get(arguments, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(arguments, key)
  end

  defp read_workpad_file(path, tool) do
    case File.read(path) do
      {:ok, ""} -> {:error, {tool, "file is empty: `#{path}`"}}
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {tool, "cannot read `#{path}`: #{:file.format_error(reason)}"}}
    end
  end

  defp read_upload_file(path) do
    case File.read(path) do
      {:ok, ""} ->
        {:error, {:linear_upload_issue_attachment, "file is empty: `#{path}`"}}

      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error, {:linear_upload_issue_attachment, "cannot read `#{path}`: #{:file.format_error(reason)}"}}
    end
  end

  defp normalize_upload_attachment_file_path(path, workspace) when is_binary(path) do
    trimmed_path = String.trim(path)
    candidate_path = expand_upload_path(trimmed_path, workspace)

    with {:ok, canonical_path} <- PathSafety.canonicalize(candidate_path),
         :ok <- ensure_upload_path_within_workspace(canonical_path, workspace) do
      {:ok, canonical_path}
    else
      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {:linear_upload_issue_attachment, "cannot resolve `#{trimmed_path}`: #{inspect(reason)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_workspace_file_path(path, workspace, tool) when is_binary(path) do
    trimmed_path = String.trim(path)
    candidate_path = expand_upload_path(trimmed_path, workspace)

    with {:ok, canonical_path} <- PathSafety.canonicalize(candidate_path),
         :ok <- ensure_workspace_path_within_workspace(canonical_path, workspace, tool, "file_path") do
      {:ok, canonical_path}
    else
      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {tool, "cannot resolve `#{trimmed_path}`: #{inspect(reason)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_workspace_manifest_path(path, workspace, tool) when is_binary(path) do
    trimmed_path = String.trim(path)
    candidate_path = expand_upload_path(trimmed_path, workspace)
    manifest_dir = Path.dirname(candidate_path)

    with {:ok, canonical_dir} <- PathSafety.canonicalize(manifest_dir),
         :ok <- ensure_workspace_path_within_workspace(canonical_dir, workspace, tool, "manifest_path") do
      {:ok, Path.join(canonical_dir, Path.basename(candidate_path))}
    else
      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {tool, "cannot resolve manifest path `#{trimmed_path}`: #{inspect(reason)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expand_upload_path(path, workspace) when is_binary(path) and is_binary(workspace) do
    if Path.type(path) == :relative do
      Path.expand(path, workspace)
    else
      path
    end
  end

  defp expand_upload_path(path, _workspace), do: path

  defp ensure_upload_path_within_workspace(_path, nil), do: :ok

  defp ensure_upload_path_within_workspace(path, workspace) when is_binary(path) and is_binary(workspace) do
    case PathSafety.canonicalize(workspace) do
      {:ok, canonical_workspace} ->
        workspace_prefix = canonical_workspace <> "/"

        if path == canonical_workspace or String.starts_with?(path, workspace_prefix) do
          :ok
        else
          {:error, {:linear_upload_issue_attachment, "file_path must stay within workspace `#{canonical_workspace}`"}}
        end

      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {:linear_upload_issue_attachment, "cannot resolve workspace `#{workspace}`: #{inspect(reason)}"}}
    end
  end

  defp ensure_workspace_path_within_workspace(_path, nil, _tool, _field), do: :ok

  defp ensure_workspace_path_within_workspace(path, workspace, tool, field)
       when is_binary(path) and is_binary(workspace) do
    case PathSafety.canonicalize(workspace) do
      {:ok, canonical_workspace} ->
        workspace_prefix = canonical_workspace <> "/"

        if path == canonical_workspace or String.starts_with?(path, workspace_prefix) do
          :ok
        else
          {:error, {tool, "`#{field}` must stay within workspace `#{canonical_workspace}`"}}
        end

      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {tool, "cannot resolve workspace `#{workspace}`: #{inspect(reason)}"}}
    end
  end

  defp normalize_upload_attachment_title(arguments, resolved_path) do
    case normalize_optional_string_arg(arguments, "title", :linear_upload_issue_attachment) do
      {:ok, nil} -> {:ok, Path.basename(resolved_path)}
      {:ok, title} -> {:ok, title}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_upload_attachment_content_type(arguments, resolved_path) do
    case normalize_optional_string_arg(arguments, "content_type", :linear_upload_issue_attachment) do
      {:ok, nil} ->
        {:ok, MIME.from_path(resolved_path)}

      {:ok, content_type} ->
        {:ok, content_type}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_optional_string_arg(arguments, key, tool) do
    case get_argument(arguments, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        {:ok, blank_to_nil(value)}

      _ ->
        {:error, {tool, "`#{key}` must be a string when provided"}}
    end
  end

  defp normalize_optional_metadata_arg(arguments) do
    case get_argument(arguments, "metadata") do
      nil -> {:ok, nil}
      metadata when is_map(metadata) -> {:ok, metadata}
      _ -> {:error, {:linear_upload_issue_attachment, "`metadata` must be an object when provided"}}
    end
  end

  defp request_linear_upload_target(file_path, content_type, size, linear_client) do
    with {:ok, response} <-
           linear_client.(
             @linear_upload_issue_attachment_file_upload,
             %{
               "filename" => Path.basename(file_path),
               "contentType" => content_type,
               "size" => size
             },
             []
           ),
         {:ok, upload_root} <- fetch_graphql_data_root(response, "fileUpload"),
         true <- get_argument(upload_root, "success") == true,
         upload_file when is_map(upload_file) <- get_argument(upload_root, "uploadFile"),
         upload_url when is_binary(upload_url) and upload_url != "" <-
           get_argument(upload_file, "uploadUrl"),
         asset_url when is_binary(asset_url) and asset_url != "" <-
           get_argument(upload_file, "assetUrl"),
         {:ok, headers} <- normalize_linear_upload_header_items(get_argument(upload_file, "headers")) do
      {:ok, %{upload_url: upload_url, asset_url: asset_url, headers: headers}}
    else
      false ->
        {:error, {:linear_upload_issue_attachment, "fileUpload did not return a successful upload target"}}

      nil ->
        {:error, {:linear_upload_issue_attachment, "fileUpload response is missing upload details"}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, {:linear_upload_issue_attachment, "fileUpload response is missing upload details"}}
    end
  end

  defp fetch_graphql_data_root(response, root_key) when is_binary(root_key) do
    case get_argument(response, "data") do
      data when is_map(data) ->
        case get_argument(data, root_key) do
          root when is_map(root) -> {:ok, root}
          _ -> {:error, {:linear_upload_issue_attachment, "GraphQL response is missing `data.#{root_key}`"}}
        end

      _ ->
        {:error, {:linear_upload_issue_attachment, "GraphQL response is missing `data`"}}
    end
  end

  defp normalize_linear_upload_header_items(nil), do: {:ok, []}

  defp normalize_linear_upload_header_items(headers) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn header, {:ok, acc} ->
      case normalize_linear_upload_header_item(header) do
        {:ok, header_pair} -> {:cont, {:ok, [header_pair | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, header_pairs} -> {:ok, Enum.reverse(header_pairs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_linear_upload_header_items(_headers) do
    {:error, {:linear_upload_issue_attachment, "fileUpload headers must be a list"}}
  end

  defp normalize_linear_upload_header_item(header) when is_map(header) do
    key = get_argument(header, "key")
    value = get_argument(header, "value")

    if is_binary(key) and key != "" and is_binary(value) do
      {:ok, {String.downcase(key), value}}
    else
      {:error, {:linear_upload_issue_attachment, "fileUpload returned an invalid header entry"}}
    end
  end

  defp normalize_linear_upload_header_item(_header) do
    {:error, {:linear_upload_issue_attachment, "fileUpload returned an invalid header entry"}}
  end

  defp build_linear_upload_headers(headers, content_type) when is_list(headers) do
    headers
    |> Enum.reduce(
      %{
        "content-type" => content_type,
        "cache-control" => "public, max-age=31536000"
      },
      fn {key, value}, acc ->
        Map.put(acc, String.downcase(key), value)
      end
    )
    |> Enum.map(fn {key, value} -> {key, value} end)
  end

  defp default_linear_upload_request(url, headers, body, _opts) do
    case Req.put(url,
           headers: headers,
           body: body,
           connect_options: [timeout: 30_000],
           receive_timeout: 120_000
         ) do
      {:ok, %{status: status} = response} when status >= 200 and status < 300 ->
        {:ok, response}

      {:ok, %{status: status}} ->
        {:error, {:linear_upload_issue_attachment_http_status, status}}

      {:error, reason} ->
        {:error, {:linear_upload_issue_attachment_request, reason}}
    end
  end

  defp create_linear_issue_attachment(upload, asset_url, linear_client) do
    with {:ok, response} <-
           linear_client.(
             @linear_upload_issue_attachment_create,
             %{"input" => linear_attachment_create_input(upload, asset_url)},
             []
           ),
         {:ok, attachment_root} <- fetch_graphql_data_root(response, "attachmentCreate"),
         true <- get_argument(attachment_root, "success") == true,
         attachment when is_map(attachment) <- get_argument(attachment_root, "attachment") do
      {:ok,
       %{
         "id" => get_argument(attachment, "id"),
         "title" => get_argument(attachment, "title"),
         "subtitle" => get_argument(attachment, "subtitle"),
         "url" => get_argument(attachment, "url")
       }}
    else
      false ->
        {:error, {:linear_upload_issue_attachment, "attachmentCreate did not return a successful attachment"}}

      nil ->
        {:error, {:linear_upload_issue_attachment, "attachmentCreate response is missing attachment data"}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, {:linear_upload_issue_attachment, "attachmentCreate response is missing attachment data"}}
    end
  end

  defp linear_attachment_create_input(upload, asset_url) do
    %{
      "issueId" => upload.issue_id,
      "title" => upload.title,
      "url" => asset_url
    }
    |> maybe_put_graphql_input("subtitle", upload.subtitle)
    |> maybe_put_graphql_input("metadata", upload.metadata)
  end

  defp maybe_put_graphql_input(input, _key, nil), do: input
  defp maybe_put_graphql_input(input, key, value), do: Map.put(input, key, value)

  defp fetch_handoff_issue_context(issue_id, linear_client) do
    with {:ok, response} <- linear_client.(@symphony_handoff_check_issue_query, %{"issueId" => issue_id}, []),
         issue when is_map(issue) <- get_in(response, ["data", "issue"]) do
      {:ok,
       %{
         "id" => get_argument(issue, "id"),
         "identifier" => get_argument(issue, "identifier"),
         "state" => get_in(issue, ["state", "name"]),
         "labels" => normalize_linear_issue_labels(get_in(issue, ["labels", "nodes"])),
         "attachments" => normalize_linear_issue_attachments(get_in(issue, ["attachments", "nodes"]))
       }}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, {:symphony_handoff_check, "issue query did not return a valid issue payload"}}
    end
  end

  defp normalize_linear_issue_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} -> name
      %{name: name} -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_linear_issue_labels(_labels), do: []

  defp normalize_linear_issue_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(fn
      %{} = attachment ->
        %{
          "title" => get_argument(attachment, "title"),
          "url" => get_argument(attachment, "url")
        }

      _ ->
        %{}
    end)
    |> Enum.filter(fn attachment -> is_binary(attachment["title"]) and attachment["title"] != "" end)
  end

  defp normalize_linear_issue_attachments(_attachments), do: []

  defp maybe_guard_review_ready_issue_update(query, variables, linear_client, opts) do
    review_ready_states = Config.settings!().verification.review_ready_states

    with true <- review_ready_issue_update_query?(query),
         state_id when is_binary(state_id) <- review_ready_state_id(query, variables),
         issue_id when is_binary(issue_id) <- review_ready_issue_id(query, variables),
         {:ok, state_name} <- resolve_issue_state_name(issue_id, state_id, linear_client),
         true <- state_name in review_ready_states do
      manifest_path = Config.settings!().verification.manifest_path
      workspace = Keyword.get(opts, :workspace)
      expected_manifest_path = expand_upload_path(manifest_path, workspace)

      case HandoffCheck.review_ready_transition_allowed?(
             expected_manifest_path,
             issue_id,
             state_name,
             nil,
             repo_path: workspace,
             git_runner: Keyword.get(opts, :git_runner)
           ) do
        :ok ->
          :ok

        {:error, reason, details} ->
          {:error,
           {:review_ready_transition_blocked,
            Map.merge(details, %{
              "reason_code" => to_string(reason),
              "required_tool" => @symphony_handoff_check_tool,
              "manifest_path" => Path.expand(expected_manifest_path)
            })}}
      end
    else
      false -> :ok
      nil -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp review_ready_issue_update_query?(query) when is_binary(query) do
    Regex.match?(~r/\bissueUpdate\s*\(/, query)
  end

  defp review_ready_state_id(query, variables) do
    possible_graphql_value(query, variables, [
      ["stateId"],
      ["state_id"],
      ["input", "stateId"],
      ["input", "state_id"]
    ])
  end

  defp review_ready_issue_id(query, variables) do
    possible_graphql_value(query, variables, [
      ["id"],
      ["issueId"],
      ["issue_id"],
      ["input", "id"],
      ["input", "issueId"],
      ["input", "issue_id"]
    ])
  end

  defp possible_graphql_value(query, variables, key_paths)
       when is_binary(query) and is_map(variables) and is_list(key_paths) do
    key_paths
    |> Enum.find_value(&possible_graphql_value_at_path(variables, &1))
    |> case do
      nil -> possible_graphql_literal(query, key_paths)
      value -> value
    end
  end

  defp possible_graphql_value(query, _variables, key_paths)
       when is_binary(query) and is_list(key_paths) do
    possible_graphql_literal(query, key_paths)
  end

  defp possible_graphql_value(_query, _variables, _key_paths), do: nil

  defp possible_graphql_value_at_path(variables, key_path) when is_map(variables) and is_list(key_path) do
    value =
      Enum.reduce_while(key_path, variables, fn key, current ->
        case graphql_map_get(current, key) do
          nil -> {:halt, nil}
          nested -> {:cont, nested}
        end
      end)

    if is_binary(value) and String.trim(value) != "" do
      String.trim(value)
    end
  end

  defp possible_graphql_literal(query, key_paths) do
    key_paths
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
    |> Enum.find_value(fn key ->
      pattern = ~r/\bissueUpdate\s*\([^)]*\b#{Regex.escape(key)}\s*:\s*"([^"]+)"/s

      case Regex.run(pattern, query, capture: :all_but_first) do
        [value] when is_binary(value) and value != "" -> String.trim(value)
        _ -> nil
      end
    end)
  end

  defp graphql_map_get(%{} = map, key) when is_binary(key) do
    map[key] || existing_atom_map_get(map, key)
  end

  defp graphql_map_get(_value, _key), do: nil

  defp existing_atom_map_get(map, key) when is_map(map) and is_binary(key) do
    Enum.find_value(map, fn
      {map_key, value} when is_atom(map_key) ->
        case Atom.to_string(map_key) do
          ^key -> value
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp resolve_issue_state_name(issue_id, state_id, linear_client) do
    with {:ok, response} <- linear_client.(@symphony_handoff_check_state_query, %{"issueId" => issue_id}, []),
         states when is_list(states) <- get_in(response, ["data", "issue", "team", "states", "nodes"]),
         state when is_map(state) <-
           Enum.find(states, fn state ->
             get_argument(state, "id") == state_id
           end),
         state_name when is_binary(state_name) <- get_argument(state, "name") do
      {:ok, state_name}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, {:review_ready_transition_blocked, %{"reason" => "cannot resolve the requested review-ready state"}}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp success_response(payload) do
    %{
      "success" => true,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp build_github_pr_snapshot(repo, pr_number, include_feedback_details, opts) do
    with {:ok, core} <- fetch_github_pr_core(repo, pr_number, opts),
         {:ok, top_level_comments} <- fetch_github_pr_issue_comments(repo, pr_number, opts),
         {:ok, reviews} <- fetch_github_pr_reviews(repo, pr_number, opts),
         {:ok, inline_comments} <- fetch_github_pr_inline_comments(repo, pr_number, opts) do
      checks = normalize_checks(Map.get(core, "statusCheckRollup") || [])
      top_level_feedback = normalize_top_level_feedback(top_level_comments)
      review_feedback = normalize_review_feedback(reviews)
      inline_feedback = normalize_inline_feedback(inline_comments)
      actionable_feedback = top_level_feedback ++ review_feedback ++ inline_feedback

      snapshot =
        %{
          "state" => Map.get(core, "state"),
          "url" => Map.get(core, "url"),
          "labels" => normalize_labels(Map.get(core, "labels") || []),
          "review_decision" => blank_to_nil(Map.get(core, "reviewDecision")),
          "merge_state_status" => blank_to_nil(Map.get(core, "mergeStateStatus")),
          "checks" => checks,
          "all_checks_green" => Enum.all?(checks, &check_green?/1),
          "has_pending_checks" => Enum.any?(checks, &check_pending?/1),
          "review_count" => length(review_feedback),
          "top_level_comment_count" => length(top_level_feedback),
          "inline_comment_count" => length(inline_feedback),
          "has_actionable_feedback" => actionable_feedback != []
        }
        |> maybe_put_actionable_feedback(include_feedback_details, actionable_feedback)

      {:ok, snapshot}
    end
  end

  defp wait_for_github_checks(repo, pr_number, timeout_ms, poll_interval_ms, opts) do
    started_at_ms = monotonic_time_ms(opts)
    do_wait_for_github_checks(repo, pr_number, timeout_ms, poll_interval_ms, started_at_ms, opts)
  end

  defp do_wait_for_github_checks(repo, pr_number, timeout_ms, poll_interval_ms, started_at_ms, opts) do
    with {:ok, core} <- fetch_github_pr_core(repo, pr_number, opts) do
      checks = normalize_checks(Map.get(core, "statusCheckRollup") || [])
      pending_checks = Enum.filter(checks, &check_pending?/1)
      failed_checks = Enum.filter(checks, &check_failed?/1)
      duration_ms = monotonic_time_ms(opts) - started_at_ms

      cond do
        pending_checks == [] ->
          {:ok,
           %{
             "all_green" => failed_checks == [],
             "failed_checks" => failed_checks,
             "pending_checks" => pending_checks,
             "checks" => checks,
             "duration_ms" => duration_ms
           }}

        duration_ms >= timeout_ms ->
          {:error,
           {:github_wait_for_checks_timeout,
            %{
              "timeout_ms" => timeout_ms,
              "duration_ms" => duration_ms,
              "failed_checks" => failed_checks,
              "pending_checks" => pending_checks
            }}}

        true ->
          sleep_ms(opts, poll_interval_ms)
          do_wait_for_github_checks(repo, pr_number, timeout_ms, poll_interval_ms, started_at_ms, opts)
      end
    end
  end

  defp fetch_github_pr_core(repo, pr_number, opts) do
    gh_json(
      ["pr", "view", Integer.to_string(pr_number), "-R", repo, "--json", "state,url,labels,reviewDecision,mergeStateStatus,statusCheckRollup"],
      opts
    )
  end

  defp fetch_github_pr_issue_comments(repo, pr_number, opts) do
    with {:ok, owner, name} <- split_repo(repo) do
      gh_json(["api", "repos/#{owner}/#{name}/issues/#{pr_number}/comments?per_page=100"], opts)
    end
  end

  defp fetch_github_pr_reviews(repo, pr_number, opts) do
    with {:ok, owner, name} <- split_repo(repo) do
      gh_json(["api", "repos/#{owner}/#{name}/pulls/#{pr_number}/reviews?per_page=100"], opts)
    end
  end

  defp fetch_github_pr_inline_comments(repo, pr_number, opts) do
    with {:ok, owner, name} <- split_repo(repo) do
      gh_json(["api", "repos/#{owner}/#{name}/pulls/#{pr_number}/comments?per_page=100"], opts)
    end
  end

  defp gh_json(args, opts) do
    with {:ok, output} <- run_gh(args, opts),
         {:ok, decoded} <- Jason.decode(output) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:github_cli_invalid_json, error.data}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_gh(args, opts) do
    runner = Keyword.get(opts, :gh_runner, &default_gh_runner/2)
    runner.(args, workspace: Keyword.get(opts, :workspace))
  end

  defp default_gh_runner(args, opts) do
    workspace = Keyword.get(opts, :workspace)

    cmd_opts =
      [stderr_to_stdout: true]
      |> maybe_put_cd(workspace)

    try do
      case System.cmd("gh", args, cmd_opts) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, {:github_cli_status, status, String.trim(output)}}
      end
    rescue
      error in ErlangError ->
        {:error, {:github_cli_unavailable, error.original}}
    end
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, workspace), do: Keyword.put(opts, :cd, workspace)

  defp split_repo(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" -> {:ok, owner, name}
      _ -> {:error, {:github_pr_snapshot, "`repo` must be in OWNER/REPO format"}}
    end
  end

  defp normalize_labels(labels) do
    Enum.map(labels, fn
      %{"name" => name} -> name
      %{name: name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_checks(checks) when is_list(checks) do
    Enum.map(checks, fn check ->
      %{
        "name" => pick_first(check, ["name", "context"]) || "unknown",
        "status" => normalize_check_status(pick_first(check, ["status"])),
        "conclusion" => normalize_check_status(pick_first(check, ["conclusion", "state"])),
        "workflow_name" => pick_first(check, ["workflowName"]),
        "details_url" => pick_first(check, ["detailsUrl", "targetUrl"])
      }
    end)
  end

  defp normalize_checks(_checks), do: []

  defp normalize_top_level_feedback(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_top_level_feedback_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_top_level_feedback(_comments), do: []

  defp normalize_top_level_feedback_item(comment) do
    author_login = extract_author_login(comment)
    author_association = pick_first(comment, ["authorAssociation"])
    body = normalize_feedback_body(pick_first(comment, ["body"]))

    cond do
      body == nil ->
        nil

      author_login in @non_actionable_pr_comment_authors ->
        nil

      true ->
        %{
          "channel" => "top_level_comment",
          "author" => author_login || author_association,
          "body" => body,
          "url" => pick_first(comment, ["url"]),
          "created_at" => pick_first(comment, ["createdAt", "submitted_at"])
        }
    end
  end

  defp normalize_review_feedback(reviews) when is_list(reviews) do
    reviews
    |> Enum.map(&normalize_review_feedback_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_review_feedback(_reviews), do: []

  defp normalize_review_feedback_item(review) do
    state = normalize_check_status(pick_first(review, ["state"]))
    body = normalize_feedback_body(pick_first(review, ["body"]))

    cond do
      state == "APPROVED" and body == nil ->
        nil

      state in ["COMMENTED", "CHANGES_REQUESTED"] or body != nil ->
        %{
          "channel" => "review",
          "author" => extract_author_login(review),
          "state" => state,
          "body" => body,
          "submitted_at" => pick_first(review, ["submittedAt", "submitted_at"])
        }

      true ->
        nil
    end
  end

  defp normalize_inline_feedback(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_inline_feedback_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_inline_feedback(_comments), do: []

  defp normalize_inline_feedback_item(comment) when is_map(comment) do
    body = normalize_feedback_body(pick_first(comment, ["body"]))

    if body do
      %{
        "channel" => "inline_comment",
        "author" => extract_author_login(comment),
        "body" => body,
        "path" => pick_first(comment, ["path"]),
        "line" => pick_first(comment, ["line", "original_line"]),
        "url" => pick_first(comment, ["html_url", "url"]),
        "created_at" => pick_first(comment, ["created_at", "createdAt"])
      }
    end
  end

  defp normalize_inline_feedback_item(_comment), do: nil

  defp maybe_put_actionable_feedback(snapshot, true, actionable_feedback) do
    Map.put(snapshot, "actionable_feedback", actionable_feedback)
  end

  defp maybe_put_actionable_feedback(snapshot, false, _actionable_feedback), do: snapshot

  defp normalize_feedback_body(body) when is_binary(body) do
    case String.trim(body) do
      "" ->
        nil

      trimmed ->
        if String.contains?(trimmed, "<!-- linear-linkback -->") do
          nil
        else
          trimmed
        end
    end
  end

  defp normalize_feedback_body(_body), do: nil

  defp extract_author_login(map) when is_map(map) do
    pick_first(map, [["user", "login"], ["author", "login"], ["user", "name"], ["author", "name"]])
  end

  defp extract_author_login(_map), do: nil

  defp pick_first(data, [key]) do
    get_nested(data, key)
  end

  defp pick_first(data, [key | rest]) do
    case get_nested(data, key) do
      nil -> pick_first(data, rest)
      value -> value
    end
  end

  defp pick_first(_data, []), do: nil

  defp get_nested(data, path) when is_list(path) do
    Enum.reduce_while(path, data, fn segment, acc ->
      case get_nested(acc, segment) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp get_nested(data, key) when is_map(data) and is_binary(key) do
    Map.get(data, key)
  end

  defp get_nested(_data, _key), do: nil

  defp normalize_check_status(nil), do: nil

  defp normalize_check_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_check_status(value), do: value |> to_string() |> normalize_check_status()

  defp check_pending?(check) do
    MapSet.member?(@pending_check_statuses, Map.get(check, "status"))
  end

  defp check_green?(check) do
    status = Map.get(check, "status")
    conclusion = Map.get(check, "conclusion")

    cond do
      check_pending?(check) -> false
      status == "COMPLETED" and MapSet.member?(@success_check_conclusions, conclusion) -> true
      status == nil and MapSet.member?(@success_check_conclusions, conclusion) -> true
      true -> false
    end
  end

  defp check_failed?(check) do
    not check_pending?(check) and not check_green?(check) and
      MapSet.member?(@failing_check_conclusions, Map.get(check, "conclusion"))
  end

  defp monotonic_time_ms(opts) do
    now_fun = Keyword.get(opts, :monotonic_time_ms, fn -> System.monotonic_time(:millisecond) end)
    now_fun.()
  end

  defp sleep_ms(opts, duration_ms) do
    sleep_fun = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
    sleep_fun.(duration_ms)
  end

  defp tool_error_payload({:sync_workpad, message}) do
    %{"error" => %{"message" => "sync_workpad: #{message}"}}
  end

  defp tool_error_payload({:symphony_handoff_check, message}) do
    %{"error" => %{"message" => "symphony_handoff_check: #{message}"}}
  end

  defp tool_error_payload({:linear_upload_issue_attachment, message}) do
    %{"error" => %{"message" => "linear_upload_issue_attachment: #{message}"}}
  end

  defp tool_error_payload({:linear_upload_issue_attachment_http_status, status}) do
    %{
      "error" => %{
        "message" => "linear_upload_issue_attachment: upload PUT request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_upload_issue_attachment_request, reason}) do
    %{
      "error" => %{
        "message" => "linear_upload_issue_attachment: upload PUT request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:github_pr_snapshot, message}) do
    %{"error" => %{"message" => "github_pr_snapshot: #{message}"}}
  end

  defp tool_error_payload({:github_wait_for_checks, message}) do
    %{"error" => %{"message" => "github_wait_for_checks: #{message}"}}
  end

  defp tool_error_payload({:github_wait_for_checks_timeout, details}) do
    %{
      "error" => %{
        "message" => "github_wait_for_checks: timed out before checks reached a terminal state.",
        "details" => details
      }
    }
  end

  defp tool_error_payload({:review_ready_transition_blocked, details}) do
    %{
      "error" => %{
        "message" => "review-ready issue transitions require a successful `symphony_handoff_check` in the current workspace.",
        "details" => details
      }
    }
  end

  defp tool_error_payload({:github_cli_status, status, output}) do
    %{
      "error" => %{
        "message" => "GitHub CLI command failed with status #{status}.",
        "status" => status,
        "output" => output
      }
    }
  end

  defp tool_error_payload({:github_cli_invalid_json, output}) do
    %{
      "error" => %{
        "message" => "GitHub CLI returned invalid JSON.",
        "output" => output
      }
    }
  end

  defp tool_error_payload({:github_cli_unavailable, reason}) do
    %{
      "error" => %{
        "message" => "GitHub CLI is unavailable in the current runtime.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
