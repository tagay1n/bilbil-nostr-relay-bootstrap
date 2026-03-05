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

- Access model: open write
- `kind:1` text notes allowed only with `#татарча` in content
- non-`kind:1` events are allowed (metadata/reactions/etc.)
- anti-abuse baseline:
  - nginx rate/connection limits on `/relay`
  - filter payload size cap
  - relay `created_at` bounds

## Repo Contents

- Installer: `deploy/scripts/install_http_stack.sh`
- Coracle host/domain rebuild: `deploy/scripts/rebuild_coracle.sh`
- TLS switch: `deploy/scripts/enable_tls.sh`
- Smoke test: `deploy/scripts/smoke_test.sh`
- Deterministic deploy: `deploy/scripts/deploy_release.sh`
- Rollback: `deploy/scripts/rollback_last_success.sh`
- Lock updater: `deploy/scripts/update_lock.sh`
- Version lock: `deploy/versions.lock.json`
- Systemd units: `deploy/systemd/`
- Nginx configs: `deploy/nginx/`
- Templates: `deploy/templates/`

## Standard Ops

Install stack:
```bash
./deploy/scripts/install_http_stack.sh <SERVER_IP>
```

Status/logs:
```bash
sudo systemctl status nostr-relay nostr-filter nginx
sudo journalctl -u nostr-relay -f
sudo journalctl -u nostr-filter -f
```

Smoke test:
```bash
./deploy/scripts/smoke_test.sh <host>
```

Local dev stack (no systemd/nginx):
```bash
./scripts/dev_up.sh
./scripts/dev_status.sh
./scripts/dev_down.sh
```

CI/CD workflows:
- `.github/workflows/ci.yml` (quality gates on PR/main)
- `.github/workflows/deploy-demo.yml` (auto-deploy on main)
- `.github/workflows/rollback-demo.yml` (manual rollback to last success)
- `.github/workflows/bootstrap-demo.yml` (manual bootstrap/install + deploy)

Nostr notifications:
- Implemented by `scripts/notify_nostr.mjs`.
- Enabled when `DEMO_NOSTR_NOTIFY_NSEC` secret is configured.

## Planned Migration to TLS

When domain is ready:
```bash
./deploy/scripts/enable_tls.sh <domain> <email>
```

After migration:
- app: `https://<domain>/`
- relay: `wss://<domain>/relay`

## Notes for Future Sessions

- Prefer keeping relay/filter behind nginx only; do not expose 8080/8081 publicly.
- Keep config files in `/opt/nostr/config` as source of truth.
- If policy changes are requested (e.g. tag-based strict checks), update `deploy/templates/nostr-filter.env` and redeploy/restart filter.
