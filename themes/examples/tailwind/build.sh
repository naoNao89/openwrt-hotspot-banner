#!/bin/sh
#
# Build a Tailwind-CSS-styled hotspot-banner theme using the Tailwind v4
# **standalone CLI** (no Node.js, no npm).
#
# Inputs:
#   src/index.html, src/queue.html, src/success.html — Tailwind utility classes
#   src/in.css                                       — `@import "tailwindcss";`
#
# Output:
#   dist/index.html, dist/queue.html, dist/success.html, dist/style.css
#
# Then push to a router via SSH (dev) or repackage via build-ipk.sh (deploy).
#

set -eu

VERSION="${TAILWIND_VERSION:-v4.0.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src"
DIST="$HERE/dist"
BIN="$HERE/.bin/tailwindcss-$VERSION"

# Detect platform/arch for the right binary.
case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux)  os="linux" ;;
    *) echo "Unsupported OS: $(uname -s)"; exit 2 ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "Unsupported arch: $(uname -m)"; exit 2 ;;
esac

mkdir -p "$HERE/.bin" "$DIST"

if [ ! -x "$BIN" ]; then
    URL="https://github.com/tailwindlabs/tailwindcss/releases/download/$VERSION/tailwindcss-$os-$arch"
    echo "Downloading Tailwind standalone CLI: $URL"
    curl -sSL -o "$BIN" "$URL"
    chmod +x "$BIN"
fi

# Tailwind scans HTML in $SRC for utility classes; emits minified CSS.
"$BIN" --input "$SRC/in.css" --output "$DIST/style.css" --minify --cwd "$SRC"

cp "$SRC/index.html"   "$DIST/index.html"
cp "$SRC/queue.html"   "$DIST/queue.html"
cp "$SRC/success.html" "$DIST/success.html"

echo
echo "Built theme: $DIST/"
ls -la "$DIST"
echo
echo "Push to a router for development:"
echo "  scp $DIST/* root@<router>:/etc/hotspot-banner/theme/"
