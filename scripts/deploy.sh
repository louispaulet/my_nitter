#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
DEPLOY_ENV="${ROOT_DIR}/deploy.env"
SESSIONS_FILE="${ROOT_DIR}/secrets/sessions.jsonl"
HMAC_FILE="${ROOT_DIR}/secrets/hmac_key"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

read_value() {
    local file="$1"
    local key="$2"
    sed -n -E \
        "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*//p" \
        "${file}" | head -n 1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

[[ -f "${ENV_FILE}" ]] || die ".env not found. Run 'cp .env.example .env' and fill in NITTER_REF."
[[ -f "${DEPLOY_ENV}" ]] || die "deploy.env not found. Run 'cp deploy.env.example deploy.env' and fill in the deployment values."
[[ -s "${SESSIONS_FILE}" ]] || die "${SESSIONS_FILE} is missing or empty. Run './scripts/create_session.py'."
[[ -s "${HMAC_FILE}" ]] || die "${HMAC_FILE} is missing or empty. Run './scripts/bootstrap.sh'."

command -v gcloud >/dev/null 2>&1 || die "gcloud is required. Install the Google Cloud CLI and try again."

# Homebrew's gcloud wrapper may not add the SDK bin directory to PATH. The
# Compose command dispatches to the run-compose binary, so make that component
# discoverable without relying on a particular installation method.
GCLOUD_SDK_ROOT="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null || true)"
if [[ -n "${GCLOUD_SDK_ROOT}" && -x "${GCLOUD_SDK_ROOT}/bin/run-compose" ]]; then
    PATH="${GCLOUD_SDK_ROOT}/bin:${PATH}"
    export PATH
fi
command -v run-compose >/dev/null 2>&1 || die "The gcloud 'run-compose' component is required. Install it with 'gcloud components install run-compose'."
gcloud run compose up --help >/dev/null 2>&1 || die "This gcloud installation does not provide 'gcloud run compose'."

NITTER_REF="$(read_value "${ENV_FILE}" NITTER_REF)"
[[ "${NITTER_REF}" =~ ^[0-9a-fA-F]{40}$ ]] || die "NITTER_REF must be an exact 40-character upstream Git commit SHA."
GCP_PROJECT_ID="$(read_value "${DEPLOY_ENV}" GCP_PROJECT_ID)"
GCP_REGION="$(read_value "${DEPLOY_ENV}" GCP_REGION)"
CLOUD_RUN_SERVICE="$(read_value "${DEPLOY_ENV}" CLOUD_RUN_SERVICE)"
GCP_REGION="${GCP_REGION:-europe-west1}"
CLOUD_RUN_SERVICE="${CLOUD_RUN_SERVICE:-my-nitter}"

[[ "${CLOUD_RUN_SERVICE}" =~ ^[a-z][a-z0-9-]{0,48}$ ]] \
    || die "CLOUD_RUN_SERVICE must be a lowercase Cloud Run service name (maximum 49 characters)."
[[ "${GCP_REGION}" =~ ^[a-z0-9-]+$ ]] || die "GCP_REGION contains invalid characters."

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
[[ -n "${ACTIVE_ACCOUNT}" ]] || die "gcloud is not authenticated. Run 'gcloud auth login'."

if [[ -z "${GCP_PROJECT_ID}" ]]; then
    GCP_PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
    [[ "${GCP_PROJECT_ID}" != "(unset)" ]] || GCP_PROJECT_ID=""
fi
[[ -n "${GCP_PROJECT_ID}" ]] || die "No GCP project configured. Set GCP_PROJECT_ID in deploy.env."

gcloud projects describe "${GCP_PROJECT_ID}" --format='value(projectId)' >/dev/null \
    || die "GCP project '${GCP_PROJECT_ID}' could not be found or is not accessible."

gcloud config set project "${GCP_PROJECT_ID}" >/dev/null
gcloud config set run/region "${GCP_REGION}" >/dev/null

"${ROOT_DIR}/scripts/create_session.py" --validate-only

ensure_secret() {
    local secret_name="$1"
    local secret_file="$2"
    if ! gcloud secrets describe "${secret_name}" --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
        gcloud secrets create "${secret_name}" \
            --replication-policy=automatic \
            --project="${GCP_PROJECT_ID}" >/dev/null
    fi
    gcloud secrets versions add "${secret_name}" \
        --data-file="${secret_file}" \
        --project="${GCP_PROJECT_ID}" >/dev/null
}

ensure_secret my-nitter-sessions "${SESSIONS_FILE}"
ensure_secret my-nitter-hmac "${HMAC_FILE}"

existing_url="$(gcloud run services describe "${CLOUD_RUN_SERVICE}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --format='value(status.url)' 2>/dev/null || true)"
if [[ -n "${existing_url}" ]]; then
    NITTER_HOSTNAME="${existing_url#https://}"
else
    # Cloud Run's generated URL is not assumed. The first deploy uses a
    # temporary hostname and is corrected from status.url afterward.
    NITTER_HOSTNAME="${CLOUD_RUN_SERVICE}.run.app"
fi

deploy_compose() {
    local build_flag="$1"
    env \
        CLOUD_RUN_SERVICE="${CLOUD_RUN_SERVICE}" \
        NITTER_REF="${NITTER_REF}" \
        NITTER_HOSTNAME="${NITTER_HOSTNAME}" \
        gcloud run compose up "${ROOT_DIR}/compose.cloudrun.yaml" \
            --region="${GCP_REGION}" \
            --project="${GCP_PROJECT_ID}" \
            --no-allow-unauthenticated \
            "${build_flag}"
}

deploy_compose --build

deployed_url="$(gcloud run services describe "${CLOUD_RUN_SERVICE}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --format='value(status.url)')"
actual_hostname="${deployed_url#https://}"
if [[ "${actual_hostname}" != "${NITTER_HOSTNAME}" ]]; then
    NITTER_HOSTNAME="${actual_hostname}"
    deploy_compose --no-build
fi

gcloud run services update "${CLOUD_RUN_SERVICE}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --min=0 \
    --max=1 \
    --cpu-throttling \
    --concurrency=4 \
    --no-allow-unauthenticated \
    >/dev/null

SERVICE_URL="$(gcloud run services describe "${CLOUD_RUN_SERVICE}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --format='value(status.url)')"

echo "Deployment complete"
echo "Service: ${CLOUD_RUN_SERVICE}"
echo "Region: ${GCP_REGION}"
echo "URL: ${SERVICE_URL}"
echo "Nitter ref: ${NITTER_REF}"
echo "Minimum instances: 0"
echo "Maximum instances: 1"
echo "Access: authenticated"
echo "Billing: request-based"
echo "X session: configured"
echo "X password: NOT uploaded"
echo "X TOTP secret: NOT uploaded"
