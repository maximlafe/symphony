.PHONY: help all setup deps build fmt fmt-check lint test dashboard coverage ci dialyzer e2e contracts validate validation-env-check

MIX ?= mix
VALIDATION_MIX_ENV ?= dev
VALIDATION_TEST_MIX_ENV ?= test
VALIDATION_MIX = MIX_ENV=$(VALIDATION_MIX_ENV) $(MIX)
VALIDATION_TEST_MIX = MIX_ENV=$(VALIDATION_TEST_MIX_ENV) $(MIX)

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, dashboard, coverage, dialyzer, e2e, ci, validate"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

contracts:
	python3 ../scripts/test_symphony_validation_contract.py
	python3 ../scripts/test_symphony_deploy_contract.py
	python3 ../scripts/test_validate_codex_accounts_contract.py
	python3 ../scripts/validate_codex_accounts_contract.py \
		--workflow-file ../workflows/letterl/maxime/let.WORKFLOW.md \
		--required-accounts-file ../workflows/letterl/maxime/let.required_codex_accounts.txt

validation-env-check:
	@$(VALIDATION_MIX) deps | grep -F "* credo " >/dev/null
	@$(VALIDATION_MIX) deps | grep -F "* dialyxir " >/dev/null

validate:
	$(MAKE) validation-env-check
	$(MAKE) contracts
	$(VALIDATION_MIX) build
	$(VALIDATION_MIX) format --check-formatted
	$(VALIDATION_MIX) lint
	$(VALIDATION_TEST_MIX) test --cover
	$(VALIDATION_MIX) deps.get
	$(VALIDATION_MIX) dialyzer --format short

dashboard:
	$(MIX) test --only dashboard

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	@if [ -z "$$LINEAR_API_KEY" ]; then \
		echo "LINEAR_API_KEY is required for \`make e2e\`."; \
		echo "Export it first, for example:"; \
		echo "  export LINEAR_API_KEY=\$$(tr -d '\\r\\n' < ~/.linear_api_key)"; \
		exit 1; \
	fi
	@if ! command -v codex >/dev/null 2>&1; then \
		echo "\`codex\` must be on PATH for \`make e2e\`."; \
		exit 1; \
	fi
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) contracts
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
