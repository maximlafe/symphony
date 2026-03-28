defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Codex.RuntimeHome, Config, PathSafety}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

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
         {:ok, port} <- start_port(expanded_workspace, Keyword.get(opts, :command_env, [])) do
      account_id = Keyword.get(opts, :account_id)

      metadata =
        port
        |> session_metadata(opts)
        |> maybe_put_account_id(account_id)

      with {:ok, session_policies} <- session_policies(expanded_workspace),
           {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies) do
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
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec open_client(Path.t(), keyword()) :: {:ok, client()} | {:error, term()}
  def open_client(cwd \\ System.tmp_dir!(), opts \\ []) do
    expanded_cwd = Path.expand(cwd)

    case start_port(expanded_cwd, Keyword.get(opts, :command_env, [])) do
      {:ok, port} ->
        case send_initialize(port) do
          :ok ->
            metadata = port_metadata(port) |> maybe_put_account_id(Keyword.get(opts, :account_id))
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

  defp start_port(workspace, command_env) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      with {:ok, normalized_command_env} <- normalize_command_env(command_env) do
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(Config.settings!().codex.command)],
              cd: String.to_charlist(workspace),
              line: @port_line_bytes,
              env: port_env(normalized_command_env)
            ]
          )

        {:ok, port}
      end
    end
  end

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

  defp session_metadata(port, opts) when is_list(opts) do
    issue = Keyword.get(opts, :issue, %{})
    trace_id = Keyword.get(opts, :trace_id)

    port_metadata(port)
    |> maybe_put_metadata(:trace_id, trace_id)
    |> maybe_put_metadata(:issue_id, Map.get(issue, :id))
    |> maybe_put_metadata(:issue_identifier, Map.get(issue, :identifier))
  end

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
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
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

    result = tool_executor.(tool_name, arguments)

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

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

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
