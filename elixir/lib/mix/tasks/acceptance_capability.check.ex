defmodule Mix.Tasks.AcceptanceCapability.Check do
  use Mix.Task

  @shortdoc "Validate explicit issue acceptance capabilities for the current workspace"

  @moduledoc """
  Validates the `Required capabilities:` line from an issue task-spec against
  the current workspace and environment.

  Usage:

      mix acceptance_capability.check --workspace /path/to/workspace --description-file issue.md

  When options are omitted, the task reads:

  - `SYMPHONY_ISSUE_DESCRIPTION`
  - current working directory as the workspace
  """

  alias SymphonyElixir.AcceptanceCapability

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [workspace: :string, description_file: :string, help: :boolean],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        workspace = Path.expand(opts[:workspace] || File.cwd!())
        description = description(opts[:description_file])

        case AcceptanceCapability.evaluate(workspace, %{"description" => description}) do
          {:ok, report} ->
            Mix.shell().info("Acceptance capability preflight passed: #{summary(report)}")

          {:error, report} ->
            Mix.raise(AcceptanceCapability.summarize_failure(report))
        end
    end
  end

  defp description(path) when is_binary(path) do
    path
    |> Path.expand()
    |> File.read!()
  end

  defp description(_path), do: System.get_env("SYMPHONY_ISSUE_DESCRIPTION") || ""

  defp summary(%{"required_capabilities" => [], "ignored_capabilities" => []}),
    do: "no explicit required capabilities"

  defp summary(%{"required_capabilities" => [], "ignored_capabilities" => ignored}) do
    "no explicit required capabilities; ignored execution-only values: #{Enum.join(ignored, ", ")}"
  end

  defp summary(%{"required_capabilities" => capabilities, "ignored_capabilities" => []}) do
    Enum.join(capabilities, ", ")
  end

  defp summary(%{"required_capabilities" => capabilities, "ignored_capabilities" => ignored}) do
    "#{Enum.join(capabilities, ", ")}; ignored execution-only values: #{Enum.join(ignored, ", ")}"
  end
end
