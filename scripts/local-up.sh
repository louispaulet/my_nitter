#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SESSIONS_FILE="${ROOT_DIR}/secrets/sessions.jsonl"
HMAC_FILE="${ROOT_DIR}/secrets/hmac_key"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -f "${ENV_FILE}" ]] || die ".env not found. Run 'cp .env.example .env' and fill in the local values."
[[ -s "${SESSIONS_FILE}" ]] || die "${SESSIONS_FILE} is missing or empty. Run './scripts/create_session.py'."
[[ -s "${HMAC_FILE}" ]] || die "${HMAC_FILE} is missing or empty. Run './scripts/bootstrap.sh'."

command -v docker >/dev/null 2>&1 || die "Docker is required. Install Docker Desktop and try again."
docker compose version >/dev/null 2>&1 || die "Docker Compose is required. Install Docker Desktop and try again."

python3 "${ROOT_DIR}/scripts/create_session.py" --validate-only

exec docker compose \
    --env-file "${ENV_FILE}" \
    -f "${ROOT_DIR}/compose.local.yaml" \
    up --build "$@"

