defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Codex.RuntimeHome, Config, PathSafety, WorkspaceCapability}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."
  @foreground_wait_refusal_tools "use exec_background + exec_wait"
  @status_check_refusal_tools "wait for exec_wait progress before repeating git/gh status checks"
  @status_check_quiet_wait_min_interval_ms 20_000
  @wait_guard_process_key :symphony_app_server_wait_guard
  @validation_bundle_patterns [
    {~r/^mix test(\s|$)/, "validation:test"},
    {~r/^make test(\s|$)/, "validation:test"},
    {~r/^make symphony-validate(\s|$)/, "validation:repo-validate"},
    {~r/^make symphony-preflight(\s|$)/, "validation:preflight"},
    {~r/^make symphony-handoff-check(\s|$)/, "validation:handoff-check"},
    {~r/^mix specs\.check(\s|$)/, "validation:specs-check"},
    {~r/^mix dialyzer(\s|$)/, "validation:dialyzer"},
    {~r/^make symphony-runtime-smoke(\s|$)/, "validation:runtime-smoke"},
    {~r/^make symphony-dashboard-checks(\s|$)/, "validation:dashboard-checks"},
    {~r/^make symphony-nginx-proxy-contract(\s|$)/, "validation:nginx-proxy-contract"},
    {~r/^make symphony-nginx-proxy-smoke(\s|$)/, "validation:nginx-proxy-smoke"}
  ]

  @type session :: %{
          port: port(),
          metadata: map(),
          account_id: String.t() | nil,
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t()
        }

  @type client :: %{
          port: port(),
          metadata: map(),
          cwd: Path.t()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <-
           start_session(
             workspace,
             Keyword.merge(opts, issue: issue, trace_id: trace_id_from(issue, opts))
           ) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
         {:ok, session_policies} <- session_policies(expanded_workspace),
         {:ok, _capability_manifest} <-
           WorkspaceCapability.prelaunch_gate(
             expanded_workspace,
             workspace_capability_opts(opts, session_policies)
           ),
         {:ok, port, cost_decision} <-
           start_port(
             expanded_workspace,
             Keyword.get(opts, :command_env, []),
             Keyword.get(opts, :issue),
             Keyword.get(opts, :cost_profile_key),
             Keyword.get(opts, :cost_stage)
           ) do
      account_id = Keyword.get(opts, :account_id)

      metadata =
        port
        |> session_metadata(Keyword.put(opts, :workspace, expanded_workspace), cost_decision)
        |> maybe_put_account_id(account_id)

      case do_start_session(port, expanded_workspace, session_policies) do
        {:ok, thread_id} ->
          {:ok,
           %{
             port: port,
             metadata: metadata,
             account_id: account_id,
             approval_policy: session_policies.approval_policy,
             auto_approve_requests: session_policies.approval_policy == "never",
             thread_sandbox: session_policies.thread_sandbox,
             turn_sandbox_policy: session_policies.turn_sandbox_policy,
             thread_id: thread_id,
             workspace: expanded_workspace
           }}

        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec open_client(Path.t(), keyword()) :: {:ok, client()} | {:error, term()}
  def open_client(cwd \\ System.tmp_dir!(), opts \\ []) do
    expanded_cwd = Path.expand(cwd)

    case start_port(
           expanded_cwd,
           Keyword.get(opts, :command_env, []),
           Keyword.get(opts, :issue),
           Keyword.get(opts, :cost_profile_key),
           Keyword.get(opts, :cost_stage)
         ) do
      {:ok, port, cost_decision} ->
        case send_initialize(port) do
          :ok ->
            metadata =
              port
              |> session_metadata(opts, cost_decision)
              |> maybe_put_account_id(Keyword.get(opts, :account_id))

            {:ok, %{port: port, metadata: metadata, cwd: expanded_cwd}}

          {:error, reason} ->
            stop_port(port)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [ArgumentError, RuntimeError] ->
      {:error, {:open_client_failed, Exception.message(error)}}
  end

  @spec request(client(), String.t(), map() | nil, integer()) :: {:ok, map()} | {:error, term()}
  def request(%{port: port}, method, params \\ nil, request_id)
      when is_binary(method) and is_integer(request_id) do
    message =
      %{"method" => method, "id" => request_id}
      |> maybe_put_params(params)

    send_message(port, message)
    await_response(port, request_id)
  end

  @spec stop_client(client()) :: :ok
  def stop_client(%{port: port}) when is_port(port), do: stop_port(port)
  def stop_client(_client), do: :ok

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          account_id: account_id,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, dynamic_tool_opts(workspace, metadata))
      end)

    with_logger_metadata(metadata, fn ->
      case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
        {:ok, turn_id} ->
          handle_started_turn(
            %{
              port: port,
              on_message: on_message,
              issue: issue,
              metadata: metadata,
              account_id: account_id,
              tool_executor: tool_executor,
              auto_approve_requests: auto_approve_requests,
              thread_id: thread_id
            },
            turn_id
          )

        {:error, reason} ->
          Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
          emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
          {:error, reason}
      end
    end)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp start_port(workspace, command_env, issue, cost_profile_key, cost_stage) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      with {:ok, normalized_command_env} <- normalize_command_env(command_env) do
        cost_decision = Config.codex_cost_decision(cost_decision_context(issue, cost_profile_key, cost_stage))
        command = Map.fetch!(cost_decision, :command)
        log_codex_cost_decision(issue, cost_decision)

        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(command)],
              cd: String.to_charlist(workspace),
              line: @port_line_bytes,
              env: port_env(normalized_command_env)
            ]
          )

        {:ok, port, cost_decision}
      end
    end
  end

  defp cost_decision_context(issue, profile_key, stage_override) when is_binary(profile_key) and profile_key != "" do
    issue
    |> cost_context_map()
    |> Map.put(:cost_profile_key, profile_key)
    |> maybe_put_stage_override(stage_override)
  end

  defp cost_decision_context(issue, _profile_key, stage_override) do
    issue
    |> cost_context_map()
    |> maybe_put_stage_override(stage_override)
  end

  defp maybe_put_stage_override(context, stage_override)
       when is_map(context) and is_binary(stage_override) and stage_override != "" do
    Map.put(context, :phase, stage_override)
  end

  defp maybe_put_stage_override(context, _stage_override), do: context

  defp cost_context_map(%_{} = struct), do: Map.from_struct(struct)
  defp cost_context_map(%{} = map), do: map
  defp cost_context_map(_issue), do: %{}

  defp workspace_capability_opts(opts, %{approval_policy: approval_policy}) when is_list(opts) do
    opts
    |> Keyword.take([:tool_probe, :time_source])
    |> Keyword.put(:approval_policy, approval_policy)
  end

  defp workspace_capability_opts(_opts, _session_policies), do: []

  defp normalize_command_env(command_env) when is_list(command_env) do
    {source_homes, remaining_env} =
      Enum.reduce(command_env, {[], []}, fn
        {"CODEX_HOME", value}, {homes, env} -> {[value | homes], env}
        entry, {homes, env} -> {homes, [entry | env]}
      end)

    case source_homes do
      [] ->
        {:ok, command_env}

      [source_home | _] ->
        with {:ok, runtime_home} <- RuntimeHome.prepare(source_home) do
          {:ok, Enum.reverse([{"CODEX_HOME", runtime_home} | remaining_env])}
        end
    end
  end

  defp normalize_command_env(_command_env), do: {:ok, []}

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{codex_app_server_pid: to_string(os_pid)}

      _ ->
        %{}
    end
  end

  defp session_metadata(port, opts, cost_decision) when is_list(opts) do
    issue = Keyword.get(opts, :issue, %{})
    trace_id = Keyword.get(opts, :trace_id)
    workspace = Keyword.get(opts, :workspace)

    port_metadata(port)
    |> Map.merge(cost_metadata(cost_decision))
    |> maybe_put_metadata(:trace_id, trace_id)
    |> maybe_put_metadata(:issue_id, Map.get(issue, :id))
    |> maybe_put_metadata(:issue_identifier, Map.get(issue, :identifier))
    |> maybe_put_metadata(:workspace, workspace)
  end

  defp log_codex_cost_decision(issue, cost_decision) when is_map(cost_decision) do
    metadata = cost_metadata(cost_decision)
    previous_metadata = Logger.metadata()

    Logger.metadata(Enum.into(metadata, []))

    try do
      Logger.info(
        "Selected Codex cost profile for #{issue_context(issue)} cost_profile_key=#{metadata[:cost_profile_key]} cost_profile_reason=#{metadata[:cost_profile_reason]} cost_stage=#{metadata[:cost_stage]} cost_signals=#{Enum.join(metadata[:cost_signals], ",")} codex_model=#{metadata[:codex_model]} codex_effort=#{metadata[:codex_effort]} command_source=#{metadata[:command_source]}"
      )
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  defp cost_metadata(cost_decision) when is_map(cost_decision) do
    %{
      cost_profile_key: Map.get(cost_decision, :profile_key),
      cost_profile_reason: Map.get(cost_decision, :reason),
      cost_stage: stringify_metadata_value(Map.get(cost_decision, :stage)),
      cost_signals: Enum.map(Map.get(cost_decision, :signals, []), &stringify_metadata_value/1),
      codex_model: Map.get(cost_decision, :model),
      codex_effort: Map.get(cost_decision, :effort),
      command_source: Map.get(cost_decision, :command_source)
    }
  end

  defp stringify_metadata_value(nil), do: nil
  defp stringify_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_metadata_value(value), do: to_string(value)

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace) do
    Config.codex_runtime_settings(workspace)
  end

  defp do_start_session(port, workspace, session_policies) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => Path.expand(workspace),
        "dynamicTools" => DynamicTool.tool_specs()
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => Path.expand(workspace),
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests, base_metadata) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests,
      base_metadata
    )
  end

  defp handle_started_turn(
         %{
           port: port,
           on_message: on_message,
           issue: issue,
           metadata: metadata,
           account_id: account_id,
           tool_executor: tool_executor,
           auto_approve_requests: auto_approve_requests,
           thread_id: thread_id
         },
         turn_id
       ) do
    reset_wait_guard_state()
    session_id = "#{thread_id}-#{turn_id}"
    Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

    emit_message(
      on_message,
      :session_started,
      %{
        session_id: session_id,
        thread_id: thread_id,
        turn_id: turn_id
      },
      metadata
    )

    base_metadata = maybe_put_account_id(metadata, account_id)

    case await_turn_completion(
           port,
           on_message,
           tool_executor,
           auto_approve_requests,
           base_metadata
         ) do
      {:ok, result} ->
        Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

        {:ok,
         %{
           result: result,
           session_id: session_id,
           thread_id: thread_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        emit_message(
          on_message,
          :turn_ended_with_error,
          %{
            session_id: session_id,
            reason: reason
          },
          metadata
        )

        {:error, reason}
    end
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests, base_metadata) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_incoming(
          port,
          on_message,
          complete_line,
          timeout_ms,
          tool_executor,
          auto_approve_requests,
          base_metadata
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests,
          base_metadata
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests, base_metadata) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload, base_metadata)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params"),
          base_metadata
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params"),
          base_metadata
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          %{
            port: port,
            on_message: on_message,
            timeout_ms: timeout_ms,
            tool_executor: tool_executor,
            auto_approve_requests: auto_approve_requests,
            base_metadata: base_metadata
          },
          payload,
          payload_string,
          method
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload, base_metadata)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests, base_metadata)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        emit_message(
          on_message,
          :malformed,
          %{
            payload: payload_string,
            raw: payload_string
          },
          metadata_from_message(port, %{raw: payload_string}, base_metadata)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests, base_metadata)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details, base_metadata) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload, base_metadata)
    )
  end

  defp handle_turn_method(
         %{
           port: port,
           on_message: on_message,
           timeout_ms: timeout_ms,
           tool_executor: tool_executor,
           auto_approve_requests: auto_approve_requests,
           base_metadata: base_metadata
         },
         payload,
         payload_string,
         method
       ) do
    metadata = metadata_from_message(port, payload, base_metadata)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests, base_metadata)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        handle_unhandled_turn_method(
          %{
            port: port,
            on_message: on_message,
            metadata: metadata,
            timeout_ms: timeout_ms,
            tool_executor: tool_executor,
            auto_approve_requests: auto_approve_requests,
            base_metadata: base_metadata
          },
          method,
          payload,
          payload_string
        )
    end
  end

  defp handle_unhandled_turn_method(
         %{
           port: port,
           on_message: on_message,
           metadata: metadata,
           timeout_ms: timeout_ms,
           tool_executor: tool_executor,
           auto_approve_requests: auto_approve_requests,
           base_metadata: base_metadata
         },
         method,
         payload,
         payload_string
       ) do
    if needs_input?(method, payload) do
      emit_message(
        on_message,
        :turn_input_required,
        %{payload: payload, raw: payload_string},
        metadata
      )

      {:error, {:turn_input_required, payload}}
    else
      handle_generic_notification(
        %{
          port: port,
          on_message: on_message,
          metadata: metadata,
          timeout_ms: timeout_ms,
          tool_executor: tool_executor,
          auto_approve_requests: auto_approve_requests,
          base_metadata: base_metadata
        },
        method,
        payload,
        payload_string
      )
    end
  end

  defp handle_generic_notification(
         %{
           port: port,
           on_message: on_message,
           metadata: metadata,
           timeout_ms: timeout_ms,
           tool_executor: tool_executor,
           auto_approve_requests: auto_approve_requests,
           base_metadata: base_metadata
         },
         method,
         payload,
         payload_string
       ) do
    case maybe_handle_direct_exec_wait_policy(
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           auto_approve_requests
         ) do
      {:error, reason} ->
        {:error, reason}

      :unhandled ->
        emit_message(
          on_message,
          :notification,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata
        )

        Logger.debug("Codex notification: #{inspect(method)}")
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests, base_metadata)
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_handle_command_execution_approval_request(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    emit_message(on_message, :tool_call_started, %{payload: payload, raw: payload_string}, metadata)

    {result, dedupe} =
      case maybe_handle_validation_exec_background_dedupe(tool_name, arguments, metadata) do
        {:deduped, deduped_result, dedupe_details} ->
          {deduped_result, dedupe_details}

        :continue ->
          {tool_executor.(tool_name, arguments), nil}
      end

    update_wait_guard_from_tool_result(tool_name, arguments, result, metadata)

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(
      on_message,
      event,
      %{payload: payload, raw: payload_string, result: result, dedupe: dedupe},
      metadata
    )

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_handle_command_execution_approval_request(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp maybe_handle_command_execution_approval_request(
         port,
         id,
         approval_decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    command = payload_command(payload)

    if deny_repeated_status_check?(command) do
      decision = command_execution_refusal_decision(payload)
      send_message(port, %{"id" => id, "result" => %{"decision" => decision}})
      record_status_check_poll(command)

      emit_message(
        on_message,
        :approval_auto_denied,
        %{
          payload: payload,
          raw: payload_string,
          decision: decision,
          command: command,
          command_surface: "approval_path",
          policy_action: "throttled",
          policy_reason: "quiet_wait_status_throttle",
          wait_routing_decision: "quiet_wait_status_throttle",
          suggested_tool_path: @status_check_refusal_tools
        },
        metadata
      )

      :approved
    else
      case command_wait_routing_decision_for_command(command) do
        :background_required ->
          decision = command_execution_refusal_decision(payload)
          send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

          emit_message(
            on_message,
            :approval_auto_denied,
            %{
              payload: payload,
              raw: payload_string,
              decision: decision,
              command: command,
              command_surface: "approval_path",
              policy_action: "rerouted",
              policy_reason: "background_required",
              wait_routing_decision: "background_required",
              suggested_tool_path: @foreground_wait_refusal_tools
            },
            metadata
          )

          :approved

        :foreground_allowed ->
          record_status_check_poll(command)

          approve_or_require(
            port,
            id,
            approval_decision,
            payload,
            payload_string,
            on_message,
            metadata,
            true
          )
      end
    end
  end

  defp maybe_handle_command_execution_approval_request(
         _port,
         _id,
         _approval_decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_handle_direct_exec_wait_policy(
         "codex/event/exec_command_begin",
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    command = payload_command(payload)

    case command_wait_routing_decision_for_command(command) do
      :background_required ->
        emit_message(
          on_message,
          :foreground_wait_policy_enforced,
          foreground_wait_policy_details(
            payload,
            payload_string,
            command,
            "direct_exec",
            "blocked_fail_closed",
            "background_required"
          ),
          metadata
        )

        {:error, {:turn_failed, direct_exec_wait_policy_error(command)}}

      :foreground_allowed ->
        :unhandled
    end
  end

  defp maybe_handle_direct_exec_wait_policy(
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp foreground_wait_policy_details(
         payload,
         payload_string,
         command,
         command_surface,
         policy_action,
         policy_reason
       ) do
    %{
      payload: payload,
      raw: payload_string,
      command: command,
      command_surface: command_surface,
      policy_action: policy_action,
      policy_reason: policy_reason,
      suggested_tool_path: @foreground_wait_refusal_tools
    }
  end

  defp direct_exec_wait_policy_error(command) do
    %{
      "summary" => "broad foreground wait blocked fail-closed on direct exec surface: #{command}",
      "error_class" => "permanent",
      "failure_class" => "process_error",
      "retry_action" => "stop",
      "account_state" => "ready",
      "command" => command,
      "command_surface" => "direct_exec",
      "policy_action" => "blocked_fail_closed",
      "policy_reason" => "background_required",
      "suggested_tool_path" => @foreground_wait_refusal_tools
    }
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp command_wait_routing_decision_for_command(command) when is_binary(command) do
    normalized = String.trim(command)

    cond do
      normalized == "" ->
        :foreground_allowed

      background_required_command?(normalized) ->
        :background_required

      true ->
        :foreground_allowed
    end
  end

  defp command_wait_routing_decision_for_command(_command), do: :foreground_allowed

  defp background_required_command?(command) do
    command
    |> command_segments()
    |> Enum.any?(&background_required_segment?/1)
  end

  defp command_segments(command) when is_binary(command) do
    Regex.split(~r/\s*(?:&&|\|\||;|\|)\s*/, command, trim: true)
  end

  defp background_required_segment?(segment) when is_binary(segment) do
    case split_command_segment(segment) do
      [] ->
        false

      argv ->
        background_required_argv?(argv)
    end
  end

  defp background_required_segment?(_segment), do: false

  defp background_required_argv?(argv) do
    broad_make_gate?(argv) or
      broad_mix_test_command?(argv) or
      broad_pytest_command?(argv) or
      broad_npm_test_e2e_command?(argv) or
      broad_team_master_ui_e2e_command?(argv) or
      broad_lint_or_build_gate?(argv)
  end

  defp broad_make_gate?(["make", "symphony-validate" | _rest]), do: true
  defp broad_make_gate?(["make", "symphony-live-e2e" | _rest]), do: true
  defp broad_make_gate?(["make", "test" | _rest]), do: true
  defp broad_make_gate?(["make", flag, "elixir", "all" | _rest]) when flag in ["-C", "-c"], do: true
  defp broad_make_gate?(["make", "all" | _rest]), do: true
  defp broad_make_gate?(["make", "team-master-ui-e2e" | _rest]), do: true
  defp broad_make_gate?(_argv), do: false

  defp broad_mix_test_command?(["mix", "test" | rest]), do: not scoped_command_args?(rest)
  defp broad_mix_test_command?(_argv), do: false

  defp broad_pytest_command?(["pytest" | rest]), do: not scoped_command_args?(rest)
  defp broad_pytest_command?(_argv), do: false

  defp broad_npm_test_e2e_command?(["npm", "run", "test:e2e" | _rest]), do: true
  defp broad_npm_test_e2e_command?(_argv), do: false

  defp broad_team_master_ui_e2e_command?(["team-master-ui-e2e" | _rest]), do: true
  defp broad_team_master_ui_e2e_command?(_argv), do: false

  defp broad_lint_or_build_gate?(["mix", "dialyzer" | _rest]), do: true
  defp broad_lint_or_build_gate?(_argv), do: false

  defp scoped_command_args?(args) when is_list(args) do
    {_previous, scoped?} =
      Enum.reduce(args, {nil, false}, fn arg, {previous, scoped?} ->
        cond do
          scoped? ->
            {arg, true}

          explicit_scope_option?(previous) and is_binary(arg) and String.trim(arg) != "" ->
            {arg, true}

          scope_path_or_selector?(arg) ->
            {arg, true}

          true ->
            {arg, false}
        end
      end)

    scoped?
  end

  defp explicit_scope_option?(option) when option in ["--only", "--exclude", "--include", "-k", "-m"],
    do: true

  defp explicit_scope_option?(_option), do: false

  defp scope_path_or_selector?(arg) when is_binary(arg) do
    trimmed = String.trim(arg)

    trimmed != "" and
      not String.starts_with?(trimmed, "-") and
      (String.contains?(trimmed, "/") or
         String.contains?(trimmed, "::") or
         String.ends_with?(trimmed, ".exs") or
         String.ends_with?(trimmed, ".py"))
  end

  defp scope_path_or_selector?(_arg), do: false

  defp split_command_segment(segment) when is_binary(segment) do
    OptionParser.split(segment)
  rescue
    _ -> [segment]
  end

  defp command_execution_refusal_decision(payload) do
    payload
    |> available_approval_decisions()
    |> choose_refusal_decision()
  end

  defp available_approval_decisions(payload) when is_map(payload) do
    payload
    |> approval_params()
    |> approval_available_decisions_value()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp approval_available_decisions_value(nil), do: []

  defp approval_available_decisions_value(params) when is_map(params) do
    fetch_first(params, ["available_decisions", :available_decisions, "availableDecisions", :availableDecisions]) || []
  end

  defp choose_refusal_decision(decisions) when is_list(decisions) do
    Enum.find(decisions, &(normalize_decision(&1) == "denied")) ||
      Enum.find(decisions, &(normalize_decision(&1) == "abort")) ||
      Enum.find(decisions, &(not approval_allow_decision?(&1))) ||
      "abort"
  end

  defp approval_allow_decision?(decision) when is_binary(decision) do
    normalized = normalize_decision(decision)
    String.starts_with?(normalized, "accept") or String.starts_with?(normalized, "approve") or String.starts_with?(normalized, "allow")
  end

  defp approval_allow_decision?(_decision), do: false

  defp normalize_decision(decision) when is_binary(decision) do
    decision
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[_\-\s]/, "")
  end

  defp normalize_decision(_decision), do: ""

  defp payload_command(payload) when is_map(payload) do
    payload
    |> approval_params()
    |> payload_command_value()
    |> normalize_approval_command()
  end

  defp payload_command_value(nil), do: nil

  defp payload_command_value(params) when is_map(params) do
    fetch_first_path(params, [
      ["msg", "command"],
      [:msg, :command],
      ["msg", "parsed_cmd"],
      [:msg, :parsed_cmd],
      ["msg", "parsedCmd"],
      [:msg, :parsedCmd],
      ["parsedCmd"],
      [:parsedCmd],
      ["command"],
      [:command],
      ["cmd"],
      [:cmd],
      ["argv"],
      [:argv],
      ["args"],
      [:args]
    ])
  end

  defp approval_params(payload) when is_map(payload) do
    Map.get(payload, "params") || Map.get(payload, :params)
  end

  defp normalize_approval_command(%{} = command) do
    command
    |> approval_command_parts()
    |> normalize_approval_command()
  end

  defp normalize_approval_command(command) when is_binary(command) do
    case String.trim(command) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_approval_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> case do
        [] -> nil
        parts -> Enum.join(parts, " ")
      end
    else
      nil
    end
  end

  defp normalize_approval_command(_command), do: nil

  defp approval_command_parts(command) when is_map(command) do
    binary_command = fetch_first(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])
    args = fetch_first(command, ["args", :args, "argv", :argv])

    case {binary_command, args} do
      {binary, list} when is_binary(binary) and is_list(list) -> [binary | list]
      {binary, _list} when is_binary(binary) -> binary
      {_binary, list} when is_list(list) -> list
      _ -> nil
    end
  end

  defp fetch_first(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp fetch_first(_map, _keys), do: nil

  defp fetch_first_path(map, paths) when is_map(map) and is_list(paths) do
    Enum.find_value(paths, &value_at_path(map, &1))
  end

  defp fetch_first_path(_map, _paths), do: nil

  defp value_at_path(map, [single]) when is_map(map), do: Map.get(map, single)

  defp value_at_path(map, [first, second]) when is_map(map) do
    case Map.get(map, first) do
      nested when is_map(nested) -> Map.get(nested, second)
      _ -> nil
    end
  end

  defp value_at_path(_map, _path), do: nil

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp wait_guard_state do
    case Process.get(@wait_guard_process_key) do
      %{quiet_wait_active: quiet_wait_active} = state when is_boolean(quiet_wait_active) ->
        state

      _ ->
        default_wait_guard_state()
    end
  end

  defp default_wait_guard_state do
    %{
      quiet_wait_active: false,
      active_result_ref: nil,
      last_status_check_command: nil,
      last_status_check_at_ms: nil,
      validation_result_refs: %{},
      running_validation_surfaces: %{},
      green_validation_surfaces: %{},
      last_feedback_digest: nil,
      last_failed_validation: nil
    }
  end

  defp reset_wait_guard_state do
    Process.put(@wait_guard_process_key, default_wait_guard_state())
    :ok
  end

  defp deny_repeated_status_check?(command) when is_binary(command) do
    guard = wait_guard_state()
    now_ms = System.monotonic_time(:millisecond)
    normalized = normalize_status_check_command(command)
    last_command = Map.get(guard, :last_status_check_command)
    last_at_ms = Map.get(guard, :last_status_check_at_ms)

    guard.quiet_wait_active == true and status_check_command?(normalized) and
      last_command == normalized and
      is_integer(last_at_ms) and
      now_ms - last_at_ms < @status_check_quiet_wait_min_interval_ms
  end

  defp deny_repeated_status_check?(_command), do: false

  defp record_status_check_poll(command) when is_binary(command) do
    normalized = normalize_status_check_command(command)

    if status_check_command?(normalized) do
      updated =
        wait_guard_state()
        |> Map.put(:last_status_check_command, normalized)
        |> Map.put(:last_status_check_at_ms, System.monotonic_time(:millisecond))

      Process.put(@wait_guard_process_key, updated)
    end

    :ok
  end

  defp record_status_check_poll(_command), do: :ok

  defp status_check_command?(command) when is_binary(command) do
    String.starts_with?(command, "git status") or
      String.starts_with?(command, "gh pr status") or
      String.starts_with?(command, "gh pr checks") or
      String.starts_with?(command, "gh pr view") or
      String.starts_with?(command, "gh run list") or
      String.starts_with?(command, "gh run view") or
      String.starts_with?(command, "gh run watch")
  end

  defp normalize_status_check_command(command) when is_binary(command) do
    command
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.downcase()
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp maybe_handle_validation_exec_background_dedupe("exec_background", arguments, metadata)
       when is_map(arguments) and is_map(metadata) do
    with command when is_binary(command) <- exec_background_command(arguments),
         surface when is_map(surface) <- validation_surface(metadata, command) do
      surface_key = validation_surface_key(surface)
      guard = wait_guard_state()

      cond do
        running_entry = Map.get(guard.running_validation_surfaces, surface_key) ->
          dedupe_payload =
            %{
              "hit" => true,
              "reason" => "duplicate_validation_running",
              "surface_key" => surface_key
            }
            |> maybe_put_map("result_ref", Map.get(running_entry, :result_ref))

          deduped_result =
            %{
              "success" => true,
              "status" => "running",
              "dedupe" => dedupe_payload
            }
            |> maybe_put_map("result_ref", Map.get(running_entry, :result_ref))

          {:deduped, deduped_result, dedupe_payload}

        duplicate_green_surface?(guard, surface, surface_key) ->
          dedupe_payload = %{
            "hit" => true,
            "reason" => "duplicate_validation_green",
            "surface_key" => surface_key
          }

          deduped_result = %{
            "success" => true,
            "status" => "completed",
            "tail" => "validation rerun skipped: identical green validation surface without new signal",
            "failure_summary" => nil,
            "dedupe" => dedupe_payload
          }

          {:deduped, deduped_result, dedupe_payload}

        true ->
          :continue
      end
    else
      _ -> :continue
    end
  end

  defp maybe_handle_validation_exec_background_dedupe(_tool_name, _arguments, _metadata), do: :continue

  defp duplicate_green_surface?(guard, surface, surface_key) when is_map(guard) and is_map(surface) do
    bundle = Map.get(surface, :validation_bundle_fingerprint)

    case Map.get(guard.green_validation_surfaces, bundle) do
      %{surface_key: ^surface_key} = green_entry ->
        not green_surface_invalidated_by_other_bundle_failure?(guard, bundle, green_entry)

      _ ->
        false
    end
  end

  defp duplicate_green_surface?(_guard, _surface, _surface_key), do: false

  defp green_surface_invalidated_by_other_bundle_failure?(guard, bundle, green_entry)
       when is_map(guard) and is_binary(bundle) and is_map(green_entry) do
    case Map.get(guard, :last_failed_validation) do
      %{bundle: failed_bundle, at_ms: failed_at_ms}
      when is_binary(failed_bundle) and is_integer(failed_at_ms) and failed_bundle != bundle ->
        completed_at_ms = Map.get(green_entry, :completed_at_ms, 0)
        failed_at_ms > completed_at_ms

      _ ->
        false
    end
  end

  defp green_surface_invalidated_by_other_bundle_failure?(_guard, _bundle, _green_entry), do: false

  defp validation_surface(metadata, command) when is_map(metadata) and is_binary(command) do
    with workspace when is_binary(workspace) <- fetch_first(metadata, [:workspace, "workspace"]),
         normalized_command when is_binary(normalized_command) <- normalize_optional_string(command),
         validation_bundle_fingerprint when is_binary(validation_bundle_fingerprint) <-
           validation_bundle_fingerprint_from_command(normalized_command) do
      git_surface = validation_git_surface(workspace)
      feedback_digest = normalize_optional_string(Map.get(wait_guard_state(), :last_feedback_digest))

      %{
        normalized_command: normalized_command,
        validation_bundle_fingerprint: validation_bundle_fingerprint,
        head_sha: git_surface.head_sha,
        tree_sha: git_surface.tree_sha,
        workspace_diff_fingerprint: git_surface.workspace_diff_fingerprint,
        feedback_digest: feedback_digest
      }
    end
  end

  defp validation_surface(_metadata, _command), do: nil

  defp validation_surface_key(surface) when is_map(surface) do
    [
      Map.get(surface, :validation_bundle_fingerprint) || "unknown",
      Map.get(surface, :normalized_command) || "unknown",
      Map.get(surface, :head_sha) || "unknown",
      Map.get(surface, :tree_sha) || "unknown",
      Map.get(surface, :workspace_diff_fingerprint) || "unknown",
      Map.get(surface, :feedback_digest) || "none"
    ]
    |> Enum.join("::")
  end

  defp validation_git_surface(workspace) when is_binary(workspace) do
    %{
      head_sha: git_trimmed(workspace, ["rev-parse", "HEAD"]) || "unknown",
      tree_sha: git_trimmed(workspace, ["rev-parse", "HEAD^{tree}"]) || "unknown",
      workspace_diff_fingerprint: git_workspace_diff_fingerprint(workspace) || "unknown"
    }
  end

  defp exec_background_command(arguments) when is_map(arguments) do
    fetch_first(arguments, ["command", :command]) |> normalize_optional_string()
  end

  defp validation_bundle_fingerprint_from_command(command) when is_binary(command) do
    command
    |> normalize_status_check_command()
    |> command_segments()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.find_value(&validation_bundle_fingerprint_for_segment/1)
  end

  defp validation_bundle_fingerprint_for_segment(segment) when is_binary(segment) do
    Enum.find_value(@validation_bundle_patterns, fn {pattern, fingerprint} ->
      Regex.match?(pattern, segment) && fingerprint
    end)
  end

  defp validation_bundle_fingerprint_for_segment(_segment), do: nil

  defp update_wait_guard_from_tool_result(tool_name, arguments, result, metadata)
       when is_map(arguments) and is_map(result) and is_map(metadata) do
    update_wait_guard_from_exec_wait_result(tool_name, arguments, result)
    update_wait_guard_from_validation_result(tool_name, arguments, result, metadata)
    update_wait_guard_feedback_digest(tool_name, result)
    :ok
  end

  defp update_wait_guard_from_tool_result(_tool_name, _arguments, _result, _metadata), do: :ok

  defp update_wait_guard_from_exec_wait_result("exec_wait", arguments, result) do
    wait_payload = decode_tool_payload(result)
    status = Map.get(wait_payload, "status")
    quiet_wait_active = Map.get(wait_payload, "quiet_wait") == true or Map.get(wait_payload, "wait_mode") == "quiet"
    result_ref = Map.get(wait_payload, "result_ref") || Map.get(arguments, "result_ref")

    updated =
      case status do
        "running" ->
          wait_guard_state()
          |> Map.put(:quiet_wait_active, quiet_wait_active)
          |> Map.put(:active_result_ref, result_ref)

        _ ->
          wait_guard_state()
          |> Map.put(:quiet_wait_active, false)
          |> Map.put(:active_result_ref, nil)
      end

    Process.put(@wait_guard_process_key, updated)
    :ok
  end

  defp update_wait_guard_from_exec_wait_result(_tool_name, _arguments, _result), do: :ok

  defp update_wait_guard_from_validation_result("exec_background", arguments, result, metadata)
       when is_map(arguments) and is_map(result) and is_map(metadata) do
    payload = decode_tool_payload(result)
    status = normalize_optional_string(Map.get(payload, "status"))

    with "running" <- status,
         true <- Map.get(payload, "success") != false,
         result_ref when is_binary(result_ref) <- normalize_optional_string(Map.get(payload, "result_ref")),
         command when is_binary(command) <- exec_background_command(arguments),
         surface when is_map(surface) <- validation_surface(metadata, command) do
      surface_key = validation_surface_key(surface)
      now_ms = System.monotonic_time(:millisecond)

      running_entry = %{
        surface: surface,
        surface_key: surface_key,
        result_ref: result_ref,
        started_at_ms: now_ms
      }

      updated_guard =
        wait_guard_state()
        |> put_validation_result_ref(result_ref, running_entry)
        |> put_running_validation_surface(surface_key, running_entry)

      Process.put(@wait_guard_process_key, updated_guard)
    end

    :ok
  end

  defp update_wait_guard_from_validation_result("exec_wait", arguments, result, _metadata)
       when is_map(arguments) and is_map(result) do
    payload = decode_tool_payload(result)
    result_ref = normalize_optional_string(Map.get(payload, "result_ref") || Map.get(arguments, "result_ref"))

    with result_ref when is_binary(result_ref) <- result_ref,
         guard = wait_guard_state(),
         %{surface: surface, surface_key: surface_key} = running_entry <- Map.get(guard.validation_result_refs, result_ref) do
      maybe_finalize_validation_wait_result(guard, running_entry, surface, surface_key, result_ref, payload)
    end

    :ok
  end

  defp update_wait_guard_from_validation_result(_tool_name, _arguments, _result, _metadata), do: :ok

  defp maybe_finalize_validation_wait_result(
         guard,
         running_entry,
         _surface,
         _surface_key,
         _result_ref,
         payload
       )
       when is_map(guard) and is_map(running_entry) and is_map(payload) do
    status = normalize_optional_string(Map.get(payload, "status"))

    if status == "running" do
      :ok
    else
      finalize_validation_wait_result(guard, running_entry, status, payload)
    end
  end

  defp maybe_finalize_validation_wait_result(_guard, _running_entry, _surface, _surface_key, _result_ref, _payload), do: :ok

  defp finalize_validation_wait_result(guard, running_entry, status, payload)
       when is_map(guard) and is_map(running_entry) and is_map(payload) do
    result_ref = Map.get(running_entry, :result_ref)
    surface = Map.get(running_entry, :surface, %{})
    surface_key = Map.get(running_entry, :surface_key) || "unknown"
    bundle = Map.get(surface, :validation_bundle_fingerprint)
    now_ms = System.monotonic_time(:millisecond)

    base_guard =
      guard
      |> remove_validation_result_ref(result_ref)
      |> remove_running_validation_surface(surface_key)

    updated_guard =
      apply_validation_wait_outcome(
        base_guard,
        running_entry,
        bundle,
        surface_key,
        status,
        payload,
        now_ms
      )

    Process.put(@wait_guard_process_key, updated_guard)
  end

  defp apply_validation_wait_outcome(base_guard, _running_entry, bundle, surface_key, _status, payload, now_ms)
       when is_map(base_guard) and is_binary(bundle) and is_binary(surface_key) and is_map(payload) do
    if validation_wait_completed_successfully?(payload) do
      put_green_validation_surface(base_guard, bundle, %{
        surface_key: surface_key,
        completed_at_ms: now_ms
      })
    else
      record_failed_validation_surface(base_guard, bundle, surface_key, nil, now_ms, payload)
    end
  end

  defp apply_validation_wait_outcome(base_guard, _running_entry, _bundle, surface_key, status, payload, now_ms)
       when is_map(base_guard) and is_binary(surface_key) and is_map(payload) do
    record_failed_validation_surface(base_guard, "unknown", surface_key, status, now_ms, payload)
  end

  defp record_failed_validation_surface(base_guard, bundle, surface_key, status, now_ms, payload)
       when is_map(base_guard) and is_binary(bundle) and is_binary(surface_key) and is_map(payload) do
    put_last_failed_validation(base_guard, %{
      bundle: bundle,
      surface_key: surface_key,
      at_ms: now_ms,
      status: status || normalize_optional_string(Map.get(payload, "status")) || "unknown",
      result_ref: normalize_optional_string(Map.get(payload, "result_ref")) || "unknown"
    })
  end

  defp update_wait_guard_feedback_digest("github_pr_snapshot", result) when is_map(result) do
    payload = decode_tool_payload(result)
    feedback_digest = normalize_optional_string(fetch_first(payload, ["feedback_digest", :feedback_digest]))

    if is_binary(feedback_digest) do
      updated = wait_guard_state() |> Map.put(:last_feedback_digest, feedback_digest)
      Process.put(@wait_guard_process_key, updated)
    end

    :ok
  end

  defp update_wait_guard_feedback_digest(_tool_name, _result), do: :ok

  defp validation_wait_completed_successfully?(payload) when is_map(payload) do
    success_flag = Map.get(payload, "success")
    status = normalize_optional_string(Map.get(payload, "status"))
    failure_summary = normalize_optional_string(Map.get(payload, "failure_summary"))
    error_payload = Map.get(payload, "error")

    status in ["completed", "succeeded", "success"] and
      success_flag != false and
      is_nil(failure_summary) and
      not is_map(error_payload)
  end

  defp put_validation_result_ref(guard, result_ref, entry) when is_map(guard) do
    refs = Map.get(guard, :validation_result_refs, %{})
    Map.put(guard, :validation_result_refs, Map.put(refs, result_ref, entry))
  end

  defp put_running_validation_surface(guard, surface_key, entry) when is_map(guard) do
    running = Map.get(guard, :running_validation_surfaces, %{})
    Map.put(guard, :running_validation_surfaces, Map.put(running, surface_key, entry))
  end

  defp remove_validation_result_ref(guard, result_ref) when is_map(guard) do
    refs = Map.get(guard, :validation_result_refs, %{})
    Map.put(guard, :validation_result_refs, Map.delete(refs, result_ref))
  end

  defp remove_running_validation_surface(guard, surface_key) when is_map(guard) do
    running = Map.get(guard, :running_validation_surfaces, %{})
    Map.put(guard, :running_validation_surfaces, Map.delete(running, surface_key))
  end

  defp put_green_validation_surface(guard, bundle, surface) when is_map(guard) and is_binary(bundle) do
    green = Map.get(guard, :green_validation_surfaces, %{})
    Map.put(guard, :green_validation_surfaces, Map.put(green, bundle, surface))
  end

  defp put_last_failed_validation(guard, last_failed_validation) when is_map(guard) and is_map(last_failed_validation) do
    Map.put(guard, :last_failed_validation, last_failed_validation)
  end

  defp maybe_put_map(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp git_trimmed(workspace, args) when is_binary(workspace) and is_list(args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp git_workspace_diff_fingerprint(workspace) when is_binary(workspace) do
    with status_lines when is_list(status_lines) <- git_status_lines(workspace) do
      head = git_trimmed(workspace, ["rev-parse", "HEAD"]) || "unknown"

      entries =
        status_lines
        |> Enum.map(&parse_status_entry/1)
        |> Enum.reject(fn {_kind, _status, path} ->
          path == "" or internal_workspace_artifact?(path)
        end)

      entry_digests =
        entries
        |> Enum.sort_by(fn {_kind, status, path} -> {path, status} end)
        |> Enum.map(fn {kind, status, path} ->
          digest = sha256_file(Path.join(workspace, path)) || "missing"
          "#{kind}:#{status}:#{path}:#{digest}"
        end)

      ["head=#{head}" | entry_digests]
      |> Enum.join("\n---\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defp git_status_lines(workspace) when is_binary(workspace) do
    case System.cmd("git", ["-C", workspace, "status", "--porcelain=v1", "--untracked-files=all"], stderr_to_stdout: true) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> nil
    end
  end

  defp parse_status_entry(line) when is_binary(line) do
    status = String.slice(line, 0, 2)
    path = parse_status_path(line)
    kind = if status == "??", do: :untracked, else: :tracked
    {kind, status, path}
  end

  defp parse_status_entry(_line), do: {:tracked, "", ""}

  defp internal_workspace_artifact?(path) when is_binary(path) do
    path in [".symphony/verification/handoff-manifest.json", "workpad.md", ".workpad-id"] or
      String.starts_with?(path, ".symphony/resume/")
  end

  defp internal_workspace_artifact?(_path), do: false

  defp parse_status_path(line) when is_binary(line) do
    trimmed =
      line
      |> String.slice(3..-1//1)
      |> to_string()
      |> String.trim()

    if String.contains?(trimmed, " -> ") do
      trimmed
      |> String.split(" -> ")
      |> List.last()
      |> String.trim()
    else
      trimmed
    end
  end

  defp sha256_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  defp decode_tool_payload(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp decode_tool_payload(%{"status" => _status} = payload), do: payload
  defp decode_tool_payload(%{status: status} = payload), do: Map.put(payload, "status", status)

  defp decode_tool_payload(_result), do: %{}

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue_id=unknown issue_identifier=unknown"

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload, base_metadata) do
    base_metadata
    |> Map.merge(port_metadata(port))
    |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp dynamic_tool_opts(workspace, metadata) when is_map(metadata) do
    [workspace: workspace]
    |> maybe_put_dynamic_tool_opt(:trace_id, Map.get(metadata, :trace_id))
  end

  defp dynamic_tool_opts(workspace, _metadata), do: [workspace: workspace]

  defp maybe_put_dynamic_tool_opt(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put_dynamic_tool_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp default_on_message(_message), do: :ok

  defp with_logger_metadata(metadata, fun) when is_map(metadata) and is_function(fun, 0) do
    previous_metadata = Logger.metadata()

    logger_metadata =
      []
      |> maybe_put_logger_metadata(:issue_id, Map.get(metadata, :issue_id))
      |> maybe_put_logger_metadata(:issue_identifier, Map.get(metadata, :issue_identifier))
      |> maybe_put_logger_metadata(:trace_id, Map.get(metadata, :trace_id))
      |> maybe_put_logger_metadata(:cost_profile_key, Map.get(metadata, :cost_profile_key))
      |> maybe_put_logger_metadata(:cost_profile_reason, Map.get(metadata, :cost_profile_reason))
      |> maybe_put_logger_metadata(:cost_stage, Map.get(metadata, :cost_stage))
      |> maybe_put_logger_metadata(:cost_signals, Map.get(metadata, :cost_signals))
      |> maybe_put_logger_metadata(:codex_model, Map.get(metadata, :codex_model))
      |> maybe_put_logger_metadata(:codex_effort, Map.get(metadata, :codex_effort))
      |> maybe_put_logger_metadata(:command_source, Map.get(metadata, :command_source))

    if logger_metadata != [] do
      Logger.metadata(logger_metadata)
    end

    try do
      fun.()
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  defp with_logger_metadata(_metadata, fun) when is_function(fun, 0), do: fun.()

  defp trace_id_from(issue, opts) when is_list(opts) do
    Keyword.get(opts, :trace_id) || Map.get(issue, :trace_id)
  end

  defp maybe_put_logger_metadata(metadata, _key, value) when value in [nil, ""], do: metadata
  defp maybe_put_logger_metadata(metadata, key, value), do: Keyword.put(metadata, key, value)
  defp maybe_put_metadata(metadata, _key, value) when value in [nil, ""], do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp maybe_put_account_id(metadata, nil), do: metadata

  defp maybe_put_account_id(metadata, account_id) when is_binary(account_id) do
    Map.put(metadata, :codex_account_id, account_id)
  end

  defp maybe_put_account_id(metadata, _account_id), do: metadata

  defp maybe_put_params(message, nil), do: message
  defp maybe_put_params(message, params), do: Map.put(message, "params", params)

  defp port_env(command_env) when is_list(command_env) do
    Enum.map(command_env, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        {String.to_charlist(key), String.to_charlist(value)}

      {key, value} ->
        {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp port_env(_command_env), do: []

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
