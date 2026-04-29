# Theming guide

`openwrt-hotspot-banner` ships a runtime-themable captive portal. You do **not**
need to rebuild the binary, the `.ipk`, or restart `hotspot-fas` to change the
look — drop HTML/CSS files into the theme directory and the next request picks
them up.

## How theme resolution works

For each page request the binary looks for `<page>.html` in this order:

1. `/etc/hotspot-banner/theme/<page>.html` — **user override**, persisted across
   `opkg upgrade` (it's a UCI conffile-equivalent directory).
2. `/usr/share/hotspot-banner/default-theme/<page>.html` — packaged default
   shipped with the `.ipk`.
3. **Embedded fallback** compiled into the binary, used when the filesystem
   fails entirely (e.g. read-only / corrupt overlay).

Pages: `index.html` (banner), `queue.html` (portal full), `success.html`
(authenticated). Plus a single shared `style.css` served from `/theme/style.css`.

For Entware installs (Padavan-NG / Asus-Merlin) the prefix is `/opt`:
`/opt/etc/hotspot-banner/theme/` and `/opt/share/hotspot-banner/default-theme/`.

## Template variables

Replaced server-side, HTML-escaped where the value is user-controlled:

| Variable                  | Where it appears        | Notes                       |
|---------------------------|-------------------------|-----------------------------|
| `{{title}}`               | `<title>`, headings     | from `WIFI_TITLE` / config  |
| `{{accept_url}}`          | `<form action=...>`     | endpoint that authenticates |
| `{{active_sessions}}`     | counter copy            | live count                  |
| `{{max_active_sessions}}` | counter copy            | from config                 |
| `{{queue_retry_seconds}}` | `<meta http-equiv>` etc | when queueing                |

If you reference a variable that doesn't exist, it's left as-is in the page —
useful while iterating.

## The captive-portal constraint (read this before adding `<script src="...">`)

A captive portal serves pages **before** the client has internet. The router's
firewall blocks all external traffic until the user clicks Connect. That means:

- `<script src="https://cdn.tailwindcss.com">` — **won't load**, page renders
  unstyled.
- `<link href="https://fonts.googleapis.com/...">` — **won't load**.
- Inline `<script>` and inline `<style>` — fine.
- Local `/theme/*.css` and `/theme/*.js` you ship — fine.

So: **pre-build everything you ship**.

(Alternative: punch holes through the firewall walled-garden config in
`/etc/config/hotspot-fas`. Fragile — CDN IPs change and HTTPS to a CDN gives
the user a half-broken pre-auth experience. Not recommended.)

## Three theming workflows

### 1. Plain HTML + CSS (zero tooling)

Edit `src/*.html` with vanilla classes, write a `style.css` by hand,
`scp` to `/etc/hotspot-banner/theme/`. Smallest payload, no toolchain.

### 2. Tailwind CSS (recommended for serious customization)

Use the Tailwind **standalone CLI** — a single self-contained binary, no Node.

```sh
cd themes/examples/tailwind
./build.sh
scp dist/* root@<router>:/etc/hotspot-banner/theme/
```

The example in `themes/examples/tailwind/` is a fully working starter. See
[`themes/examples/tailwind/README.md`](../themes/examples/tailwind/README.md).

Why standalone CLI:

- No Node.js, npm, or `node_modules/` baggage.
- Tailwind v4 scans your HTML, emits a minified CSS file with **only** the
  utility classes you actually use. Typical output: 5–15 KB.
- Cross-platform binaries (macOS, Linux, Windows; x64 and arm64).

References:

- [Tailwind standalone CLI announcement](https://tailwindcss.com/blog/standalone-cli)
- [Tailwind v4 standalone CLI tutorial](https://github.com/tailwindlabs/tailwindcss/discussions/15855)

### 3. Other CSS frameworks

The same rule applies: **build statically, ship one CSS file.** Bulma, Pico,
Water.css, hand-rolled — all fine. Simply replace `style.css` and ensure your
HTML's `<link rel="stylesheet" href="/theme/style.css">` matches.

## Two ways to deploy a theme

**Dev (SSH, fast iteration)**

```sh
scp my-theme/* root@router:/etc/hotspot-banner/theme/
```

The next browser request renders the new theme. No service restart.

**Prod (bake into a custom `.ipk`)**

Drop your finalized files into
`openwrt-package/openwrt-hotspot-banner/files/etc/hotspot-banner/theme/` (or
the Entware variant under `files-entware/opt/etc/hotspot-banner/theme/`),
then `make ipk` (or `make ipk-all`) and `opkg install` on the router. The
theme becomes the package default and survives reboots/factory resets that
preserve `/etc`.

## Resetting to defaults

```sh
ssh root@router 'rm -rf /etc/hotspot-banner/theme/*'
```

Resolution falls through to `/usr/share/hotspot-banner/default-theme/`.

## Pitfalls

- **Empty theme dir** is OK — falls through to the packaged default.
- **Missing `style.css`** in the theme dir but `index.html` overridden — the
  HTML `<link>` will 404. Either ship both files or omit the `<link>` and
  inline your CSS.
- **Wrong stylesheet path** — always use `/theme/style.css` (root-relative).
  The portal serves theme assets from `/theme/<filename>` regardless of where
  they live on disk.
- **`opkg install` of the same version is a no-op.** Use `--force-reinstall`
  to overwrite an existing install (or `opkg remove` first).
