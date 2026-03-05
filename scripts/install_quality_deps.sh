#!/usr/bin/env bash
set -euo pipefail

REQUIRED_CMDS=(jq shellcheck yamllint)
MISSING=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    MISSING+=("${cmd}")
  fi
done

if [[ "${#MISSING[@]}" -eq 0 ]]; then
  echo "Quality dependencies already installed: ${REQUIRED_CMDS[*]}"
  exit 0
fi

echo "Missing quality dependencies: ${MISSING[*]}"

if command -v apt-get >/dev/null 2>&1; then
  if [[ "$(id -u)" -eq 0 ]]; then
    apt-get update
    apt-get install -y jq shellcheck yamllint
  else
    sudo apt-get update
    sudo apt-get install -y jq shellcheck yamllint
  fi
elif command -v brew >/dev/null 2>&1; then
  brew install jq shellcheck yamllint
else
  echo "Unsupported package manager. Install manually: jq shellcheck yamllint" >&2
  exit 1
fi

echo "Installed quality dependencies."
