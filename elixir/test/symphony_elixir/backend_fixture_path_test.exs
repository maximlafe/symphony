defmodule SymphonyElixir.BackendFixturePathTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ValidationGate

  test "classifies nested staging fixture JSON with backend ExUnit changes" do
    fixture_path = "test/fixtures/staging/let_759_backend_fixture.json"
    backend_test_path = "elixir/test/symphony_elixir/backend_fixture_path_test.exs"

    assert File.exists?(fixture_path)
    assert Path.extname(backend_test_path) == ".exs"

    assert {:ok, ["backend_only"]} =
             ValidationGate.classify_paths([
               backend_test_path,
               fixture_path
             ])

    assert {:ok, final} =
             ValidationGate.classify_paths([
               backend_test_path,
               fixture_path
             ])
             |> then(fn {:ok, classes} -> ValidationGate.requirements(classes, "final") end)

    assert final["required_checks"] == ["preflight", "targeted_tests", "repo_validation"]
    refute "runtime_smoke" in final["required_checks"]
  end
end
