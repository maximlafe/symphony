from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import validate_codex_accounts_contract as contract


class ValidateCodexAccountsContractTest(unittest.TestCase):
    def write_file(self, directory: Path, name: str, content: str) -> Path:
        path = directory / name
        path.write_text(content, encoding="utf-8")
        return path

    def test_validate_workflow_contract_accepts_required_accounts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            workflow_file = self.write_file(
                tmp_path,
                "let.WORKFLOW.md",
                """---
codex:
  accounts:
    - id: "charlotte.coulter@hmlservice.com"
      codex_home: /root/.codex
    - id: Deborah
      codex_home: /root/.codex-deborah
---
Instructions
""",
            )
            required_accounts_file = self.write_file(
                tmp_path,
                "required.txt",
                "charlotte.coulter@hmlservice.com\nDeborah\n",
            )

            contract.validate_workflow_contract(workflow_file, required_accounts_file)

    def test_validate_workflow_contract_rejects_missing_accounts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            workflow_file = self.write_file(
                tmp_path,
                "let.WORKFLOW.md",
                """---
codex:
  accounts:
    - id: Deborah
      codex_home: /root/.codex-deborah
---
Instructions
""",
            )
            required_accounts_file = self.write_file(
                tmp_path,
                "required.txt",
                "charlotte.coulter@hmlservice.com\nDeborah\n",
            )

            with self.assertRaisesRegex(contract.ContractError, "missing required Codex accounts"):
                contract.validate_workflow_contract(workflow_file, required_accounts_file)

    def test_validate_state_contract_accepts_required_accounts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            state_json_file = self.write_file(
                tmp_path,
                "state.json",
                json.dumps(
                    {
                        "codex_accounts": [
                            {"id": "charlotte.coulter@hmlservice.com", "healthy": True},
                            {"id": "Deborah", "healthy": False},
                        ]
                    }
                ),
            )
            required_accounts_file = self.write_file(
                tmp_path,
                "required.txt",
                "charlotte.coulter@hmlservice.com\nDeborah\n",
            )

            contract.validate_state_contract(state_json_file, required_accounts_file)

    def test_validate_state_contract_rejects_missing_accounts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            state_json_file = self.write_file(
                tmp_path,
                "state.json",
                json.dumps({"codex_accounts": [{"id": "Deborah", "healthy": True}]}),
            )
            required_accounts_file = self.write_file(
                tmp_path,
                "required.txt",
                "charlotte.coulter@hmlservice.com\nDeborah\n",
            )

            with self.assertRaisesRegex(contract.ContractError, "missing required Codex accounts"):
                contract.validate_state_contract(state_json_file, required_accounts_file)


if __name__ == "__main__":
    unittest.main()
