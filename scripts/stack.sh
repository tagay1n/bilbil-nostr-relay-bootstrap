#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<USAGE
Usage: ./scripts/stack.sh <command> [args]

Local commands:
  up                          Run local stack in foreground (Ctrl+C stops all)
  down                        Stop local stack (best-effort)
  status                      Show local stack status
  restart                     Restart local stack in foreground
  logs                        Tail local logs
  quality                     Run repo quality checks

Deploy commands:
  install-http [args...]      Install VPS HTTP/WS stack (e.g. --skip-build <host-or-ip>)
  rebuild-coracle <host> [scheme]
                              Rebuild Coracle for host/domain with ws or wss (default ws)
  enable-tls <domain> <email> Enable TLS and switch to HTTPS/WSS
  enable-tls-ip <ip> <email>  Enable short-lived TLS for IPv4 and switch to HTTPS/WSS
  smoke-test <host>           Run smoke checks
  deploy [args...]            Run deterministic release deploy (passes args through)
  rollback [args...]          Roll back to last successful release (passes args through)
  update-lock                 Update pinned upstream refs in versions.lock.json
USAGE
}

cmd="${1:-}"
if [[ -z "${cmd}" ]]; then
  usage
  exit 1
fi
shift || true

case "${cmd}" in
  up)
    exec "${SCRIPT_DIR}/dev_up.sh" "$@"
    ;;
  down)
    exec "${SCRIPT_DIR}/dev_down.sh" "$@"
    ;;
  status)
    exec "${SCRIPT_DIR}/dev_status.sh" "$@"
    ;;
  restart)
    "${SCRIPT_DIR}/dev_down.sh" "$@"
    exec "${SCRIPT_DIR}/dev_up.sh"
    ;;
  logs)
    mkdir -p "${SCRIPT_DIR}/../.dev/logs"
    exec tail -n 120 -F \
      "${SCRIPT_DIR}/../.dev/logs/nostr-relay.log" \
      "${SCRIPT_DIR}/../.dev/logs/nostr-filter.log" \
      "${SCRIPT_DIR}/../.dev/logs/coracle.log"
    ;;
  quality)
    exec "${SCRIPT_DIR}/quality_gate.sh" "$@"
    ;;
  install-http)
    exec "${SCRIPT_DIR}/install_http_stack.sh" "$@"
    ;;
  rebuild-coracle)
    exec "${SCRIPT_DIR}/rebuild_coracle.sh" "$@"
    ;;
  enable-tls)
    exec "${SCRIPT_DIR}/enable_tls.sh" "$@"
    ;;
  enable-tls-ip)
    exec "${SCRIPT_DIR}/enable_tls_ip.sh" "$@"
    ;;
  smoke-test)
    exec "${SCRIPT_DIR}/smoke_test.sh" "$@"
    ;;
  deploy)
    exec "${SCRIPT_DIR}/deploy_release.sh" "$@"
    ;;
  rollback)
    exec "${SCRIPT_DIR}/rollback_last_success.sh" "$@"
    ;;
  update-lock)
    exec "${SCRIPT_DIR}/update_lock.sh" "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: ${cmd}" >&2
    usage
    exit 1
    ;;
esac
