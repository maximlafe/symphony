defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{AcceptanceCapability, Config, Linear.Issue, Linear.RateLimitGuard, RiskyTaskClassifier}

  @issue_page_size 50
  @execution_comment_page_size 10
  @execution_attachment_page_size 20
  @max_error_body_log_bytes 1_000
  @max_execution_attachment_content_bytes 16_384
  @max_execution_attachment_download_bytes @max_execution_attachment_content_bytes + 1
  @execution_attachment_download_timeout_ms 15_000
  @linear_upload_host "uploads.linear.app"
  @linear_upload_url_regex ~r/https?:\/\/uploads\.linear\.app\/[^\s<>\]\[(){}"']+/u
  @ingested_attachment_body_private_key :symphony_linear_ingested_attachment_body

  @text_attachment_extensions MapSet.new([
                                "csv",
                                "json",
                                "log",
                                "markdown",
                                "md",
                                "text",
                                "tsv",
                                "txt",
                                "xml",
                                "yaml",
                                "yml"
                              ])

  @text_attachment_content_types MapSet.new([
                                   "application/json",
                                   "application/ld+json",
                                   "application/problem+json",
                                   "application/x-ndjson",
                                   "application/x-yaml",
                                   "application/xml",
                                   "application/yaml",
                                   "text/csv",
                                   "text/markdown",
                                   "text/plain",
                                   "text/tab-separated-values",
                                   "text/xml",
                                   "text/x-yaml",
                                   "text/yaml"
                                 ])

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        project {
          slugId
          name
        }
        state {
          name
        }
        branchName
        url
        assignee {
          id
          email
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_assignee_id """
  query SymphonyLinearPollByAssigneeId($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String, $assigneeId: ID!) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}, assignee: {id: {eq: $assigneeId}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        project {
          slugId
          name
        }
        state {
          name
        }
        branchName
        url
        assignee {
          id
          email
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_assignee_email """
  query SymphonyLinearPollByAssigneeEmail($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String, $assigneeEmail: String!) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}, assignee: {email: {eq: $assigneeEmail}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        project {
          slugId
          name
        }
        state {
          name
        }
        branchName
        url
        assignee {
          id
          email
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @team_query """
  query SymphonyLinearTeamPoll($teamKey: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        project {
          slugId
          name
        }
        state {
          name
        }
        branchName
        url
        assignee {
          id
          email
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @team_query_assignee_id """
  query SymphonyLinearTeamPollByAssigneeId($teamKey: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String, $assigneeId: ID!) {
    issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}, assignee: {id: {eq: $assigneeId}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        project {
          slugId
          name
        }
        state {
          name
        }
        branchName
        url
        assignee {
          id
          email
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @team_query_assignee_email """
  query SymphonyLinearTeamPollByAssigneeEmail($teamKey: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String, $assigneeEmail: String!) {
    issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}, assignee: {email: {eq: $assigneeEmail}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        project {
          slugId
          name
        }
        state {
          name
        }
        branchName
        url
        assignee {
          id
          email
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        project {
          slugId
          name
        }
        state {
          name
        }
        branchName
        url
        assignee {
          id
          email
          name
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @execution_issue_query """
  query SymphonyLinearExecutionIssue($id: String!, $attachmentFirst: Int!, $commentFirst: Int!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      priority
      project {
        slugId
        name
      }
      state {
        name
      }
      branchName
      url
      assignee {
        id
        email
        name
      }
      labels {
        nodes {
          name
        }
      }
      createdAt
      updatedAt
      attachments(first: $attachmentFirst) {
        nodes {
          title
          url
          sourceType
          metadata
        }
      }
      comments(first: $commentFirst) {
        nodes {
          id
          body
          createdAt
          updatedAt
          user {
            name
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(Config.linear_polling_scope()) ->
        {:error, :missing_linear_polling_scope}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(Config.linear_polling_scope(), tracker.active_states, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(Config.linear_polling_scope()) ->
          {:error, :missing_linear_polling_scope}

        true ->
          do_fetch_by_states(Config.linear_polling_scope(), normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with :ok <- RateLimitGuard.enforce_guard(),
         {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        normalized_status = normalize_linear_response_status(response)

        {status, rate_limited_cooldown_ms} =
          RateLimitGuard.normalize_rate_limited_status(response, normalized_status)

        Logger.error(
          "Linear GraphQL request failed status=#{status}" <>
            RateLimitGuard.rate_limit_context(rate_limited_cooldown_ms) <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, status}}

      {:error, {:linear_rate_limited, retry_after_ms}} ->
        Logger.error("Linear GraphQL request skipped due to active local rate-limit cooldown retry_after_ms=#{retry_after_ms}")

        {:error, {:linear_api_status, 429}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @spec fetch_issue_for_execution(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_for_execution(issue_id_or_identifier) when is_binary(issue_id_or_identifier) do
    trimmed = String.trim(issue_id_or_identifier)
    tracker = Config.settings!().tracker

    cond do
      trimmed == "" ->
        {:error, :missing_issue_identifier}

      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      true ->
        case graphql(@execution_issue_query, %{
               id: trimmed,
               attachmentFirst: @execution_attachment_page_size,
               commentFirst: @execution_comment_page_size
             }) do
          {:ok, body} ->
            decode_execution_issue_response(body,
              attachment_download_fun: linear_attachment_download_fun(tracker.api_key)
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test(
          {:project, String.t()} | {:team, String.t()},
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          map() | nil
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(scope, state_names, graphql_fun, assignee_filter \\ nil)
      when is_list(state_names) and is_function(graphql_fun, 2) and
             (is_nil(assignee_filter) or is_map(assignee_filter)) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      do_fetch_by_states(scope, normalized_states, assignee_filter, graphql_fun)
    end
  end

  @doc false
  @spec fetch_issue_for_execution_for_test(
          String.t(),
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          keyword()
        ) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue_for_execution_for_test(issue_id_or_identifier, graphql_fun, opts \\ [])
      when is_binary(issue_id_or_identifier) and is_function(graphql_fun, 2) and is_list(opts) do
    attachment_download_fun = Keyword.get(opts, :attachment_download_fun, &default_test_attachment_download/2)

    decode_opts = [attachment_download_fun: attachment_download_fun]

    trimmed = String.trim(issue_id_or_identifier)

    case trimmed do
      "" ->
        {:error, :missing_issue_identifier}

      _ ->
        case graphql_fun.(@execution_issue_query, %{
               id: trimmed,
               attachmentFirst: @execution_attachment_page_size,
               commentFirst: @execution_comment_page_size
             }) do
          {:ok, body} -> decode_execution_issue_response(body, decode_opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp do_fetch_by_states(scope, state_names, assignee_filter) do
    do_fetch_by_states(scope, state_names, assignee_filter, &graphql/2)
  end

  defp do_fetch_by_states(scope, state_names, assignee_filter, graphql_fun)
       when is_function(graphql_fun, 2) do
    do_fetch_by_states_page(scope, state_names, assignee_filter, graphql_fun, nil, [])
  end

  defp do_fetch_by_states_page(scope, state_names, assignee_filter, graphql_fun, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql_fun.(
             linear_scope_query(scope, assignee_filter),
             linear_scope_variables(scope, state_names, after_cursor, assignee_filter)
           ),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(scope, state_names, assignee_filter, graphql_fun, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp linear_scope_query({:project, _project_slug}, assignee_filter) do
    case assignee_query_filter(assignee_filter) do
      {:id, _value} -> @query_assignee_id
      {:email, _value} -> @query_assignee_email
      _ -> @query
    end
  end

  defp linear_scope_query({:team, _team_key}, assignee_filter) do
    case assignee_query_filter(assignee_filter) do
      {:id, _value} -> @team_query_assignee_id
      {:email, _value} -> @team_query_assignee_email
      _ -> @team_query
    end
  end

  defp linear_scope_variables({:project, project_slug}, state_names, after_cursor, assignee_filter) do
    base = %{
      projectSlug: project_slug,
      stateNames: state_names,
      first: @issue_page_size,
      relationFirst: @issue_page_size,
      after: after_cursor
    }

    maybe_add_assignee_query_filter(base, assignee_filter)
  end

  defp linear_scope_variables({:team, team_key}, state_names, after_cursor, assignee_filter) do
    base = %{
      teamKey: team_key,
      stateNames: state_names,
      first: @issue_page_size,
      relationFirst: @issue_page_size,
      after: after_cursor
    }

    maybe_add_assignee_query_filter(base, assignee_filter)
  end

  defp maybe_add_assignee_query_filter(variables, assignee_filter) when is_map(variables) do
    case assignee_query_filter(assignee_filter) do
      {:id, value} ->
        Map.put(variables, :assigneeId, value)

      {:email, value} ->
        Map.put(variables, :assigneeEmail, value)

      _ ->
        variables
    end
  end

  defp assignee_query_filter(%{query_filter: {kind, value}})
       when kind in [:id, :email] and is_binary(value),
       do: {kind, value}

  defp assignee_query_filter(_assignee_filter), do: nil

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp normalize_linear_response_status(%{status: status}) when is_integer(status), do: status
  defp normalize_linear_response_status(_response), do: 0

  @doc false
  @spec clear_rate_limit_guard_for_test() :: :ok
  def clear_rate_limit_guard_for_test do
    RateLimitGuard.clear_guard_for_test()
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_execution_issue_response(response, opts)

  defp decode_execution_issue_response(%{"data" => %{"issue" => issue}}, opts) when is_map(issue) do
    {:ok, normalize_execution_issue(issue, opts)}
  end

  defp decode_execution_issue_response(%{"errors" => errors}, _opts) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_execution_issue_response(_unknown, _opts) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]
    description = issue["description"]
    labels = extract_labels(issue)
    blocked_by = extract_blockers(issue)
    {required_capabilities, _capability_errors} = AcceptanceCapability.required_capabilities(description)

    risk_classification =
      RiskyTaskClassifier.classify(%{
        description: description,
        labels: labels,
        blocked_by: blocked_by,
        required_capabilities: required_capabilities
      })

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: description,
      priority: parse_priority(issue["priority"]),
      project_slug: issue |> project_field("slugId"),
      project_name: issue |> project_field("name"),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: blocked_by,
      labels: labels,
      risk_classification: risk_classification,
      cost_signals: risk_classification["cost_signals"] || [],
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp normalize_execution_issue(issue, opts)

  defp normalize_execution_issue(issue, opts) when is_map(issue) and is_list(opts) do
    assignee = issue["assignee"]
    raw_comments = get_in(issue, ["comments", "nodes"])
    comments = normalize_execution_comments(raw_comments)

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      project_slug: issue |> project_field("slugId"),
      project_name: issue |> project_field("name"),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      labels: extract_labels(issue),
      attachments: execution_attachments(issue, raw_comments, opts),
      comments: comments,
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp execution_attachments(issue, raw_comments, opts) when is_map(issue) and is_list(opts) do
    issue
    |> execution_attachment_candidates(raw_comments)
    |> ingest_execution_attachments(opts)
  end

  defp execution_attachment_candidates(issue, raw_comments) when is_map(issue) do
    metadata_attachments = normalize_execution_attachments(get_in(issue, ["attachments", "nodes"]))

    description_attachments =
      issue
      |> Map.get("description")
      |> extract_linear_upload_attachments("description")

    comment_attachments =
      raw_comments
      |> comment_bodies()
      |> Enum.flat_map(&extract_linear_upload_attachments(&1, "comment"))

    dedupe_attachments(metadata_attachments ++ description_attachments ++ comment_attachments)
  end

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp project_field(%{"project" => %{} = project}, field) when is_binary(field), do: project[field]
  defp project_field(_issue, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_match_values()
    |> MapSet.disjoint?(match_values)
    |> Kernel.not()
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp assignee_match_values(%{} = assignee) do
    [assignee["id"], assignee["email"], assignee["name"]]
    |> Enum.map(&normalize_assignee_match_value/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok,
         %{
           configured_assignee: assignee,
           match_values: MapSet.new([normalized]),
           query_filter: assignee_query_filter_for_value(normalized)
         }}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok,
             %{
               configured_assignee: "me",
               match_values: MapSet.new([viewer_id]),
               query_filter: {:id, viewer_id}
             }}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" ->
        nil

      normalized ->
        if String.contains?(normalized, "@") do
          String.downcase(normalized)
        else
          normalized
        end
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp assignee_query_filter_for_value(value) when is_binary(value) do
    cond do
      String.contains?(value, "@") ->
        {:email, value}

      String.match?(value, ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) ->
        {:id, value}

      true ->
        nil
    end
  end

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp normalize_execution_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(fn
      %{} = attachment ->
        %{
          "title" => normalize_optional_string(attachment["title"]),
          "url" => normalize_optional_string(attachment["url"]),
          "source_type" => normalize_optional_string(attachment["sourceType"]),
          "metadata" => attachment["metadata"]
        }

      _ ->
        nil
    end)
    |> Enum.reject(&(is_nil(&1) or is_nil(&1["title"])))
  end

  defp normalize_execution_attachments(_attachments), do: []

  defp ingest_execution_attachments(attachments, opts) when is_list(attachments) and is_list(opts) do
    attachment_download_fun = Keyword.get(opts, :attachment_download_fun, &default_test_attachment_download/2)

    Enum.map(attachments, &ingest_execution_attachment(&1, attachment_download_fun))
  end

  defp ingest_execution_attachment(%{"url" => url} = attachment, attachment_download_fun)
       when is_binary(url) and is_function(attachment_download_fun, 2) do
    extension = attachment_extension(url)

    cond do
      not linear_upload_url?(url) ->
        merge_execution_attachment_content(attachment, "unsupported_host", nil, nil)

      extension_capability(extension) == :binary ->
        merge_execution_attachment_content(
          attachment,
          "unsupported_extension",
          extension_content_type(extension),
          nil
        )

      true ->
        download_and_attach_execution_content(attachment, url, extension, attachment_download_fun)
    end
  end

  defp ingest_execution_attachment(%{} = attachment, _attachment_download_fun) do
    merge_execution_attachment_content(attachment, "missing_url", nil, nil)
  end

  defp ingest_execution_attachment(attachment, _attachment_download_fun), do: attachment

  defp attach_execution_content(attachment, response, extension)
       when is_map(attachment) and is_map(response) do
    content_type = normalize_content_type(response_content_type(response))
    fallback_content_type = content_type || extension_content_type(extension)

    case execution_attachment_policy(extension, content_type) do
      {:reject, status} ->
        merge_execution_attachment_content(attachment, status, content_type, nil)

      :accept ->
        attach_execution_text_body(attachment, response, fallback_content_type)
    end
  end

  defp download_and_attach_execution_content(attachment, url, extension, attachment_download_fun) do
    case attachment_download_fun.(url, timeout: @execution_attachment_download_timeout_ms) do
      {:ok, response} ->
        attach_execution_content(attachment, response, extension)

      {:error, reason} ->
        merge_execution_attachment_content(
          attachment,
          "download_error",
          nil,
          nil,
          %{"content_error" => inspect(reason)}
        )
    end
  end

  defp execution_attachment_policy(extension, content_type) do
    extension_capability = extension_capability(extension)
    content_type_capability = content_type_capability(content_type)

    cond do
      extension_capability == :binary -> {:reject, "unsupported_extension"}
      content_type_capability == :binary -> {:reject, "unsupported_content_type"}
      extension_capability == :unknown and content_type_capability == :unknown -> {:reject, "unsupported_type"}
      true -> :accept
    end
  end

  defp attach_execution_text_body(attachment, response, fallback_content_type) do
    case response_text_body(response) do
      text_body when is_binary(text_body) ->
        attach_capped_execution_text(attachment, text_body, fallback_content_type)

      _ ->
        merge_execution_attachment_content(attachment, "invalid_body", fallback_content_type, nil)
    end
  end

  defp attach_capped_execution_text(attachment, text_body, fallback_content_type)
       when is_binary(text_body) do
    case capped_utf8_text(text_body) do
      {:ok, text, truncated?} ->
        status = if(truncated?, do: "truncated", else: "ok")
        merge_execution_attachment_content(attachment, status, fallback_content_type, text)

      :error ->
        merge_execution_attachment_content(attachment, "invalid_text", fallback_content_type, nil)
    end
  end

  defp merge_execution_attachment_content(attachment, status, content_type, content_text, extra_fields \\ %{})
       when is_map(attachment) and is_binary(status) and is_map(extra_fields) do
    Map.merge(
      attachment,
      Map.merge(
        %{
          "content_status" => status,
          "content_type" => content_type,
          "content_text" => content_text
        },
        extra_fields
      )
    )
  end

  defp comment_bodies(comments) when is_list(comments) do
    comments
    |> Enum.map(fn
      %{} = comment ->
        body = normalize_optional_string(comment["body"])
        if is_binary(body) and workpad_comment_body?(body), do: nil, else: body

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp comment_bodies(_comments), do: []

  defp extract_linear_upload_attachments(text, source) when is_binary(text) and is_binary(source) do
    text
    |> extract_linear_upload_links()
    |> Enum.map(fn url ->
      %{
        "title" => title_from_url(url),
        "url" => url,
        "source_type" => "linear_upload_link",
        "metadata" => %{"source" => source}
      }
    end)
  end

  defp extract_linear_upload_attachments(_text, _source), do: []

  defp extract_linear_upload_links(text) when is_binary(text) do
    @linear_upload_url_regex
    |> Regex.scan(text)
    |> Enum.map(&List.first/1)
    |> Enum.map(&sanitize_detected_url/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp sanitize_detected_url(url) when is_binary(url) do
    sanitized =
      url
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.trim_trailing(",")
      |> String.trim_trailing(";")
      |> String.trim_trailing(":")
      |> String.trim_trailing(")")
      |> String.trim_trailing("]")

    case URI.parse(sanitized) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and host == @linear_upload_host ->
        sanitized

      _ ->
        nil
    end
  end

  defp sanitize_detected_url(_url), do: nil

  defp title_from_url(url) when is_binary(url) do
    title =
      url
      |> URI.parse()
      |> Map.get(:path)
      |> Kernel.||("")
      |> Path.basename()
      |> normalize_optional_string()

    title || "linear-upload"
  end

  defp title_from_url(_url), do: "linear-upload"

  defp dedupe_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.reduce([], fn
      %{} = attachment, acc ->
        if attachment_duplicate?(attachment, acc) do
          acc
        else
          acc ++ [attachment]
        end

      _attachment, acc ->
        acc
    end)
  end

  defp attachment_duplicate?(attachment, attachments)
       when is_map(attachment) and is_list(attachments) do
    candidate_url = normalize_optional_string(attachment["url"])
    candidate_title = normalize_optional_string(attachment["title"])

    Enum.any?(attachments, fn existing ->
      existing_url = normalize_optional_string(existing["url"])
      existing_title = normalize_optional_string(existing["title"])

      cond do
        is_binary(candidate_url) ->
          is_binary(existing_url) and candidate_url == existing_url

        is_binary(candidate_title) ->
          is_binary(existing_title) and candidate_title == existing_title

        true ->
          false
      end
    end)
  end

  defp attachment_duplicate?(_attachment, _attachments), do: false

  defp attachment_extension(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> Kernel.||("")
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
  end

  defp linear_upload_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} -> scheme in ["http", "https"] and host == @linear_upload_host
    end
  end

  defp extension_allowed?(extension) when is_binary(extension),
    do: MapSet.member?(@text_attachment_extensions, extension)

  defp content_type_allowed?(content_type) when is_binary(content_type) do
    String.starts_with?(content_type, "text/") or MapSet.member?(@text_attachment_content_types, content_type)
  end

  defp extension_capability(extension) when is_binary(extension) do
    cond do
      extension == "" -> :unknown
      extension_allowed?(extension) -> :text
      true -> :binary
    end
  end

  defp content_type_capability(content_type) when is_binary(content_type) do
    if content_type_allowed?(content_type), do: :text, else: :binary
  end

  defp content_type_capability(_content_type), do: :unknown

  defp response_text_body(%{body: body}) when is_binary(body), do: body
  defp response_text_body(%{body: body}) when is_list(body), do: IO.iodata_to_binary(body)
  defp response_text_body(_response), do: nil

  defp response_content_type(%Req.Response{} = response),
    do: response |> Req.Response.get_header("content-type") |> List.first()

  defp response_content_type(%{headers: headers}) when is_map(headers) do
    headers
    |> Map.get("content-type")
    |> first_header_value()
  end

  defp response_content_type(%{headers: headers}) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == "content-type", do: value, else: nil

      _ ->
        nil
    end)
    |> first_header_value()
  end

  defp response_content_type(_response), do: nil

  defp first_header_value([value | _]) when is_binary(value), do: value
  defp first_header_value(value) when is_binary(value), do: value
  defp first_header_value(_value), do: nil

  defp normalize_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> List.first()
    |> normalize_optional_string()
  end

  defp normalize_content_type(_content_type), do: nil

  defp extension_content_type("csv"), do: "text/csv"
  defp extension_content_type("json"), do: "application/json"
  defp extension_content_type("log"), do: "text/plain"
  defp extension_content_type("markdown"), do: "text/markdown"
  defp extension_content_type("md"), do: "text/markdown"
  defp extension_content_type("text"), do: "text/plain"
  defp extension_content_type("tsv"), do: "text/tab-separated-values"
  defp extension_content_type("txt"), do: "text/plain"
  defp extension_content_type("xml"), do: "application/xml"
  defp extension_content_type("yaml"), do: "application/yaml"
  defp extension_content_type("yml"), do: "application/yaml"
  defp extension_content_type(_extension), do: nil

  defp capped_utf8_text(text) when is_binary(text) do
    {truncated, truncated?} = utf8_prefix(text, @max_execution_attachment_content_bytes)

    if String.valid?(truncated) do
      {:ok, truncated, truncated?}
    else
      :error
    end
  end

  defp utf8_prefix(binary, max_bytes) when is_binary(binary) and is_integer(max_bytes) and max_bytes >= 0 do
    utf8_prefix(binary, max_bytes, <<>>, false)
  end

  defp utf8_prefix(<<>>, _remaining, acc, truncated?), do: {acc, truncated?}
  defp utf8_prefix(_rest, remaining, acc, _truncated?) when remaining <= 0, do: {acc, true}

  defp utf8_prefix(<<codepoint::utf8, rest::binary>>, remaining, acc, truncated?) do
    char = <<codepoint::utf8>>
    char_size = byte_size(char)

    if char_size <= remaining do
      utf8_prefix(rest, remaining - char_size, <<acc::binary, char::binary>>, truncated?)
    else
      {acc, true}
    end
  end

  defp utf8_prefix(_invalid, _remaining, acc, _truncated?), do: {acc, true}

  defp linear_attachment_download_fun(token) when is_binary(token) do
    fn url, opts ->
      download_linear_attachment_content(url, token, opts)
    end
  end

  defp linear_attachment_download_fun(_token), do: &default_test_attachment_download/2

  defp download_linear_attachment_content(url, token, opts)
       when is_binary(url) and is_binary(token) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @execution_attachment_download_timeout_ms)
    normalized_token = String.trim(token)
    auth_header = [{"Authorization", normalized_token}]

    with {:error, {:http_status, status}} when status in [401, 403] <- request_linear_upload(url, auth_header, timeout),
         false <- String.starts_with?(normalized_token, "Bearer "),
         bearer when byte_size(bearer) > byte_size("Bearer ") <- "Bearer " <> normalized_token do
      request_linear_upload(url, [{"Authorization", bearer}], timeout)
    else
      result -> result
    end
  end

  defp download_linear_attachment_content(_url, _token, _opts), do: {:error, :invalid_download_request}

  defp request_linear_upload(url, headers, timeout)
       when is_binary(url) and is_list(headers) and is_integer(timeout) do
    case Req.get(url,
           headers: headers,
           decode_body: false,
           compressed: false,
           into: &collect_bounded_response_body/2,
           connect_options: [timeout: timeout]
         ) do
      {:ok, %{status: 200} = response} ->
        {:ok, with_bounded_response_body(response)}

      {:ok, response} ->
        {:error, {:http_status, response.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_bounded_response_body({:data, data}, {request, response})
       when is_binary(data) and is_map(request) do
    current = Req.Response.get_private(response, @ingested_attachment_body_private_key, <<>>)
    remaining = @max_execution_attachment_download_bytes - byte_size(current)

    cond do
      remaining <= 0 ->
        {:halt, {request, response}}

      byte_size(data) <= remaining ->
        updated_response =
          Req.Response.put_private(response, @ingested_attachment_body_private_key, <<current::binary, data::binary>>)

        {:cont, {request, updated_response}}

      true ->
        chunk = binary_part(data, 0, remaining)

        updated_response =
          Req.Response.put_private(response, @ingested_attachment_body_private_key, <<current::binary, chunk::binary>>)

        {:halt, {request, updated_response}}
    end
  end

  defp collect_bounded_response_body(_other, {request, response}), do: {:cont, {request, response}}

  defp with_bounded_response_body(%Req.Response{} = response) do
    body = Req.Response.get_private(response, @ingested_attachment_body_private_key, <<>>)
    %{response | body: body}
  end

  defp default_test_attachment_download(_url, _opts), do: {:error, :download_not_configured}

  defp normalize_execution_comments(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_execution_comment/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&comment_sort_key/1, {:desc, DateTime})
  end

  defp normalize_execution_comments(_comments), do: []

  defp normalize_execution_comment(%{} = comment) do
    body = normalize_optional_string(comment["body"])

    cond do
      is_nil(body) ->
        nil

      workpad_comment_body?(body) ->
        nil

      true ->
        %{
          "id" => normalize_optional_string(comment["id"]),
          "body" => body,
          "created_at" => parse_datetime(comment["createdAt"]),
          "updated_at" => parse_datetime(comment["updatedAt"]),
          "author_name" => normalize_optional_string(get_in(comment, ["user", "name"]))
        }
    end
  end

  defp normalize_execution_comment(_comment), do: nil

  defp comment_sort_key(%{"created_at" => %DateTime{} = created_at}), do: created_at
  defp comment_sort_key(_comment), do: ~U[1970-01-01 00:00:00Z]

  defp workpad_comment_body?(body) when is_binary(body) do
    String.contains?(body, "## Codex Workpad") or
      String.contains?(body, "## Рабочий журнал Codex")
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
