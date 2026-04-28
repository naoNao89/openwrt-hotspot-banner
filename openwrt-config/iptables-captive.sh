#!/bin/sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_PATH="${INSTALL_PATH:-/etc/hotspot-firewall.sh}"

cp "$SCRIPT_DIR/hotspot-firewall.sh" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
FAS_PORT="${FAS_PORT:-8080}" "$INSTALL_PATH"
