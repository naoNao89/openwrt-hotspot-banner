#!/bin/sh
#
# Tear down the guest captive-portal configuration created by
# uci-guest-setup.sh + hotspot-firewall.sh. Called by the .ipk prerm hook
# (and manually invokable for forensics).
#
# Reverses, in order:
#   1. iptables: CAPTIVE_REDIRECT, CAPTIVE_AUTH, CAPTIVE_BLOCK, CAPTIVE_INPUT,
#      CAPTIVE_EASTWEST, CAPTIVE_EGRESS_GUARD chains and the POSTROUTING
#      MASQUERADE for the guest subnet.
#   2. UCI: firewall guest zone + forwarding + rules,
#      dhcp.guest pool + dnsmasq DNS-hijack address entries,
#      wireless.guest (the SSID), network.guest + network.guest_dev.
#   3. Service reload: firewall, dnsmasq, network, wifi.
#
# Honors KEEP_UCI=1 to skip the UCI/service reload phase (test-only) and
# UCI_BIN/IPTABLES_BIN/SERVICE_BIN/WIFI_BIN to point at mocked binaries
# (CI exercise via tests/teardown-mock.sh).

set -u
( set -o pipefail ) 2>/dev/null && set -o pipefail || true

GUEST_SSID="${GUEST_SSID:-FreeWiFi}"
GUEST_IP="${GUEST_IP:-192.168.28.1}"
GUEST_NET="${GUEST_NET:-192.168.28.0/24}"
GUEST_IFACE="${GUEST_IFACE:-br-guest}"
KEEP_UCI="${KEEP_UCI:-0}"

UCI="${UCI_BIN:-uci}"
IPT="${IPTABLES_BIN:-iptables}"
SERVICE="${SERVICE_BIN:-service}"
WIFI="${WIFI_BIN:-wifi}"
IP_BIN="${IP_BIN:-ip}"

# All errors are tolerated: teardown must be idempotent and survive partial state.
log() { echo "teardown: $*"; }

# 1. iptables ---------------------------------------------------------------
log "removing iptables rules"

# nat PREROUTING jump from guest interface
$IPT -t nat -D PREROUTING -i "$GUEST_IFACE" -j CAPTIVE_REDIRECT 2>/dev/null || true

# nat POSTROUTING masquerade for guest subnet
$IPT -t nat -D POSTROUTING -s "$GUEST_NET" -j MASQUERADE 2>/dev/null || true

# filter FORWARD/INPUT jumps from guest iface (idempotent: try a few common patterns)
for chain in FORWARD INPUT; do
    while $IPT -D "$chain" -i "$GUEST_IFACE" -j CAPTIVE_INPUT 2>/dev/null; do :; done
    while $IPT -D "$chain" -i "$GUEST_IFACE" -j CAPTIVE_EASTWEST 2>/dev/null; do :; done
    while $IPT -D "$chain" -i "$GUEST_IFACE" -j CAPTIVE_EGRESS_GUARD 2>/dev/null; do :; done
    while $IPT -D "$chain" -i "$GUEST_IFACE" -j CAPTIVE_AUTH 2>/dev/null; do :; done
    while $IPT -D "$chain" -i "$GUEST_IFACE" -j CAPTIVE_BLOCK 2>/dev/null; do :; done
done

# Flush + delete user chains (must be empty before -X).
for chain in CAPTIVE_REDIRECT; do
    $IPT -t nat -F "$chain" 2>/dev/null || true
    $IPT -t nat -X "$chain" 2>/dev/null || true
done
for chain in CAPTIVE_AUTH CAPTIVE_BLOCK CAPTIVE_INPUT CAPTIVE_EASTWEST CAPTIVE_EGRESS_GUARD; do
    $IPT -F "$chain" 2>/dev/null || true
    $IPT -X "$chain" 2>/dev/null || true
done

# 2. drop guest IP off the bridge (best-effort, leave bridge alive in case other
#    services still reference it; UCI step below will tear down the OpenWrt-managed bridge).
$IP_BIN addr del "${GUEST_IP}/24" dev "$GUEST_IFACE" 2>/dev/null || true

if [ "$KEEP_UCI" = "1" ]; then
    log "KEEP_UCI=1, skipping uci/service phase"
    exit 0
fi

# 3. UCI --------------------------------------------------------------------
log "removing uci sections"

# wireless: the SSID (FreeWiFi) — this is what stops broadcasting.
$UCI -q delete wireless.guest

# network: the bridge interface.
$UCI -q delete network.guest
$UCI -q delete network.guest_dev

# dhcp: the pool + dnsmasq DNS hijack list.
$UCI -q delete dhcp.guest

for domain in \
    connectivitycheck.gstatic.com \
    clients3.google.com \
    clients4.google.com \
    www.gstatic.com \
    captive.apple.com \
    netcts.cdn-apple.com \
    www.apple.com \
    www.msftconnecttest.com \
    msftconnecttest.com \
    ipv6.msftconnecttest.com \
    detectportal.firefox.com; do
    $UCI -q del_list dhcp.@dnsmasq[0].address="/${domain}/${GUEST_IP}" || true
done

# firewall: zone + forwarding + rules.
$UCI -q delete firewall.guest
$UCI -q delete firewall.guest_wan
$UCI -q delete firewall.guest_dns
$UCI -q delete firewall.guest_dhcp
$UCI -q delete firewall.guest_block_lan

$UCI commit network   2>/dev/null || true
$UCI commit wireless  2>/dev/null || true
$UCI commit dhcp      2>/dev/null || true
$UCI commit firewall  2>/dev/null || true

# 4. Service reload ---------------------------------------------------------
log "reloading services"
$SERVICE network restart  >/dev/null 2>&1 || true
$WIFI reload              >/dev/null 2>&1 || true
$SERVICE dnsmasq restart  >/dev/null 2>&1 || true
$SERVICE firewall restart >/dev/null 2>&1 || true

log "guest network '${GUEST_SSID}' removed"
exit 0
