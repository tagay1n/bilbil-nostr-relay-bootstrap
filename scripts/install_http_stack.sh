#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<USAGE
Usage: $0 [--skip-build] [host-or-ip]

Options:
  --skip-build   Skip component builds/start; useful before immediate deploy
USAGE
}

SKIP_BUILD="false"
PUBLIC_HOST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "${PUBLIC_HOST}" ]]; then
        PUBLIC_HOST="$1"
        shift
      else
        echo "Unknown argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

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
else
  SUDO="sudo"
fi

apt_update_with_retry() {
  local max_attempts="${APT_UPDATE_MAX_ATTEMPTS:-5}"
  local retry_delay="${APT_UPDATE_RETRY_DELAY_SECONDS:-5}"
  local attempt

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ${SUDO} apt-get update -o Acquire::Retries=3; then
      return 0
    fi

    if (( attempt < max_attempts )); then
      echo "apt-get update failed (attempt ${attempt}/${max_attempts}), retrying in ${retry_delay}s..."
      sleep "${retry_delay}"
    fi
  done

  echo "apt-get update failed after ${max_attempts} attempts" >&2
  return 1
}

is_pkg_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"
}

run_as_nostr() {
  if [[ "${EUID}" -eq 0 ]]; then
    runuser -u nostr -- "$@"
  else
    sudo -u nostr "$@"
  fi
}

ensure_rust_toolchain() {
  local rustup_bin="/opt/nostr/.cargo/bin/rustup"

  if ! ${SUDO} test -x "${rustup_bin}"; then
    echo "==> Installing rustup toolchain for nostr user"
    run_as_nostr bash -lc 'curl https://sh.rustup.rs -sSf | sh -s -- -y'
  fi

  run_as_nostr bash -lc "\"${rustup_bin}\" toolchain install stable"
  run_as_nostr bash -lc "\"${rustup_bin}\" default stable"
}

echo "==> Installing base packages"
BASE_PACKAGES=(curl git ca-certificates gnupg build-essential cmake protobuf-compiler pkg-config libssl-dev zlib1g-dev nginx ufw jq)
MISSING_PACKAGES=()
for pkg in "${BASE_PACKAGES[@]}"; do
  if ! is_pkg_installed "${pkg}"; then
    MISSING_PACKAGES+=("${pkg}")
  fi
done

