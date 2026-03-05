#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENV_NAME="demo"
LOCK_FILE="${ROOT_DIR}/deploy/versions.lock.json"
PUBLIC_HOST=""
RELAY_SCHEME="ws"
SOURCE_SHA=""
HEALTHCHECK_BASE_URL="http://127.0.0.1"
AUTO_ROLLBACK="true"
ROLLBACK_LAST="false"

usage() {
  cat <<USAGE
Usage:
  $0 --public-host <host> [options]
  $0 --rollback-last [options]

Options:
  --env <name>                      Environment label (default: demo)
  --public-host <host>              Public host/IP used by Coracle defaults
  --relay-scheme <ws|wss>           Relay scheme for Coracle defaults (default: ws)
  --lock-file <path>                Version lock file (default: deploy/versions.lock.json)
  --source-sha <sha>                Source commit SHA for release metadata
  --healthcheck-base-url <url>      Base URL for smoke checks (default: http://127.0.0.1)
  --auto-rollback <true|false>      Rollback to last success if deploy fails (default: true)
  --rollback-last                   Roll back to last successful release and exit
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_NAME="$2"
      shift 2
      ;;
    --public-host)
      PUBLIC_HOST="$2"
      shift 2
      ;;
    --relay-scheme)
      RELAY_SCHEME="$2"
      shift 2
      ;;
    --lock-file)
      LOCK_FILE="$2"
      shift 2
      ;;
    --source-sha)
      SOURCE_SHA="$2"
      shift 2
      ;;
    --healthcheck-base-url)
      HEALTHCHECK_BASE_URL="$2"
      shift 2
      ;;
    --auto-rollback)
      AUTO_ROLLBACK="$2"
      shift 2
      ;;
    --rollback-last)
      ROLLBACK_LAST="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

STACK_ROOT="${STACK_ROOT:-/opt/nostr}"
SRC_ROOT="${STACK_ROOT}/src"
CFG_ROOT="${STACK_ROOT}/config"
RELEASES_DIR="${STACK_ROOT}/releases"
LAST_SUCCESS_FILE="${RELEASES_DIR}/last_success.json"
WWW_ROOT="${WWW_ROOT:-/var/www/coracle}"

RELAY_SERVICE="${RELAY_SERVICE:-nostr-relay}"
FILTER_SERVICE="${FILTER_SERVICE:-nostr-filter}"
NGINX_SERVICE="${NGINX_SERVICE:-nginx}"

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

run_as_nostr() {
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u nostr -- "$@"
  else
    sudo -u nostr "$@"
  fi
}

check_prerequisites() {
  require_cmd jq
  require_cmd git
  require_cmd node
  require_cmd npm
  require_cmd curl
  require_cmd systemctl

  if [[ ! -f "${LOCK_FILE}" ]]; then
    echo "Lock file not found: ${LOCK_FILE}" >&2
    exit 1
  fi

  if ! id -u nostr >/dev/null 2>&1; then
    echo "System user 'nostr' does not exist. Bootstrap first with install_http_stack.sh" >&2
    exit 1
  fi

  if [[ ! -d "${SRC_ROOT}" ]] || [[ ! -d "${CFG_ROOT}" ]]; then
    echo "Missing ${SRC_ROOT} or ${CFG_ROOT}. Bootstrap first with install_http_stack.sh" >&2
    exit 1
  fi

  if [[ -z "${WWW_ROOT}" || "${WWW_ROOT}" == "/" ]]; then
    echo "Unsafe WWW_ROOT: ${WWW_ROOT}" >&2
    exit 1
  fi

  local node_major
  node_major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
  if [[ "${node_major}" -lt 20 ]]; then
    echo "Node.js >= 20 required. Current: $(node -v)" >&2
    exit 1
  fi

  mkdir -p "${RELEASES_DIR}"
}

