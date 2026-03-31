#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/symphony_deploy.sh --image-repository <repo> --image-tag <tag> --image-digest <sha256:...>
EOF
}

image_repository=""
image_tag=""
image_digest=""

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

ssh \
  -i "${HOME}/.ssh/id_ed25519" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
  -p "${ssh_port}" \
  "${SYMPHONY_DEPLOY_USER}@${SYMPHONY_DEPLOY_HOST}" \
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

docker compose -f "${SYMPHONY_DEPLOY_COMPOSE_FILE}" config >/tmp/symphony-compose.rendered.yml
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
    cat /tmp/symphony-post-deploy-health.json
    docker compose -f "${SYMPHONY_DEPLOY_COMPOSE_FILE}" ps
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

