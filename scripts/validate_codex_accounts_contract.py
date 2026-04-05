#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


class ContractError(RuntimeError):
    pass


def load_required_accounts(path: Path) -> list[str]:
    accounts: list[str] = []

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        accounts.append(line)

    if not accounts:
        raise ContractError(f"{path} does not define any required Codex accounts")

    return accounts


def extract_front_matter(path: Path) -> str:
    content = path.read_text(encoding="utf-8")
    lines = content.splitlines()

    if not lines or lines[0].strip() != "---":
        raise ContractError(f"{path} does not start with YAML front matter")

    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            return "\n".join(lines[1:index])

    raise ContractError(f"{path} is missing the closing YAML front matter delimiter")


def load_workflow_accounts(path: Path) -> list[str]:
    front_matter = extract_front_matter(path)
    accounts: list[str] = []
    accounts_indent: int | None = None

    for raw_line in front_matter.splitlines():
        stripped = raw_line.strip()
        indent = len(raw_line) - len(raw_line.lstrip(" "))

        if accounts_indent is None:
            if re.match(r"^\s*accounts:\s*$", raw_line):
                accounts_indent = indent
            continue

        if stripped and indent <= accounts_indent:
            accounts_indent = None
            if re.match(r"^\s*accounts:\s*$", raw_line):
                accounts_indent = indent
            continue

        match = re.match(r"^\s*-\s+id:\s*(.+?)\s*$", raw_line)
        if not match:
            continue

        value = match.group(1).split("#", 1)[0].strip()
        if not value:
            raise ContractError(f"{path} has an empty account id entry")
        if value[0] in {'"', "'"} and value[-1] == value[0]:
            value = value[1:-1]
        accounts.append(value)

    if not accounts:
        raise ContractError(f"{path} does not define any codex.accounts entries")

    return accounts


def load_state_accounts(path: Path) -> dict[str, dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    codex_accounts = payload.get("codex_accounts")

    if not isinstance(codex_accounts, list):
        raise ContractError(f"{path} is missing a codex_accounts list")

    accounts: dict[str, dict] = {}
    for entry in codex_accounts:
        if not isinstance(entry, dict):
            continue
        account_id = entry.get("id")
        if isinstance(account_id, str) and account_id:
            accounts[account_id] = entry

    if not accounts:
        raise ContractError(f"{path} does not expose any codex_accounts ids")

    return accounts


def missing_required_accounts(required_accounts: list[str], actual_accounts: list[str]) -> list[str]:
    actual_lookup = set(actual_accounts)
    return [account_id for account_id in required_accounts if account_id not in actual_lookup]


def validate_workflow_contract(workflow_file: Path, required_accounts_file: Path) -> None:
    required_accounts = load_required_accounts(required_accounts_file)
    workflow_accounts = load_workflow_accounts(workflow_file)
    missing_accounts = missing_required_accounts(required_accounts, workflow_accounts)

    if missing_accounts:
        configured = ", ".join(workflow_accounts)
        missing = ", ".join(missing_accounts)
        raise ContractError(
            f"{workflow_file} is missing required Codex accounts: {missing}. Configured accounts: {configured}"
        )

    print(
        f"Workflow contract OK: {workflow_file} exposes {len(workflow_accounts)} configured accounts and all "
        f"{len(required_accounts)} required accounts from {required_accounts_file}."
    )


def validate_state_contract(state_json_file: Path, required_accounts_file: Path) -> None:
    required_accounts = load_required_accounts(required_accounts_file)
    state_accounts = load_state_accounts(state_json_file)
    missing_accounts = missing_required_accounts(required_accounts, list(state_accounts.keys()))

    if missing_accounts:
        visible = ", ".join(state_accounts.keys())
        missing = ", ".join(missing_accounts)
        raise ContractError(
            f"{state_json_file} is missing required Codex accounts in /api/v1/state: {missing}. "
            f"Visible accounts: {visible}"
        )

    statuses = []
    for account_id in required_accounts:
        account = state_accounts[account_id]
        health = account.get("healthy")
        statuses.append(f"{account_id}={'healthy' if health is True else 'present'}")

    print(
        f"State contract OK: {state_json_file} exposes all {len(required_accounts)} required accounts from "
        f"{required_accounts_file}: {', '.join(statuses)}."
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate required Codex account contracts against a workflow file or /api/v1/state payload."
    )
    parser.add_argument("--required-accounts-file", type=Path, required=True)
    parser.add_argument("--workflow-file", type=Path)
    parser.add_argument("--state-json-file", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if bool(args.workflow_file) == bool(args.state_json_file):
        raise ContractError("Pass exactly one of --workflow-file or --state-json-file")

    if args.workflow_file:
        validate_workflow_contract(args.workflow_file, args.required_accounts_file)
    else:
        validate_state_contract(args.state_json_file, args.required_accounts_file)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ContractError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
