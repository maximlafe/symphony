defmodule SymphonyElixir.Codex.SkillSync do
  @moduledoc """
  Keeps bundled Symphony worker skills available in every configured `CODEX_HOME`.
  """

  require Logger

  alias SymphonyElixir.Config

  @source_root_env "SYMPHONY_BUNDLED_SKILLS_ROOT"

  @spec sync_configured_homes(keyword()) :: :ok
  def sync_configured_homes(opts \\ []) when is_list(opts) do
    source_root = Keyword.get_lazy(opts, :source_root, &bundled_skills_root/0)
    codex_homes = Keyword.get_lazy(opts, :codex_homes, &configured_codex_homes/0)

    case sync_codex_homes(codex_homes, source_root) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Bundled worker skill sync skipped reason=#{inspect(reason)}")
        :ok
    end
  end

  @spec configured_codex_homes() :: [Path.t()]
  def configured_codex_homes do
    [Config.ambient_codex_home() | Enum.map(Config.codex_accounts(), &Map.get(&1, :codex_home))]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  @spec sync_codex_homes([Path.t()], Path.t()) :: :ok | {:error, term()}
  def sync_codex_homes(codex_homes, source_root)
      when is_list(codex_homes) and is_binary(source_root) do
    case bundled_skill_names(source_root) do
      {:ok, bundled_skills} ->
        codex_homes
        |> Enum.map(&Path.expand/1)
        |> Enum.uniq()
        |> sync_expanded_codex_homes(source_root, bundled_skills)

      {:error, _reason} = error ->
        error
    end
  end

  defp sync_codex_home(codex_home, source_root, bundled_skills) do
    skills_root = Path.join(codex_home, "skills")

    case File.mkdir_p(skills_root) do
      :ok ->
        sync_skill_dirs(skills_root, source_root, bundled_skills)

      {:error, reason} ->
        {:error, {:skills_root_create_failed, skills_root, reason}}
    end
  end

  defp sync_expanded_codex_homes(codex_homes, source_root, bundled_skills) do
    Enum.reduce_while(codex_homes, :ok, fn codex_home, :ok ->
      case sync_codex_home(codex_home, source_root, bundled_skills) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sync_skill_dirs(skills_root, source_root, bundled_skills) do
    Enum.reduce_while(bundled_skills, :ok, fn skill, :ok ->
      case copy_skill_dir(source_root, skills_root, skill) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp copy_skill_dir(source_root, skills_root, skill) do
    source = Path.join(source_root, skill)
    target = Path.join(skills_root, skill)

    File.rm_rf(target)

    case File.cp_r(source, target) do
      {:ok, _copied_paths} -> :ok
      {:error, reason, _file} -> {:error, {:skill_copy_failed, source, target, reason}}
    end
  end

  defp bundled_skill_names(source_root) do
    case File.ls(source_root) do
      {:ok, entries} ->
        bundled_skills =
          entries
          |> Enum.filter(&File.dir?(Path.join(source_root, &1)))
          |> Enum.sort()

        case bundled_skills do
          [] -> {:error, {:no_bundled_skills, source_root}}
          _ -> {:ok, bundled_skills}
        end

      {:error, reason} ->
        {:error, {:bundled_skills_unavailable, source_root, reason}}
    end
  end

  defp bundled_skills_root do
    case System.get_env(@source_root_env) do
      value when is_binary(value) and value != "" ->
        Path.expand(value)

      _ ->
        Path.expand("../../../../.agents/skills", __DIR__)
    end
  end
end
