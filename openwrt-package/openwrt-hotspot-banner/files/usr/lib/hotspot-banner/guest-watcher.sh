#!/bin/sh
#
# Boot-race resilient watcher for the captive-portal guest bridge.
#
# Why this exists:
#   On QSDK-derived OpenWrt forks (e.g. CMCC RAX3000QY) the wifi AP vif
#   (ath01) can take 30s..several minutes to spawn after boot, depending on
#   firmware load order, regulatory init, and vendor whc-iface.sh hooks.
#   The hotspot-fas init script can't block procd that long, and a
#   single timed retry (e.g. 30s) is not enough on cold boot. A small
#   detached watcher fixes both: launch fast, retry on a slow cadence
#   until ath01 appears, then exit.
#
# What it does (idempotently, in a permanent heartbeat loop):
#   1. Wait for ${GUEST_IFACE} to exist (default ath01).
#   2. Bring br-guest up, assign GUEST_IP/24, enslave GUEST_IFACE.
#   3. Reapply hotspot-firewall.sh so iptables CAPTIVE_* chains match the
#      now-live interfaces.
#   4. Sleep, then verify ath01 is still master=br-guest. If netifd or the
#      vendor wifi stack has un-enslaved it (observed on RAX3000QY), redo
#      step 2 immediately.
#
# We intentionally DO NOT call `dnsmasq reload` here, even though it would
# seem helpful. On RAX3000QY-class boxes, dnsmasq reload nudges netifd to
# re-evaluate br-guest, and netifd's view of network.guest_dev does NOT
# contain ath01 (the wifi auto-bridge hooks are broken), so it kicks ath01
# back out of the bridge. The packaged /etc/dnsmasq.d/guest.conf is loaded
# on dnsmasq's normal start; we never need to reload mid-flight.
#
# Tuning via env (or /etc/config/hotspot-fas):
#   GUEST_IFACE         - wifi vif name (default ath01)
#   GUEST_IP            - router IP on br-guest (default 192.168.28.1)
#   FAS_PORT            - portal port (default 8080)
#   GUEST_WATCH_DEADLINE_SECONDS - max wall-clock time to keep retrying
#                                  (default 600 = 10 min, then exit)
#   GUEST_WATCH_INTERVAL_SECONDS - sleep between retries (default 3)
#
# This script is meant to be run in the background:
#   /usr/lib/hotspot-banner/guest-watcher.sh &

set -u

# Naming: GUEST_WIFI_IFACE is the wifi vif (e.g. ath01); GUEST_IFACE is the
# bridge (br-guest), per hotspot-firewall.sh + uci-guest-teardown.sh. Accept
# the legacy GUEST_IFACE env for back-compat (older init scripts set it to
# the wifi vif), but never propagate it to firewall.sh — see apply_once.
GUEST_WIFI_IFACE="${GUEST_WIFI_IFACE:-${GUEST_IFACE:-ath01}}"
GUEST_IFACE="$GUEST_WIFI_IFACE"
GUEST_IP="${GUEST_IP:-192.168.28.1}"
FAS_PORT="${FAS_PORT:-8080}"
DEADLINE="${GUEST_WATCH_DEADLINE_SECONDS:-600}"
INTERVAL="${GUEST_WATCH_INTERVAL_SECONDS:-3}"

logger -t hotspot-fas-watcher "started; iface=${GUEST_IFACE} interval=${INTERVAL}s deadline=${DEADLINE}s (until first success), then heartbeat forever"

# Returns 0 if iface exists AND its master is br-guest right now.
already_enslaved() {
    [ "$(readlink "/sys/class/net/${GUEST_IFACE}/master" 2>/dev/null | xargs -r basename 2>/dev/null)" = "br-guest" ]
}

apply_once() {
    ip link add name br-guest type bridge 2>/dev/null || true
    ip link set br-guest up 2>/dev/null || true
    ip addr add "${GUEST_IP}/24" dev br-guest 2>/dev/null || true
    ip link set "$GUEST_IFACE" master br-guest 2>/dev/null || true
    ip link set "$GUEST_IFACE" up 2>/dev/null || true
    # Force GUEST_IFACE=br-guest for the firewall script: rules must attach to
    # the bridge, not the wifi vif (which is GUEST_WIFI_IFACE). The watcher
    # itself has GUEST_IFACE set to the wifi vif, so we explicitly override.
    GUEST_IFACE=br-guest GUEST_WIFI_IFACE="$GUEST_WIFI_IFACE" GUEST_IP="$GUEST_IP" FAS_PORT="$FAS_PORT" \
        sh /usr/lib/hotspot-banner/hotspot-firewall.sh >/dev/null 2>&1 || true
}

# Phase 1: wait until the wifi vif exists (cold-boot race), bounded by DEADLINE.
elapsed=0
while [ "$elapsed" -lt "$DEADLINE" ] && ! ip link show "$GUEST_IFACE" >/dev/null 2>&1; do
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

if ! ip link show "$GUEST_IFACE" >/dev/null 2>&1; then
    logger -t hotspot-fas-watcher "WARNING: ${GUEST_IFACE} did not appear within ${DEADLINE}s; entering heartbeat anyway in case it shows up later"
else
    logger -t hotspot-fas-watcher "${GUEST_IFACE} appeared after ${elapsed}s, applying initial config"
fi

apply_once
if already_enslaved; then
    logger -t hotspot-fas-watcher "guest network ready (br-guest has ${GUEST_IFACE})"
fi

# Phase 2: heartbeat forever. If anything (netifd, vendor wifi stack, fw3
# reload) un-enslaves ${GUEST_IFACE}, we re-enslave on the next tick.
while :; do
    sleep "$INTERVAL"
    if ip link show "$GUEST_IFACE" >/dev/null 2>&1 && ! already_enslaved; then
        logger -t hotspot-fas-watcher "${GUEST_IFACE} drifted off br-guest; re-enslaving"
        apply_once
    fi
done
