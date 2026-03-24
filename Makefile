.PHONY: help symphony-bootstrap

ELIXIR_APP_DIR := elixir

help:
	@echo "Targets: symphony-bootstrap"

symphony-bootstrap:
	@set -eu; \
	if [ ! -d "$(ELIXIR_APP_DIR)" ]; then \
		echo "Symphony bootstrap failed: missing ./$(ELIXIR_APP_DIR) application directory."; \
		exit 1; \
	fi; \
	if command -v mise >/dev/null 2>&1; then \
		cd "$(ELIXIR_APP_DIR)"; \
		mise trust >/dev/null; \
		mise install; \
		exec mise exec -- $(MAKE) setup; \
	fi; \
	if command -v mix >/dev/null 2>&1; then \
		exec $(MAKE) -C "$(ELIXIR_APP_DIR)" setup; \
	fi; \
	echo "Symphony bootstrap failed: install mise or provide mix on PATH."; \
	exit 1
