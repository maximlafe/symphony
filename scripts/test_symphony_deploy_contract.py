from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SymphonyDeployContractTest(unittest.TestCase):
    def test_deploy_workflow_syncs_versioned_compose_contract(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/deploy-production.yml").read_text(encoding="utf-8")

        self.assertIn("--compose-file elixir/deploy/docker/docker-compose.yml", workflow)

    def test_deploy_script_pushes_compose_contract_to_remote_host(self) -> None:
        script = (REPO_ROOT / "scripts/symphony_deploy.sh").read_text(encoding="utf-8")

        self.assertIn("--compose-file <path>", script)
        self.assertIn('sync_remote_file "${compose_file}" "${SYMPHONY_DEPLOY_COMPOSE_FILE}"', script)


if __name__ == "__main__":
    unittest.main()
