#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${ROOT_DIR}/.dev/run"
LOG_DIR="${ROOT_DIR}/.dev/logs"

status_one() {
  local name="$1"
  local pid_file="${RUN_DIR}/${name}.pid"

  if [[ ! -f "${pid_file}" ]]; then
    echo "${name}: not running"
    return
  fi

  local pid
  pid="$(cat "${pid_file}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "${name}: running (pid ${pid})"
  else
    echo "${name}: stale pid file"
  fi
}

status_one "nostr-relay"
status_one "nostr-filter"
status_one "coracle"

echo "logs: ${LOG_DIR}"
