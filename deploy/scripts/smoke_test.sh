#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <host-or-ip>" >&2
  exit 1
fi

HOST="$1"

echo "==> Coracle index"
curl -fsS "http://${HOST}/" >/dev/null && echo "OK"

echo "==> Relay NIP-11"
curl -fsS -H 'Accept: application/nostr+json' "http://${HOST}/relay" | jq .

echo "==> Services"
sudo systemctl --no-pager --full status nostr-relay nostr-filter nginx | sed -n '1,80p'
