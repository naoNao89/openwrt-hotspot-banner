#!/bin/sh
# Run on the router. Verify opkg remove cleans up, then opkg install re-installs cleanly.

set -e

DEFAULT_IPK="$(ls /tmp/openwrt-hotspot-banner_*_arm_cortex-a7_neon-vfpv4.ipk 2>/dev/null | head -1)"
IPK="${IPK:-${DEFAULT_IPK:-/tmp/openwrt-hotspot-banner.ipk}}"
FILES="/usr/bin/hotspot-fas /etc/init.d/hotspot-fas /etc/hotplug.d/iface/99-hotspot-guest /usr/lib/hotspot-banner/hotspot-firewall.sh /usr/lib/hotspot-banner/setup-router.sh /usr/lib/hotspot-banner/uci-guest-setup.sh /usr/share/hotspot-banner/default-theme/index.html /usr/share/hotspot-banner/default-theme/queue.html /usr/share/hotspot-banner/default-theme/success.html /usr/share/hotspot-banner/default-theme/style.css"

echo "=== pre-remove ==="
opkg list-installed | grep openwrt-hotspot-banner || echo "not installed"
pgrep -laf /usr/bin/hotspot-fas || true

echo "=== opkg remove ==="
opkg remove openwrt-hotspot-banner

echo "=== post-remove: process should be gone ==="
sleep 1
if pgrep -f /usr/bin/hotspot-fas >/dev/null; then
    echo "FAIL: process still running"; exit 1
fi
echo "process stopped: OK"

echo "=== post-remove: package files should be gone (conffile + empty dirs may stay) ==="
fail=0
for p in $FILES; do
    if [ -e "$p" ]; then echo "still present: $p"; fail=1; fi
done
if [ "$fail" = 1 ]; then exit 1; fi
echo "all package files removed: OK"

echo "=== conffile retention (expected to stay): /etc/config/hotspot-fas ==="
ls -la /etc/config/hotspot-fas 2>/dev/null || echo "(removed)"

echo "=== opkg install (reinstall) ==="
opkg install "$IPK"

echo "=== post-reinstall ==="
sleep 2
opkg status openwrt-hotspot-banner | grep -E '^(Package|Version|Status):'
pgrep -laf /usr/bin/hotspot-fas
wget -T 3 -qO- http://127.0.0.1:8080/health
echo
wget -T 3 -qO- http://127.0.0.1:8080/ | grep -c 'Connect & Start Internet'

echo "=== upgrade flow (install over installed) ==="
opkg install --force-reinstall "$IPK"
sleep 2
pgrep -laf /usr/bin/hotspot-fas
wget -T 3 -qO- http://127.0.0.1:8080/health
echo
echo "=== done ==="