if [[ "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then
  apt_update_with_retry
  ${SUDO} apt-get install -y "${MISSING_PACKAGES[@]}"
else
  echo "Base packages are already installed."
fi

NODE_MAJOR=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
fi
if [[ "${NODE_MAJOR}" -lt 20 ]]; then
  echo "==> Installing Node.js 20.x"
  curl -fsSL https://deb.nodesource.com/setup_20.x | ${SUDO} -E bash -
  apt_update_with_retry
  ${SUDO} apt-get install -y nodejs
fi

${SUDO} corepack enable

echo "==> Creating system user and directories"
if ! id -u nostr >/dev/null 2>&1; then
  ${SUDO} useradd --system --create-home --home /opt/nostr --shell /usr/sbin/nologin nostr
fi
${SUDO} mkdir -p /opt/nostr/src /opt/nostr/config /opt/nostr/data/nostr-rs-relay /var/www/coracle /var/www/certbot/.well-known/acme-challenge
${SUDO} chown -R nostr:nostr /opt/nostr
${SUDO} chmod 755 /var/www/certbot /var/www/certbot/.well-known /var/www/certbot/.well-known/acme-challenge

clone_or_update_repo() {
  local url="$1"
  local dst="$2"

  if [[ "${dst}" != /opt/nostr/src/* ]]; then
    echo "Refusing unsafe clone path: ${dst}" >&2
    exit 1
  fi

  if ${SUDO} test -d "${dst}/.git"; then
    echo "==> Updating $(basename "${dst}")"
    ${SUDO} chown -R nostr:nostr "${dst}"
    run_as_nostr git -C "${dst}" fetch --prune origin
    run_as_nostr git -C "${dst}" pull --ff-only
  else
    if ${SUDO} test -e "${dst}"; then
      echo "==> Resetting non-git path $(basename "${dst}")"
      ${SUDO} rm -rf "${dst}"
    fi
    echo "==> Cloning $(basename "${dst}")"
    run_as_nostr git clone --depth 1 "${url}" "${dst}"
  fi
}

clone_or_update_repo https://github.com/scsibug/nostr-rs-relay.git /opt/nostr/src/nostr-rs-relay
clone_or_update_repo https://github.com/imksoo/nostr-filter.git /opt/nostr/src/nostr-filter
clone_or_update_repo https://github.com/coracle-social/coracle.git /opt/nostr/src/coracle

if [[ ! -f /opt/nostr/config/nostr-rs-relay.toml ]]; then
  sed "s|__PUBLIC_HOST__|${PUBLIC_HOST}|g" "${REPO_DIR}/deploy/templates/nostr-rs-relay.toml" \
    | ${SUDO} tee /opt/nostr/config/nostr-rs-relay.toml >/dev/null
  ${SUDO} chown nostr:nostr /opt/nostr/config/nostr-rs-relay.toml
fi

if [[ ! -f /opt/nostr/config/nostr-filter.env ]]; then
  ${SUDO} cp "${REPO_DIR}/deploy/templates/nostr-filter.env" /opt/nostr/config/nostr-filter.env
  ${SUDO} chown nostr:nostr /opt/nostr/config/nostr-filter.env
fi

ensure_rust_toolchain

if [[ "${SKIP_BUILD}" == "true" ]]; then
  echo "==> Skipping component builds (--skip-build)"
else
  echo "==> Building nostr-relay"
  run_as_nostr bash -lc 'cd /opt/nostr/src/nostr-rs-relay && ~/.cargo/bin/cargo build --release'

  echo "==> Building nostr-filter"
  run_as_nostr bash -lc 'cd /opt/nostr/src/nostr-filter && npm ci --no-audit --no-fund && npx tsc'

  echo "==> Building Coracle static bundle"
  sed "s|__PUBLIC_HOST__|${PUBLIC_HOST}|g" "${REPO_DIR}/deploy/templates/coracle.env.local" \
    | ${SUDO} tee /opt/nostr/src/coracle/.env.local >/dev/null
  ${SUDO} chown nostr:nostr /opt/nostr/src/coracle/.env.local
  run_as_nostr bash -lc 'cd /opt/nostr/src/coracle && corepack prepare pnpm@latest --activate && CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile && pnpm exec vite build'

  ${SUDO} rm -rf /var/www/coracle/*
  ${SUDO} cp -a /opt/nostr/src/coracle/dist/. /var/www/coracle/
  ${SUDO} chown -R www-data:www-data /var/www/coracle
fi

echo "==> Installing systemd units"
${SUDO} cp "${REPO_DIR}/deploy/systemd/nostr-relay.service" /etc/systemd/system/nostr-relay.service
${SUDO} cp "${REPO_DIR}/deploy/systemd/nostr-filter.service" /etc/systemd/system/nostr-filter.service
${SUDO} systemctl daemon-reload
if [[ "${SKIP_BUILD}" == "true" ]]; then
  ${SUDO} systemctl enable nostr-relay.service nostr-filter.service
else
  ${SUDO} systemctl enable --now nostr-relay.service nostr-filter.service
fi

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
${SUDO} ufw deny 8080/tcp >/dev/null 2>&1 || true
${SUDO} ufw deny 8081/tcp >/dev/null 2>&1 || true

UFW_STATUS="$(${SUDO} ufw status | head -n 1 || true)"
if echo "${UFW_STATUS}" | grep -qi inactive; then
  echo "UFW is inactive. To enforce private relay/filter ports (8080/8081), enable it: sudo ufw enable"
fi

echo

echo "Done."
echo "Coracle: http://${PUBLIC_HOST}/"
echo "Relay WS URL: ws://${PUBLIC_HOST}/relay"
echo "Relay NIP-11: curl -H 'Accept: application/nostr+json' http://${PUBLIC_HOST}/relay"
echo "Relay logs: sudo journalctl -u nostr-relay -f"
echo "Filter logs: sudo journalctl -u nostr-filter -f"
if [[ "${SKIP_BUILD}" == "true" ]]; then
  echo "Next step: run deploy (stack is installed, builds are skipped)."
fi
