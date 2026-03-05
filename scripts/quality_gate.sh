#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

is_ci="${CI:-false}"

require_tool_or_skip() {
  local tool="$1"
  if command -v "${tool}" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${is_ci}" == "true" ]]; then
    echo "Missing required command in CI: ${tool}" >&2
    exit 1
  fi

  echo "Skipping check that requires '${tool}' (not installed locally)." >&2
  return 1
}

if [[ -f deploy/versions.lock.json ]]; then
  if require_tool_or_skip jq; then
    jq empty deploy/versions.lock.json
  fi
fi

mapfile -t SH_FILES < <(git ls-files '*.sh')
if [[ "${#SH_FILES[@]}" -gt 0 ]]; then
  bash -n "${SH_FILES[@]}"
  if require_tool_or_skip shellcheck; then
    shellcheck "${SH_FILES[@]}"
  fi
fi

mapfile -t YAML_FILES < <(git ls-files '*.yml' '*.yaml')
if [[ "${#YAML_FILES[@]}" -gt 0 ]]; then
  if require_tool_or_skip yamllint; then
    yamllint "${YAML_FILES[@]}"
  fi
fi
