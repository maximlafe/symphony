.PHONY: help test symphony-bootstrap symphony-dashboard-checks symphony-handoff-check symphony-live-e2e symphony-preflight symphony-runtime-smoke symphony-validate symphony-nginx-proxy-contract symphony-nginx-proxy-smoke

MISE ?= mise
ELIXIR_DIR ?= elixir

help:
	@echo "Targets: test, symphony-preflight, symphony-bootstrap, symphony-dashboard-checks, symphony-handoff-check, symphony-runtime-smoke, symphony-validate, symphony-live-e2e, symphony-nginx-proxy-contract, symphony-nginx-proxy-smoke"

test: symphony-validate symphony-dashboard-checks symphony-nginx-proxy-contract

symphony-preflight:
	@if ! command -v codex >/dev/null 2>&1; then \
		echo "\`codex\` must be installed and authenticated."; \
		exit 1; \
	fi
	@if ! command -v $(MISE) >/dev/null 2>&1; then \
		echo "\`mise\` is required for Symphony bootstrap."; \
		exit 1; \
	fi
	@if ! command -v gh >/dev/null 2>&1; then \
		echo "\`gh\` is required for unattended PR flow."; \
		exit 1; \
	fi
	@if [ -z "$$LINEAR_API_KEY" ]; then \
		echo "\`LINEAR_API_KEY\` must be set."; \
		exit 1; \
	fi
	@if ! gh auth status >/dev/null 2>&1; then \
		echo "\`gh auth status\` failed. Refresh GH_TOKEN or run \`gh auth login -h github.com\`."; \
		exit 1; \
	fi
	@source_repo_url=$${SYMPHONY_SOURCE_REPO_URL:-$$(git remote get-url origin 2>/dev/null || printf '%s' 'https://github.com/maximlafe/symphony.git')}; \
	if ! git ls-remote --heads "$$source_repo_url" >/dev/null 2>&1; then \
		echo "Non-interactive git access failed for $$source_repo_url."; \
		exit 1; \
	fi
	@echo "Symphony preflight passed."

symphony-bootstrap:
	@if ! command -v gh >/dev/null 2>&1; then \
		echo "\`gh\` is required for unattended GitHub auth."; \
		exit 1; \
	fi
	@if ! gh auth status >/dev/null 2>&1; then \
		echo "\`gh auth status\` failed. Refresh GH_TOKEN or run \`gh auth login -h github.com\`."; \
		exit 1; \
	fi
	@if ! gh auth setup-git >/dev/null 2>&1; then \
		echo "Failed to configure git credentials via \`gh auth setup-git\`."; \
		exit 1; \
	fi
	@if ! command -v $(MISE) >/dev/null 2>&1; then \
		echo "\`mise\` is required for repo bootstrap."; \
		exit 1; \
	fi
	cd $(ELIXIR_DIR) && $(MISE) trust && $(MISE) install && $(MISE) exec -- mix setup

symphony-dashboard-checks:
	cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) dashboard

symphony-runtime-smoke:
	cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) runtime-smoke SCENARIO="$(SCENARIO)"

symphony-handoff-check:
	@if [ -z "$$ISSUE_ID" ]; then \
		echo "\`ISSUE_ID\` must be set."; \
		exit 1; \
	fi
	@if [ -z "$$WORKPAD_FILE" ]; then \
		echo "\`WORKPAD_FILE\` must be set."; \
		exit 1; \
	fi
	@if [ -z "$$REPO" ]; then \
		echo "\`REPO\` must be set."; \
		exit 1; \
	fi
	@if [ -z "$$PR_NUMBER" ]; then \
		echo "\`PR_NUMBER\` must be set."; \
		exit 1; \
	fi
	cd $(ELIXIR_DIR) && $(MISE) exec -- mix handoff.check --issue "$$ISSUE_ID" --workpad "$$WORKPAD_FILE" --repo "$$REPO" --pr "$$PR_NUMBER" $(if $(MANIFEST_FILE),--manifest "$(MANIFEST_FILE)",)

symphony-nginx-proxy-contract:
	python3 scripts/symphony_nginx_proxy_smoke.py --contract-only

symphony-nginx-proxy-smoke:
	python3 scripts/symphony_nginx_proxy_smoke.py

symphony-validate:
	cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) validate

symphony-live-e2e:
	cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) e2e
