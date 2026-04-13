defmodule SymphonyElixir.CodexAccountProbeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AccountProbe

  test "account probe reads account metadata and rate limits from a filtered runtime home derived from CODEX_HOME" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-account-probe-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "probe.trace")
      workspace_root = Path.join(test_root, "workspaces")
      primary_home = Path.join(test_root, "primary-home")
      logged_out_home = Path.join(test_root, "logged-out-home")

      File.mkdir_p!(primary_home)
      File.mkdir_p!(logged_out_home)
      File.write!(Path.join(primary_home, "auth.json"), ~s({"marker":"primary"}\n))
      File.write!(Path.join(logged_out_home, "auth.json"), ~s({"marker":"logged-out"}\n))

      File.write!(Path.join(primary_home, "config.toml"), """
      [mcp_servers.linear]
      url = "https://mcp.linear.app/mcp"

      [plugins."github@openai-curated"]
      enabled = true
      """)

      File.write!(Path.join(logged_out_home, "config.toml"), """
      [mcp_servers.linear]
      url = "https://mcp.linear.app/mcp"

      [plugins."linear@openai-curated"]
      enabled = true
      """)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      auth_json=$(cat "${CODEX_HOME}/auth.json" 2>/dev/null || printf '{}')
      account_name=unknown
      plugins_present=no
      count=0

      case "$auth_json" in
        *'"marker":"primary"'*)
          account_name=primary
          ;;
        *'"marker":"logged-out"'*)
          account_name=logged-out
          ;;
      esac

      if grep -q '^\\[plugins\\.' "${CODEX_HOME}/config.toml" 2>/dev/null; then
        plugins_present=yes
      fi

      while IFS= read -r line; do
        count=$((count + 1))
        printf '%s|%s|plugins=%s:%s\\n' "$CODEX_HOME" "$account_name" "$plugins_present" "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            if [ "$account_name" = "primary" ]; then
              printf '%s\\n' '{"id":1001,"result":{"account":{"type":"chatgpt","email":"primary@example.com","planType":"pro"},"requiresOpenaiAuth":false}}'
            else
              printf '%s\\n' '{"id":1001,"result":{"requires_openai_auth":true}}'
            fi
            ;;
          3)
            if [ "$account_name" = "primary" ]; then
              printf '%s\\n' '{"id":1002,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"windowDurationMins":300,"usedPercent":20},"secondary":{"windowDurationMins":10080,"usedPercent":35},"credits":{"hasCredits":false,"unlimited":false,"balance":null}}}}}'
            else
              printf '%s\\n' '{"id":1002,"result":{"rate_limits":{"limit_id":"codex","primary":{"window_minutes":300,"used_percent":20},"secondary":{"window_minutes":10080,"used_percent":35},"credits":{"has_credits":false,"unlimited":false,"balance":null}}}}'
            fi
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_command: "#{codex_binary} app-server",
        workspace_root: workspace_root
      )

      [healthy, logged_out] =
        AccountProbe.probe_accounts(
          [
            %{id: "primary", codex_home: primary_home, explicit?: true},
            %{id: "logged-out", codex_home: logged_out_home, explicit?: true}
          ],
          cwd: test_root,
          monitored_windows_mins: [300, 10_080],
          minimum_remaining_percent: 5,
          timeout_ms: 1_000
        )

      assert healthy.id == "primary"
      assert healthy.healthy == true
      assert healthy.auth_mode == "chatgpt"
      assert healthy.email == "primary@example.com"
      assert healthy.plan_type == "pro"
      assert healthy.requires_openai_auth == false
      assert healthy.health_reason == nil
      assert healthy.missing_windows_mins == []
      assert healthy.insufficient_windows_mins == []
      assert get_in(healthy.rate_limits, ["primary", "windowDurationMins"]) == 300

      assert logged_out.id == "logged-out"
      assert logged_out.healthy == false
      assert logged_out.requires_openai_auth == true
      assert logged_out.health_reason == "not logged in"
      assert get_in(logged_out.rate_limits, ["primary", "window_minutes"]) == 300

      trace = File.read!(trace_file)
      assert trace =~ "|primary|plugins=no:"
      assert trace =~ "|logged-out|plugins=no:"
      assert trace =~ Path.join(workspace_root, ".codex-runtime/homes/")
      refute trace =~ primary_home <> "|primary|"
      refute trace =~ logged_out_home <> "|logged-out|"
    after
      File.rm_rf(test_root)
    end
  end

  test "account probe preserves account identity when a probe times out" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-account-probe-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      timeout_home = Path.join(test_root, "timeout-home")

      File.mkdir_p!(timeout_home)

      File.write!(codex_binary, """
      #!/bin/sh
      sleep 1
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_command: "#{codex_binary} app-server"
      )

      [timed_out] =
        AccountProbe.probe_accounts(
          [%{id: "timeout", codex_home: timeout_home, explicit?: true}],
          cwd: test_root,
          monitored_windows_mins: [300, 10_080],
          minimum_remaining_percent: 5,
          timeout_ms: 50
        )

      assert timed_out.id == "timeout"
      assert timed_out.healthy == false
      assert timed_out.health_reason =~ "probe failed"
      assert timed_out.codex_home == timeout_home
    after
      File.rm_rf(test_root)
    end
  end

  test "account probe keeps logged-in accounts healthy when rate limits require extra auth" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-account-probe-rate-limits-auth-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      codex_home = Path.join(test_root, "primary-home")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(codex_home)
      File.write!(Path.join(codex_home, "auth.json"), ~s({"marker":"primary"}\n))

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":1001,"result":{"account":{"type":"chatgpt","email":"primary@example.com","planType":"pro"},"requiresOpenaiAuth":false}}'
            ;;
          3)
            printf '%s\\n' '{"id":1002,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_command: "#{codex_binary} app-server",
        workspace_root: workspace_root
      )

      [account] =
        AccountProbe.probe_accounts(
          [%{id: "primary", codex_home: codex_home, explicit?: true}],
          cwd: test_root,
          monitored_windows_mins: [300, 10_080],
          minimum_remaining_percent: 5,
          timeout_ms: 1_000
        )

      assert account.id == "primary"
      assert account.healthy == true
      assert account.auth_mode == "chatgpt"
      assert account.email == "primary@example.com"
      assert account.plan_type == "pro"
      assert account.requires_openai_auth == false
      assert account.health_reason == nil
      assert account.rate_limits == nil
      assert account.missing_windows_mins == []
      assert account.insufficient_windows_mins == []
    after
      File.rm_rf(test_root)
    end
  end

  test "account probe skips rate limit reads in account-only mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-account-probe-account-only-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "probe.trace")
      codex_home = Path.join(test_root, "primary-home")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(codex_home)
      File.write!(Path.join(codex_home, "auth.json"), ~s({"marker":"primary"}\n))

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"

      while IFS= read -r line; do
        printf '%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"account/read"'*)
            printf '%s\\n' '{"id":1001,"result":{"account":{"type":"chatgpt","email":"primary@example.com","planType":"pro"},"requiresOpenaiAuth":false}}'
            ;;
          *)
            exit 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_command: "#{codex_binary} app-server",
        workspace_root: workspace_root
      )

      [account] =
        AccountProbe.probe_accounts(
          [%{id: "primary", codex_home: codex_home, explicit?: true}],
          cwd: test_root,
          monitored_windows_mins: [300, 10_080],
          minimum_remaining_percent: 5,
          timeout_ms: 1_000,
          probe_mode: :account_only
        )

      assert account.id == "primary"
      assert account.healthy == true
      assert account.auth_mode == "chatgpt"
      assert account.email == "primary@example.com"
      assert account.plan_type == "pro"
      assert account.requires_openai_auth == false
      assert account.health_reason == nil
      assert account.rate_limits == nil
      assert account.probe_scope == :account_only

      trace = File.read!(trace_file)
      assert trace =~ "\"method\":\"account/read\""
      refute trace =~ "\"method\":\"account/rateLimits/read\""
    after
      File.rm_rf(test_root)
    end
  end
end
