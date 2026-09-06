#!/bin/sh
set -eu

: "${NITTER_HOSTNAME:?NITTER_HOSTNAME is required}"
: "${NITTER_REDIS_HOST:=valkey}"
: "${NITTER_HTTPS:=true}"
: "${NITTER_CONF_FILE:=/tmp/nitter.conf}"
: "${NITTER_SESSIONS_FILE:=/run/secrets/nitter_sessions}"
: "${NITTER_HMAC_FILE:=/run/secrets/nitter_hmac}"
: "${NITTER_ALLOW_EPHEMERAL_HMAC:=false}"

if [ ! -f "${NITTER_SESSIONS_FILE}" ]; then
    echo "ERROR: Nitter sessions file is missing." >&2
    exit 1
fi

if [ ! -s "${NITTER_SESSIONS_FILE}" ]; then
    echo "ERROR: Nitter sessions file is empty." >&2
    exit 1
fi

umask 077
if [ -f "${NITTER_HMAC_FILE}" ]; then
    if [ ! -s "${NITTER_HMAC_FILE}" ]; then
        echo "ERROR: Nitter HMAC secret is empty." >&2
        exit 1
    fi
    NITTER_HMAC_KEY="$(cat "${NITTER_HMAC_FILE}")"
elif [ "${NITTER_ALLOW_EPHEMERAL_HMAC}" = "true" ]; then
    echo "No HMAC file mounted; generating a temporary bootstrap key."
    NITTER_HMAC_KEY="$(openssl rand -hex 32)"
else
    echo "ERROR: Nitter HMAC secret is missing." >&2
    exit 1
fi
export NITTER_HMAC_KEY

echo "Waiting for Valkey at ${NITTER_REDIS_HOST}:6379..."

ready=0
for _ in $(seq 1 50); do
    if nc -z "${NITTER_REDIS_HOST}" 6379 >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.2
done

if [ "${ready}" != "1" ]; then
    echo "ERROR: Valkey did not become available." >&2
    exit 1
fi

envsubst "\${NITTER_HOSTNAME} \${NITTER_HTTPS} \${NITTER_REDIS_HOST} \${NITTER_HMAC_KEY}" \
    < /etc/nitter/nitter.conf.template \
    > "${NITTER_CONF_FILE}"

echo "Starting Nitter."
exec /src/nitter
