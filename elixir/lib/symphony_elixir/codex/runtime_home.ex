defmodule SymphonyElixir.Codex.RuntimeHome do
  @moduledoc false

  alias SymphonyElixir.Config

  @config_file "config.toml"
  @auth_file "auth.json"
  @skills_dir "skills"
  @runtime_root_dir ".codex-runtime/homes"

  @spec prepare(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def prepare(source_home) when is_binary(source_home) do
    expanded_source_home = Path.expand(source_home)

    if runtime_home?(expanded_source_home) do
      {:ok, expanded_source_home}
    else
      runtime_home = runtime_home_path(expanded_source_home)

      with :ok <- File.mkdir_p(runtime_home),
           :ok <- sync_auth(expanded_source_home, runtime_home),
           :ok <- sync_config(expanded_source_home, runtime_home),
           :ok <- sync_skills(expanded_source_home, runtime_home) do
        {:ok, runtime_home}
      end
    end
  end

  def prepare(_source_home), do: {:error, :invalid_codex_home}

  defp sync_auth(source_home, runtime_home) do
    source = Path.join(source_home, @auth_file)
    target = Path.join(runtime_home, @auth_file)

    sync_optional_file(source, target)
  end

  defp sync_config(source_home, runtime_home) do
    source = Path.join(source_home, @config_file)
    target = Path.join(runtime_home, @config_file)

    case File.read(source) do
      {:ok, contents} ->
        filtered = strip_plugin_tables(contents)

        case String.trim(filtered) do
          "" ->
            remove_managed_path(target)

          _ ->
            write_if_changed(target, filtered)
        end

      {:error, :enoent} ->
        remove_managed_path(target)

      {:error, reason} ->
        {:error, {:runtime_home_config_read_failed, source, reason}}
    end
  end

  defp sync_skills(source_home, runtime_home) do
    source = Path.join(source_home, @skills_dir)
    target = Path.join(runtime_home, @skills_dir)

    case File.dir?(source) do
      true ->
        sync_symlink(source, target)

      false ->
        remove_managed_path(target)
    end
  end

  defp sync_optional_file(source, target) do
    case File.read(source) do
      {:ok, contents} ->
        write_if_changed(target, contents)

      {:error, :enoent} ->
        remove_managed_path(target)

      {:error, reason} ->
        {:error, {:runtime_home_file_read_failed, source, reason}}
    end
  end

  defp write_if_changed(target, contents) when is_binary(target) and is_binary(contents) do
    case File.read(target) do
      {:ok, ^contents} ->
        :ok

      {:ok, _different_contents} ->
        File.write(target, contents)

      {:error, :enoent} ->
        File.write(target, contents)

      {:error, reason} ->
        {:error, {:runtime_home_file_read_failed, target, reason}}
    end
  end

  defp sync_symlink(source, target) do
    with :ok <- remove_managed_path(target) do
      case File.ln_s(source, target) do
        :ok -> :ok
        {:error, reason} -> {:error, {:runtime_home_symlink_failed, source, target, reason}}
      end
    end
  end

  defp remove_managed_path(path) do
    case File.rm_rf(path) do
      {:ok, _paths} -> :ok
      {:error, reason, _path} -> {:error, {:runtime_home_remove_failed, path, reason}}
    end
  end

  defp runtime_home_path(source_home) do
    Path.join([runtime_root(), runtime_home_name(source_home)])
  end

  defp runtime_root do
    Path.join(Config.settings!().workspace.root, @runtime_root_dir)
  end

  defp runtime_home?(path) do
    runtime_root = Path.expand(runtime_root())
    expanded_path = Path.expand(path)

    String.starts_with?(expanded_path <> "/", runtime_root <> "/")
  end

  defp runtime_home_name(source_home) do
    source_home
    |> Path.basename()
    |> sanitize_segment()
    |> Kernel.<>("-" <> short_hash(source_home))
  end

  defp sanitize_segment(segment) when is_binary(segment) do
    String.replace(segment, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp short_hash(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
  end

  defp strip_plugin_tables(contents) when is_binary(contents) do
    {lines, _skip?} =
      contents
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], false}, &reduce_config_line/2)

    Enum.reverse(lines)
    |> Enum.join("\n")
  end

  defp reduce_config_line(line, {acc, skip?}) do
    case table_header(line) do
      nil -> maybe_keep_line(line, acc, skip?)
      table_name -> handle_table_header(line, table_name, acc)
    end
  end

  defp maybe_keep_line(_line, acc, true), do: {acc, true}
  defp maybe_keep_line(line, acc, false), do: {[line | acc], false}

  defp handle_table_header(line, table_name, acc) do
    if plugin_table?(table_name) do
      {acc, true}
    else
      {[line | acc], false}
    end
  end

  defp table_header(line) when is_binary(line) do
    case Regex.run(~r/^\s*\[\[?([^\]]+)\]\]?\s*$/, line, capture: :all_but_first) do
      [table_name] -> table_name
      _ -> nil
    end
  end

  defp plugin_table?(table_name) when is_binary(table_name) do
    trimmed = String.trim(table_name)
    trimmed == "plugins" or String.starts_with?(trimmed, "plugins.")
  end
end
