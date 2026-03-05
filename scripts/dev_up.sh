#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="${ROOT_DIR}/.dev"
SRC_DIR="${DEV_DIR}/src"
CFG_DIR="${DEV_DIR}/config"
LOG_DIR="${DEV_DIR}/logs"
RUN_DIR="${DEV_DIR}/run"

mkdir -p "${SRC_DIR}" "${CFG_DIR}" "${LOG_DIR}" "${RUN_DIR}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd git
require_cmd node
require_cmd npm

NODE_MAJOR="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
if [[ "${NODE_MAJOR}" -lt 20 ]]; then
  echo "Node.js >= 20 is required. Current: $(node -v)" >&2
  exit 1
fi

corepack enable >/dev/null 2>&1 || true

clone_or_update_repo() {
  local url="$1"
  local dst="$2"

  if [[ -d "${dst}/.git" ]]; then
    git -C "${dst}" fetch --prune origin
    git -C "${dst}" pull --ff-only
  else
    git clone --depth 1 "${url}" "${dst}"
  fi
}

clone_or_update_repo https://github.com/rrainn/nostr-relay.git "${SRC_DIR}/nostr-relay"
clone_or_update_repo https://github.com/imksoo/nostr-filter.git "${SRC_DIR}/nostr-filter"
clone_or_update_repo https://github.com/coracle-social/coracle.git "${SRC_DIR}/coracle"

cp "${ROOT_DIR}/deploy/templates/nostr-relay.config.json" "${CFG_DIR}/nostr-relay.config.json"
cp "${ROOT_DIR}/deploy/templates/nostr-filter.env" "${CFG_DIR}/nostr-filter.env"
cat > "${CFG_DIR}/coracle.env.local" <<'ENVEOF'
VITE_APP_NAME=Bilbil Dev
VITE_APP_DESCRIPTION=Bilbil local development
VITE_DEFAULT_RELAYS=ws://127.0.0.1:8081
VITE_SEARCH_RELAYS=ws://127.0.0.1:8081
VITE_LOG_LEVEL=info
ENVEOF

ln -sfn "${CFG_DIR}/nostr-relay.config.json" "${SRC_DIR}/nostr-relay/config.json"
cp "${CFG_DIR}/coracle.env.local" "${SRC_DIR}/coracle/.env.local"

echo "Building nostr-relay"
(
  cd "${SRC_DIR}/nostr-relay"
  npm ci
  npm run build
)

echo "Building nostr-filter"
(
  cd "${SRC_DIR}/nostr-filter"
  npm ci
  npx tsc
)

echo "Installing Coracle deps"
(
  cd "${SRC_DIR}/coracle"
  corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
  CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile
)

start_if_not_running() {
  local name="$1"
  local cmd="$2"
  local pid_file="${RUN_DIR}/${name}.pid"
  local log_file="${LOG_DIR}/${name}.log"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}")"
    if kill -0 "${pid}" >/dev/null 2>&1; then
      echo "${name} already running (pid ${pid})"
      return
    fi
    rm -f "${pid_file}"
  fi

  bash -lc "${cmd}" >"${log_file}" 2>&1 &
  echo $! >"${pid_file}"
  echo "Started ${name} (pid $(cat "${pid_file}"))"
}

start_if_not_running "nostr-relay" "cd '${SRC_DIR}/nostr-relay' && node dist/src/WebSocket.js"
start_if_not_running "nostr-filter" "cd '${SRC_DIR}/nostr-filter' && set -a && source '${CFG_DIR}/nostr-filter.env' && set +a && node --max-old-space-size=1024 filter.js"
start_if_not_running "coracle" "cd '${SRC_DIR}/coracle' && pnpm run dev -- --host 127.0.0.1 --port 5173"

echo
echo "Dev stack is up"
echo "Coracle: http://127.0.0.1:5173"
echo "Relay: ws://127.0.0.1:8081"
echo "Logs: ${LOG_DIR}"
echo "Stop with: ./scripts/dev_down.sh"
