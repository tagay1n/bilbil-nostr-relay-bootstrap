#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <host-or-ip>" >&2
  exit 1
fi

HOST="$1"
BASE_URL="http://${HOST}"

echo "==> Coracle index"
curl -fsS "${BASE_URL}/" >/dev/null && echo "OK"

echo "==> Relay NIP-11"
if curl -fsS -H 'Accept: application/nostr+json' "${BASE_URL}/relay" >/tmp/bylbil-nip11.json 2>/dev/null; then
  jq . /tmp/bylbil-nip11.json
else
  echo "nginx relay path not available, trying direct local relay endpoint..."
  if [[ "${HOST}" == *:* ]]; then
    RELAY_BASE="http://${HOST}"
  else
    RELAY_BASE="http://${HOST}:8081"
  fi
  curl -fsS -H 'Accept: application/nostr+json' "${RELAY_BASE}/" | jq .
fi

echo "==> Services"
if command -v systemctl >/dev/null 2>&1; then
  if [[ "${EUID}" -eq 0 ]]; then
    systemctl --no-pager --full status nostr-relay nostr-filter nginx | sed -n '1,80p' || true
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo systemctl --no-pager --full status nostr-relay nostr-filter nginx | sed -n '1,80p' || true
  else
    echo "Skipping systemd status (no non-interactive sudo)."
  fi
else
  echo "Skipping systemd status (systemctl not available)."
fi
