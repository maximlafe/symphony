#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/symphony_deploy.sh --image-repository <repo> --image-tag <tag> --image-digest <sha256:...> [--workflow-file <path>] [--required-codex-accounts-file <path>]
EOF
}

image_repository=""
image_tag=""
image_digest=""
workflow_file=""
required_codex_accounts_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --image-repository)
      image_repository="${2:-}"
      shift 2
      ;;
    --image-tag)
      image_tag="${2:-}"
      shift 2
      ;;
    --image-digest)
      image_digest="${2:-}"
      shift 2
      ;;
    --workflow-file)
      workflow_file="${2:-}"
      shift 2
      ;;
    --required-codex-accounts-file)
      required_codex_accounts_file="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

: "${image_repository:?--image-repository is required}"
: "${image_tag:?--image-tag is required}"
: "${image_digest:?--image-digest is required}"
: "${SYMPHONY_DEPLOY_HOST:?SYMPHONY_DEPLOY_HOST is required}"
: "${SYMPHONY_DEPLOY_USER:?SYMPHONY_DEPLOY_USER is required}"
: "${SYMPHONY_DEPLOY_COMPOSE_FILE:?SYMPHONY_DEPLOY_COMPOSE_FILE is required}"
: "${SYMPHONY_DEPLOY_ENV_FILE:?SYMPHONY_DEPLOY_ENV_FILE is required}"
: "${SYMPHONY_DEPLOY_HEALTHCHECK_URL:?SYMPHONY_DEPLOY_HEALTHCHECK_URL is required}"

ssh_port="${SYMPHONY_DEPLOY_SSH_PORT:-22}"
registry_host="${image_repository%%/*}"
image_ref="${image_repository}:${image_tag}"
image_digest_ref="${image_repository}@${image_digest}"
release_sha="${GITHUB_SHA:-unknown}"
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
remote="${SYMPHONY_DEPLOY_USER}@${SYMPHONY_DEPLOY_HOST}"
ssh_common_opts=(
  -i "${HOME}/.ssh/id_ed25519"
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="${HOME}/.ssh/known_hosts"
)

if [ -n "${workflow_file}" ] && [ ! -f "${workflow_file}" ]; then
  echo "Workflow file not found: ${workflow_file}" >&2
  exit 1
fi

if [ -n "${required_codex_accounts_file}" ] && [ ! -f "${required_codex_accounts_file}" ]; then
  echo "Required Codex accounts file not found: ${required_codex_accounts_file}" >&2
  exit 1
fi

if [ -n "${workflow_file}" ] && [ -n "${required_codex_accounts_file}" ]; then
  python3 "${script_dir}/validate_codex_accounts_contract.py" \
    --workflow-file "${workflow_file}" \
    --required-accounts-file "${required_codex_accounts_file}"
fi

if [ -n "${workflow_file}" ]; then
  remote_workflow_file="$(
    ssh "${ssh_common_opts[@]}" -p "${ssh_port}" "${remote}" \
      env SYMPHONY_DEPLOY_ENV_FILE="${SYMPHONY_DEPLOY_ENV_FILE}" bash -s <<'REMOTE'
set -euo pipefail
set -a
. "${SYMPHONY_DEPLOY_ENV_FILE}"
set +a
workflow_host_path="${SYMPHONY_WORKFLOW_HOST_PATH:?Set SYMPHONY_WORKFLOW_HOST_PATH in the deploy env file.}"
workflow_basename="$(basename "${SYMPHONY_WORKFLOW_PATH:?Set SYMPHONY_WORKFLOW_PATH in the deploy env file.}")"
printf '%s\n' "${workflow_host_path%/}/${workflow_basename}"
REMOTE
  )"
  ssh "${ssh_common_opts[@]}" -p "${ssh_port}" "${remote}" "mkdir -p \"$(dirname "${remote_workflow_file}")\""
  scp "${ssh_common_opts[@]}" -P "${ssh_port}" "${workflow_file}" "${remote}:${remote_workflow_file}"
  printf 'synced workflow file: %s -> %s\n' "${workflow_file}" "${remote_workflow_file}"
fi

