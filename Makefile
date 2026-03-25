.PHONY: help symphony-bootstrap symphony-live-e2e symphony-preflight symphony-validate

MISE ?= mise
ELIXIR_DIR ?= elixir

help:
	@echo "Targets: symphony-preflight, symphony-bootstrap, symphony-validate, symphony-live-e2e"

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

symphony-validate:
	cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) all

symphony-live-e2e:
	cd $(ELIXIR_DIR) && $(MISE) exec -- $(MAKE) e2e
