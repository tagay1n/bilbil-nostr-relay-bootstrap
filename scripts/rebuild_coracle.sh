#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <public-host-or-domain>" >&2
  exit 1
fi

PUBLIC_HOST="$1"

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

sed "s|__PUBLIC_HOST__|${PUBLIC_HOST}|g" "${REPO_DIR}/deploy/templates/coracle.env.local" \
  | ${SUDO} tee /opt/nostr/src/coracle/.env.local >/dev/null
${SUDO} chown nostr:nostr /opt/nostr/src/coracle/.env.local
run_as_nostr bash -lc 'cd /opt/nostr/src/coracle && corepack prepare pnpm@latest --activate && CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile && pnpm exec vite build'

${SUDO} rm -rf /var/www/coracle/*
${SUDO} cp -a /opt/nostr/src/coracle/dist/. /var/www/coracle/
${SUDO} chown -R www-data:www-data /var/www/coracle
${SUDO} systemctl reload nginx

echo "Coracle rebuilt."
echo "If host is a domain with TLS, relay URL will be wss://${PUBLIC_HOST}/relay"
