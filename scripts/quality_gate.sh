#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f deploy/versions.lock.json ]]; then
  jq empty deploy/versions.lock.json
fi

mapfile -t SH_FILES < <(git ls-files '*.sh')
if [[ "${#SH_FILES[@]}" -gt 0 ]]; then
  bash -n "${SH_FILES[@]}"
  shellcheck "${SH_FILES[@]}"
fi

mapfile -t YAML_FILES < <(git ls-files '*.yml' '*.yaml')
if [[ "${#YAML_FILES[@]}" -gt 0 ]]; then
  yamllint "${YAML_FILES[@]}"
fi
