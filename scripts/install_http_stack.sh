#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PUBLIC_HOST="${1:-}"
if [[ -z "${PUBLIC_HOST}" ]]; then
  PUBLIC_HOST="$(curl -4 -fsS https://ifconfig.me 2>/dev/null || true)"
fi
if [[ -z "${PUBLIC_HOST}" ]]; then
  PUBLIC_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
if [[ -z "${PUBLIC_HOST}" ]]; then
  echo "Could not detect public host. Pass it explicitly: $0 <server-ip-or-hostname>" >&2
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
  AS_ROOT_USER="root"
else
  SUDO="sudo"
  AS_ROOT_USER="${USER}"
fi

run_as_nostr() {
  if [[ "${EUID}" -eq 0 ]]; then
    runuser -u nostr -- "$@"
  else
    sudo -u nostr "$@"
  fi
}

echo "==> Installing base packages"
${SUDO} apt-get update
${SUDO} apt-get install -y curl git ca-certificates gnupg build-essential nginx ufw jq

NODE_MAJOR=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
fi
if [[ "${NODE_MAJOR}" -lt 20 ]]; then
  echo "==> Installing Node.js 20.x"
  curl -fsSL https://deb.nodesource.com/setup_20.x | ${SUDO} -E bash -
  ${SUDO} apt-get install -y nodejs
fi

${SUDO} corepack enable

echo "==> Creating system user and directories"
if ! id -u nostr >/dev/null 2>&1; then
  ${SUDO} useradd --system --create-home --home /opt/nostr --shell /usr/sbin/nologin nostr
fi
${SUDO} mkdir -p /opt/nostr/src /opt/nostr/config /var/www/coracle
${SUDO} chown -R nostr:nostr /opt/nostr

clone_or_update_repo() {
  local url="$1"
  local dst="$2"

  if [[ -d "${dst}/.git" ]]; then
    echo "==> Updating $(basename "${dst}")"
    run_as_nostr git -C "${dst}" fetch --prune origin
    run_as_nostr git -C "${dst}" pull --ff-only
  else
    echo "==> Cloning $(basename "${dst}")"
    run_as_nostr git clone --depth 1 "${url}" "${dst}"
  fi
}

clone_or_update_repo https://github.com/rrainn/nostr-relay.git /opt/nostr/src/nostr-relay
clone_or_update_repo https://github.com/imksoo/nostr-filter.git /opt/nostr/src/nostr-filter
clone_or_update_repo https://github.com/coracle-social/coracle.git /opt/nostr/src/coracle

echo "==> Building nostr-relay"
run_as_nostr bash -lc 'cd /opt/nostr/src/nostr-relay && npm ci && npm run build'

if [[ ! -f /opt/nostr/config/nostr-relay.config.json ]]; then
  ${SUDO} cp "${REPO_DIR}/deploy/templates/nostr-relay.config.json" /opt/nostr/config/nostr-relay.config.json
  ${SUDO} chown nostr:nostr /opt/nostr/config/nostr-relay.config.json
fi
${SUDO} ln -sfn /opt/nostr/config/nostr-relay.config.json /opt/nostr/src/nostr-relay/config.json

echo "==> Building nostr-filter"
run_as_nostr bash -lc 'cd /opt/nostr/src/nostr-filter && npm ci && npx tsc'

if [[ ! -f /opt/nostr/config/nostr-filter.env ]]; then
  ${SUDO} cp "${REPO_DIR}/deploy/templates/nostr-filter.env" /opt/nostr/config/nostr-filter.env
  ${SUDO} chown nostr:nostr /opt/nostr/config/nostr-filter.env
fi

echo "==> Building Coracle static bundle"
run_as_nostr bash -lc "cd /opt/nostr/src/coracle && sed 's|__PUBLIC_HOST__|${PUBLIC_HOST}|g' '${REPO_DIR}/deploy/templates/coracle.env.local' > .env.local"
run_as_nostr bash -lc 'cd /opt/nostr/src/coracle && corepack prepare pnpm@latest --activate && CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile && pnpm exec vite build'

${SUDO} rm -rf /var/www/coracle/*
${SUDO} cp -a /opt/nostr/src/coracle/dist/. /var/www/coracle/
${SUDO} chown -R www-data:www-data /var/www/coracle

echo "==> Installing systemd units"
${SUDO} cp "${REPO_DIR}/deploy/systemd/nostr-relay.service" /etc/systemd/system/nostr-relay.service
${SUDO} cp "${REPO_DIR}/deploy/systemd/nostr-filter.service" /etc/systemd/system/nostr-filter.service
${SUDO} systemctl daemon-reload
${SUDO} systemctl enable --now nostr-relay.service nostr-filter.service

echo "==> Configuring nginx"
${SUDO} cp "${REPO_DIR}/deploy/nginx/bilbil-limits.conf" /etc/nginx/conf.d/bilbil-limits.conf
${SUDO} cp "${REPO_DIR}/deploy/nginx/bilbil-http.conf" /etc/nginx/sites-available/bilbil-http.conf
${SUDO} ln -sfn /etc/nginx/sites-available/bilbil-http.conf /etc/nginx/sites-enabled/bilbil-http.conf
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  ${SUDO} rm -f /etc/nginx/sites-enabled/default
fi
${SUDO} nginx -t
${SUDO} systemctl enable --now nginx
${SUDO} systemctl reload nginx

echo "==> Firewall rules"
${SUDO} ufw allow OpenSSH >/dev/null 2>&1 || true
${SUDO} ufw allow 80/tcp >/dev/null 2>&1 || true

UFW_STATUS="$(${SUDO} ufw status | head -n 1 || true)"
if echo "${UFW_STATUS}" | grep -qi inactive; then
  echo "UFW is inactive. If you want, enable later with: sudo ufw enable"
fi

echo

echo "Done."
echo "Coracle: http://${PUBLIC_HOST}/"
echo "Relay WS URL: ws://${PUBLIC_HOST}/relay"
echo "Relay NIP-11: curl -H 'Accept: application/nostr+json' http://${PUBLIC_HOST}/relay"
echo "Relay logs: sudo journalctl -u nostr-relay -f"
echo "Filter logs: sudo journalctl -u nostr-filter -f"
echo
echo "IMPORTANT:"
echo "  rrainn/nostr-relay currently requires write pubkeys in allowedPublicKeys."
echo "  Edit /opt/nostr/config/nostr-relay.config.json and set allowedPublicKeys,"
echo "  then restart relay: sudo systemctl restart nostr-relay"
