from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SymphonyValidationContractTest(unittest.TestCase):
    def test_root_makefile_routes_runtime_smoke_and_repo_validation_to_dedicated_targets(self) -> None:
        makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("symphony-acceptance-preflight:", makefile)
        self.assertIn("mix acceptance_capability.check", makefile)
        self.assertIn("symphony-runtime-smoke:", makefile)
        self.assertIn('cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) runtime-smoke SCENARIO="$(SCENARIO)"', makefile)
        self.assertIn("symphony-validate:", makefile)
        self.assertIn("cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) validate", makefile)
        self.assertNotIn("cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) all", makefile)

    def test_elixir_makefile_declares_validation_env_contract(self) -> None:
        makefile = (REPO_ROOT / "elixir/Makefile").read_text(encoding="utf-8")

        self.assertIn("VALIDATION_MIX_ENV ?= dev", makefile)
        self.assertIn("VALIDATION_TEST_MIX_ENV ?= test", makefile)
        self.assertIn("validation-env-check:", makefile)
        self.assertIn("validate:", makefile)
        self.assertIn("$(VALIDATION_MIX) deps.get", makefile)
        self.assertIn('$(VALIDATION_MIX) deps | grep -F "* credo " >/dev/null', makefile)
        self.assertIn('$(VALIDATION_MIX) deps | grep -F "* dialyxir " >/dev/null', makefile)
        self.assertIn("$(VALIDATION_MIX) build", makefile)
        self.assertIn("$(VALIDATION_MIX) lint", makefile)
        self.assertIn("$(VALIDATION_TEST_MIX) test --cover", makefile)

    def test_runtime_proof_workflow_uses_reusable_elixir_command(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/runtime-proof.yml").read_text(encoding="utf-8")

        self.assertIn("name: runtime-proof", workflow)
        self.assertIn("uses: ./.github/workflows/_elixir-command.yml", workflow)
        self.assertIn("artifact-name: runtime-proof", workflow)
        self.assertIn("cache-scope: runtime-proof", workflow)
        self.assertIn("working-directory: .", workflow)
        self.assertIn("command: make symphony-runtime-smoke SCENARIO=all", workflow)

    def test_infra_pass_workflow_uses_reusable_elixir_command(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/infra-pass.yml").read_text(encoding="utf-8")

        self.assertIn("name: infra-pass", workflow)
        self.assertIn("uses: ./.github/workflows/_elixir-command.yml", workflow)
        self.assertIn("artifact-name: infra-pass", workflow)
        self.assertIn("cache-scope: infra-pass", workflow)
        self.assertIn("working-directory: .", workflow)
        self.assertIn("command: make symphony-validate", workflow)

    def test_reusable_elixir_command_supports_custom_working_directory(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/_elixir-command.yml").read_text(encoding="utf-8")

        self.assertIn("working-directory:", workflow)
        self.assertIn("default: elixir", workflow)
        self.assertIn("working-directory: ${{ inputs.working-directory }}", workflow)

    def test_push_skill_creates_pr_with_body_file_before_first_ci_event(self) -> None:
        skill = (REPO_ROOT / ".agents/skills/push/SKILL.md").read_text(encoding="utf-8")

        self.assertIn("Draft the complete PR body before any `gh pr create` call.", skill)
        self.assertIn("gh pr create --base \"$base_branch\" --title \"$pr_title\" --body-file \"$pr_body_file\"", skill)
        self.assertNotIn("gh pr create --base \"$base_branch\" --title \"$pr_title\"\n", skill)


if __name__ == "__main__":
    unittest.main()