ssh \
  "${ssh_common_opts[@]}" \
  -p "${ssh_port}" \
  "${remote}" \
  env \
    REGISTRY_HOST="${registry_host}" \
    SYMPHONY_DEPLOY_COMPOSE_FILE="${SYMPHONY_DEPLOY_COMPOSE_FILE}" \
    SYMPHONY_DEPLOY_ENV_FILE="${SYMPHONY_DEPLOY_ENV_FILE}" \
    SYMPHONY_DEPLOY_HEALTHCHECK_URL="${SYMPHONY_DEPLOY_HEALTHCHECK_URL}" \
    SYMPHONY_DEPLOY_POST_UP_COMMAND="${SYMPHONY_DEPLOY_POST_UP_COMMAND:-}" \
    SYMPHONY_DEPLOY_PRE_UP_COMMAND="${SYMPHONY_DEPLOY_PRE_UP_COMMAND:-}" \
    SYMPHONY_IMAGE="${image_ref}" \
    SYMPHONY_IMAGE_DIGEST="${image_digest}" \
    SYMPHONY_IMAGE_DIGEST_REF="${image_digest_ref}" \
    SYMPHONY_IMAGE_TAG="${image_tag}" \
    SYMPHONY_REGISTRY_PASSWORD="${SYMPHONY_REGISTRY_PASSWORD:-}" \
    SYMPHONY_REGISTRY_USERNAME="${SYMPHONY_REGISTRY_USERNAME:-}" \
    SYMPHONY_RELEASE_SHA="${release_sha}" \
    bash -s <<'REMOTE'
set -euo pipefail

if [ -n "${SYMPHONY_REGISTRY_USERNAME:-}" ] && [ -n "${SYMPHONY_REGISTRY_PASSWORD:-}" ]; then
  printf '%s' "${SYMPHONY_REGISTRY_PASSWORD}" | docker login "${REGISTRY_HOST}" -u "${SYMPHONY_REGISTRY_USERNAME}" --password-stdin >/dev/null
fi

set -a
. "${SYMPHONY_DEPLOY_ENV_FILE}"
set +a

export SYMPHONY_IMAGE="${SYMPHONY_IMAGE_DIGEST_REF}"
export SYMPHONY_IMAGE_TAG="${SYMPHONY_IMAGE_TAG}"
export SYMPHONY_IMAGE_DIGEST="${SYMPHONY_IMAGE_DIGEST}"
export SYMPHONY_RELEASE_SHA="${SYMPHONY_RELEASE_SHA}"

if [ -n "${SYMPHONY_DEPLOY_PRE_UP_COMMAND:-}" ]; then
  sh -lc "${SYMPHONY_DEPLOY_PRE_UP_COMMAND}"
fi

# Validate the Compose contract without persisting expanded env (includes secrets from env_file).
docker compose -f "${SYMPHONY_DEPLOY_COMPOSE_FILE}" config >/dev/null
docker compose -f "${SYMPHONY_DEPLOY_COMPOSE_FILE}" pull
docker compose -f "${SYMPHONY_DEPLOY_COMPOSE_FILE}" up -d --remove-orphans

if [ -n "${SYMPHONY_DEPLOY_POST_UP_COMMAND:-}" ]; then
  sh -lc "${SYMPHONY_DEPLOY_POST_UP_COMMAND}"
fi

if [ -n "${SYMPHONY_CONTAINER_NAME:-}" ]; then
  for _attempt in $(seq 1 20); do
    health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${SYMPHONY_CONTAINER_NAME}" 2>/dev/null || true)
    if [ "${health_status}" = "healthy" ] || [ "${health_status}" = "no-healthcheck" ]; then
      break
    fi
    sleep 3
  done
  printf 'container health: %s\n' "${health_status:-unknown}"
fi

for attempt in $(seq 1 20); do
  if curl -fsS "${SYMPHONY_DEPLOY_HEALTHCHECK_URL}" > /tmp/symphony-post-deploy-health.json; then
    exit 0
  fi
  if [ "${attempt}" -eq 20 ]; then
    docker compose -f "${SYMPHONY_DEPLOY_COMPOSE_FILE}" ps
    docker compose -f "${SYMPHONY_DEPLOY_COMPOSE_FILE}" logs --tail=200
    exit 1
  fi
  sleep 5
done
REMOTE

health_payload_file="$(mktemp)"
trap 'rm -f "${health_payload_file}"' EXIT

ssh "${ssh_common_opts[@]}" -p "${ssh_port}" "${remote}" "cat /tmp/symphony-post-deploy-health.json" > "${health_payload_file}"
cat "${health_payload_file}"

if [ -n "${required_codex_accounts_file}" ]; then
  python3 "${script_dir}/validate_codex_accounts_contract.py" \
    --state-json-file "${health_payload_file}" \
    --required-accounts-file "${required_codex_accounts_file}"
fi

ssh "${ssh_common_opts[@]}" -p "${ssh_port}" "${remote}" \
  env \
    SYMPHONY_DEPLOY_COMPOSE_FILE="${SYMPHONY_DEPLOY_COMPOSE_FILE}" \
    SYMPHONY_DEPLOY_ENV_FILE="${SYMPHONY_DEPLOY_ENV_FILE}" \
    bash -s <<'REMOTE'
set -euo pipefail
set -a
. "${SYMPHONY_DEPLOY_ENV_FILE}"
set +a
docker compose -f "${SYMPHONY_DEPLOY_COMPOSE_FILE}" ps
REMOTE
