#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="${ROOT_DIR}/.dev"
SRC_DIR="${DEV_DIR}/src"
CFG_DIR="${DEV_DIR}/config"
LOG_DIR="${DEV_DIR}/logs"

mkdir -p "${SRC_DIR}" "${CFG_DIR}" "${LOG_DIR}"

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

if [[ ! -f "${CFG_DIR}/nostr-relay.config.json" ]]; then
  cp "${ROOT_DIR}/deploy/templates/nostr-relay.config.json" "${CFG_DIR}/nostr-relay.config.json"
fi
if [[ ! -f "${CFG_DIR}/nostr-filter.env" ]]; then
  cp "${ROOT_DIR}/deploy/templates/nostr-filter.env" "${CFG_DIR}/nostr-filter.env"
fi
cat > "${CFG_DIR}/coracle.env.local" <<'ENVEOF'
VITE_APP_NAME=Bılbıl Dev
VITE_APP_DESCRIPTION=Bılbıl local development
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
  # On low-resource hosts pnpm may occasionally fail with transient EAGAIN while
  # materializing node_modules; retry with conservative concurrency.
  attempt=1
  max_attempts=3
  until CYPRESS_INSTALL_BINARY=0 pnpm install \
    --frozen-lockfile \
    --package-import-method=hardlink \
    --child-concurrency=4 \
    --network-concurrency=8; do
    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "Coracle dependency install failed after ${max_attempts} attempts" >&2
      exit 1
    fi
    sleep_seconds=$((attempt * 3))
    echo "Coracle dependency install failed (attempt ${attempt}/${max_attempts}), retrying in ${sleep_seconds}s..." >&2
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done
)

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local timeout_seconds="${3:-20}"
  local start_ts
  start_ts="$(date +%s)"

  while true; do
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      exec 3<&-
      exec 3>&-
      return 0
    fi

    if (( "$(date +%s)" - start_ts >= timeout_seconds )); then
      return 1
    fi
    sleep 0.5
  done
}

start_foreground() {
  local pids=()

  start_component() {
    local name="$1"
    local cmd="$2"
    local pid
    : > "${LOG_DIR}/${name}.log"
    bash -lc "${cmd}" \
      > >(tee -a "${LOG_DIR}/${name}.log" | sed -u "s/^/[${name}] /") \
      2> >(tee -a "${LOG_DIR}/${name}.log" | sed -u "s/^/[${name}] /" >&2) &
    pid="$!"
    pids+=("${pid}")
    echo "Started ${name} (pid ${pid})"
  }

  # shellcheck disable=SC2317
  cleanup() {
    for pid in "${pids[@]}"; do
      kill "${pid}" >/dev/null 2>&1 || true
    done
    wait >/dev/null 2>&1 || true
  }

  trap 'cleanup; exit 130' INT TERM
  trap 'cleanup' EXIT

  start_component "nostr-relay" "cd '${SRC_DIR}/nostr-relay' && exec node dist/src/WebSocket.js"
  if ! wait_for_tcp "127.0.0.1" "8080" "20"; then
    echo "nostr-relay did not become ready on 127.0.0.1:8080" >&2
    exit 1
  fi

  start_component "nostr-filter" "cd '${SRC_DIR}/nostr-filter' && set -a && source '${CFG_DIR}/nostr-filter.env' && set +a && exec node --max-old-space-size=1024 filter.js"
  start_component "coracle" "cd '${SRC_DIR}/coracle' && exec pnpm run dev -- --host 127.0.0.1 --port 5173"

  echo
  echo "Dev stack is up (foreground mode)"
  echo "Coracle: http://127.0.0.1:5173"
  echo "Relay: ws://127.0.0.1:8081"
  echo "Press Ctrl+C to stop all components"

  set +e
  wait -n
  local exit_code=$?
  set -e
  echo "A component exited (code ${exit_code}), stopping remaining components..." >&2
  exit "${exit_code}"
}

start_foreground
