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

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
[[ -n "${ACTIVE_ACCOUNT}" ]] || die "gcloud is not authenticated. Run 'gcloud auth login'."
if [[ "${ACTIVE_ACCOUNT}" == *"gserviceaccount.com" ]]; then
    INVOKER_MEMBER="serviceAccount:${ACTIVE_ACCOUNT}"
else
    INVOKER_MEMBER="user:${ACTIVE_ACCOUNT}"
fi
IAM_POLICY="$(gcloud run services get-iam-policy "${CLOUD_RUN_SERVICE}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" \
    --format=json)"
if ! IAM_POLICY="${IAM_POLICY}" python3 - "${INVOKER_MEMBER}" <<'PY'
import json
import os
import sys

policy = json.loads(os.environ["IAM_POLICY"])
principal = sys.argv[1]
bindings = policy.get("bindings", [])
broad_members = {"allUsers", "allAuthenticatedUsers"}
if any(
    binding.get("role") == "roles/run.invoker"
    and broad_members.intersection(binding.get("members", []))
    for binding in bindings
):
    raise SystemExit("ERROR: Cloud Run still grants invoke access to a broad principal.")
if not any(
    binding.get("role") == "roles/run.invoker"
    and principal in binding.get("members", [])
    for binding in bindings
):
    raise SystemExit("ERROR: active gcloud identity is missing roles/run.invoker.")
PY
then
    die "Cloud Run IAM allowlist checks failed."
fi

python3 - "${metadata_file}" "${GCP_PROJECT_ID}" "${GCP_REGION}" "${CLOUD_RUN_SERVICE}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

service = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
hosts = {urlparse(service.get("status", {}).get("url", "")).netloc}
annotations = service.get("metadata", {}).get("annotations", {})
try:
    urls = json.loads(annotations.get("run.googleapis.com/urls", "[]"))
except json.JSONDecodeError:
    urls = []
hosts.update(urlparse(value).netloc for value in urls)
domain_mappings = subprocess.run(
    ["gcloud", "beta", "run", "domain-mappings", "list",
     "--project=" + sys.argv[2], "--region=" + sys.argv[3], "--format=json"],
    check=True, capture_output=True, text=True,
).stdout
domain_data = json.loads(domain_mappings)
if isinstance(domain_data, dict):
    domain_data = domain_data.get("items", [])
for mapping in domain_data:
    if mapping.get("spec", {}).get("routeName") == sys.argv[4]:
        domain = mapping.get("metadata", {}).get("name", "")
        hosts.add(urlparse(domain if "://" in domain else f"https://{domain}").netloc)
for host in sorted(host for host in hosts if host):
    result = subprocess.run(
        ["curl", "--silent", "--show-error", "--max-time", "30", "-o", "/dev/null",
         "-w", "%{http_code}", f"https://{host}/"],
        check=True, capture_output=True, text=True,
    )
    if result.stdout not in {"401", "403"}:
        raise SystemExit(f"ERROR: anonymous access to a Cloud Run URL returned HTTP {result.stdout}.")
print("Anonymous access blocked on the service URL aliases")
PY
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
echo "Access: IAM allowlist; anonymous requests blocked"
