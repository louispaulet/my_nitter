#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
CACHE_DIR="${ROOT_DIR}/.cache"
NITTER_DIR="${CACHE_DIR}/nitter"
VENV_DIR="${ROOT_DIR}/.venv"
SECRETS_DIR="${ROOT_DIR}/secrets"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found in PATH."
}

read_env_value() {
    local key="$1"
    sed -n -E \
        "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*//p" \
        "${ENV_FILE}" | head -n 1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

[[ -f "${ENV_FILE}" ]] || die ".env not found. Run 'cp .env.example .env' and fill in the local values."

for command_name in git python3 docker openssl; do
    require_command "${command_name}"
done
docker compose version >/dev/null 2>&1 || die "Docker Compose is required. Install Docker Desktop and try again."

NITTER_REF="$(read_env_value NITTER_REF)"
[[ "${NITTER_REF}" =~ ^[0-9a-fA-F]{40}$ ]] || die "NITTER_REF must be an exact 40-character upstream Git commit SHA."

mkdir -p "${CACHE_DIR}" "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

if [[ ! -d "${NITTER_DIR}/.git" ]]; then
    [[ ! -e "${NITTER_DIR}" ]] || die "${NITTER_DIR} exists but is not a Git checkout. Move it aside and retry."
    git clone --filter=blob:none https://github.com/zedeus/nitter.git "${NITTER_DIR}"
else
    git -C "${NITTER_DIR}" remote get-url origin >/dev/null 2>&1 \
        || die "${NITTER_DIR} has no usable origin remote."
    git -C "${NITTER_DIR}" fetch --prune origin
fi

git -C "${NITTER_DIR}" fetch --depth=1 origin "${NITTER_REF}"
git -C "${NITTER_DIR}" checkout --detach "${NITTER_REF}"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    python3 -m venv "${VENV_DIR}"
fi

"${VENV_DIR}/bin/python" -m pip install \
    --disable-pip-version-check \
    -r "${NITTER_DIR}/tools/requirements.txt"

if [[ ! -s "${SECRETS_DIR}/hmac_key" ]]; then
    temporary_hmac="$(mktemp "${SECRETS_DIR}/.hmac_key.XXXXXX")"
    trap 'rm -f "${temporary_hmac}"' EXIT
    openssl rand -hex 32 > "${temporary_hmac}"
    chmod 600 "${temporary_hmac}"
    mv -f "${temporary_hmac}" "${SECRETS_DIR}/hmac_key"
    trap - EXIT
else
    chmod 600 "${SECRETS_DIR}/hmac_key"
fi

echo "Bootstrap complete."
echo "Upstream Nitter: ${NITTER_REF}"
echo "Python environment: ${VENV_DIR}"
echo "HMAC key: configured locally"

