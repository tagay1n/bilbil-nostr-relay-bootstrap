#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <public-ipv4> <email>

Issue a short-lived Let's Encrypt certificate for an IPv4 address
and switch nginx/Coracle to HTTPS/WSS on that IP.
Requires a host already bootstrapped with ./scripts/stack.sh install-http.
USAGE
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

PUBLIC_IP="$1"
EMAIL="$2"

if ! [[ "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Invalid IPv4 address: ${PUBLIC_IP}" >&2
  exit 1
fi

for octet in ${PUBLIC_IP//./ }; do
  if (( octet < 0 || octet > 255 )); then
    echo "Invalid IPv4 address: ${PUBLIC_IP}" >&2
    exit 1
  fi
done

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

STACK_ROOT="${STACK_ROOT:-/opt/nostr}"
SRC_ROOT="${STACK_ROOT}/src"
WWW_ROOT="${WWW_ROOT:-/var/www/coracle}"

LEGO_STATE_DIR="${STACK_ROOT}/acme"
CHALLENGE_WEBROOT="/var/www/certbot"
CERT_DIR="/etc/letsencrypt/live/${PUBLIC_IP}"
TMPDIR_CLEANUP=""
LEGO_RUN_PROFILE_ARGS=()
LEGO_RENEW_PROFILE_ARGS=()

cleanup() {
  if [[ -n "${TMPDIR_CLEANUP:-}" && -d "${TMPDIR_CLEANUP}" ]]; then
    rm -rf "${TMPDIR_CLEANUP}"
  fi
}
trap cleanup EXIT

require_prerequisites() {
  local missing=()

  for cmd in nginx systemctl; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Missing required commands: ${missing[*]}" >&2
    echo "Run this script on the bootstrapped VPS (after install-http)." >&2
    exit 1
  fi

  if [[ ! -d /etc/nginx/sites-available || ! -d /etc/nginx/sites-enabled ]]; then
    echo "Missing nginx site directories in /etc/nginx. Bootstrap first with install-http." >&2
    exit 1
  fi

  if ! ${SUDO} test -d "${SRC_ROOT}/coracle" || ! ${SUDO} test -d "${WWW_ROOT}"; then
    echo "Missing Coracle directories under ${SRC_ROOT}/coracle or ${WWW_ROOT}. Bootstrap first with install-http." >&2
    exit 1
  fi
}

install_lego_if_needed() {
  if command -v lego >/dev/null 2>&1; then
    return 0
  fi

  echo "==> Installing lego ACME client"
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y curl jq tar

  local arch
  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "Unsupported architecture for automatic lego install: $(uname -m)" >&2
      exit 1
      ;;
  esac

  local release_json asset_url tmpdir
  release_json="$(curl -fsSL https://api.github.com/repos/go-acme/lego/releases/latest)"
  asset_url="$(printf '%s' "${release_json}" | jq -r --arg arch "${arch}" '
    .assets[]
    | .browser_download_url
    | select(test("lego.*linux_" + $arch + "\\.tar\\.gz$"))
    ' | head -n 1)"
  if [[ -z "${asset_url}" || "${asset_url}" == "null" ]]; then
    echo "Could not find lego linux_${arch} tar.gz asset in latest release." >&2
    printf '%s' "${release_json}" | jq -r '.assets[].browser_download_url' >&2 || true
    exit 1
  fi

  tmpdir="$(mktemp -d)"
  TMPDIR_CLEANUP="${tmpdir}"

  curl -fsSL -o "${tmpdir}/lego.tar.gz" "${asset_url}"
  tar -xzf "${tmpdir}/lego.tar.gz" -C "${tmpdir}" lego
  ${SUDO} install -m 0755 "${tmpdir}/lego" /usr/local/bin/lego
  rm -rf "${tmpdir}"
  TMPDIR_CLEANUP=""
}

configure_lego_profile_args() {
  if lego run --help 2>&1 | grep -q -- "--profile"; then
    LEGO_RUN_PROFILE_ARGS=(--profile shortlived)
  else
    LEGO_RUN_PROFILE_ARGS=()
  fi

  if lego renew --help 2>&1 | grep -q -- "--profile"; then
    LEGO_RENEW_PROFILE_ARGS=(--profile shortlived)
  else
    LEGO_RENEW_PROFILE_ARGS=()
  fi

  if [[ "${#LEGO_RUN_PROFILE_ARGS[@]}" -eq 0 ]]; then
    echo "lego run does not support --profile; IP certificate issuance may fail on CA profile enforcement." >&2
  fi
}

issue_or_renew_ip_cert() {
  local crt_path="${LEGO_STATE_DIR}/certificates/${PUBLIC_IP}.crt"
  local key_path="${LEGO_STATE_DIR}/certificates/${PUBLIC_IP}.key"

  ${SUDO} mkdir -p "${LEGO_STATE_DIR}" "${CHALLENGE_WEBROOT}/.well-known/acme-challenge" "${CERT_DIR}"
  ${SUDO} chmod 755 "${CHALLENGE_WEBROOT}" "${CHALLENGE_WEBROOT}/.well-known" "${CHALLENGE_WEBROOT}/.well-known/acme-challenge"

  if ${SUDO} test -f "${crt_path}" && ${SUDO} test -f "${key_path}"; then
    echo "==> Renewing short-lived IP certificate"
    ${SUDO} lego \
      --accept-tos \
      --email "${EMAIL}" \
      --path "${LEGO_STATE_DIR}" \
      --domains "${PUBLIC_IP}" \
      --http \
      --http.webroot "${CHALLENGE_WEBROOT}" \
      renew --days 3 "${LEGO_RENEW_PROFILE_ARGS[@]}"
  else
    echo "==> Issuing short-lived IP certificate"
    ${SUDO} lego \
      --accept-tos \
      --email "${EMAIL}" \
      --path "${LEGO_STATE_DIR}" \
      --domains "${PUBLIC_IP}" \
      --http \
      --http.webroot "${CHALLENGE_WEBROOT}" \
      run "${LEGO_RUN_PROFILE_ARGS[@]}"
  fi

  ${SUDO} install -m 0644 "${crt_path}" "${CERT_DIR}/fullchain.pem"
  ${SUDO} install -m 0600 "${key_path}" "${CERT_DIR}/privkey.pem"
}

configure_nginx_tls() {
  echo "==> Configuring nginx for HTTPS on ${PUBLIC_IP}"
  sed "s|__DOMAIN__|${PUBLIC_IP}|g" "${REPO_DIR}/deploy/nginx/bilbil-https.conf" \
    | ${SUDO} tee /etc/nginx/sites-available/bilbil-http.conf >/dev/null
  ${SUDO} nginx -t
  ${SUDO} systemctl reload nginx
}

ensure_http_challenge_route() {
  if ! ${SUDO} grep -q "/.well-known/acme-challenge/" /etc/nginx/sites-available/bilbil-http.conf 2>/dev/null; then
    echo "==> Ensuring nginx serves ACME challenge on port 80"
    ${SUDO} cp "${REPO_DIR}/deploy/nginx/bilbil-http.conf" /etc/nginx/sites-available/bilbil-http.conf
    ${SUDO} ln -sfn /etc/nginx/sites-available/bilbil-http.conf /etc/nginx/sites-enabled/bilbil-http.conf
    ${SUDO} nginx -t
    ${SUDO} systemctl reload nginx
  fi
}

rebuild_coracle_wss() {
  echo "==> Rebuilding Coracle defaults to wss://${PUBLIC_IP}/relay"
  local tmp_env
  tmp_env="$(mktemp)"
  sed "s|__PUBLIC_HOST__|${PUBLIC_IP}|g" "${REPO_DIR}/deploy/templates/coracle.env.local" > "${tmp_env}"
  sed -i 's|ws://|wss://|g' "${tmp_env}"

  ${SUDO} cp "${tmp_env}" "${SRC_ROOT}/coracle/.env.local"
  ${SUDO} chown nostr:nostr "${SRC_ROOT}/coracle/.env.local"
  rm -f "${tmp_env}"

  if [[ "${EUID}" -eq 0 ]]; then
    runuser -u nostr -- bash -lc 'cd "'"${SRC_ROOT}/coracle"'" && corepack prepare pnpm@latest --activate && CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile && pnpm exec vite build'
  else
    sudo -u nostr bash -lc 'cd "'"${SRC_ROOT}/coracle"'" && corepack prepare pnpm@latest --activate && CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile && pnpm exec vite build'
  fi

  ${SUDO} find "${WWW_ROOT:?}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  ${SUDO} cp -a "${SRC_ROOT}/coracle/dist/." "${WWW_ROOT}/"
  ${SUDO} chown -R www-data:www-data "${WWW_ROOT}"
  ${SUDO} systemctl reload nginx
}

require_prerequisites
install_lego_if_needed
configure_lego_profile_args
ensure_http_challenge_route
issue_or_renew_ip_cert
configure_nginx_tls
rebuild_coracle_wss

echo "TLS enabled for IP."
echo "Coracle: https://${PUBLIC_IP}/"
echo "Relay URL: wss://${PUBLIC_IP}/relay"
echo
echo "Note: Let's Encrypt IP certificates are short-lived. Re-run this command periodically."
