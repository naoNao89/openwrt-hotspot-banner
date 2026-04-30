#!/usr/bin/env bash
#
# Regression tests for two production bugs that prevented phones from joining
# FreeWiFi. Both were silent (no log errors) and only manifested at runtime on
# a real router.
#
# Bug #1 - GUEST_IFACE / GUEST_WIFI_IFACE naming collision
#   etc/init.d/hotspot-fas exported GUEST_IFACE=$guest_iface (=ath01) to
#   guest-watcher.sh. The watcher then propagated GUEST_IFACE=ath01 into
#   hotspot-firewall.sh's environment. hotspot-firewall.sh treats GUEST_IFACE
#   as the *bridge* (br-guest) and attached every CAPTIVE_* iptables rule to
#   `-i ath01` (the wifi vif) instead of `-i br-guest`. Consequences:
#     - bridge-nf had to be on for any redirect to fire at all
#     - uci-guest-teardown.sh (which deletes -i br-guest) couldn't clean them
#     - DNS/HTTP REDIRECT routed packets to ath01's IP, but dnsmasq only binds
#       br-guest -> portal redirect was unreliable.
#
# Bug #2 - dhcp-range used tag: instead of set:
#   etc/dnsmasq.d/guest.conf shipped:
#       dhcp-range=tag:br-guest,192.168.28.100,192.168.28.150,255.255.255.0,1h
#   `tag:NAME` *filters* on a tag that something else must set; nothing did,
#   so dnsmasq silently dropped every DHCP request from br-guest. Phones
#   associated, never got an IP, and the OS disassociated after ~20s. The
#   correct form is `set:NAME` which binds the range to the interface AND
#   defines the tag for the matching dhcp-option lines.
#
# This test is purely host-side (mocks iptables/ip/etc.), runs in CI on every
# push, and fails if either regression is reintroduced.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT_SCRIPT="${REPO_ROOT}/openwrt-package/openwrt-hotspot-banner/files/etc/init.d/hotspot-fas"
WATCHER="${REPO_ROOT}/openwrt-package/openwrt-hotspot-banner/files/usr/lib/hotspot-banner/guest-watcher.sh"
FIREWALL="${REPO_ROOT}/openwrt-package/openwrt-hotspot-banner/files/usr/lib/hotspot-banner/hotspot-firewall.sh"
DNSMASQ_CONF="${REPO_ROOT}/openwrt-package/openwrt-hotspot-banner/files/etc/dnsmasq.d/guest.conf"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

# ---------------------------------------------------------------------------
echo "=== Bug #1a: init.d/hotspot-fas must export GUEST_WIFI_IFACE (not GUEST_IFACE) to the watcher ==="

# A line of the form  GUEST_IFACE="$guest_iface" \
# (followed by other env vars and the watcher invocation) reintroduces Bug #1.
# Allow the same pattern inside comments (lines starting with #).
if grep -nE '^[[:space:]]*GUEST_IFACE="\$guest_iface"' "$INIT_SCRIPT" \
    | grep -v ':[[:space:]]*#'; then
    fail "init.d/hotspot-fas exports GUEST_IFACE=\$guest_iface (Bug #1 regression)"
fi

if ! grep -qE 'GUEST_WIFI_IFACE="\$guest_iface"' "$INIT_SCRIPT"; then
    fail "init.d/hotspot-fas must pass GUEST_WIFI_IFACE=\$guest_iface to the watcher"
fi
pass "init.d/hotspot-fas passes the wifi vif as GUEST_WIFI_IFACE only"

# ---------------------------------------------------------------------------
echo "=== Bug #1b: guest-watcher.sh apply_once must force GUEST_IFACE=br-guest into firewall env ==="

