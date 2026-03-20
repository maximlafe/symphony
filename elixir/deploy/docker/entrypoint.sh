#!/usr/bin/env bash
set -euo pipefail

: "${WORKFLOW_PATH:?WORKFLOW_PATH is required}"
: "${SYMPHONY_PORT:?SYMPHONY_PORT is required}"
: "${SYMPHONY_WORKSPACE_ROOT:?SYMPHONY_WORKSPACE_ROOT is required}"
: "${SYMPHONY_LOGS_ROOT:?SYMPHONY_LOGS_ROOT is required}"
: "${SOURCE_REPO_URL:?SOURCE_REPO_URL is required}"

export CODEX_HOME="${CODEX_HOME:-/root/.codex}"
export POETRY_NO_INTERACTION=1
export POETRY_VIRTUALENVS_IN_PROJECT="${POETRY_VIRTUALENVS_IN_PROJECT:-true}"

if [ -n "${SYMPHONY_REQUIRED_ENV_VARS:-}" ]; then
  missing_vars=0
  for var_name in $SYMPHONY_REQUIRED_ENV_VARS; do
    if [ -z "${!var_name:-}" ]; then
      echo "Required environment variable ${var_name} is missing." >&2
      missing_vars=1
    fi
  done
  if [ "$missing_vars" -ne 0 ]; then
    exit 1
  fi
fi

mkdir -p "$SYMPHONY_WORKSPACE_ROOT" "$SYMPHONY_LOGS_ROOT" "$CODEX_HOME/skills"

if [ -n "${GH_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1; then
  printf '%s' "$GH_TOKEN" | gh auth login --with-token >/dev/null
fi
gh auth setup-git >/dev/null 2>&1 || true

if [ -n "${OPENAI_API_KEY:-}" ] && ! codex login status >/dev/null 2>&1; then
  printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null
fi

cd /opt/symphony/elixir

exec ./bin/symphony \
  "$WORKFLOW_PATH" \
  --logs-root "$SYMPHONY_LOGS_ROOT" \
  --port "$SYMPHONY_PORT" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
