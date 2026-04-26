defmodule SymphonyElixir.PrEvidence do
  @moduledoc """
  Resolves canonical pull request evidence from legacy tracker/workspace sources.
  """

  @pr_url_regex ~r{https://github\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/pull/(?<number>\d+)}
  @pr_marker_regex ~r/(?i)\bPR\s*#\s*(?<number>\d+)\b/

  @type source :: String.t()

  @type evidence :: map()

  @spec resolve(map()) :: evidence()
  def resolve(input) when is_map(input), do: resolve(input, [])
  def resolve(_input), do: none_evidence()

  @spec resolve(map(), keyword()) :: evidence()
  def resolve(input, opts) when is_map(input) and is_list(opts) do
    repo_hint = normalize_repo_hint(map_any(input, ["repo", :repo]))

    (workspace_checkpoint_evidence(input, repo_hint) ||
       workpad_evidence(input, repo_hint) ||
       issue_comment_evidence(input, repo_hint) ||
       issue_attachment_evidence(input, repo_hint) ||
       branch_lookup_evidence(input, repo_hint, opts))
    |> normalize_none_evidence()
  end

  def resolve(_input, _opts), do: none_evidence()

  defp workspace_checkpoint_evidence(input, repo_hint) when is_map(input) do
    input
    |> workspace_checkpoint_map()
    |> workspace_checkpoint_open_pr()
    |> normalize_open_pr(repo_hint, "workspace_checkpoint")
  end

  defp workspace_checkpoint_map(input) when is_map(input) do
    case map_any(input, ["workspace_checkpoint", :workspace_checkpoint]) do
      %{} = checkpoint ->
        checkpoint

      _ ->
        with path when is_binary(path) <- map_any(input, ["workspace_checkpoint_path", :workspace_checkpoint_path]),
             {:ok, body} <- File.read(path),
             {:ok, decoded} <- Jason.decode(body),
             true <- is_map(decoded) do
          decoded
        else
          _ -> nil
        end
    end
  end

  defp workspace_checkpoint_open_pr(%{} = checkpoint) do
    map_any(checkpoint, ["open_pr", :open_pr])
  end

  defp workspace_checkpoint_open_pr(_checkpoint), do: nil

  defp normalize_open_pr(%{} = open_pr, repo_hint, source) when is_binary(source) do
    url = normalize_optional_string(map_any(open_pr, ["url", :url]))

    number =
      normalize_pr_number(map_any(open_pr, ["number", :number])) ||
        pr_number_from_text(url)

    repo = repo_from_url(url) || repo_hint

    if is_binary(repo) and is_integer(number) and number > 0 do
      build_evidence(repo, number, url, source)
    end
  end

  defp normalize_open_pr(_open_pr, _repo_hint, _source), do: nil

  defp workpad_evidence(input, repo_hint) when is_map(input) do
    map_any(input, ["workpad_body", :workpad_body])
    |> extract_from_text(repo_hint, "workpad")
  end

  defp issue_comment_evidence(input, repo_hint) when is_map(input) do
    case map_any(input, ["issue_comments", :issue_comments]) do
      comments when is_list(comments) ->
        Enum.find_value(comments, fn comment ->
          comment_body(comment)
          |> extract_from_text(repo_hint, "issue_comment")
        end)

      _ ->
        nil
    end
  end

  defp issue_attachment_evidence(input, repo_hint) when is_map(input) do
    case map_any(input, ["issue_attachments", :issue_attachments]) do
      attachments when is_list(attachments) ->
        Enum.find_value(attachments, &attachment_evidence(&1, repo_hint))

      _ ->
        nil
    end
  end

  defp branch_lookup_evidence(input, repo_hint, opts) when is_map(input) and is_list(opts) do
    lookup_fun = Keyword.get(opts, :branch_lookup_fun)
    branch_name = normalize_optional_string(map_any(input, ["issue_branch_name", :issue_branch_name]))

    if is_binary(repo_hint) and is_binary(branch_name) and is_function(lookup_fun, 2) do
      case lookup_fun.(repo_hint, branch_name) do
        {:ok, result} ->
          normalize_branch_lookup_result(result, repo_hint)

        result when is_map(result) ->
          normalize_branch_lookup_result(result, repo_hint)

        _ ->
          nil
      end
    end
  end

  defp normalize_branch_lookup_result(result, repo_hint) when is_map(result) do
    url = normalize_optional_string(map_any(result, ["url", :url]))
    number = normalize_pr_number(map_any(result, ["number", :number])) || pr_number_from_text(url)
    repo = repo_from_url(url) || repo_hint

    if is_binary(repo) and is_integer(number) and number > 0 do
      build_evidence(repo, number, url, "branch_lookup")
    end
  end

  defp normalize_none_evidence(%{} = evidence), do: evidence
  defp normalize_none_evidence(_value), do: none_evidence()

  defp none_evidence do
    %{
      "source" => "none",
      "repo" => nil,
      "pr_number" => nil,
      "url" => nil
    }
  end

  defp extract_from_text(text, repo_hint, source)
       when is_binary(text) and is_binary(source) do
    case extract_url_evidence(text) do
      %{"repo" => repo, "pr_number" => pr_number, "url" => url} ->
        build_evidence(repo, pr_number, url, source)

      nil ->
        case extract_marker_pr_number(text) do
          pr_number when is_integer(pr_number) and is_binary(repo_hint) ->
            build_evidence(repo_hint, pr_number, nil, source)

          _ ->
            nil
        end
    end
  end

  defp extract_from_text(_text, _repo_hint, _source), do: nil

  defp extract_url_evidence(text) when is_binary(text) do
    case Regex.named_captures(@pr_url_regex, text) do
      %{"owner" => owner, "repo" => repo, "number" => number} ->
        pr_number = String.to_integer(number)
        repo_full = "#{owner}/#{repo}"
        %{"repo" => repo_full, "pr_number" => pr_number, "url" => "https://github.com/#{repo_full}/pull/#{pr_number}"}

      _ ->
        nil
    end
  end

  defp attachment_evidence(attachment, repo_hint) do
    case attachment_url(attachment)
         |> extract_from_text(repo_hint, "issue_attachment") do
      %{} = evidence ->
        evidence

      _ ->
        attachment_marker_text(attachment)
        |> extract_from_text(repo_hint, "issue_attachment")
    end
  end

  defp extract_marker_pr_number(text) when is_binary(text) do
    case Regex.named_captures(@pr_marker_regex, text) do
      %{"number" => number} ->
        String.to_integer(number)

      _ ->
        nil
    end
  end

  defp pr_number_from_text(text) when is_binary(text) do
    case extract_url_evidence(text) do
      %{"pr_number" => pr_number} -> pr_number
      _ -> nil
    end
  end

  defp pr_number_from_text(_text), do: nil

  defp repo_from_url(url) when is_binary(url) do
    case extract_url_evidence(url) do
      %{"repo" => repo} -> repo
      _ -> nil
    end
  end

  defp repo_from_url(_url), do: nil

  defp build_evidence(repo, pr_number, url, source)
       when is_binary(repo) and is_integer(pr_number) and is_binary(source) do
    %{
      "repo" => repo,
      "pr_number" => pr_number,
      "url" => url || "https://github.com/#{repo}/pull/#{pr_number}",
      "source" => source
    }
  end

  defp comment_body(%{} = comment) do
    map_any(comment, ["body", :body])
  end

  defp comment_body(comment) when is_binary(comment), do: comment
  defp comment_body(_comment), do: nil

  defp attachment_url(%{} = attachment) do
    map_any(attachment, ["url", :url])
  end

  defp attachment_url(_attachment), do: nil

  defp attachment_marker_text(%{} = attachment) do
    [map_any(attachment, ["title", :title]), map_any(attachment, ["subtitle", :subtitle])]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp attachment_marker_text(_attachment), do: ""

  defp normalize_pr_number(value) when is_integer(value) and value > 0, do: value

  defp normalize_pr_number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {pr_number, ""} when pr_number > 0 -> pr_number
      _ -> nil
    end
  end

  defp normalize_pr_number(_value), do: nil

  defp normalize_repo_hint(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, trimmed), do: trimmed
  end

  defp normalize_repo_hint(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp map_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end
end
