from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SymphonyValidationContractTest(unittest.TestCase):
    def test_root_makefile_routes_repo_validation_to_dedicated_target(self) -> None:
        makefile = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("symphony-validate:", makefile)
        self.assertIn("cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) validate", makefile)
        self.assertNotIn("cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) all", makefile)

    def test_elixir_makefile_declares_validation_env_contract(self) -> None:
        makefile = (REPO_ROOT / "elixir/Makefile").read_text(encoding="utf-8")

        self.assertIn("VALIDATION_MIX_ENV ?= dev", makefile)
        self.assertIn("VALIDATION_TEST_MIX_ENV ?= test", makefile)
        self.assertIn("validation-env-check:", makefile)
        self.assertIn("validate:", makefile)
        self.assertIn('$(VALIDATION_MIX) deps | grep -F "* credo " >/dev/null', makefile)
        self.assertIn('$(VALIDATION_MIX) deps | grep -F "* dialyxir " >/dev/null', makefile)
        self.assertIn("$(VALIDATION_MIX) build", makefile)
        self.assertIn("$(VALIDATION_MIX) lint", makefile)
        self.assertIn("$(VALIDATION_TEST_MIX) test --cover", makefile)


if __name__ == "__main__":
    unittest.main()
