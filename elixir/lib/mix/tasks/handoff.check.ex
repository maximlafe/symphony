defmodule Mix.Tasks.Handoff.Check do
  use Mix.Task

  @shortdoc "Run the Symphony handoff verification contract"

  @moduledoc """
  Runs the repo-owned handoff verification contract and prints the resulting manifest.

      mix handoff.check --issue LET-416 --workpad ../workpad.md --repo maximlafe/symphony --pr 52 --phase review
  """

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client

  @switches [
    issue: :string,
    workpad: :string,
    repo: :string,
    pr: :integer,
    phase: :string,
    profile: :string,
    manifest: :string
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown options: #{inspect(invalid)}")
    end

    issue_id = required_option!(opts, :issue, "--issue")
    workpad_path = required_option!(opts, :workpad, "--workpad")
    repo = required_option!(opts, :repo, "--repo")
    pr_number = required_option!(opts, :pr, "--pr")

    verification = Config.settings!().verification
    workspace = workpad_path |> Path.expand() |> Path.dirname()
    manifest_path = Keyword.get(opts, :manifest) || verification.manifest_path

    response =
      DynamicTool.execute(
        "symphony_handoff_check",
        %{
          "issue_id" => issue_id,
          "file_path" => workpad_path,
          "repo" => repo,
          "pr_number" => pr_number,
          "phase" => Keyword.get(opts, :phase) || "review",
          "profile" => Keyword.get(opts, :profile) || verification.profile,
          "manifest_path" => manifest_path
        },
        workspace: workspace,
        linear_client: &Client.graphql/3
      )

    payload = response |> decode_payload() |> IO.iodata_to_binary()
    Mix.shell().info(payload)

    if response["success"] == true do
      :ok
    else
      Mix.raise("handoff verification failed")
    end
  end

  defp required_option!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> Mix.raise("Missing required option #{flag}")
      value -> value
    end
  end

  defp decode_payload(%{"contentItems" => [%{"text" => text}]}), do: text
  defp decode_payload(_response), do: Jason.encode!(%{"error" => %{"message" => "unexpected handoff.check response"}}, pretty: true)
end
