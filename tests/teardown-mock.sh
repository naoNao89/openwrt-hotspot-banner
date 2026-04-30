#!/usr/bin/env bash
#
# Host-side test for uci-guest-teardown.sh.
#
# Stubs uci, iptables, ip, service, wifi as recording shims; runs the
# teardown script; asserts that every expected delete/flush/restart was
# invoked and nothing unexpected happened.
#
# This runs in CI on every push (no router required) so regressions in the
# teardown matrix are caught before .ipk reaches a device.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/openwrt-package/openwrt-hotspot-banner/files/usr/lib/hotspot-banner/uci-guest-teardown.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOG="$WORK/calls.log"
: >"$LOG"

# Shared recorder: write each invocation as `<bin> <argv...>` to LOG, exit 0.
make_shim() {
    local name="$1"
    local path="$WORK/bin/$name"
    cat >"$path" <<EOF
#!/bin/sh
# Record this call, then decide exit code based on operation.
printf '%s' "$name" >>"$LOG"
for arg in "\$@"; do printf ' %s' "\$arg" >>"$LOG"; done
printf '\n' >>"$LOG"
# iptables -D and ip addr del must fail after the first attempt so the
# teardown's "while ... -D ... ; do :; done" terminates and "|| true"
# branches are exercised. Same behavior matches a real kernel returning
# ENOENT once the rule is removed.
case "$name \$*" in
    "iptables "*"-D "*) exit 1 ;;
    "ip addr del "*) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$path"
}

mkdir -p "$WORK/bin"
for b in uci iptables ip service wifi; do make_shim "$b"; done

env -i PATH="$WORK/bin:/usr/bin:/bin" \
    UCI_BIN="$WORK/bin/uci" \
    IPTABLES_BIN="$WORK/bin/iptables" \
    IP_BIN="$WORK/bin/ip" \
    SERVICE_BIN="$WORK/bin/service" \
    WIFI_BIN="$WORK/bin/wifi" \
    GUEST_SSID="FreeWiFi" \
    GUEST_IP="192.168.28.1" \
    GUEST_NET="192.168.28.0/24" \
    GUEST_IFACE="br-guest" \
    sh "$SCRIPT" >/dev/null

calls="$(cat "$LOG")"

assert_match() {
    local pattern="$1" label="$2"
    if ! grep -qE -- "$pattern" "$LOG"; then
        echo "FAIL: missing $label (pattern: $pattern)"
        echo "--- recorded calls ---"
        cat "$LOG"
        exit 1
    fi
    echo "  ok: $label"
}

echo "=== iptables tear-down ==="
assert_match '^iptables -t nat -D PREROUTING -i br-guest -j CAPTIVE_REDIRECT$' "remove nat PREROUTING jump"
assert_match '^iptables -t nat -D POSTROUTING -s 192\.168\.28\.0/24 -j MASQUERADE$' "remove guest masquerade"
assert_match '^iptables -t nat -F CAPTIVE_REDIRECT$' "flush CAPTIVE_REDIRECT"
assert_match '^iptables -t nat -X CAPTIVE_REDIRECT$' "delete CAPTIVE_REDIRECT"
for chain in CAPTIVE_AUTH CAPTIVE_BLOCK CAPTIVE_INPUT CAPTIVE_EASTWEST CAPTIVE_EGRESS_GUARD; do
    assert_match "^iptables -F ${chain}$" "flush ${chain}"
    assert_match "^iptables -X ${chain}$" "delete ${chain}"
done

echo "=== ip address removal ==="
assert_match '^ip addr del 192\.168\.28\.1/24 dev br-guest$' "drop guest ip"

echo "=== uci deletes (the SSID, the bridge, dhcp pool, firewall zone) ==="
assert_match '^uci -q delete wireless\.guest$'      "wireless.guest (the SSID FreeWiFi)"
assert_match '^uci -q delete network\.guest$'       "network.guest"
assert_match '^uci -q delete network\.guest_dev$'   "network.guest_dev (br-guest)"
assert_match '^uci -q delete dhcp\.guest$'          "dhcp.guest"
assert_match '^uci -q delete firewall\.guest$'      "firewall guest zone"
assert_match '^uci -q delete firewall\.guest_wan$'  "firewall guest->wan"
assert_match '^uci -q delete firewall\.guest_dns$'  "firewall guest dns rule"
assert_match '^uci -q delete firewall\.guest_dhcp$' "firewall guest dhcp rule"
assert_match '^uci -q delete firewall\.guest_block_lan$' "firewall guest block lan"

echo "=== dnsmasq DNS-hijack entries removed ==="
for d in connectivitycheck.gstatic.com captive.apple.com www.msftconnecttest.com detectportal.firefox.com; do
    assert_match "del_list dhcp\.@dnsmasq\[0\]\.address=/${d}/192\.168\.28\.1" "DNS hijack ${d}"
done

echo "=== uci commits ==="
for cfg in network wireless dhcp firewall; do
    assert_match "^uci commit ${cfg}$" "commit ${cfg}"
done

echo "=== service reloads ==="
assert_match '^service network restart$'  "network restart"
assert_match '^wifi reload$'               "wifi reload"
assert_match '^service dnsmasq restart$'  "dnsmasq restart"
assert_match '^service firewall restart$' "firewall restart"

echo
echo "=== KEEP_UCI=1 short-circuit test ==="
: >"$LOG"
env -i PATH="$WORK/bin:/usr/bin:/bin" \
    UCI_BIN="$WORK/bin/uci" \
    IPTABLES_BIN="$WORK/bin/iptables" \
    IP_BIN="$WORK/bin/ip" \
    SERVICE_BIN="$WORK/bin/service" \
    WIFI_BIN="$WORK/bin/wifi" \
    KEEP_UCI=1 \
    sh "$SCRIPT" >/dev/null

if grep -q '^uci ' "$LOG"; then
    echo "FAIL: KEEP_UCI=1 did not skip uci phase"
    cat "$LOG"
    exit 1
fi
if grep -q '^service ' "$LOG"; then
    echo "FAIL: KEEP_UCI=1 did not skip service reload"
    cat "$LOG"
    exit 1
fi
if ! grep -q '^iptables ' "$LOG"; then
    echo "FAIL: KEEP_UCI=1 should still tear iptables"
    cat "$LOG"
    exit 1
fi
echo "  ok: KEEP_UCI=1 skipped uci+services, kept iptables"

echo
echo "All teardown-mock assertions passed."
