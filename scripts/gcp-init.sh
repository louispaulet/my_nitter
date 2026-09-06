#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_ENV="${ROOT_DIR}/deploy.env"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

read_env_value() {
    local key="$1"
    sed -n -E \
        "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*//p" \
        "${DEPLOY_ENV}" | head -n 1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

[[ -f "${DEPLOY_ENV}" ]] || die "deploy.env not found. Run 'cp deploy.env.example deploy.env' and fill in the deployment values."
command -v gcloud >/dev/null 2>&1 || die "gcloud is required. Install the Google Cloud CLI and try again."

GCP_PROJECT_ID="$(read_env_value GCP_PROJECT_ID)"
GCP_REGION="$(read_env_value GCP_REGION)"
GCP_REGION="${GCP_REGION:-europe-west1}"

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
[[ -n "${ACTIVE_ACCOUNT}" ]] || die "gcloud is not authenticated. Run 'gcloud auth login'."

if [[ -z "${GCP_PROJECT_ID}" ]]; then
    GCP_PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
    [[ "${GCP_PROJECT_ID}" != "(unset)" ]] || GCP_PROJECT_ID=""
fi
[[ -n "${GCP_PROJECT_ID}" ]] || die "No GCP project configured. Set GCP_PROJECT_ID in deploy.env or run 'gcloud config set project PROJECT_ID'."

gcloud projects describe "${GCP_PROJECT_ID}" --format='value(projectId)' >/dev/null \
    || die "GCP project '${GCP_PROJECT_ID}' could not be found or is not accessible."

gcloud config set project "${GCP_PROJECT_ID}" >/dev/null
gcloud config set run/region "${GCP_REGION}" >/dev/null

gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com \
    --project="${GCP_PROJECT_ID}"

echo "GCP initialization complete."
echo "Project: ${GCP_PROJECT_ID}"
echo "Region: ${GCP_REGION}"
echo "Account: ${ACTIVE_ACCOUNT}"

