#!/usr/bin/env bash
set -euo pipefail

stop_by_pattern() {
  local name="$1"
  local pattern="$2"
  local pids
  pids="$(pgrep -f "${pattern}" || true)"

  if [[ -z "${pids}" ]]; then
    echo "${name}: not running"
    return
  fi

  while read -r pid; do
    [[ -z "${pid}" ]] && continue
    kill "${pid}" >/dev/null 2>&1 || true
  done <<< "${pids}"

  sleep 1

  while read -r pid; do
    [[ -z "${pid}" ]] && continue
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill -9 "${pid}" >/dev/null 2>&1 || true
    fi
  done <<< "${pids}"

  echo "${name}: stopped"
}

stop_by_pattern "coracle" "pnpm run dev -- --host 127.0.0.1 --port 5173|vite --host -- --host 127.0.0.1 --port 5173"
stop_by_pattern "nostr-filter" "node --max-old-space-size=1024 filter.js"
stop_by_pattern "nostr-relay" "node dist/src/WebSocket.js"
