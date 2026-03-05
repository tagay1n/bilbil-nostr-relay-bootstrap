#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOCK_FILE="${ROOT_DIR}/deploy/versions.lock.json"

repos=(
  "nostr-relay https://github.com/rrainn/nostr-relay.git"
  "nostr-filter https://github.com/imksoo/nostr-filter.git"
  "coracle https://github.com/coracle-social/coracle.git"
)

tmp="$(mktemp)"
cp "${LOCK_FILE}" "${tmp}"

for item in "${repos[@]}"; do
  name="${item%% *}"
  url="${item#* }"
  sha="$(git ls-remote "${url}" HEAD | awk '{print $1}')"
  if [[ -z "${sha}" ]]; then
    echo "Failed to resolve HEAD for ${name}" >&2
    exit 1
  fi

  jq \
    --arg name "${name}" \
    --arg url "${url}" \
    --arg sha "${sha}" \
    '.components[$name].repo = $url | .components[$name].ref = $sha' \
    "${tmp}" >"${tmp}.next"
  mv "${tmp}.next" "${tmp}"
done

jq --arg now "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '.updated_at = $now' "${tmp}" >"${LOCK_FILE}"
rm -f "${tmp}"

echo "Updated ${LOCK_FILE}"
