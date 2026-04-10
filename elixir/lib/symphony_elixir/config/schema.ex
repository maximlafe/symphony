defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:team_key, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])

      field(:manual_intervention_state, :string, default: "Blocked")

      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :team_key,
          :assignee,
          :active_states,
          :manual_intervention_state,
          :terminal_states
        ],
        empty_values: []
      )
      |> update_change(:project_slug, &normalize_optional_string/1)
      |> update_change(:team_key, &normalize_optional_string/1)
      |> update_change(:manual_intervention_state, &String.trim/1)
      |> validate_length(:manual_intervention_state, min: 1)
      |> validate_linear_polling_scope()
    end

    defp validate_linear_polling_scope(changeset) do
      project_slug = get_field(changeset, :project_slug)
      team_key = get_field(changeset, :team_key)

      if is_binary(project_slug) and is_binary(team_key) do
        add_error(
          changeset,
          :team_key,
          "must not be set when tracker.project_slug is configured; choose exactly one Linear polling scope"
        )
      else
        changeset
      end
    end

    defp normalize_optional_string(value) when is_binary(value) do
      case String.trim(value) do
        "" -> nil
        normalized -> normalized
      end
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
      field(:cleanup_keep_recent, :integer, default: 5)
      field(:warning_threshold_bytes, :integer, default: 10 * 1024 * 1024 * 1024)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root, :cleanup_keep_recent, :warning_threshold_bytes], empty_values: [])
      |> validate_number(:cleanup_keep_recent, greater_than_or_equal_to: 0)
      |> validate_number(:warning_threshold_bytes, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    defmodule Account do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field(:id, :string)
        field(:codex_home, :string)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:id, :codex_home], empty_values: [])
        |> validate_required([:id, :codex_home])
      end
    end

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")
      field(:planning_command, :string)
      field(:implementation_command, :string)

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      field(:minimum_remaining_percent, :integer, default: 5)
      field(:monitored_windows_mins, {:array, :integer}, default: [300, 10_080])

      embeds_many(:accounts, Account, on_replace: :delete)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :planning_command,
          :implementation_command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms,
          :minimum_remaining_percent,
          :monitored_windows_mins
        ],
        empty_values: []
      )
      |> cast_embed(:accounts, with: &Account.changeset/2)
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:minimum_remaining_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
      |> update_change(:monitored_windows_mins, &SymphonyElixir.Config.Schema.normalize_monitored_windows/1)
      |> SymphonyElixir.Config.Schema.validate_monitored_windows(:monitored_windows_mins)
      |> SymphonyElixir.Config.Schema.validate_unique_codex_account_ids()
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Verification do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @supported_profiles ["ui", "data-extraction", "runtime", "generic"]
    @default_profile_labels %{
      "ui" => "verification:ui",
      "data-extraction" => "verification:data-extraction",
      "runtime" => "verification:runtime",
      "generic" => "verification:generic"
    }
    @default_review_ready_states ["In Review", "Human Review"]
    @default_manifest_path ".symphony/verification/handoff-manifest.json"

    @primary_key false
    embedded_schema do
      field(:profile, :string)
      field(:profile_labels, :map, default: @default_profile_labels)
      field(:review_ready_states, {:array, :string}, default: @default_review_ready_states)
      field(:manifest_path, :string, default: @default_manifest_path)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:profile, :profile_labels, :review_ready_states, :manifest_path], empty_values: [])
      |> update_change(:profile, &normalize_optional_string/1)
      |> validate_inclusion(:profile, @supported_profiles)
      |> update_change(:profile_labels, &normalize_profile_labels/1)
      |> validate_profile_labels()
      |> update_change(:review_ready_states, &normalize_review_ready_states/1)
      |> validate_review_ready_states()
      |> update_change(:manifest_path, &normalize_manifest_path/1)
      |> validate_length(:manifest_path, min: 1)
    end

    defp normalize_optional_string(nil), do: nil

    defp normalize_optional_string(value) when is_binary(value) do
      case String.trim(value) do
        "" -> nil
        normalized -> normalized
      end
    end

    defp normalize_optional_string(value), do: value

    defp normalize_profile_labels(nil), do: @default_profile_labels

    defp normalize_profile_labels(labels) when is_map(labels) do
      Enum.reduce(labels, %{}, fn {profile, label}, acc ->
        normalized_profile =
          profile
          |> to_string()
          |> String.trim()

        normalized_label =
          label
          |> to_string()
          |> String.trim()

        Map.put(acc, normalized_profile, normalized_label)
      end)
    end

    defp normalize_profile_labels(_labels), do: @default_profile_labels

    defp validate_profile_labels(changeset) do
      validate_change(changeset, :profile_labels, fn :profile_labels, labels ->
        keys = Map.keys(labels)
        values = Map.values(labels)

        cond do
          Enum.any?(keys, &(&1 == "" or &1 not in @supported_profiles)) ->
            [profile_labels: "profile_labels keys must be one of #{Enum.join(@supported_profiles, ", ")}"]

          Enum.any?(values, &(&1 == "")) ->
            [profile_labels: "profile_labels values must not be blank"]

          length(values) != length(Enum.uniq(values)) ->
            [profile_labels: "profile_labels values must be unique"]

          true ->
            []
        end
      end)
    end

    defp normalize_review_ready_states(nil), do: @default_review_ready_states

    defp normalize_review_ready_states(states) when is_list(states) do
      Enum.map(states, fn
        value when is_binary(value) -> String.trim(value)
        value -> value |> to_string() |> String.trim()
      end)
    end

    defp normalize_review_ready_states(_states), do: @default_review_ready_states

    defp validate_review_ready_states(changeset) do
      validate_change(changeset, :review_ready_states, fn :review_ready_states, states ->
        cond do
          not is_list(states) or states == [] ->
            [review_ready_states: "review_ready_states must include at least one state"]

          Enum.any?(states, &(&1 == "")) ->
            [review_ready_states: "review_ready_states must not contain blank values"]

          true ->
            []
        end
      end)
    end

    defp normalize_manifest_path(value) when is_binary(value) do
      value
      |> String.trim()
      |> case do
        "" -> @default_manifest_path
        normalized -> normalized
      end
    end

    defp normalize_manifest_path(_value), do: @default_manifest_path
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
      field(:path, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host, :path], empty_values: [])
      |> update_change(:host, &normalize_optional_string/1)
      |> update_change(:path, &normalize_optional_path_token/1)
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end

    defp normalize_optional_string(value) when is_binary(value) do
      case String.trim(value) do
        "" -> nil
        normalized -> normalized
      end
    end

    defp normalize_optional_path_token(value) when is_binary(value) do
      case env_reference_name(value) do
        {:ok, _env_name} -> value
        :error -> normalize_optional_path(value)
      end
    end

    defp normalize_optional_path(value) when is_binary(value) do
      case String.trim(value) do
        "" ->
          nil

        "/" ->
          "/"

        trimmed ->
          trimmed
          |> String.trim_trailing("/")
          |> ensure_leading_slash()
      end
    end

    defp ensure_leading_slash("/" <> _ = path), do: path
    defp ensure_leading_slash(path), do: "/" <> path

    defp env_reference_name("$" <> env_name) do
      if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
        {:ok, env_name}
      else
        :error
      end
    end

    defp env_reference_name(_value), do: :error
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:verification, Verification, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        finalize_settings(settings)

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        default_turn_sandbox_policy(workspace || settings.workspace.root)
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        default_runtime_turn_sandbox_policy(workspace || settings.workspace.root)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec normalize_monitored_windows(nil | list()) :: [integer()]
  def normalize_monitored_windows(nil), do: []

  def normalize_monitored_windows(windows) when is_list(windows) do
    windows
    |> Enum.reduce([], fn
      window, acc when is_integer(window) -> acc ++ [window]
      _window, acc -> acc
    end)
    |> Enum.uniq()
  end

  def normalize_monitored_windows(_windows), do: []

  @doc false
  @spec validate_monitored_windows(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_monitored_windows(changeset, field) do
    validate_change(changeset, field, fn ^field, windows ->
      cond do
        not is_list(windows) ->
          [{field, "must be a list of positive integers"}]

        windows == [] ->
          [{field, "must contain at least one positive integer"}]

        Enum.any?(windows, fn window -> not is_integer(window) or window <= 0 end) ->
          [{field, "must contain positive integers"}]

        true ->
          []
      end
    end)
  end

  @doc false
  @spec validate_unique_codex_account_ids(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_unique_codex_account_ids(changeset) do
    ids =
      changeset
      |> get_field(:accounts, [])
      |> Enum.map(&codex_account_id/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)

    duplicate_ids =
      ids
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)

    changeset =
      if Enum.any?(ids, &(&1 == "")) do
        add_error(changeset, :accounts, "ids must not be blank")
      else
        changeset
      end

    Enum.reduce(duplicate_ids, changeset, fn id, acc ->
      add_error(acc, :accounts, "duplicate codex account id #{inspect(id)}")
    end)
  end

  defp codex_account_id(%Ecto.Changeset{} = changeset), do: get_field(changeset, :id)
  defp codex_account_id(%{id: id}), do: id
  defp codex_account_id(%{"id" => id}), do: id
  defp codex_account_id(_account), do: nil

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:verification, with: &Verification.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    server = %{
      settings.server
      | host: resolve_server_host(settings.server.host),
        path: resolve_server_path(settings.server.path)
    }

    with {:ok, codex_accounts} <- resolve_codex_accounts(settings.codex.accounts) do
      codex = %{
        settings.codex
        | approval_policy: normalize_keys(settings.codex.approval_policy),
          turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy),
          monitored_windows_mins: normalize_monitored_windows(settings.codex.monitored_windows_mins),
          accounts: codex_accounts
      }

      {:ok, %{settings | tracker: tracker, workspace: workspace, codex: codex, server: server}}
    end
  end

  defp resolve_server_host(nil), do: "127.0.0.1"

  defp resolve_server_host(value) when is_binary(value) do
    case resolve_env_value(value, "127.0.0.1") do
      resolved when is_binary(resolved) ->
        case String.trim(resolved) do
          "" -> "127.0.0.1"
          normalized -> normalized
        end

      _ ->
        "127.0.0.1"
    end
  end

  defp resolve_server_host(_value), do: "127.0.0.1"

  defp resolve_server_path(nil), do: nil

  defp resolve_server_path(value) when is_binary(value) do
    case resolve_env_value(value, nil) do
      nil ->
        nil

      resolved ->
        case String.trim(resolved) do
          "" ->
            nil

          "/" ->
            "/"

          trimmed ->
            "/" <> String.trim_leading(String.trim_trailing(trimmed, "/"), "/")
        end
    end
  end

  defp resolve_server_path(_value), do: nil

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        Path.expand(default)

      "" ->
        Path.expand(default)

      path ->
        Path.expand(path)
    end
  end

  defp resolve_required_path_value(value) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        {:error, "env-backed path is missing"}

      "" ->
        {:error, "path must not be blank"}

      path ->
        {:ok, Path.expand(path)}
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp resolve_codex_accounts(accounts) when is_list(accounts) do
    accounts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{id: id, codex_home: codex_home} = account, index}, {:ok, acc}
      when is_binary(id) and is_binary(codex_home) ->
        case resolve_required_path_value(codex_home) do
          {:ok, resolved_codex_home} ->
            resolved_account = %{account | id: String.trim(id), codex_home: resolved_codex_home}
            {:cont, {:ok, acc ++ [resolved_account]}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_workflow_config, "codex.accounts.#{index}.codex_home #{reason}"}}}
        end

      {_account, index}, _acc ->
        {:halt, {:error, {:invalid_workflow_config, "codex.accounts.#{index} is invalid"}}}
    end)
  end

  defp resolve_codex_accounts(_accounts), do: {:ok, []}

  defp default_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and workspace != "" do
        Path.expand(workspace)
      else
        Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root) when is_binary(workspace_root) do
    with {:ok, canonical_workspace_root} <- PathSafety.canonicalize(workspace_root) do
      {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
