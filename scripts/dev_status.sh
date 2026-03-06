#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/.dev/logs"

status_by_pattern() {
  local name="$1"
  local pattern="$2"
  local pids
  pids="$(pgrep -f "${pattern}" || true)"

  if [[ -n "${pids}" ]]; then
    echo "${name}: running (pid(s) $(echo "${pids}" | tr '\n' ' ' | sed 's/ $//'))"
  else
    echo "${name}: not running"
  fi
}

status_by_pattern "nostr-relay" "target/release/nostr-rs-relay --config .*nostr-rs-relay.toml"
status_by_pattern "nostr-filter" "node --max-old-space-size=1024 filter.js"
status_by_pattern "coracle" "pnpm run dev -- --host 127.0.0.1 --port 5173|vite --host -- --host 127.0.0.1 --port 5173"

echo "logs: ${LOG_DIR}"
