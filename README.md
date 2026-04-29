# OpenWrt Hotspot Banner

Rust/Axum captive portal for OpenWrt guest WiFi. It redirects unauthenticated HTTP clients to a click-to-connect page, adds accepted clients to iptables, and can queue new clients when the active-session limit is full.

## Features

- Standalone Rust service; no openNDS required.
- Android, iOS/macOS, Windows, and Firefox captive-check routes.
- iptables-based guest isolation on `br-guest`.
- Session expiry and disconnected-client cleanup.
- Configurable active-session queue.
- Router audit and guarded live E2E scripts.

## Requirements

Development machine:

```bash
rustup target add armv7-unknown-linux-musleabihf
brew install zig
```

Router:

- OpenWrt/QSDK-style system with classic `iptables`/`fw3`.
- Guest WiFi interface, tested as `ath01`.
- SSH access as `root` for setup and deploy scripts.

## Configuration

Create local `.env` from the committed template:

```bash
cp .env.example .env
```

Set your router address locally:

```env
ROUTER_HOST=192.168.27.1
ROUTER_IP=192.168.27.1
```

`.env` is ignored by Git. Do not commit router-specific values, keys, tokens, or passwords.

Important interface values for local router audits:

```env
GUEST_IFACE=br-guest
GUEST_WIFI_IFACE=ath01
```

## Defaults

| Setting | Default |
|---|---|
| Guest SSID | `FreeWiFi` |
| Guest bridge | `br-guest` |
| Guest gateway | `192.168.28.1` |
| Guest subnet | `192.168.28.0/24` |
| Portal port | `8080` |
| Session duration | `60` minutes |
| Max active sessions | `30` |
| Queue retry | `300` seconds |
| Target | `armv7-unknown-linux-musleabihf` |

## Build and Test

```bash
cargo fmt --check
cargo test
./scripts/check-shell.sh
make build
```

CI should run only the safe local checks for now:

```bash
cargo fmt --check
cargo test
./scripts/check-shell.sh
```

The GitHub Actions workflow in `.github/workflows/ci.yml` runs:

- Rust format, Clippy, and tests.
- Shell syntax checks.
- Docker CI image build through `make ci-docker`.
- Repository hygiene checks for `.env`, guarded router scripts, and README fences.

Do not run deploy, router audit, or live E2E scripts in CI unless a stable test router is explicitly configured.

To reproduce the CI container locally:

```bash
make ci-docker
```

## First Router Setup

Upload setup scripts:

```bash
scp -O -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  openwrt-config/*.sh root@<router-ip>:/tmp/
```

Run setup on the router:

```bash
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  root@<router-ip> 'cd /tmp && sh setup-router.sh'
```

## Deploy

Load `.env`, build, and deploy:

```bash
set -a
. ./.env
set +a
make deploy
```

`deploy.sh` requires `ROUTER_IP`. It copies the binary through `/tmp`, restarts `hotspot-fas`, clears current auth rules, and verifies the portal route.

## Router Audit

Run the read-only live audit:

```bash
set -a
. ./.env
set +a
./scripts/test-router.sh
```

Healthy tested result:

```text
Summary: OK=105 WARN=0 FAIL=0 SKIP=0 NOTE=3
```

## Live Queue E2E

The live E2E is guarded and skips by default:

```bash
./scripts/live-queue-e2e.sh
```

Run it only when you are ready to temporarily change queue settings on the router:

```bash
set -a
. ./.env
set +a
RUN_LIVE_QUEUE_E2E=1 ./scripts/live-queue-e2e.sh
```

It temporarily sets `MAX_ACTIVE_SESSIONS=1`, simulates two source-IP clients, verifies one auth rule and one queue page, asserts router `logread` markers, then restores the router config.

## How It Works

Before acceptance:

- DHCP and DNS to the router are allowed.
- HTTP port `80` is redirected to the portal.
- Guest forwarding is blocked.
- IPv6 forwarding from guest is dropped.

After acceptance:

- The client IP is added to `CAPTIVE_AUTH`.
- Internet forwarding is allowed for that client.
- Captive-check URLs return OS success responses.

When the queue is full, new unauthenticated clients receive an auto-refresh queue page instead of being authenticated.

## Useful Checks

```bash
ssh root@<router-ip> 'ps | grep hotspot-fas; wget -qO- http://127.0.0.1:8080/generate_204 | head'
ssh root@<router-ip> 'iptables -S CAPTIVE_AUTH; iptables -t nat -S CAPTIVE_REDIRECT'
ssh root@<router-ip> 'logread | grep -Ei "hotspot|dnsmasq|DHCP" | tail -60'
```

## Theming

Captive-portal pages are runtime-themable — drop HTML/CSS into
`/etc/hotspot-banner/theme/` and the next request renders the new theme. No
binary rebuild, no service restart.

To customize, copy our Tailwind example, tweak the HTML, rebuild, and push:

```bash
cp -r themes/examples/tailwind ~/my-portal-theme
cd ~/my-portal-theme
# edit src/{index,queue,success}.html — change classes, copy, branding
./build.sh
scp dist/* root@<router-ip>:/etc/hotspot-banner/theme/
```

`build.sh` auto-downloads the **Tailwind v4 standalone CLI** (no Node.js, no
npm) and emits `dist/{index,queue,success}.html` plus a minified `style.css`.
The portal picks up changes on the very next request.

Available template variables: `{{title}}`, `{{accept_url}}`,
`{{active_sessions}}`, `{{max_active_sessions}}`, `{{queue_retry_seconds}}`.

Prefer plain CSS, or want to bake your theme into a `.ipk` so it survives
factory resets? See the full guide at [`docs/theming.md`](./docs/theming.md)
— covers the captive-portal walled-garden constraint (why CDN-loaded CSS
won't work), three theming workflows, and SSH-vs-`.ipk` deployment paths.

## Notes

- Modern HTTPS traffic cannot be transparently redirected without certificate errors.
- Phone testing is more reliable after forgetting `FreeWiFi` and disabling mobile data.
- The guest SSID is intentionally open; access control is enforced by firewall and portal state.
