#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <public-host-or-domain> [ws|wss]" >&2
  exit 1
fi

PUBLIC_HOST="$1"
RELAY_SCHEME="${2:-ws}"

if [[ "${RELAY_SCHEME}" != "ws" && "${RELAY_SCHEME}" != "wss" ]]; then
  echo "Invalid relay scheme: ${RELAY_SCHEME} (expected ws or wss)" >&2
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

run_as_nostr() {
  if [[ "${EUID}" -eq 0 ]]; then
    runuser -u nostr -- "$@"
  else
    sudo -u nostr "$@"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_ROOT="${STACK_ROOT:-/opt/nostr}"
SRC_ROOT="${STACK_ROOT}/src"
WWW_ROOT="${WWW_ROOT:-/var/www/coracle}"

if ! ${SUDO} test -d "${SRC_ROOT}/coracle"; then
  echo "Missing ${SRC_ROOT}/coracle. Bootstrap first with install-http." >&2
  exit 1
fi

${SUDO} mkdir -p "${WWW_ROOT}"

tmp_env="$(mktemp)"
sed "s|__PUBLIC_HOST__|${PUBLIC_HOST}|g" "${REPO_DIR}/deploy/templates/coracle.env.local" > "${tmp_env}"
if [[ "${RELAY_SCHEME}" == "wss" ]]; then
  sed -i 's|ws://|wss://|g' "${tmp_env}"
fi

${SUDO} cp "${tmp_env}" "${SRC_ROOT}/coracle/.env.local"
${SUDO} chown nostr:nostr "${SRC_ROOT}/coracle/.env.local"
rm -f "${tmp_env}"

run_as_nostr bash -lc 'cd "'"${SRC_ROOT}/coracle"'" && corepack prepare pnpm@latest --activate && CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile && pnpm exec vite build'

${SUDO} find "${WWW_ROOT:?}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
${SUDO} cp -a "${SRC_ROOT}/coracle/dist/." "${WWW_ROOT}/"
${SUDO} chown -R www-data:www-data "${WWW_ROOT}"
${SUDO} systemctl reload nginx

echo "Coracle rebuilt."
echo "Relay URL default: ${RELAY_SCHEME}://${PUBLIC_HOST}/relay"
