defmodule SymphonyElixir.AcceptanceCapabilityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AcceptanceCapability

  @manifest %{
    "tools" => %{
      "git" => %{"available" => true},
      "gh" => %{"available" => true},
      "make" => %{"available" => true}
    },
    "makefile" => %{
      "targets" => ["symphony-validate", "symphony-runtime-smoke", "symphony-pr-body-check"]
    }
  }

  test "exposes supported capabilities" do
    assert "stateful_db" in AcceptanceCapability.supported_capabilities()
    assert "vps_ssh" in AcceptanceCapability.supported_capabilities()
  end

  test "parses required capabilities from task spec aliases" do
    description = """
    ## Symphony
    Repo: maximlafe/lead_status
    Required capabilities: db, runtime, vps, pr_body
    """

    assert {capabilities, []} = AcceptanceCapability.required_capabilities(description)

    assert capabilities == [
             "stateful_db",
             "runtime_smoke",
             "vps_ssh",
             "pr_body_contract"
           ]
  end

  test "reports unsupported capability names" do
    assert {[], ["unsupported required capability `moon_base`"]} =
             AcceptanceCapability.required_capabilities("Required capabilities: moon_base")
  end

  test "passes when no explicit capabilities are declared" do
    assert {:ok, report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => ""}, manifest_result: {:ok, @manifest})

    assert report["required_capabilities"] == []
    assert report["passed"] == true

    assert {:ok, _fallback_report} =
             AcceptanceCapability.evaluate("/tmp/workspace", :issue_without_description, manifest_result: {:ok, @manifest})
  end

  test "reports workspace capability manifest failures" do
    assert {:error, report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => "Required capabilities: repo_validation"}, manifest_result: {:error, :enoent})

    assert report["passed"] == false
    assert "workspace capability manifest unavailable: :enoent" in report["missing"]
  end

  test "checks vps env requirements fail closed" do
    description = "Required capabilities: vps_ssh"

    assert {:error, report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{}
             )

    assert "vps_ssh requires env `PROD_VPS_HOST`" in report["missing"]
    assert "vps_ssh requires one env: `PROD_VPS_SSH_KEY`, `PROD_VPS_SSH_KEY_PATH`" in report["missing"]
  end

  test "passes vps env requirements with key path fallback" do
    description = "Required capabilities: vps_ssh"

    assert {:ok, report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{description: description},
               manifest_result: {:ok, @manifest},
               env: %{
                 "PROD_VPS_HOST" => "example.test",
                 "PROD_VPS_USER" => "deploy",
                 "PROD_VPS_KNOWN_HOSTS" => "example.test ssh-ed25519 AAAA",
                 "PROD_VPS_SSH_KEY_PATH" => "/run/secrets/vps_key"
               }
             )

    assert report["passed"] == true
  end

  test "checks required make targets" do
    description = "Required capabilities: runtime_smoke, pr_body_contract"
    manifest = put_in(@manifest, ["makefile", "targets"], ["symphony-validate"])

    assert {:error, report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, manifest},
               env: %{}
             )

    assert Enum.any?(report["missing"], &String.contains?(&1, "runtime_smoke requires one Makefile target"))
    assert Enum.any?(report["missing"], &String.contains?(&1, "pr_body_contract requires one Makefile target"))
  end

  test "checks pr publication, artifact upload, repo validation, and ui runtime capabilities" do
    description = "Required capabilities: pr_publication, artifact_upload, repo_validation, ui_runtime"

    assert {:ok, report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{"GH_TOKEN" => "ghp_test", "LINEAR_API_KEY" => "lin_test"}
             )

    assert report["passed"] == true

    missing_manifest = %{
      "tools" => %{"git" => %{"available" => false}, "gh" => %{"available" => false}},
      "makefile" => %{"targets" => []}
    }

    assert {:error, missing_report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, missing_manifest},
               env: %{}
             )

    assert "pr_publication requires tool `git`" in missing_report["missing"]
    assert "pr_publication requires tool `gh`" in missing_report["missing"]
    assert "pr_publication requires one env: `GH_TOKEN`, `GITHUB_TOKEN`" in missing_report["missing"]
    assert "artifact_upload requires env `LINEAR_API_KEY`" in missing_report["missing"]
    assert Enum.any?(missing_report["missing"], &String.contains?(&1, "repo_validation requires one Makefile target"))
    assert Enum.any?(missing_report["missing"], &String.contains?(&1, "ui_runtime requires one Makefile target"))
  end

  test "checks stateful database reachability through injectable connector" do
    description = "Required capabilities: stateful_db"

    assert {:ok, report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{"DATABASE_URL" => "postgresql://user:pass@db.example:5432/app"},
               tcp_connect: fn "db.example", 5432 -> :ok end
             )

    assert report["passed"] == true

    assert {:ok, sql_alchemy_report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{"DATABASE_URL" => "postgresql+psycopg2://user:pass@db.example:5432/app"},
               tcp_connect: fn "db.example", 5432 -> :ok end
             )

    assert sql_alchemy_report["passed"] == true
  end

  test "checks stateful database reachability through the default tcp connector" do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen_socket)
    parent = self()

    acceptor =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        send(parent, :accepted)
        :gen_tcp.close(socket)
      end)

    description = "Required capabilities: stateful_db"

    assert {:ok, report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{"DATABASE_URL" => "postgresql://user:pass@127.0.0.1:#{port}/app"}
             )

    assert report["passed"] == true
    assert_receive :accepted
    Task.await(acceptor)
    :gen_tcp.close(listen_socket)

    assert {:error, error_report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{"DATABASE_URL" => "postgresql://user:pass@127.0.0.1:1/app"}
             )

    assert Enum.any?(error_report["missing"], &String.contains?(&1, "DATABASE_URL is not reachable"))
  end

  test "checks stateful database missing, invalid, and unreachable cases" do
    description = "Required capabilities: stateful_db"

    assert {:error, missing_report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{}
             )

    assert "stateful_db requires env `DATABASE_URL`" in missing_report["missing"]

    assert {:error, scheme_report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{"DATABASE_URL" => "mysql://user:pass@db/app"}
             )

    assert "stateful_db requires postgres DATABASE_URL" in scheme_report["missing"]

    assert {:error, missing_scheme_report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{"DATABASE_URL" => "//db.example:5432/app"}
             )

    assert "stateful_db requires postgres DATABASE_URL" in missing_scheme_report["missing"]

    assert {:error, unreachable_report} =
             AcceptanceCapability.evaluate("/tmp/workspace", %{"description" => description},
               manifest_result: {:ok, @manifest},
               env: %{"DATABASE_URL" => "postgresql://user:pass@db.example:15432/app"},
               tcp_connect: fn "db.example", 15_432 -> {:error, :nxdomain} end
             )

    assert "stateful_db DATABASE_URL is not reachable at db.example:15432: :nxdomain" in unreachable_report["missing"]
  end

  test "summarizes failure reports" do
    summary =
      AcceptanceCapability.summarize_failure(%{
        "required_capabilities" => ["vps_ssh"],
        "missing" => ["vps_ssh requires env `PROD_VPS_HOST`"]
      })

    assert summary =~ "required=vps_ssh"
    assert summary =~ "PROD_VPS_HOST"

    assert AcceptanceCapability.summarize_failure(%{"required_capabilities" => [], "missing" => []}) =~
             "required=none; missing=none"
  end
end