# The watcher's own GUEST_IFACE is the wifi vif (back-compat). When it shells
# out to hotspot-firewall.sh it MUST override GUEST_IFACE=br-guest, otherwise
# the leaked env breaks rule attachment.
if ! grep -qE 'GUEST_IFACE=br-guest[[:space:]]+GUEST_WIFI_IFACE=' "$WATCHER"; then
    fail "guest-watcher.sh does not force GUEST_IFACE=br-guest when calling hotspot-firewall.sh"
fi
pass "guest-watcher.sh overrides GUEST_IFACE=br-guest for hotspot-firewall.sh"

# ---------------------------------------------------------------------------
echo "=== Bug #2: dnsmasq guest.conf dhcp-range must use set:br-guest (not tag:br-guest) ==="

if grep -qE '^[[:space:]]*dhcp-range=tag:br-guest' "$DNSMASQ_CONF"; then
    fail "guest.conf uses dhcp-range=tag:br-guest,... which dnsmasq silently ignores (Bug #2)"
fi
if ! grep -qE '^[[:space:]]*dhcp-range=set:br-guest' "$DNSMASQ_CONF"; then
    fail "guest.conf must use dhcp-range=set:br-guest,..."
fi
pass "dnsmasq guest.conf uses dhcp-range=set:br-guest"

# ---------------------------------------------------------------------------
echo "=== Runtime: hotspot-firewall.sh attaches CAPTIVE_* rules to -i br-guest under the correct env ==="

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/calls.log"
: >"$LOG"
mkdir -p "$WORK/bin"

# Recording shims for every binary the firewall script invokes.
for b in iptables ip6tables sysctl ip logger; do
    cat >"$WORK/bin/$b" <<EOF
#!/bin/sh
printf '%s' "$b" >>"$LOG"
for arg in "\$@"; do printf ' %s' "\$arg" >>"$LOG"; done
printf '\n' >>"$LOG"
case "\$*" in
    # iptables -C (check) must "fail" so the script falls through to -A/-I.
    *" -C "*) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$WORK/bin/$b"
done

# Invoke the firewall script with exactly the env that guest-watcher.sh's
# apply_once now produces (after the fix).
env -i PATH="$WORK/bin:/usr/bin:/bin" \
    GUEST_IFACE=br-guest \
    GUEST_WIFI_IFACE=ath01 \
    GUEST_IP=192.168.28.1 \
    FAS_PORT=8080 \
    sh "$FIREWALL" >/dev/null 2>&1

# Every CAPTIVE_* attachment to INPUT/FORWARD/PREROUTING must reference the
# bridge, not the wifi vif. The legacy bug attached them to -i ath01.
if grep -E '^iptables[[:space:]].*-i[[:space:]]+ath01[[:space:]]+.*-j[[:space:]]+CAPTIVE_' "$LOG"; then
    echo "--- recorded iptables calls ---" >&2
    cat "$LOG" >&2
    fail "hotspot-firewall.sh attached CAPTIVE_* rules to -i ath01 instead of -i br-guest"
fi

assert_call() {
    local pattern="$1" label="$2"
    if ! grep -qE -- "$pattern" "$LOG"; then
        echo "--- recorded iptables calls ---" >&2
        cat "$LOG" >&2
        fail "missing $label (pattern: $pattern)"
    fi
    pass "$label"
}

assert_call '^iptables -I INPUT 1 -i br-guest -j CAPTIVE_INPUT$' \
    "INPUT CAPTIVE_INPUT attached to br-guest"
assert_call '^iptables -I FORWARD 1 -i br-guest -j CAPTIVE_EASTWEST$' \
    "FORWARD CAPTIVE_EASTWEST attached to br-guest"
assert_call '^iptables -I FORWARD 3 -i br-guest -j CAPTIVE_AUTH$' \
    "FORWARD CAPTIVE_AUTH attached to br-guest"
assert_call '^iptables -t nat -I PREROUTING 1 -i br-guest -j CAPTIVE_REDIRECT$' \
    "nat PREROUTING CAPTIVE_REDIRECT attached to br-guest"

echo
echo "All regression-guest-iface-and-dhcp assertions passed."
