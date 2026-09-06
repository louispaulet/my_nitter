#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -f "${ENV_FILE}" ]] || die ".env not found. Run 'cp .env.example .env'."
command -v git >/dev/null 2>&1 || die "git is required."

current_ref="$(sed -n -E \
    's/^[[:space:]]*(export[[:space:]]+)?NITTER_REF[[:space:]]*=[[:space:]]*//p' \
    "${ENV_FILE}" | head -n 1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
latest_ref="$(git ls-remote https://github.com/zedeus/nitter.git refs/heads/master | awk '{print $1}')"

[[ "${current_ref}" =~ ^[0-9a-fA-F]{40}$ ]] || die "NITTER_REF in .env is not an exact 40-character commit SHA."
[[ "${latest_ref}" =~ ^[0-9a-fA-F]{40}$ ]] || die "Could not read the latest upstream Nitter commit SHA."

echo "Current pinned Nitter: ${current_ref}"
echo "Latest upstream master: ${latest_ref}"
if [[ "${current_ref}" == "${latest_ref}" ]]; then
    echo "Already up to date."
    exit 0
fi

echo "Update available."
if [[ "${1:-}" == "--write" ]]; then
    temporary_file="$(mktemp "${ENV_FILE}.XXXXXX")"
    trap 'rm -f "${temporary_file}"' EXIT
    awk -v latest="${latest_ref}" '
        /^[[:space:]]*(export[[:space:]]+)?NITTER_REF[[:space:]]*=/ {
            prefix = $0
            sub(/[=].*$/, "=", prefix)
            print prefix latest
            replaced = 1
            next
        }
        { print }
        END {
            if (!replaced) print "NITTER_REF=" latest
        }
    ' "${ENV_FILE}" > "${temporary_file}"
    chmod 600 "${temporary_file}"
    mv -f "${temporary_file}" "${ENV_FILE}"
    trap - EXIT
    echo "Updated local .env. Rebuild and validate locally before deploying."
fi