clone_or_update() {
  local repo="$1"
  local ref="$2"
  local dst="$3"

  if [[ -d "${dst}/.git" ]]; then
    run_as_nostr git -C "${dst}" fetch --tags --prune origin
  else
    run_as_nostr git clone "${repo}" "${dst}"
  fi

  run_as_nostr git -C "${dst}" checkout --detach "${ref}"
}

ensure_base_configs() {
  if [[ ! -f "${CFG_ROOT}/nostr-relay.config.json" ]]; then
    cp "${ROOT_DIR}/deploy/templates/nostr-relay.config.json" "${CFG_ROOT}/nostr-relay.config.json"
    chown nostr:nostr "${CFG_ROOT}/nostr-relay.config.json"
  fi

  if [[ ! -f "${CFG_ROOT}/nostr-filter.env" ]]; then
    cp "${ROOT_DIR}/deploy/templates/nostr-filter.env" "${CFG_ROOT}/nostr-filter.env"
    chown nostr:nostr "${CFG_ROOT}/nostr-filter.env"
  fi

  ln -sfn "${CFG_ROOT}/nostr-relay.config.json" "${SRC_ROOT}/nostr-relay/config.json"
}

build_nostr_relay() {
  run_as_nostr bash -lc 'cd "'"${SRC_ROOT}/nostr-relay"'" && npm ci && npm run build'
}

build_nostr_filter() {
  run_as_nostr bash -lc 'cd "'"${SRC_ROOT}/nostr-filter"'" && npm ci && npx tsc'
}

