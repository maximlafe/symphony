defmodule SymphonyElixir.CodexAccountProbeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AccountProbe

  test "account probe reads account metadata and rate limits from the configured CODEX_HOME" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-account-probe-#{System.unique_integer([:positive])}"
      )

    try do
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "probe.trace")
      primary_home = Path.join(test_root, "primary-home")
      logged_out_home = Path.join(test_root, "logged-out-home")

      File.mkdir_p!(primary_home)
      File.mkdir_p!(logged_out_home)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      account_name=$(basename "${CODEX_HOME:-unknown}")
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf '%s:%s\\n' "$account_name" "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            if [ "$account_name" = "primary-home" ]; then
              printf '%s\\n' '{"id":1001,"result":{"account":{"type":"chatgpt","email":"primary@example.com","planType":"pro"},"requiresOpenaiAuth":false}}'
            else
              printf '%s\\n' '{"id":1001,"result":{"requires_openai_auth":true}}'
            fi
            ;;
          3)
            if [ "$account_name" = "primary-home" ]; then
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
        codex_command: "#{codex_binary} app-server"
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
      assert trace =~ "primary-home:"
      assert trace =~ "logged-out-home:"
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
end
