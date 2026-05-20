from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SymphonyDeployContractTest(unittest.TestCase):
    def test_production_deploy_workflow_is_manual_dispatch_only(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/deploy-production.yml").read_text(encoding="utf-8")

        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("workflow_run:", workflow)
        self.assertNotIn("github.event.workflow_run", workflow)

    def test_deploy_workflows_sync_versioned_compose_contract(self) -> None:
        production_workflow = (REPO_ROOT / ".github/workflows/deploy-production.yml").read_text(
            encoding="utf-8"
        )
        staging_workflow = (REPO_ROOT / ".github/workflows/deploy-staging.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("--compose-file elixir/deploy/docker/docker-compose.yml", production_workflow)
        self.assertIn("--compose-file elixir/deploy/docker/docker-compose.yml", staging_workflow)

    def test_staging_deploy_workflow_promotes_release_image_from_main(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/deploy-staging.yml").read_text(encoding="utf-8")

        self.assertIn("workflow_run:", workflow)
        self.assertIn("- release-image", workflow)
        self.assertIn("branches:\n      - main", workflow)
        self.assertIn("environment:\n      name: staging", workflow)
        self.assertIn('gh run download "${{ github.event.workflow_run.id }}"', workflow)
        self.assertIn("--compose-file elixir/deploy/docker/docker-compose.yml", workflow)

    def test_deploy_script_pushes_compose_contract_to_remote_host(self) -> None:
        script = (REPO_ROOT / "scripts/symphony_deploy.sh").read_text(encoding="utf-8")

        self.assertIn("--compose-file <path>", script)
        self.assertIn('sync_remote_file "${compose_file}" "${SYMPHONY_DEPLOY_COMPOSE_FILE}"', script)


if __name__ == "__main__":
    unittest.main()
