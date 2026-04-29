#!/bin/sh

set -u

STATUS=0

check_script() {
    script="$1"
    printf 'Checking %s ... ' "$script"

    if [ ! -f "$script" ]; then
        echo 'MISSING'
        STATUS=1
        return
    fi

    if sh -n "$script"; then
        echo 'OK'
    else
        echo 'FAILED'
        STATUS=1
    fi
}

check_script openwrt-config/hotspot-firewall.sh
check_script openwrt-config/harden-router-services.sh
check_script openwrt-config/uci-guest-setup.sh
check_script openwrt-config/setup-router.sh
check_script openwrt-package/openwrt-hotspot-banner/files/etc/init.d/hotspot-fas
check_script openwrt-package/openwrt-hotspot-banner/files/etc/hotplug.d/iface/99-hotspot-guest
check_script openwrt-package/openwrt-hotspot-banner/files/usr/lib/hotspot-banner/hotspot-firewall.sh
check_script openwrt-package/openwrt-hotspot-banner/files/usr/lib/hotspot-banner/setup-router.sh
check_script openwrt-package/openwrt-hotspot-banner/files/usr/lib/hotspot-banner/uci-guest-setup.sh
check_script openwrt-package/openwrt-hotspot-banner/files-entware/opt/etc/init.d/S99hotspot-fas
check_script scripts/build-ipk.sh
check_script scripts/build-ipk-all.sh
check_script scripts/deploy-package-test.sh
check_script scripts/router-ipk-test.sh
check_script scripts/router-ipk-remove-test.sh
check_script scripts/test-router.sh
check_script scripts/live-queue-e2e.sh
check_script scripts/qemu-openwrt-smoke.sh

if [ "$STATUS" -eq 0 ]; then
    echo 'All shell scripts OK'
else
    echo 'One or more shell scripts failed validation'
fi

exit "$STATUS"
