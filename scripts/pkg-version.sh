#!/bin/sh
# Single source of truth for the .ipk version string.
#
# Output: "<PKG_VERSION>-<PKG_RELEASE>"
#   PKG_VERSION is read from Cargo.toml's `version = "..."` line.
#   PKG_RELEASE defaults to "1", overridable via the env var.
#
# Conventions follow OpenWrt's package.mk: bump PKG_VERSION when the upstream
# (Rust crate) changes; bump PKG_RELEASE when only the packaging changes;
# reset PKG_RELEASE to 1 when PKG_VERSION moves.
#
# Usage:
#   PKG_VERSION="$(./scripts/pkg-version.sh)"
#   PKG_RELEASE=2 ./scripts/pkg-version.sh   # -> "0.1.0-2"
#

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
CARGO_TOML="${CARGO_TOML:-$HERE/../Cargo.toml}"

if [ ! -f "$CARGO_TOML" ]; then
    echo "pkg-version: Cargo.toml not found at $CARGO_TOML" >&2
    exit 2
fi

# Match the first `version = "X.Y.Z"` under [package]; refuse to fall through
# into a [dependencies] entry that happens to set version.
VER="$(awk '
    /^\[package\]/ { in_pkg = 1; next }
    /^\[/          { in_pkg = 0 }
    in_pkg && /^version[[:space:]]*=/ {
        gsub(/.*=[[:space:]]*"/, "")
        gsub(/".*/, "")
        print
        exit
    }
' "$CARGO_TOML")"

if [ -z "$VER" ]; then
    echo "pkg-version: could not parse [package].version from $CARGO_TOML" >&2
    exit 2
fi

REL="${PKG_RELEASE:-1}"

printf '%s-%s\n' "$VER" "$REL"
