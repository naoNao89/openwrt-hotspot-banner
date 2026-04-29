# Tailwind theme example

A minimal **pre-built** Tailwind theme for `openwrt-hotspot-banner`. Captive
portals run **before** a client has internet, so a `<script src="cdn...">` won't
load — you must ship a static stylesheet alongside the HTML.

## Quick start

```sh
./build.sh                           # downloads Tailwind v4 standalone CLI, emits dist/
scp dist/* root@<router>:/etc/hotspot-banner/theme/   # SSH dev path
```

That's it. The portal reads files from `/etc/hotspot-banner/theme/` per request,
so the theme is live immediately — no `hotspot-fas` restart needed.

## What's in `src/`

- `index.html`, `queue.html`, `success.html` — Tailwind utility classes plus
  the project's runtime template variables (`{{title}}`, `{{accept_url}}`,
  `{{active_sessions}}`, `{{max_active_sessions}}`, `{{queue_retry_seconds}}`).
- `in.css` — single `@import "tailwindcss";` line. Tailwind v4 scans the HTML
  in the same directory for classes to emit.

## Why standalone CLI?

No Node.js, no npm, no `node_modules/`. One self-contained binary downloaded
once into `.bin/`. See [Tailwind's announcement](https://tailwindcss.com/blog/standalone-cli)
and the [v4 standalone CLI tutorial](https://github.com/tailwindlabs/tailwindcss/discussions/15855).

## Customization tips

- Keep the output small — every byte loads on a constrained guest network.
- The `--minify` flag is on; `dist/style.css` should be a few KB.
- Want richer interactions? Add a small inline `<script>` in the HTML — but
  remember external requests are blocked pre-auth.
