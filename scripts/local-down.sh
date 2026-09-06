#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: .env not found. Run 'cp .env.example .env' before using local Compose." >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || {
    echo "ERROR: Docker is required. Install Docker Desktop and try again." >&2
    exit 1
}
docker compose version >/dev/null 2>&1 || {
    echo "ERROR: Docker Compose is required. Install Docker Desktop and try again." >&2
    exit 1
}

exec docker compose \
    --env-file "${ENV_FILE}" \
    -f "${ROOT_DIR}/compose.local.yaml" \
    down "$@"

