defmodule SymphonyElixir.DeployContractTest do
  use ExUnit.Case, async: true

  test "docker compose forwards release metadata into the runtime environment" do
    compose_path = Path.expand("../../deploy/docker/docker-compose.yml", __DIR__)

    assert {:ok, compose} =
             compose_path
             |> File.read!()
             |> YamlElixir.read_from_string()

    environment = get_in(compose, ["services", "symphony", "environment"])

    assert environment["SYMPHONY_RELEASE_SHA"] == "${SYMPHONY_RELEASE_SHA:-}"
    assert environment["SYMPHONY_IMAGE_TAG"] == "${SYMPHONY_IMAGE_TAG:-}"
    assert environment["SYMPHONY_IMAGE_DIGEST"] == "${SYMPHONY_IMAGE_DIGEST:-}"
  end
end
