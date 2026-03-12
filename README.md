# Bılbıl MVP (Nostr Relay + Filter + Coracle)

This repo contains deployment tooling for a test-first stack on Ubuntu 22:

- `scsibug/nostr-rs-relay` as backend relay (`127.0.0.1:8080`)
- `imksoo/nostr-filter` as policy/filter relay (`:8081`, should be firewalled/private)
- self-hosted Coracle static frontend served by nginx (`:80`)
- public relay URL for clients: `ws://<host>/relay`

## Policy (current MVP)

- Intended policy:
  - open write
  - `kind:1` text notes accepted only if note content includes `#татарча`
  - non-`kind:1` events allowed (metadata, reactions, etc.)

- Relay notes:
  - open write works by default
  - optional author allowlist is available via `[authorization].pubkey_whitelist` in relay config

Note: the current rule checks note content with a regex. In most clients, hashtags appear in content, so this works for MVP.

## Files

- Main entrypoint: `scripts/stack.sh`
- Installer: `scripts/install_http_stack.sh`
- Coracle rebuild (host/domain change): `scripts/rebuild_coracle.sh`
- TLS switch (Let's Encrypt): `scripts/enable_tls.sh`
- Smoke test: `scripts/smoke_test.sh`
- Deterministic deploy: `scripts/deploy_release.sh`
- Manual rollback: `scripts/rollback_last_success.sh`
- Lock updater: `scripts/update_lock.sh`
- Locked upstream versions: `deploy/versions.lock.json`

## 1) Install on VPS (HTTP + WS)

On your VPS:

```bash
git clone <this-repo-url> bılbıl
cd bılbıl
./scripts/stack.sh install-http <SERVER_IP>
```

If host argument is omitted, script tries to auto-detect public IP.
For CI/bootstrap where deploy runs immediately after install, you can skip initial builds:

```bash
./scripts/stack.sh install-http --skip-build <SERVER_IP>
```

After install:

- Coracle: `http://<SERVER_IP>/`
- Relay: `ws://<SERVER_IP>/relay`
- NIP-11 check:

```bash
curl -H 'Accept: application/nostr+json' http://<SERVER_IP>/relay
```

## 2) Update Coracle host later

When moving from IP to domain (or any host change):

```bash
./scripts/stack.sh rebuild-coracle <new-host> [ws|wss]
```

This updates Coracle defaults to use:

- `ws://<new-host>/relay` (HTTP mode)
- or `wss://<new-host>/relay` once TLS is enabled

## 3) Enable TLS later (domain required)

```bash
./scripts/stack.sh enable-tls <domain> <email>
```

This does:

- gets Let's Encrypt cert
- switches nginx config to HTTPS
- rebuilds Coracle for domain host

After that use:

- Coracle: `https://<domain>/`
- Relay: `wss://<domain>/relay`

### Temporary TLS on raw IP (short-lived cert)

If you need signer extension support before buying a domain, you can issue a short-lived
Let's Encrypt IP certificate:

```bash
./scripts/stack.sh enable-tls-ip <server-ipv4> <email>
```

After that use:
- Coracle: `https://<server-ipv4>/`
- Relay: `wss://<server-ipv4>/relay`

Important:
- IP certificates are short-lived; re-run `enable-tls-ip` periodically to renew.
- Domain + regular TLS is still the recommended long-term setup.

## 4) Ops quick commands

```bash
sudo systemctl status nostr-relay nostr-filter nginx
sudo journalctl -u nostr-relay -f
sudo journalctl -u nostr-filter -f
./scripts/stack.sh smoke-test <host>
```

Relay config file:
- `/opt/nostr/config/nostr-rs-relay.toml`

Update pinned upstream versions:

```bash
./scripts/stack.sh update-lock
```

Deploy pinned release manually:

```bash
./scripts/stack.sh deploy \
  --env demo \
  --public-host <host-or-domain> \
  --relay-scheme ws \
  --source-sha <git-sha>
```

Manual rollback to last successful release:

```bash
./scripts/stack.sh rollback --env demo
```

## Local dev mode (single machine, no systemd/nginx)

For quick testing all components locally:

```bash
./scripts/stack.sh up
```

Endpoints:
- Coracle: `http://127.0.0.1:5173`
- Relay (filtered): `ws://127.0.0.1:8081`

Local prerequisite:
- Rust toolchain with `cargo` installed (used to build `nostr-rs-relay`)

Helpers:

```bash
./scripts/stack.sh status
./scripts/stack.sh down
make hooks-install
```

`make hooks-install` enables repo-managed git hooks (`.githooks/`).
After that, `pre-commit` runs `./scripts/quality_gate.sh` before each commit.
To bypass once: `SKIP_QUALITY_HOOK=1 git commit ...`

Note: local quality checks automatically skip missing optional tools (`jq`, `shellcheck`, `yamllint`).
CI remains strict and requires all quality tools.

Logs:
- `.dev/logs/nostr-relay.log`
- `.dev/logs/nostr-filter.log`
- `.dev/logs/coracle.log`

## Security defaults included

- nginx websocket reverse proxy
- request/connection limits at nginx relay endpoint
- payload limit in filter (`MAX_WEBSOCKET_PAYLOAD_SIZE=200000`)
- relay future timestamp bound (`reject_future_seconds`) via `nostr-rs-relay` config
- relay binds to `127.0.0.1:8080` via relay config
- installer config adds firewall deny rules for `8080/tcp` and `8081/tcp` (effective when UFW is enabled)
- `nostr-filter` can listen on `:8081`; keep host/cloud firewall blocking public access

## Security notes (important)

- Nostr signatures protect authenticity/integrity of events, not network reachability.
- `wss://` protects traffic in transit, but does not prevent IP/domain/SNI-based blocking by censors.
- This relay is a public social system, not a secure secret-sharing channel.
- Do not ask users to share high-risk secrets (passwords, private keys, sensitive personal data) via notes/DMs.
- Prefer newer encrypted DM standards (`NIP-17` + `NIP-44` + `NIP-59`) in clients; avoid legacy `NIP-04` for sensitive use.
- Enforce strong key hygiene:
  - never share `nsec` keys
  - use hardware/extension signers when possible
  - rotate compromised keys immediately
- For censorship-heavy regions, plan transport fallback outside protocol scope (for example Tor/VPN/bridges).

## CI/CD (GitHub Actions)

Workflows:
- `.github/workflows/ci.yml` (manual + reusable by other workflows)
- `.github/workflows/deploy.yml` (manual deploy)
- `.github/workflows/bootstrap.yml` (manual first-time bootstrap + deploy)
- `.github/workflows/enable-tls-ip.yml` (manual + scheduled short-lived IP TLS issue/renew)

### Required demo secrets

- `DEMO_SSH_HOST`
- `DEMO_SSH_PORT` (optional, defaults to `22`)
- `DEMO_SSH_USER`
- `DEMO_SSH_KEY` (private key used by Actions)
- `DEMO_REPO_PATH` (optional, defaults to `/home/<DEMO_SSH_USER>/<repo-name>`)
- `DEMO_PUBLIC_HOST` (optional, IP/domain used by Coracle defaults; falls back to `DEMO_SSH_HOST`)
- `DEMO_RELAY_SCHEME` (optional: `ws` or `wss`; if empty, deploy auto-detects from nginx TLS config)
- `DEMO_STACK_ROOT` (optional, default `/opt/nostr`)
- `DEMO_WWW_ROOT` (optional, default `/var/www/coracle`)
- `DEMO_ACME_EMAIL` (recommended for scheduled TLS-IP renewal if manual input is absent)
- `DEMO_NOSTR_NOTIFY_NSEC` (optional, deploy bot private key in `nsec1...` or hex)
- `DEMO_NOSTR_NOTIFY_RELAYS` (optional, comma-separated relay URLs for notifications)

`deploy.yml` requires CI quality gate (`ci.yml`) and runs only via `workflow_dispatch`.
It supports optional overrides (`public_host`, `relay_scheme`, `source_sha`).
If `DEMO_NOSTR_NOTIFY_NSEC` is set, deploy runs publish status notes to Nostr.
Deploy and Bootstrap share one concurrency group per branch and use `cancel-in-progress: true`.
That means a newer run on the same branch cancels older in-progress deploy/bootstrap runs.
For stable TLS behavior after enabling HTTPS/WSS, set `DEMO_RELAY_SCHEME=wss`.

`enable-tls-ip.yml` is manual and also runs on a daily schedule.
It runs:
`./scripts/stack.sh enable-tls-ip <public_ip> <email>` on the VPS over SSH.
Inputs:
- `public_ip` (optional, IPv4; defaults to `DEMO_SSH_HOST`)
- `email` (optional if `DEMO_ACME_EMAIL` secret is set)
- `renew_after_days` (optional, default `5`; renew only when cert age reaches this threshold)
- `source_sha` (optional, commit SHA to run)
It also respects `DEMO_STACK_ROOT` and `DEMO_WWW_ROOT` secrets (same defaults as deploy).
If TLS prerequisites are missing, it automatically runs `install-http --skip-build` first.

### Bootstrap workflow

Use `Bootstrap` workflow manually for first-time VPS setup or re-bootstrap.
It performs:
- base install (`install_http_stack.sh --skip-build`)
- pinned release deploy (`deploy_release.sh`)

Requirements on VPS user:
- sudo access
- passwordless sudo (non-interactive workflow)

If repo is absent on VPS, bootstrap tries:
```bash
git clone https://github.com/<owner>/<repo>.git <DEMO_REPO_PATH or /home/<DEMO_SSH_USER>/<repo-name>>
```
For private repos, pre-clone manually on VPS or adjust bootstrap auth strategy.

## Next hardening ideas

- add blocked CIDRs in `/opt/nostr/config/nostr-filter.env`
- optional PoW gate (`NIP-13`) via relay/filter extension
- optional write allowlist for trusted pubkeys
- tune `nostr-rs-relay` limits/auth (`[limits]`, `[authorization]`) as traffic grows
