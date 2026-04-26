defmodule SymphonyElixir.PrEvidenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrEvidence

  test "resolve/1 fails closed for non-map input" do
    assert PrEvidence.resolve("not-a-map") == %{
             "source" => "none",
             "repo" => nil,
             "pr_number" => nil,
             "url" => nil
           }
  end

  test "resolve/2 fails closed for invalid opts and invalid marker repo hint" do
    assert PrEvidence.resolve(%{}, :invalid_opts) == %{
             "source" => "none",
             "repo" => nil,
             "pr_number" => nil,
             "url" => nil
           }

    assert PrEvidence.resolve(%{"repo" => "invalid repo", "workpad_body" => "continue PR #12"}) == %{
             "source" => "none",
             "repo" => nil,
             "pr_number" => nil,
             "url" => nil
           }
  end

  test "workspace checkpoint source resolves canonical open_pr payload" do
    assert PrEvidence.resolve(%{
             "repo" => "maximlafe/symphony",
             "workspace_checkpoint" => %{
               "open_pr" => %{
                 "number" => "123",
                 "url" => "https://github.com/maximlafe/symphony/pull/123"
               }
             }
           }) == %{
             "source" => "workspace_checkpoint",
             "repo" => "maximlafe/symphony",
             "pr_number" => 123,
             "url" => "https://github.com/maximlafe/symphony/pull/123"
           }

    assert PrEvidence.resolve(%{
             "repo" => "maximlafe/symphony",
             "workspace_checkpoint" => %{
               "open_pr" => %{
                 "number" => "123x",
                 "url" => "https://example.com/not-a-pull-url"
               }
             }
           })["source"] == "none"
  end

  test "workspace checkpoint path source resolves and handles invalid path/decode" do
    path = Path.join(System.tmp_dir!(), "pr-evidence-checkpoint-#{System.unique_integer([:positive])}.json")
    bad_path = Path.join(System.tmp_dir!(), "pr-evidence-checkpoint-bad-#{System.unique_integer([:positive])}.json")
    missing_path = Path.join(System.tmp_dir!(), "pr-evidence-checkpoint-missing-#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      File.rm(path)
      File.rm(bad_path)
    end)

    File.write!(
      path,
      Jason.encode!(%{
        "open_pr" => %{"url" => "https://github.com/openai/symphony/pull/124"}
      })
    )

    File.write!(bad_path, "{not-json")

    assert PrEvidence.resolve(%{
             "repo" => "maximlafe/symphony",
             "workspace_checkpoint_path" => path
           }) == %{
             "source" => "workspace_checkpoint",
             "repo" => "openai/symphony",
             "pr_number" => 124,
             "url" => "https://github.com/openai/symphony/pull/124"
           }

    assert PrEvidence.resolve(%{
             "repo" => "maximlafe/symphony",
             "workspace_checkpoint_path" => bad_path
           })["source"] == "none"

    assert PrEvidence.resolve(%{
             "repo" => "maximlafe/symphony",
             "workspace_checkpoint_path" => missing_path
           })["source"] == "none"
  end

  test "workpad and comment sources parse url and marker evidence" do
    assert PrEvidence.resolve(%{
             "repo" => "maximlafe/symphony",
             "workpad_body" => "handoff from PR #125"
           }) == %{
             "source" => "workpad",
             "repo" => "maximlafe/symphony",
             "pr_number" => 125,
             "url" => "https://github.com/maximlafe/symphony/pull/125"
           }

    assert PrEvidence.resolve(%{
             "issue_comments" => [
               %{"body" => "see https://github.com/maximlafe/symphony/pull/126"},
               "PR #999"
             ]
           }) == %{
             "source" => "issue_comment",
             "repo" => "maximlafe/symphony",
             "pr_number" => 126,
             "url" => "https://github.com/maximlafe/symphony/pull/126"
           }

    assert PrEvidence.resolve(%{
             "repo" => "maximlafe/symphony",
             "issue_comments" => [42, %{not_body: true}, "PR #127"]
           }) == %{
             "source" => "issue_comment",
             "repo" => "maximlafe/symphony",
             "pr_number" => 127,
             "url" => "https://github.com/maximlafe/symphony/pull/127"
           }
  end

  test "attachment source prefers url then marker fallback and ignores invalid entries" do
    assert PrEvidence.resolve(%{
             "issue_attachments" => [
               %{"title" => "artifact", "url" => "https://github.com/openai/symphony/pull/128"}
             ]
           }) == %{
             "source" => "issue_attachment",
             "repo" => "openai/symphony",
             "pr_number" => 128,
             "url" => "https://github.com/openai/symphony/pull/128"
           }

    assert PrEvidence.resolve(%{
             "repo" => "maximlafe/symphony",
             "issue_attachments" => [
               10,
               %{"title" => "follow-up PR #129", "subtitle" => ""},
               %{"title" => "PR #130"}
             ]
           }) == %{
             "source" => "issue_attachment",
             "repo" => "maximlafe/symphony",
             "pr_number" => 129,
             "url" => "https://github.com/maximlafe/symphony/pull/129"
           }
  end

  test "branch lookup source supports both {:ok, map} and map lookup results" do
    assert PrEvidence.resolve(
             %{
               "repo" => "maximlafe/symphony",
               "issue_branch_name" => "feature/parity-04"
             },
             branch_lookup_fun: fn "maximlafe/symphony", "feature/parity-04" ->
               {:ok, %{"url" => "https://github.com/maximlafe/symphony/pull/131"}}
             end
           ) == %{
             "source" => "branch_lookup",
             "repo" => "maximlafe/symphony",
             "pr_number" => 131,
             "url" => "https://github.com/maximlafe/symphony/pull/131"
           }

    assert PrEvidence.resolve(
             %{
               "repo" => "maximlafe/symphony",
               "issue_branch_name" => "feature/parity-04-direct"
             },
             branch_lookup_fun: fn _repo, _branch ->
               %{"number" => 132, "url" => ""}
             end
           ) == %{
             "source" => "branch_lookup",
             "repo" => "maximlafe/symphony",
             "pr_number" => 132,
             "url" => "https://github.com/maximlafe/symphony/pull/132"
           }
  end

  test "branch lookup fails closed when lookup is unavailable or invalid" do
    assert PrEvidence.resolve(
             %{
               "repo" => "maximlafe/symphony",
               "issue_branch_name" => "feature/unknown"
             },
             branch_lookup_fun: fn _repo, _branch -> :not_found end
           )["source"] == "none"

    assert PrEvidence.resolve(
             %{
               "repo" => "maximlafe/symphony",
               "issue_branch_name" => "feature/invalid"
             },
             branch_lookup_fun: fn _repo, _branch -> %{"number" => 0} end
           )["source"] == "none"

    assert PrEvidence.resolve(
             %{
               "repo" => "maximlafe/symphony",
               "issue_branch_name" => "feature/no-fun"
             },
             branch_lookup_fun: "not-a-function"
           )["source"] == "none"
  end

  test "source precedence keeps workspace evidence when all sources are present" do
    assert PrEvidence.resolve(
             %{
               "repo" => "maximlafe/symphony",
               "workspace_checkpoint" => %{
                 "open_pr" => %{
                   "number" => 200,
                   "url" => "https://github.com/maximlafe/symphony/pull/200"
                 }
               },
               "workpad_body" => "PR #901",
               "issue_comments" => [%{"body" => "https://github.com/maximlafe/symphony/pull/902"}],
               "issue_attachments" => [%{"url" => "https://github.com/maximlafe/symphony/pull/903"}],
               "issue_branch_name" => "feature/all-sources"
             },
             branch_lookup_fun: fn _repo, _branch -> %{"url" => "https://github.com/maximlafe/symphony/pull/904"} end
           ) == %{
             "source" => "workspace_checkpoint",
             "repo" => "maximlafe/symphony",
             "pr_number" => 200,
             "url" => "https://github.com/maximlafe/symphony/pull/200"
           }
  end
end
