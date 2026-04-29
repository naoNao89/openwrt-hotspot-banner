#!/bin/sh
# Run on the router. Stash previous file-based deploy, install the ipk,
# verify service + custom theme, dump diagnostics.

set -e

IPK="${IPK:-/tmp/openwrt-hotspot-banner_0.1.0-1_arm_cortex-a7_neon-vfpv4.ipk}"
TS="$(date +%Y%m%d%H%M%S)"
STASH="/tmp/pre-ipk-${TS}"

echo "=== stop existing service ==="
/etc/init.d/hotspot-fas stop 2>/dev/null || true
killall -9 hotspot-fas 2>/dev/null || true

echo "=== stash previous file-based deploy to ${STASH} ==="
mkdir -p "${STASH}"
for p in /usr/bin/hotspot-fas \
         /etc/config/hotspot-fas \
         /etc/init.d/hotspot-fas \
         /etc/hotplug.d/iface/99-hotspot-guest \
         /etc/hotspot-banner \
         /usr/share/hotspot-banner \
         /usr/lib/hotspot-banner; do
    if [ -e "$p" ]; then
        mkdir -p "${STASH}$(dirname "$p")"
        mv "$p" "${STASH}$p"
    fi
done

echo "=== opkg install ==="
opkg install "${IPK}"

echo "=== opkg status ==="
opkg status openwrt-hotspot-banner

echo "=== opkg files ==="
opkg files openwrt-hotspot-banner

echo "=== service state ==="
sleep 2
pgrep -laf /usr/bin/hotspot-fas || echo "process not running"

echo "=== /health ==="
wget -T 3 -qO- http://127.0.0.1:8080/health || true
echo

echo "=== custom theme marker ==="
wget -T 3 -qO- http://127.0.0.1:8080/ | grep -c CUSTOM_THEME_ACTIVE || true

echo "=== /theme/style.css head ==="
wget -T 3 -qO- http://127.0.0.1:8080/theme/style.css | head -3 || true

echo "=== logread tail ==="
logread | grep -i hotspot | tail -20 || true

echo "=== done. stash dir: ${STASH} ==="
