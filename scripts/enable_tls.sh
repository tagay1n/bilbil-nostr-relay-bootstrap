#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <domain> <email>" >&2
  exit 1
fi

DOMAIN="$1"
EMAIL="$2"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

${SUDO} apt-get update
${SUDO} apt-get install -y certbot python3-certbot-nginx

${SUDO} certbot certonly --nginx -d "${DOMAIN}" --email "${EMAIL}" --agree-tos --non-interactive

sed "s|__DOMAIN__|${DOMAIN}|g" "${REPO_DIR}/deploy/nginx/bilbil-https.conf" | ${SUDO} tee /etc/nginx/sites-available/bilbil-http.conf >/dev/null
${SUDO} nginx -t
${SUDO} systemctl reload nginx

"${REPO_DIR}/scripts/rebuild_coracle.sh" "${DOMAIN}"

echo "TLS enabled."
echo "Coracle: https://${DOMAIN}/"
echo "Relay URL: wss://${DOMAIN}/relay"
