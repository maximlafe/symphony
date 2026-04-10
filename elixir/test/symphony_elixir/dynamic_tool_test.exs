defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the linear_graphql input contract" do
    specs = DynamicTool.tool_specs()
    graphql_spec = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert graphql_spec != nil
    assert graphql_spec["description"] =~ "Linear"
    assert graphql_spec["inputSchema"]["required"] == ["query"]
  end

  test "tool_specs advertises GitHub runtime tools" do
    specs = DynamicTool.tool_specs()
    upload_spec = Enum.find(specs, &(&1["name"] == "linear_upload_issue_attachment"))
    snapshot_spec = Enum.find(specs, &(&1["name"] == "github_pr_snapshot"))
    wait_spec = Enum.find(specs, &(&1["name"] == "github_wait_for_checks"))
    handoff_spec = Enum.find(specs, &(&1["name"] == "symphony_handoff_check"))

    assert upload_spec["inputSchema"]["required"] == ["issue_id", "file_path"]
    assert upload_spec["description"] =~ "attachment"

    assert snapshot_spec["inputSchema"]["required"] == ["repo", "pr_number"]
    assert snapshot_spec["description"] =~ "GitHub"

    assert wait_spec["inputSchema"]["required"] == ["repo", "pr_number"]
    assert wait_spec["description"] =~ "checks"

    assert handoff_spec["inputSchema"]["required"] == ["issue_id", "file_path", "repo", "pr_number"]
    assert handoff_spec["description"] =~ "handoff"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => [
                 "linear_graphql",
                 "sync_workpad",
                 "linear_upload_issue_attachment",
                 "github_pr_snapshot",
                 "github_wait_for_checks",
                 "symphony_handoff_check"
               ]
             }
           }
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert [
             %{
               "text" => missing_token_text
             }
           ] = missing_token["contentItems"]

    assert Jason.decode!(missing_token_text) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert [
             %{
               "text" => status_error_text
             }
           ] = status_error["contentItems"]

    assert Jason.decode!(status_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert [
             %{
               "text" => request_error_text
             }
           ] = request_error["contentItems"]

    assert Jason.decode!(request_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true

    assert [
             %{
               "text" => ":ok"
             }
           ] = response["contentItems"]
  end

  # ── sync_workpad ───────────────────────────────────────────────────

  defp write_tmp_workpad(content) do
    path = Path.join(System.tmp_dir!(), "test_workpad_#{:erlang.unique_integer([:positive])}.md")
    File.write!(path, content)
    path
  end

  defp write_tmp_file(workspace, filename, content) do
    File.mkdir_p!(workspace)
    path = Path.join(workspace, filename)
    File.write!(path, content)
    path
  end

  defp decode_tool_text(response) do
    assert [%{"text" => text}] = response["contentItems"]
    Jason.decode!(text)
  end

  test "sync_workpad creates a comment from file when no comment_id given" do
    test_pid = self()
    path = write_tmp_workpad("## Codex Workpad\n\nProgress.")

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "file_path" => path},
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:graphql, query, variables})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c1", "url" => "https://linear.app/c1"}}}}}
        end
      )

    assert_received {:graphql, query, %{"issueId" => "ENG-42", "body" => "## Codex Workpad\n\nProgress."}}
    assert query =~ "commentCreate"
    assert response["success"] == true
  end

  test "sync_workpad updates an existing comment when comment_id given" do
    test_pid = self()
    path = write_tmp_workpad("Updated.")

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "file_path" => path, "comment_id" => "c1"},
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:graphql, query, variables})
          {:ok, %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => %{"id" => "c1", "url" => "https://linear.app/c1"}}}}}
        end
      )

    assert_received {:graphql, query, %{"id" => "c1", "body" => "Updated."}}
    assert query =~ "commentUpdate"
    assert response["success"] == true
  end

  test "sync_workpad validates required arguments before calling Linear" do
    no_issue =
      DynamicTool.execute(
        "sync_workpad",
        %{"file_path" => "/tmp/x"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert no_issue["success"] == false
    assert [%{"text" => no_issue_text}] = no_issue["contentItems"]
    assert Jason.decode!(no_issue_text)["error"]["message"] =~ "issue_id"

    no_path =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert no_path["success"] == false
    assert [%{"text" => no_path_text}] = no_path["contentItems"]
    assert Jason.decode!(no_path_text)["error"]["message"] =~ "file_path"
  end

  test "sync_workpad rejects an empty workpad file" do
    path = write_tmp_workpad("")

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "file_path" => path},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the file is empty")
        end
      )

    assert response["success"] == false
    assert [%{"text" => text}] = response["contentItems"]
    assert Jason.decode!(text)["error"]["message"] =~ "file is empty"
  end

  test "sync_workpad reports unreadable file paths" do
    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "file_path" => "/tmp/does_not_exist_#{:erlang.unique_integer([:positive])}.md"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the file cannot be read")
        end
      )

    assert response["success"] == false
    assert [%{"text" => text}] = response["contentItems"]
    assert Jason.decode!(text)["error"]["message"] =~ "cannot read"
  end

  test "linear_upload_issue_attachment uploads a local file and creates an issue attachment" do
    test_pid = self()
    workspace = Path.join(System.tmp_dir!(), "linear_upload_workspace_#{System.unique_integer([:positive])}")
    path = write_tmp_file(workspace, "artifact.csv", "id,name\n1,test\n")
    {:ok, canonical_path} = SymphonyElixir.PathSafety.canonicalize(path)

    response =
      DynamicTool.execute(
        "linear_upload_issue_attachment",
        %{
          "issue_id" => "LET-276",
          "file_path" => path,
          "title" => "LET-276 export artifact",
          "subtitle" => "CSV export",
          "content_type" => "text/csv",
          "metadata" => %{"artifact_type" => "export", "source" => "validation"}
        },
        workspace: workspace,
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:graphql, query, variables})

          cond do
            query =~ "fileUpload(" ->
              {:ok,
               %{
                 "data" => %{
                   "fileUpload" => %{
                     "success" => true,
                     "uploadFile" => %{
                       "uploadUrl" => "https://upload.example.test/artifact.csv",
                       "assetUrl" => "https://assets.example.test/artifact.csv",
                       "headers" => [%{"key" => "x-amz-acl", "value" => "private"}]
                     }
                   }
                 }
               }}

            query =~ "attachmentCreate" ->
              {:ok,
               %{
                 "data" => %{
                   "attachmentCreate" => %{
                     "success" => true,
                     "attachment" => %{
                       "id" => "att_123",
                       "title" => "LET-276 export artifact",
                       "subtitle" => "CSV export",
                       "url" => "https://assets.example.test/artifact.csv"
                     }
                   }
                 }
               }}

            true ->
              flunk("unexpected GraphQL query: #{query}")
          end
        end,
        upload_request_fun: fn url, headers, body, opts ->
          send(test_pid, {:upload, url, headers, body, opts})
          {:ok, %{status: 200}}
        end
      )

    assert response["success"] == true

    assert_received {:graphql, file_upload_query,
                     %{
                       "filename" => "artifact.csv",
                       "contentType" => "text/csv",
                       "size" => 15
                     }}

    assert file_upload_query =~ "fileUpload"
    refute file_upload_query =~ "makePublic"

    assert_received {:upload, "https://upload.example.test/artifact.csv", headers, "id,name\n1,test\n", _opts}

    assert {"content-type", "text/csv"} in headers
    assert {"cache-control", "public, max-age=31536000"} in headers
    assert {"x-amz-acl", "private"} in headers

    assert_received {:graphql, attachment_query,
                     %{
                       "input" => %{
                         "issueId" => "LET-276",
                         "title" => "LET-276 export artifact",
                         "subtitle" => "CSV export",
                         "url" => "https://assets.example.test/artifact.csv",
                         "metadata" => %{
                           "artifact_type" => "export",
                           "source" => "validation"
                         }
                       }
                     }}

    assert attachment_query =~ "attachmentCreate"

    assert decode_tool_text(response) == %{
             "artifact" => %{
               "issue_id" => "LET-276",
               "file_name" => "artifact.csv",
               "file_path" => canonical_path,
               "content_type" => "text/csv",
               "size_bytes" => 15
             },
             "attachment" => %{
               "id" => "att_123",
               "title" => "LET-276 export artifact",
               "subtitle" => "CSV export",
               "url" => "https://assets.example.test/artifact.csv"
             }
           }
  end

  test "linear_upload_issue_attachment validates required arguments and workspace paths before calling Linear" do
    workspace = Path.join(System.tmp_dir!(), "linear_upload_guard_#{System.unique_integer([:positive])}")
    path = write_tmp_file(workspace, "artifact.txt", "proof")

    no_issue =
      DynamicTool.execute(
        "linear_upload_issue_attachment",
        %{"file_path" => path},
        workspace: workspace,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when issue_id is missing")
        end
      )

    assert no_issue["success"] == false
    assert decode_tool_text(no_issue)["error"]["message"] =~ "issue_id"

    no_path =
      DynamicTool.execute(
        "linear_upload_issue_attachment",
        %{"issue_id" => "LET-276"},
        workspace: workspace,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when file_path is missing")
        end
      )

    assert no_path["success"] == false
    assert decode_tool_text(no_path)["error"]["message"] =~ "file_path"

    outside_workspace = write_tmp_workpad("outside")

    outside =
      DynamicTool.execute(
        "linear_upload_issue_attachment",
        %{"issue_id" => "LET-276", "file_path" => outside_workspace},
        workspace: workspace,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for files outside the workspace")
        end
      )

    assert outside["success"] == false
    assert decode_tool_text(outside)["error"]["message"] =~ "must stay within workspace"
  end

  test "linear_upload_issue_attachment infers defaults when optional fields and upload headers are omitted" do
    test_pid = self()
    workspace = Path.join(System.tmp_dir!(), "linear_upload_defaults_#{System.unique_integer([:positive])}")
    path = write_tmp_file(workspace, "artifact.txt", "proof")
    {:ok, canonical_path} = SymphonyElixir.PathSafety.canonicalize(path)

    response =
      DynamicTool.execute(
        "linear_upload_issue_attachment",
        %{
          "issue_id" => "LET-276",
          "file_path" => "./artifact.txt",
          "subtitle" => "   ",
          "content_type" => "  "
        },
        workspace: workspace,
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:graphql, query, variables})

          cond do
            query =~ "fileUpload(" ->
              {:ok,
               %{
                 "data" => %{
                   "fileUpload" => %{
                     "success" => true,
                     "uploadFile" => %{
                       "uploadUrl" => "https://upload.example.test/artifact.txt",
                       "assetUrl" => "https://assets.example.test/artifact.txt",
                       "headers" => nil
                     }
                   }
                 }
               }}

            query =~ "attachmentCreate" ->
              {:ok,
               %{
                 "data" => %{
                   "attachmentCreate" => %{
                     "success" => true,
                     "attachment" => %{
                       "id" => "att_defaults",
                       "title" => "artifact.txt",
                       "subtitle" => nil,
                       "url" => "https://assets.example.test/artifact.txt"
                     }
                   }
                 }
               }}

            true ->
              flunk("unexpected GraphQL query: #{query}")
          end
        end,
        upload_request_fun: fn url, headers, body, opts ->
          send(test_pid, {:upload, url, headers, body, opts})
          {:ok, %{status: 200}}
        end
      )

    assert response["success"] == true

    assert_received {:graphql, file_upload_query,
                     %{
                       "filename" => "artifact.txt",
                       "contentType" => "text/plain",
                       "size" => 5
                     }}

    assert file_upload_query =~ "fileUpload"

    assert_received {:upload, "https://upload.example.test/artifact.txt", headers, "proof", _opts}
    assert length(headers) == 2
    assert {"content-type", "text/plain"} in headers
    assert {"cache-control", "public, max-age=31536000"} in headers

    assert_received {:graphql, attachment_query,
                     %{
                       "input" => %{
                         "issueId" => "LET-276",
                         "title" => "artifact.txt",
                         "url" => "https://assets.example.test/artifact.txt"
                       }
                     }}

    assert attachment_query =~ "attachmentCreate"

    assert decode_tool_text(response) == %{
             "artifact" => %{
               "issue_id" => "LET-276",
               "file_name" => "artifact.txt",
               "file_path" => canonical_path,
               "content_type" => "text/plain",
               "size_bytes" => 5
             },
             "attachment" => %{
               "id" => "att_defaults",
               "title" => "artifact.txt",
               "subtitle" => nil,
               "url" => "https://assets.example.test/artifact.txt"
             }
           }
  end

  test "github_pr_snapshot returns a compact summary without feedback details by default" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_pr_snapshot",
        %{"repo" => "maximlafe/lead_status", "pr_number" => 62},
        workspace: "/tmp/test-workspace",
        gh_runner: fn args, opts ->
          send(test_pid, {:gh, args, opts})

          case args do
            ["pr", "view", "62", "-R", "maximlafe/lead_status", "--json", "state,url,labels,reviewDecision,mergeStateStatus,statusCheckRollup"] ->
              {:ok,
               Jason.encode!(%{
                 "state" => "OPEN",
                 "url" => "https://github.com/maximlafe/lead_status/pull/62",
                 "labels" => [%{"name" => "symphony"}],
                 "reviewDecision" => "",
                 "mergeStateStatus" => "CLEAN",
                 "statusCheckRollup" => [
                   %{
                     "name" => "test",
                     "status" => "COMPLETED",
                     "conclusion" => "SUCCESS",
                     "workflowName" => "CI Pipeline",
                     "detailsUrl" => "https://example.test/check"
                   }
                 ]
               })}

            ["api", "repos/maximlafe/lead_status/issues/62/comments?per_page=100"] ->
              {:ok, "[]"}

            ["api", "repos/maximlafe/lead_status/pulls/62/reviews?per_page=100"] ->
              {:ok, "[]"}

            ["api", "repos/maximlafe/lead_status/pulls/62/comments?per_page=100"] ->
              {:ok, "[]"}
          end
        end
      )

    assert_received {:gh, ["pr", "view", "62", "-R", "maximlafe/lead_status", "--json", _], [workspace: "/tmp/test-workspace"]}
    assert response["success"] == true

    payload = decode_tool_text(response)

    assert payload == %{
             "all_checks_green" => true,
             "checks" => [
               %{
                 "conclusion" => "SUCCESS",
                 "details_url" => "https://example.test/check",
                 "name" => "test",
                 "status" => "COMPLETED",
                 "workflow_name" => "CI Pipeline"
               }
             ],
             "has_actionable_feedback" => false,
             "has_pending_checks" => false,
             "inline_comment_count" => 0,
             "labels" => ["symphony"],
             "merge_state_status" => "CLEAN",
             "review_count" => 0,
             "review_decision" => nil,
             "state" => "OPEN",
             "top_level_comment_count" => 0,
             "url" => "https://github.com/maximlafe/lead_status/pull/62"
           }
  end

  test "github_pr_snapshot returns normalized actionable feedback details when requested" do
    response =
      DynamicTool.execute(
        "github_pr_snapshot",
        %{
          "repo" => "maximlafe/lead_status",
          "pr_number" => 62,
          "include_feedback_details" => true
        },
        gh_runner: fn args, _opts ->
          case args do
            ["pr", "view", "62", "-R", "maximlafe/lead_status", "--json", "state,url,labels,reviewDecision,mergeStateStatus,statusCheckRollup"] ->
              {:ok,
               Jason.encode!(%{
                 "state" => "OPEN",
                 "url" => "https://github.com/maximlafe/lead_status/pull/62",
                 "labels" => [%{"name" => "symphony"}],
                 "reviewDecision" => "CHANGES_REQUESTED",
                 "mergeStateStatus" => "DIRTY",
                 "statusCheckRollup" => [
                   %{"name" => "test", "status" => "IN_PROGRESS", "conclusion" => "", "workflowName" => "CI"}
                 ]
               })}

            ["api", "repos/maximlafe/lead_status/issues/62/comments?per_page=100"] ->
              {:ok,
               Jason.encode!([
                 %{"user" => %{"login" => "linear"}, "body" => "<!-- linear-linkback -->", "url" => "https://example.test/ignore"},
                 %{
                   "user" => %{"login" => "reviewer"},
                   "body" => "Нужно проверить handoff flow.",
                   "url" => "https://example.test/comment/1",
                   "createdAt" => "2026-03-19T10:00:00Z"
                 }
               ])}

            ["api", "repos/maximlafe/lead_status/pulls/62/reviews?per_page=100"] ->
              {:ok,
               Jason.encode!([
                 %{
                   "user" => %{"login" => "qa-reviewer"},
                   "state" => "CHANGES_REQUESTED",
                   "body" => "Покрой сценарий зелёного CI.",
                   "submittedAt" => "2026-03-19T10:01:00Z"
                 }
               ])}

            ["api", "repos/maximlafe/lead_status/pulls/62/comments?per_page=100"] ->
              {:ok,
               Jason.encode!([
                 %{
                   "user" => %{"login" => "bot-reviewer"},
                   "body" => "Нужен один compact flow.",
                   "path" => "WORKFLOW.md",
                   "line" => 256,
                   "html_url" => "https://example.test/inline/1",
                   "created_at" => "2026-03-19T10:02:00Z"
                 }
               ])}
          end
        end
      )

    assert response["success"] == true
    payload = decode_tool_text(response)

    assert payload["has_pending_checks"] == true
    assert payload["all_checks_green"] == false
    assert payload["has_actionable_feedback"] == true
    assert payload["top_level_comment_count"] == 1
    assert payload["review_count"] == 1
    assert payload["inline_comment_count"] == 1
    assert payload["review_decision"] == "CHANGES_REQUESTED"
    assert length(payload["actionable_feedback"]) == 3

    assert Enum.any?(payload["actionable_feedback"], fn item ->
             item["channel"] == "top_level_comment" and item["author"] == "reviewer"
           end)

    assert Enum.any?(payload["actionable_feedback"], fn item ->
             item["channel"] == "review" and item["state"] == "CHANGES_REQUESTED"
           end)

    assert Enum.any?(payload["actionable_feedback"], fn item ->
             item["channel"] == "inline_comment" and item["path"] == "WORKFLOW.md"
           end)
  end

  test "github_wait_for_checks waits outside the model loop until checks are green" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{call_count: 0, now_ms: 0}
      end)

    gh_runner = fn args, _opts ->
      Agent.get_and_update(agent, fn %{call_count: call_count} = state ->
        next_count = call_count + 1

        payload =
          if next_count == 1 do
            %{
              "state" => "OPEN",
              "url" => "https://example.test/pr/62",
              "labels" => [],
              "reviewDecision" => "",
              "mergeStateStatus" => "UNSTABLE",
              "statusCheckRollup" => [
                %{"name" => "test", "status" => "IN_PROGRESS", "conclusion" => "", "workflowName" => "CI"}
              ]
            }
          else
            %{
              "state" => "OPEN",
              "url" => "https://example.test/pr/62",
              "labels" => [],
              "reviewDecision" => "",
              "mergeStateStatus" => "CLEAN",
              "statusCheckRollup" => [
                %{"name" => "test", "status" => "COMPLETED", "conclusion" => "SUCCESS", "workflowName" => "CI"}
              ]
            }
          end

        result =
          case args do
            ["pr", "view", "62", "-R", "maximlafe/lead_status", "--json", "state,url,labels,reviewDecision,mergeStateStatus,statusCheckRollup"] ->
              {:ok, Jason.encode!(payload)}
          end

        {result, %{state | call_count: next_count}}
      end)
    end

    sleep_fn = fn duration_ms ->
      Agent.update(agent, fn state -> %{state | now_ms: state.now_ms + duration_ms} end)
    end

    monotonic_time_ms = fn ->
      Agent.get(agent, & &1.now_ms)
    end

    response =
      DynamicTool.execute(
        "github_wait_for_checks",
        %{
          "repo" => "maximlafe/lead_status",
          "pr_number" => 62,
          "timeout_ms" => 1_000,
          "poll_interval_ms" => 200
        },
        gh_runner: gh_runner,
        sleep_fn: sleep_fn,
        monotonic_time_ms: monotonic_time_ms
      )

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    assert response["success"] == true
    payload = decode_tool_text(response)

    assert payload["all_green"] == true
    assert payload["failed_checks"] == []
    assert payload["pending_checks"] == []

    assert payload["checks"] == [
             %{
               "conclusion" => "SUCCESS",
               "details_url" => nil,
               "name" => "test",
               "status" => "COMPLETED",
               "workflow_name" => "CI"
             }
           ]

    assert payload["duration_ms"] == 200
    assert Agent.get(agent, & &1.call_count) == 2
  end

  test "github_wait_for_checks reports a timeout with compact pending check details" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{now_ms: 0}
      end)

    gh_runner = fn args, _opts ->
      case args do
        ["pr", "view", "62", "-R", "maximlafe/lead_status", "--json", "state,url,labels,reviewDecision,mergeStateStatus,statusCheckRollup"] ->
          {:ok,
           Jason.encode!(%{
             "state" => "OPEN",
             "url" => "https://example.test/pr/62",
             "labels" => [],
             "reviewDecision" => "",
             "mergeStateStatus" => "UNSTABLE",
             "statusCheckRollup" => [
               %{"name" => "test", "status" => "IN_PROGRESS", "conclusion" => "", "workflowName" => "CI"}
             ]
           })}
      end
    end

    sleep_fn = fn duration_ms ->
      Agent.update(agent, fn state -> %{state | now_ms: state.now_ms + duration_ms} end)
    end

    monotonic_time_ms = fn ->
      Agent.get(agent, & &1.now_ms)
    end

    response =
      DynamicTool.execute(
        "github_wait_for_checks",
        %{
          "repo" => "maximlafe/lead_status",
          "pr_number" => 62,
          "timeout_ms" => 250,
          "poll_interval_ms" => 100
        },
        gh_runner: gh_runner,
        sleep_fn: sleep_fn,
        monotonic_time_ms: monotonic_time_ms
      )

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    assert response["success"] == false
    payload = decode_tool_text(response)
    assert payload["error"]["message"] =~ "timed out"
    assert payload["error"]["details"]["timeout_ms"] == 250
    assert payload["error"]["details"]["duration_ms"] >= 300
    assert length(payload["error"]["details"]["pending_checks"]) == 1
  end

  test "symphony_handoff_check fails closed for an incomplete workpad and writes a manifest" do
    workspace = Path.join(System.tmp_dir!(), "handoff_tool_workspace_#{System.unique_integer([:positive])}")

    workpad_path =
      write_tmp_file(workspace, "workpad.md", """
      ## Codex Workpad

      ### Validation

      - [x] targeted tests: `mix test test/smoke.exs`

      ### Artifacts

      - [x] uploaded attachment: `proof.txt` -> placeholder proof

      ### Checkpoint

      - `checkpoint_type`: `<human-verify|decision|human-action>` (fill only at handoff)
      """)

    response =
      DynamicTool.execute(
        "symphony_handoff_check",
        %{
          "issue_id" => "LET-416",
          "file_path" => workpad_path,
          "repo" => "maximlafe/symphony",
          "pr_number" => 52
        },
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if query =~ "SymphonyHandoffCheckIssue" do
            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "id" => "LET-416",
                   "identifier" => "LET-416",
                   "state" => %{"name" => "In Progress"},
                   "labels" => %{"nodes" => []},
                   "attachments" => %{"nodes" => [%{"title" => "proof.txt", "url" => "https://example.test/proof.txt"}]}
                 }
               }
             }}
          else
            flunk("unexpected GraphQL query: #{query}")
          end
        end,
        gh_runner: fn args, _opts ->
          case args do
            ["pr", "view", "52", "-R", "maximlafe/symphony", "--json", _] ->
              {:ok,
               Jason.encode!(%{
                 "state" => "OPEN",
                 "url" => "https://example.test/pr/52",
                 "labels" => [%{"name" => "symphony"}],
                 "reviewDecision" => "",
                 "mergeStateStatus" => "CLEAN",
                 "statusCheckRollup" => [
                   %{"name" => "test", "status" => "COMPLETED", "conclusion" => "SUCCESS", "workflowName" => "CI"}
                 ]
               })}

            ["api", "repos/maximlafe/symphony/issues/52/comments?per_page=100"] ->
              {:ok, "[]"}

            ["api", "repos/maximlafe/symphony/pulls/52/reviews?per_page=100"] ->
              {:ok, "[]"}

            ["api", "repos/maximlafe/symphony/pulls/52/comments?per_page=100"] ->
              {:ok, "[]"}

            _ ->
              flunk("unexpected gh command: #{inspect(args)}")
          end
        end
      )

    assert response["success"] == false
    payload = decode_tool_text(response)
    assert payload["error"]["message"] =~ "verification contract failed"
    assert payload["manifest"]["manifest_path"] =~ ".symphony/verification/handoff-manifest.json"
    assert File.exists?(payload["manifest"]["manifest_path"])
    assert Enum.any?(payload["manifest"]["missing_items"], &String.contains?(&1, "preflight"))
  end

  test "linear_graphql blocks review-ready issue transitions until symphony_handoff_check succeeds" do
    workspace = Path.join(System.tmp_dir!(), "handoff_guard_workspace_#{System.unique_integer([:positive])}")

    workpad_path =
      write_tmp_file(workspace, "workpad.md", """
      ## Codex Workpad

      ### Validation

      - [x] preflight: `make symphony-preflight`
      - [x] targeted tests: `mix test test/symphony_elixir/handoff_check_test.exs`
      - [x] repo validation: `make symphony-validate`

      ### Artifacts

      - [x] uploaded attachment: `runtime-proof.log` -> runtime smoke log from the health check

      ### Checkpoint

      - `checkpoint_type`: `human-verify`
      - `risk_level`: `medium`
      - `summary`: Runtime proof, tests, and repo validation are complete.
      """)

    state_catalog_response = fn ->
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{
               "states" => %{
                 "nodes" => [
                   %{"id" => "in-review-state-id", "name" => "In Review"}
                 ]
               }
             }
           }
         }
       }}
    end

    blocked =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success } }",
          "variables" => %{"id" => "LET-416", "stateId" => "in-review-state-id"}
        },
        workspace: workspace,
        linear_client: fn query, _variables, _opts ->
          if query =~ "SymphonyHandoffCheckState" do
            state_catalog_response.()
          else
            flunk("unexpected linear_graphql mutation without manifest guard")
          end
        end
      )

    assert blocked["success"] == false
    assert decode_tool_text(blocked)["error"]["message"] =~ "review-ready issue transitions require"

    assert DynamicTool.execute(
             "symphony_handoff_check",
             %{
               "issue_id" => "LET-416",
               "file_path" => workpad_path,
               "repo" => "maximlafe/symphony",
               "pr_number" => 52,
               "profile" => "runtime"
             },
             workspace: workspace,
             linear_client: fn query, _variables, _opts ->
               if query =~ "SymphonyHandoffCheckIssue" do
                 {:ok,
                  %{
                    "data" => %{
                      "issue" => %{
                        "id" => "LET-416",
                        "identifier" => "LET-416",
                        "state" => %{"name" => "In Progress"},
                        "labels" => %{"nodes" => [%{"name" => "verification:runtime"}]},
                        "attachments" => %{"nodes" => [%{"title" => "runtime-proof.log", "url" => "https://example.test/runtime-proof.log"}]}
                      }
                    }
                  }}
               else
                 flunk("unexpected handoff query: #{query}")
               end
             end,
             gh_runner: fn args, _opts ->
               case args do
                 ["pr", "view", "52", "-R", "maximlafe/symphony", "--json", _] ->
                   {:ok,
                    Jason.encode!(%{
                      "state" => "OPEN",
                      "url" => "https://example.test/pr/52",
                      "labels" => [%{"name" => "symphony"}],
                      "reviewDecision" => "",
                      "mergeStateStatus" => "CLEAN",
                      "statusCheckRollup" => [
                        %{"name" => "test", "status" => "COMPLETED", "conclusion" => "SUCCESS", "workflowName" => "CI"}
                      ]
                    })}

                 ["api", "repos/maximlafe/symphony/issues/52/comments?per_page=100"] ->
                   {:ok, "[]"}

                 ["api", "repos/maximlafe/symphony/pulls/52/reviews?per_page=100"] ->
                   {:ok, "[]"}

                 ["api", "repos/maximlafe/symphony/pulls/52/comments?per_page=100"] ->
                   {:ok, "[]"}

                 _ ->
                   flunk("unexpected gh command: #{inspect(args)}")
               end
             end
           )["success"] == true

    allowed =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success } }",
          "variables" => %{"id" => "LET-416", "stateId" => "in-review-state-id"}
        },
        workspace: workspace,
        linear_client: fn query, variables, _opts ->
          cond do
            query =~ "SymphonyHandoffCheckState" ->
              state_catalog_response.()

            query =~ "issueUpdate" ->
              send(self(), {:issue_update, variables})
              {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

            true ->
              flunk("unexpected GraphQL query: #{query}")
          end
        end
      )

    assert allowed["success"] == true
    assert_received {:issue_update, %{"id" => "LET-416", "stateId" => "in-review-state-id"}}
  end
end
