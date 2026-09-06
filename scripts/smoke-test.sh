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

[[ -f "${DEPLOY_ENV}" ]] || die "deploy.env not found."
command -v gcloud >/dev/null 2>&1 || die "gcloud is required."
command -v curl >/dev/null 2>&1 || die "curl is required."

GCP_PROJECT_ID="$(read_env_value GCP_PROJECT_ID)"
GCP_REGION="$(read_env_value GCP_REGION)"
CLOUD_RUN_SERVICE="$(read_env_value CLOUD_RUN_SERVICE)"
GCP_REGION="${GCP_REGION:-europe-west1}"
CLOUD_RUN_SERVICE="${CLOUD_RUN_SERVICE:-my-nitter}"
if [[ -z "${GCP_PROJECT_ID}" ]]; then
    GCP_PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
    [[ "${GCP_PROJECT_ID}" != "(unset)" ]] || GCP_PROJECT_ID=""
fi
[[ -n "${GCP_PROJECT_ID}" ]] || die "No GCP project configured."

metadata_file="$(mktemp "${TMPDIR:-/tmp}/my-nitter-cloudrun.XXXXXX.json")"
trap 'rm -f "${metadata_file}"' EXIT
gcloud run services describe "${CLOUD_RUN_SERVICE}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --format=json > "${metadata_file}"

python3 - "${metadata_file}" <<'PY'
import json
import sys
from pathlib import Path


def nested(data, *keys):
    for key in keys:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
    return data


service = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not service.get("status", {}).get("url"):
    raise SystemExit("ERROR: Cloud Run service has no URL.")

conditions = service.get("status", {}).get("conditions", [])
ready = next((item for item in conditions if item.get("type") == "Ready"), None)
if ready is None or ready.get("status") != "True":
    raise SystemExit("ERROR: Cloud Run service is not Ready.")

template = nested(service, "spec", "template") or service.get("template", {})
scaling = template.get("scaling", {})
annotations = nested(template, "metadata", "annotations") or {}
service_annotations = service.get("metadata", {}).get("annotations", {})
min_instances = scaling.get("minInstanceCount")
max_instances = scaling.get("maxInstanceCount")
if min_instances is None:
    min_instances = service_annotations.get("run.googleapis.com/minScale")
if min_instances is None:
    min_instances = annotations.get("autoscaling.knative.dev/minScale")
if min_instances is None:
    min_instances = 0
if max_instances is None:
    max_instances = service_annotations.get("run.googleapis.com/maxScale")
if max_instances is None:
    max_instances = annotations.get("autoscaling.knative.dev/maxScale")
if str(min_instances) != "0":
    raise SystemExit(f"ERROR: expected minimum instances 0, found {min_instances!r}.")
if str(max_instances) != "1":
    raise SystemExit(f"ERROR: expected maximum instances 1, found {max_instances!r}.")

if annotations.get("run.googleapis.com/cpu-throttling") == "false":
    raise SystemExit("ERROR: CPU throttling is disabled.")

containers = template.get("containers") or nested(template, "spec", "containers") or []
names = {container.get("name") for container in containers}
if not {"nitter", "valkey"}.issubset(names):
    raise SystemExit(f"ERROR: expected nitter and valkey containers, found {sorted(names)}.")

nitter = next(container for container in containers if container.get("name") == "nitter")
ports = {port.get("containerPort") for port in nitter.get("ports", [])}
if 8080 not in ports and "8080" not in ports:
    raise SystemExit("ERROR: nitter ingress container does not expose port 8080.")

all_env_names = {
    item.get("name")
    for container in containers
    for item in container.get("env", [])
}
for required in {"NITTER_HOSTNAME", "NITTER_REDIS_HOST", "NITTER_SESSIONS_FILE", "NITTER_HMAC_FILE"}:
    if required not in all_env_names:
        raise SystemExit(f"ERROR: required runtime variable {required} is missing.")
for forbidden in {"X_USERNAME", "X_PASSWORD", "X_TOTP_SECRET"}:
    if forbidden in all_env_names:
        raise SystemExit(f"ERROR: forbidden credential variable {forbidden} is present.")

all_volumes = template.get("volumes") or nested(template, "spec", "volumes") or []
secret_volume_names = {
    volume.get("name")
    for volume in all_volumes
    if volume.get("secret") or volume.get("secretName")
}
mounted_volume_names = {
    mount.get("name")
    for mount in nitter.get("volumeMounts", [])
    if str(mount.get("mountPath", "")).startswith("/run/secrets")
}
if len(secret_volume_names & mounted_volume_names) < 2:
    raise SystemExit("ERROR: expected both Secret Manager files mounted under /run/secrets.")

secret_mount_paths = {
    mount.get("mountPath")
    for mount in nitter.get("volumeMounts", [])
    if mount.get("name") in secret_volume_names
}
if not {"/run/secrets/sessions", "/run/secrets/hmac"}.issubset(secret_mount_paths):
    raise SystemExit(f"ERROR: expected distinct stable secret mount directories, found {sorted(secret_mount_paths)}.")

runtime_env = {
    item.get("name"): item.get("value")
    for container in containers
    for item in container.get("env", [])
}
if runtime_env.get("NITTER_ALLOW_EPHEMERAL_HMAC") == "true":
    raise SystemExit("ERROR: temporary bootstrap HMAC mode is still enabled.")

print("Cloud Run configuration checks passed")
print("Containers: nitter, valkey")
print("Minimum instances: 0")
print("Maximum instances: 1")
print("Credential environment variables: absent")
print("Secret mounts: stable sessions and HMAC files present")
PY

SERVICE_URL="$(gcloud run services describe "${CLOUD_RUN_SERVICE}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --format='value(status.url)')"
TOKEN="$(gcloud auth print-identity-token)"

curl --fail --silent --show-error --max-time 90 \
    -H "Authorization: Bearer ${TOKEN}" \
    "${SERVICE_URL}/" >/dev/null

TEST_PROFILE="${NITTER_TEST_PROFILE:-Jack}"
curl --fail --silent --show-error --max-time 90 \
    -H "Authorization: Bearer ${TOKEN}" \
    "${SERVICE_URL}/${TEST_PROFILE}" >/dev/null

echo "HTTP smoke tests passed"
echo "Service URL: ${SERVICE_URL}"
echo "Profile tested: ${TEST_PROFILE}"
