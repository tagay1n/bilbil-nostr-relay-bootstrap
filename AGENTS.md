# AGENTS.md

## Project Purpose

Build an MVP "Tatar Twitter" on Nostr:
- backend relay: `rrainn/nostr-relay`
- policy layer: `imksoo/nostr-filter`
- web client: self-hosted Coracle

Current goal is test-first on raw IP and HTTP/WS, then migrate to domain + TLS (HTTPS/WSS) later.

## Current Architecture

- `nostr-relay` listens on `127.0.0.1:8080` (systemd)
- `nostr-filter` listens on `127.0.0.1:8081` (systemd), proxies upstream to relay
- `nginx` listens on `:80`
  - `/` -> Coracle static files in `/var/www/coracle`
  - `/relay` -> websocket proxy to `127.0.0.1:8081`

Public endpoints (HTTP mode):
- app: `http://<host>/`
- relay: `ws://<host>/relay`

## Policy Decisions (MVP)

- Intended access model: open write
- Current relay implementation constraint:
  - writes are accepted only for pubkeys listed in `allowedPublicKeys` in relay config
  - backend relay write kinds are limited (`0`, `1`, `5`)
- `kind:1` text notes allowed only with `#татарча` in content (filter layer)
- anti-abuse baseline:
  - nginx rate/connection limits on `/relay`
  - filter payload size cap
  - relay `created_at` bounds

## Repo Contents

- Main entrypoint: `scripts/stack.sh`
- Installer: `scripts/install_http_stack.sh`
- Coracle host/domain rebuild: `scripts/rebuild_coracle.sh`
- TLS switch: `scripts/enable_tls.sh`
- Smoke test: `scripts/smoke_test.sh`
- Deterministic deploy: `scripts/deploy_release.sh`
- Rollback: `scripts/rollback_last_success.sh`
- Lock updater: `scripts/update_lock.sh`
- Version lock: `deploy/versions.lock.json`
- Systemd units: `deploy/systemd/`
- Nginx configs: `deploy/nginx/`
- Templates: `deploy/templates/`

## Standard Ops

Install stack:
```bash
./scripts/stack.sh install-http <SERVER_IP>
```

Status/logs:
```bash
sudo systemctl status nostr-relay nostr-filter nginx
sudo journalctl -u nostr-relay -f
sudo journalctl -u nostr-filter -f
```

Smoke test:
```bash
./scripts/stack.sh smoke-test <host>
```

Local dev stack (no systemd/nginx):
```bash
./scripts/stack.sh up
./scripts/stack.sh status
./scripts/stack.sh down
```

CI/CD workflows:
- `.github/workflows/ci.yml` (quality gates on PR; reusable by deploy/bootstrap)
- `.github/workflows/deploy.yml` (auto-deploy on main + manual dispatch)
- `.github/workflows/bootstrap.yml` (manual bootstrap/install + deploy)
- `deploy` and `bootstrap` share one concurrency group per branch with `cancel-in-progress: true`

Nostr notifications:
- Implemented by `scripts/notify_nostr.mjs`.
- Enabled when `DEMO_NOSTR_NOTIFY_NSEC` secret is configured.

## Planned Migration to TLS

When domain is ready:
```bash
./scripts/stack.sh enable-tls <domain> <email>
```

After migration:
- app: `https://<domain>/`
- relay: `wss://<domain>/relay`

## Notes for Future Sessions

- Prefer keeping relay/filter behind nginx only; do not expose 8080/8081 publicly.
- systemd unit hardening includes `IPAddressDeny=any` with loopback allowlist for relay/filter.
- Keep config files in `/opt/nostr/config` as source of truth.
- If policy changes are requested (e.g. tag-based strict checks), update `deploy/templates/nostr-filter.env` and redeploy/restart filter.