build_coracle() {
  local host="$1"
  local relay_scheme="$2"

  run_as_nostr bash -lc "cd '${SRC_ROOT}/coracle' && sed 's|__PUBLIC_HOST__|${host}|g' '${ROOT_DIR}/deploy/templates/coracle.env.local' > .env.local"
  if [[ "${relay_scheme}" == "wss" ]]; then
    run_as_nostr bash -lc "cd '${SRC_ROOT}/coracle' && sed -i 's|ws://|wss://|g' .env.local"
  fi

  run_as_nostr bash -lc 'cd "'"${SRC_ROOT}/coracle"'" && corepack prepare pnpm@latest --activate && CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile && pnpm exec vite build'

  mkdir -p "${WWW_ROOT}"
  rm -rf "${WWW_ROOT}"/*
  cp -a "${SRC_ROOT}/coracle/dist/." "${WWW_ROOT}/"
  chown -R www-data:www-data "${WWW_ROOT}"
}

restart_services() {
  systemctl restart "${RELAY_SERVICE}" "${FILTER_SERVICE}"
  systemctl reload "${NGINX_SERVICE}"
}

smoke_checks() {
  local base_url="$1"

  systemctl is-active --quiet "${RELAY_SERVICE}"
  systemctl is-active --quiet "${FILTER_SERVICE}"
  systemctl is-active --quiet "${NGINX_SERVICE}"

  curl -fsS "${base_url}/" >/dev/null
  curl -fsS -H 'Accept: application/nostr+json' "${base_url}/relay" >/dev/null
}

apply_manifest() {
  local manifest_file="$1"
  local reason="$2"

  local relay_repo relay_ref
  local filter_repo filter_ref
  local coracle_repo coracle_ref
  local host relay_scheme

  relay_repo="$(jq -r '.components["nostr-relay"].repo' "${manifest_file}")"
  relay_ref="$(jq -r '.components["nostr-relay"].ref' "${manifest_file}")"
  filter_repo="$(jq -r '.components["nostr-filter"].repo' "${manifest_file}")"
  filter_ref="$(jq -r '.components["nostr-filter"].ref' "${manifest_file}")"
  coracle_repo="$(jq -r '.components["coracle"].repo' "${manifest_file}")"
  coracle_ref="$(jq -r '.components["coracle"].ref' "${manifest_file}")"
  host="$(jq -r '.public_host' "${manifest_file}")"
  relay_scheme="$(jq -r '.relay_scheme' "${manifest_file}")"

  if [[ -z "${host}" || "${host}" == "null" ]]; then
    echo "Manifest missing public_host" >&2
    return 1
  fi

  log "[${reason}] Checking out pinned sources"
  clone_or_update "${relay_repo}" "${relay_ref}" "${SRC_ROOT}/nostr-relay"
  clone_or_update "${filter_repo}" "${filter_ref}" "${SRC_ROOT}/nostr-filter"
  clone_or_update "${coracle_repo}" "${coracle_ref}" "${SRC_ROOT}/coracle"

  ensure_base_configs

  log "[${reason}] Building nostr-relay"
  build_nostr_relay
  log "[${reason}] Building nostr-filter"
  build_nostr_filter
  log "[${reason}] Building Coracle"
  build_coracle "${host}" "${relay_scheme}"

  log "[${reason}] Restarting services"
  restart_services
  log "[${reason}] Running smoke checks"
  smoke_checks "${HEALTHCHECK_BASE_URL}"
}

write_release_manifest() {
  local output="$1"
  local release_id="$2"

  jq -n \
    --arg schema "1" \
    --arg release_id "${release_id}" \
    --arg source_sha "${SOURCE_SHA}" \
    --arg environment "${ENV_NAME}" \
    --arg public_host "${PUBLIC_HOST}" \
    --arg relay_scheme "${RELAY_SCHEME}" \
    --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --slurpfile lock "${LOCK_FILE}" \
    '{
      schema: ($schema | tonumber),
      release_id: $release_id,
      source_sha: $source_sha,
      environment: $environment,
      public_host: $public_host,
      relay_scheme: $relay_scheme,
      generated_at: $generated_at,
      components: $lock[0].components
    }' >"${output}"
}

rollback_last_success() {
  if [[ ! -f "${LAST_SUCCESS_FILE}" ]]; then
    echo "No previous successful release found at ${LAST_SUCCESS_FILE}" >&2
    exit 1
  fi

  log "Rolling back to last successful release"
  apply_manifest "${LAST_SUCCESS_FILE}" "rollback"
  log "Rollback completed"
}

on_error() {
  local code="$?"
  trap - ERR
  echo "Deploy failed with exit code ${code}" >&2

  if [[ "${AUTO_ROLLBACK}" == "true" && -f "${LAST_SUCCESS_FILE}" ]]; then
    echo "Attempting automatic rollback to last successful release..." >&2
    if apply_manifest "${LAST_SUCCESS_FILE}" "auto-rollback"; then
      echo "Automatic rollback succeeded" >&2
    else
      echo "Automatic rollback failed" >&2
    fi
  fi

  exit "${code}"
}

check_prerequisites

if [[ "${ROLLBACK_LAST}" == "true" ]]; then
  rollback_last_success
  exit 0
fi

if [[ -z "${PUBLIC_HOST}" ]]; then
  echo "--public-host is required for deployment" >&2
  exit 1
fi

trap on_error ERR

if [[ -z "${SOURCE_SHA}" ]]; then
  SOURCE_SHA="local-$(date -u +'%Y%m%d%H%M%S')"
fi

RELEASE_ID="$(date -u +'%Y%m%dT%H%M%SZ')-${SOURCE_SHA:0:12}"
TMP_MANIFEST="$(mktemp)"
write_release_manifest "${TMP_MANIFEST}" "${RELEASE_ID}"

log "Starting deployment ${RELEASE_ID}"
apply_manifest "${TMP_MANIFEST}" "deploy"

cp "${TMP_MANIFEST}" "${RELEASES_DIR}/${RELEASE_ID}.json"
cp "${TMP_MANIFEST}" "${LAST_SUCCESS_FILE}"
rm -f "${TMP_MANIFEST}"

log "Deployment successful"
log "Release: ${RELEASE_ID}"
