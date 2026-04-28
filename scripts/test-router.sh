#!/bin/sh

set -u

ROUTER_HOST="${ROUTER_HOST:-}"
ROUTER_USER="${ROUTER_USER:-root}"
GUEST_IFACE="${GUEST_IFACE:-br-guest}"
GUEST_WIFI_IFACE="${GUEST_WIFI_IFACE:-ath01}"
GUEST_IP="${GUEST_IP:-192.168.28.1}"
GUEST_NET="${GUEST_NET:-192.168.28.0/24}"
FAS_PORT="${FAS_PORT:-8080}"
MAX_ACTIVE_SESSIONS="${MAX_ACTIVE_SESSIONS:-30}"
QUEUE_RETRY_SECONDS="${QUEUE_RETRY_SECONDS:-300}"
GUEST_TCP_SYN_LIMIT="${GUEST_TCP_SYN_LIMIT:-100/sec}"
GUEST_TCP_SYN_BURST="${GUEST_TCP_SYN_BURST:-200}"
GUEST_BLOCK_TCP_PORTS="${GUEST_BLOCK_TCP_PORTS:-23 25 135:139 445 3389}"
GUEST_BLOCK_UDP_PORTS="${GUEST_BLOCK_UDP_PORTS:-135:139 445}"
CLIENT_MODE=0
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
NOTE_COUNT=0
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"

usage() {
    cat <<EOF
Usage: $0 [--client] [--help]

Environment:
  ROUTER_HOST=$ROUTER_HOST
  ROUTER_USER=$ROUTER_USER
  GUEST_IFACE=$GUEST_IFACE
  GUEST_WIFI_IFACE=$GUEST_WIFI_IFACE
  GUEST_IP=$GUEST_IP
  GUEST_NET=$GUEST_NET
  FAS_PORT=$FAS_PORT
  MAX_ACTIVE_SESSIONS=$MAX_ACTIVE_SESSIONS
  QUEUE_RETRY_SECONDS=$QUEUE_RETRY_SECONDS
  GUEST_TCP_SYN_LIMIT=$GUEST_TCP_SYN_LIMIT
  GUEST_TCP_SYN_BURST=$GUEST_TCP_SYN_BURST
  GUEST_BLOCK_TCP_PORTS="$GUEST_BLOCK_TCP_PORTS"
  GUEST_BLOCK_UDP_PORTS="$GUEST_BLOCK_UDP_PORTS"

Default mode runs read-only checks over SSH against the router.
--client adds local guest-client checks from the current machine.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --client)
            CLIENT_MODE=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
    shift
done

if [ -z "$ROUTER_HOST" ]; then
    echo "Set ROUTER_HOST before running router tests."
    exit 2
fi

ok() {
    echo "OK   $1"
    OK_COUNT=$((OK_COUNT + 1))
}

warn() {
    echo "WARN $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

note() {
    echo "NOTE $1"
    NOTE_COUNT=$((NOTE_COUNT + 1))
}

fail() {
    echo "FAIL $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
    echo "SKIP $1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

section() {
    echo
    echo "=== $1 ==="
}

remote() {
    ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_HOST}" "$1"
}

remote_ok() {
    label="$1"
    command="$2"
    if remote "$command" >/dev/null 2>&1; then
        ok "$label"
    else
        fail "$label"
    fi
}

remote_warn_if_ok() {
    label="$1"
    command="$2"
    if remote "$command" >/dev/null 2>&1; then
        warn "$label"
    else
        ok "$label"
    fi
}

remote_warn_if_fail() {
    label="$1"
    command="$2"
    if remote "$command" >/dev/null 2>&1; then
        ok "$label"
    else
        warn "$label"
    fi
}

remote_warn_on_match() {
    ok_label="$1"
    warn_label="$2"
    command="$3"
    if remote "$command" >/dev/null 2>&1; then
        warn "$warn_label"
    else
        ok "$ok_label"
    fi
}

remote_ok_if_mitigated() {
    ok_label="$1"
    warn_label="$2"
    risky_command="$3"
    mitigation_command="$4"
    if remote "$risky_command" >/dev/null 2>&1; then
        if remote "$mitigation_command" >/dev/null 2>&1; then
            ok "$ok_label"
        else
            warn "$warn_label"
        fi
    else
        ok "$ok_label"
    fi
}

remote_note_if_mitigated() {
    ok_label="$1"
    warn_label="$2"
    note_label="$3"
    risky_command="$4"
    mitigation_command="$5"
    if remote "$risky_command" >/dev/null 2>&1; then
        if remote "$mitigation_command" >/dev/null 2>&1; then
            note "$note_label"
        else
            warn "$warn_label"
        fi
    else
        ok "$ok_label"
    fi
}

has_local_command() {
    command -v "$1" >/dev/null 2>&1
}

section "Router Connectivity"
if remote "true" >/dev/null 2>&1; then
    ok "SSH reachable: ${ROUTER_USER}@${ROUTER_HOST}"
else
    fail "SSH reachable: ${ROUTER_USER}@${ROUTER_HOST}"
    echo
    echo "Summary: OK=$OK_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT SKIP=$SKIP_COUNT NOTE=$NOTE_COUNT"
    exit 1
fi

section "Required Router Commands"
for cmd in ip iptables uci wget iw; do
    remote_ok "router command exists: $cmd" "command -v $cmd"
done
remote_warn_if_fail "router command exists: ip6tables" "command -v ip6tables"
remote_warn_if_fail "router command exists: netstat" "command -v netstat"
remote_warn_if_fail "router command exists: opkg" "command -v opkg"

section "CVE and Patch Hygiene"
if remote "grep -q \"DISTRIB_ID='OpenWrt'\" /etc/openwrt_release 2>/dev/null" >/dev/null 2>&1; then
    ok "OpenWrt release metadata is present"
else
    warn "OpenWrt release metadata is missing or vendor-customized"
fi
if remote "grep -Eq \"DISTRIB_RELEASE='(24\\.10|25\\.12)\" /etc/openwrt_release 2>/dev/null" >/dev/null 2>&1; then
    ok "OpenWrt release appears to be a currently maintained stable series"
else
    note "OpenWrt release is old/vendor snapshot; verify vendor security backports during firmware maintenance"
fi
remote_warn_on_match "Dropbear password auth is not enabled" "Dropbear PasswordAuth is enabled; prefer key-only admin access for public Wi-Fi routers" "test \"\$(uci -q get dropbear.@dropbear[0].PasswordAuth)\" = on"
remote_warn_on_match "Dropbear GatewayPorts is not enabled" "Dropbear GatewayPorts is enabled; avoid exposing forwarded ports from SSH sessions" "test \"\$(uci -q get dropbear.@dropbear[0].GatewayPorts)\" = on"
remote_warn_on_match "Dropbear local forwarding appears disabled with -j" "Dropbear is not running with -j; consider disabling SSH local forwarding if non-root users or automation keys exist" "ps w | grep '[d]ropbear' | grep -vq -- ' -j'"
remote_warn_on_match "uhttpd is not listening on all IPv4 interfaces" "uhttpd listens on 0.0.0.0:80/443; ensure guest INPUT guard remains enforced" "uci show uhttpd 2>/dev/null | grep -q \"listen_.*0.0.0.0\""
remote_warn_on_match "uhttpd is not listening on all IPv6 interfaces" "uhttpd listens on [::]:80/443; ensure guest IPv6 stays disabled/dropped" "uci show uhttpd 2>/dev/null | grep -q \"listen_.*\\[::\\]\""
remote_note_if_mitigated "dnsmasq package is not the old 2.80 line" "dnsmasq reports 2.80 without localservice/rebind/firewall mitigation" "dnsmasq reports 2.80; localservice, rebind protection, and guest DNS firewall controls are active" "opkg list-installed 2>/dev/null | grep -q '^dnsmasq.* - 2\\.80'" "test \"\$(uci -q get dhcp.@dnsmasq[0].localservice)\" = 1 && test \"\$(uci -q get dhcp.@dnsmasq[0].rebind_protection)\" = 1 && test \"\$(uci -q get dhcp.@dnsmasq[0].domainneeded)\" = 1 && test \"\$(uci -q get dhcp.@dnsmasq[0].boguspriv)\" = 1 && iptables -S CAPTIVE_INPUT | grep -q -- '--dport 53' && iptables -S CAPTIVE_INPUT | grep -q -- '-j DROP' && test \"\$(uci -q get firewall.wan.input)\" != ACCEPT"
remote_ok_if_mitigated "Dropbear old package line is mitigated by key-only LAN-bound SSH with -j" "Dropbear reports 2019.78 without full SSH hardening" "opkg list-installed 2>/dev/null | grep -q '^dropbear - 2019\\.78'" "test \"\$(uci -q get dropbear.@dropbear[0].PasswordAuth)\" = 0 && test \"\$(uci -q get dropbear.@dropbear[0].GatewayPorts)\" = 0 && test \"\$(uci -q get dropbear.@dropbear[0].Interface)\" = lan && ps w | grep '[d]ropbear' | grep -q -- ' -j'"
remote_ok_if_mitigated "uhttpd old package line is mitigated by LAN-only LuCI binding" "uhttpd reports 2020 while still broadly exposed" "opkg list-installed 2>/dev/null | grep -q '^uhttpd - 2020'" "! uci show uhttpd 2>/dev/null | grep -Eq 'listen_.*(0\\.0\\.0\\.0|\\[::\\])'"
remote_ok_if_mitigated "odhcpd old package line is mitigated for guests by disabling guest IPv6" "odhcpd reports 2020 while guest IPv6 is still enabled" "opkg list-installed 2>/dev/null | grep -q '^odhcpd.* - 2020'" "test \"\$(uci -q get network.guest.delegate)\" = 0 && test \"\$(uci -q get dhcp.guest.ra)\" = disabled && test \"\$(uci -q get dhcp.guest.dhcpv6)\" = disabled && test \"\$(uci -q get dhcp.guest.ndp)\" = disabled && ! ip -6 addr show dev ${GUEST_IFACE} 2>/dev/null | grep -q 'inet6'"

section "Hotspot Service"
remote_ok "hotspot process is running" "ps w | grep '[h]otspot-fas'"
remote_ok "hotspot health endpoint returns ok" "test \"\$(wget -T 3 -qO- http://127.0.0.1:${FAS_PORT}/health 2>/dev/null)\" = ok"
remote_ok "service env has PORT=${FAS_PORT}" "grep -q 'PORT=${FAS_PORT}' /etc/init.d/hotspot-fas"
remote_ok "service env has SESSION_MINUTES" "grep -q 'SESSION_MINUTES=' /etc/init.d/hotspot-fas"
remote_ok "service env has DISCONNECT_GRACE_SECONDS" "grep -q 'DISCONNECT_GRACE_SECONDS=' /etc/init.d/hotspot-fas"
remote_ok "service env has QUEUE_RETRY_SECONDS=${QUEUE_RETRY_SECONDS}" "grep -q 'QUEUE_RETRY_SECONDS=${QUEUE_RETRY_SECONDS}' /etc/init.d/hotspot-fas"
remote_ok "service env has MAX_ACTIVE_SESSIONS=${MAX_ACTIVE_SESSIONS}" "grep -q 'MAX_ACTIVE_SESSIONS=${MAX_ACTIVE_SESSIONS}' /etc/init.d/hotspot-fas"
remote_ok "service env has GUEST_IFACE=${GUEST_WIFI_IFACE}" "grep -q 'GUEST_IFACE=${GUEST_WIFI_IFACE}' /etc/init.d/hotspot-fas"

section "Captive Firewall Chains"
remote_ok "CAPTIVE_REDIRECT nat chain exists" "iptables -t nat -S CAPTIVE_REDIRECT"
remote_ok "CAPTIVE_AUTH filter chain exists" "iptables -S CAPTIVE_AUTH"
remote_ok "CAPTIVE_BLOCK filter chain exists" "iptables -S CAPTIVE_BLOCK"
remote_ok "CAPTIVE_INPUT filter chain exists" "iptables -S CAPTIVE_INPUT"
remote_ok "CAPTIVE_EASTWEST filter chain exists" "iptables -S CAPTIVE_EASTWEST"
remote_ok "CAPTIVE_EGRESS_GUARD filter chain exists" "iptables -S CAPTIVE_EGRESS_GUARD"
remote_ok "nat PREROUTING jumps from ${GUEST_IFACE} to CAPTIVE_REDIRECT" "iptables -t nat -S PREROUTING | grep -q -- '-i ${GUEST_IFACE} -j CAPTIVE_REDIRECT'"
remote_ok "DNS UDP redirects to router DNS" "iptables -t nat -S CAPTIVE_REDIRECT | grep -q -- '-p udp' && iptables -t nat -S CAPTIVE_REDIRECT | grep -q -- '--dport 53'"
remote_ok "DNS TCP redirects to router DNS" "iptables -t nat -S CAPTIVE_REDIRECT | grep -q -- '-p tcp' && iptables -t nat -S CAPTIVE_REDIRECT | grep -q -- '--dport 53'"
remote_ok "HTTP TCP/80 redirects to portal port ${FAS_PORT}" "iptables -t nat -S CAPTIVE_REDIRECT | grep -q -- '--dport 80' && iptables -t nat -S CAPTIVE_REDIRECT | grep -q -- '--to-ports ${FAS_PORT}\|--to-port ${FAS_PORT}'"
remote_ok "FORWARD includes CAPTIVE_AUTH for ${GUEST_IFACE}" "iptables -S FORWARD | grep -q -- '-i ${GUEST_IFACE} -j CAPTIVE_AUTH'"
remote_ok "FORWARD includes CAPTIVE_BLOCK for ${GUEST_IFACE}" "iptables -S FORWARD | grep -q -- '-i ${GUEST_IFACE} -j CAPTIVE_BLOCK'"
remote_ok "FORWARD includes CAPTIVE_EASTWEST before auth for ${GUEST_IFACE}" "iptables -S FORWARD | grep -q -- '-i ${GUEST_IFACE} -j CAPTIVE_EASTWEST'"
remote_ok "FORWARD includes CAPTIVE_EGRESS_GUARD before auth for ${GUEST_IFACE}" "iptables -S FORWARD | grep -q -- '-i ${GUEST_IFACE} -j CAPTIVE_EGRESS_GUARD'"
remote_ok "FORWARD includes zone_guest_forward after captive chains" "iptables -S FORWARD | grep -q -- '-i ${GUEST_IFACE} -j zone_guest_forward'"

section "Guest Anti-Scan and Egress Guards"
remote_ok "bridge IPv4 netfilter is enabled" "test \"\$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)\" = 1"
remote_warn_if_fail "bridge IPv6 netfilter is enabled" "test \"\$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null)\" = 1"
remote_ok "guest east-west traffic is dropped" "iptables -S CAPTIVE_EASTWEST | grep -q -- '-s ${GUEST_NET} -d ${GUEST_NET} -j DROP'"
for dest in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    remote_ok "guest egress blocks $dest" "iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '-d $dest -j DROP'"
done
for port in $GUEST_BLOCK_TCP_PORTS; do
    remote_ok "guest egress blocks TCP port $port" "iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '-p tcp' && iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '--dport $port'"
done
for port in $GUEST_BLOCK_UDP_PORTS; do
    remote_ok "guest egress blocks UDP port $port" "iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '-p udp' && iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '--dport $port'"
done
remote_ok "guest TCP SYN burst limit is active" "iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '--limit ${GUEST_TCP_SYN_LIMIT}' && iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '--limit-burst ${GUEST_TCP_SYN_BURST}'"
remote_ok "guest TCP SYN excess traffic is dropped" "iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '-p tcp' && iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '--tcp-flags FIN,SYN,RST,ACK SYN' && iptables -S CAPTIVE_EGRESS_GUARD | grep -q -- '-j DROP'"

section "Guest Router Input Safety"
remote_ok "INPUT from ${GUEST_IFACE} jumps to CAPTIVE_INPUT" "iptables -S INPUT | grep -q -- '-i ${GUEST_IFACE} -j CAPTIVE_INPUT'"
remote_ok "CAPTIVE_INPUT allows DHCP" "iptables -S CAPTIVE_INPUT | grep -q -- '-p udp' && iptables -S CAPTIVE_INPUT | grep -q -- '--dport 67'"
remote_ok "CAPTIVE_INPUT allows UDP DNS" "iptables -S CAPTIVE_INPUT | grep -q -- '-p udp' && iptables -S CAPTIVE_INPUT | grep -q -- '--dport 53'"
remote_ok "CAPTIVE_INPUT allows TCP DNS" "iptables -S CAPTIVE_INPUT | grep -q -- '-p tcp' && iptables -S CAPTIVE_INPUT | grep -q -- '--dport 53'"
remote_ok "CAPTIVE_INPUT allows portal port ${FAS_PORT}" "iptables -S CAPTIVE_INPUT | grep -q -- '--dport ${FAS_PORT}'"
remote_ok "CAPTIVE_INPUT drops all other guest router traffic" "iptables -S CAPTIVE_INPUT | grep -q -- '-j DROP'"
for port in 22 80 443 7681 2601; do
    remote_warn_on_match "no direct guest INPUT accept for admin/risky port $port" "direct guest INPUT accept exists for admin/risky port $port" "iptables -S INPUT | grep -- '-i ${GUEST_IFACE}' | grep -q -- '--dport $port'"
done

section "Guest UCI Safety"
remote_ok "guest firewall input policy is REJECT" "test \"\$(uci -q get firewall.guest.input)\" = REJECT"
remote_ok "guest firewall forward policy is REJECT" "test \"\$(uci -q get firewall.guest.forward)\" = REJECT"
remote_ok "guest firewall output policy is ACCEPT" "test \"\$(uci -q get firewall.guest.output)\" = ACCEPT"
remote_ok "guest-to-LAN block rule exists" "uci show firewall 2>/dev/null | grep -q 'Block-Guest-LAN'"
remote_ok "guest-to-WAN forwarding exists" "uci show firewall.guest_wan 2>/dev/null | grep -q 'dest=.wan.'"
remote_ok "wireless guest client isolation is enabled" "test \"\$(uci -q get wireless.guest.isolate)\" = 1"
if remote "test \"\$(uci -q get wireless.guest.encryption)\" = none" >/dev/null 2>&1; then
    if remote "test \"\$(uci -q get wireless.guest.isolate)\" = 1 && test \"\$(uci -q get firewall.guest.input)\" = REJECT && test \"\$(uci -q get firewall.guest.forward)\" = REJECT && iptables -S INPUT | grep -q -- '-i ${GUEST_IFACE} -j CAPTIVE_INPUT'" >/dev/null 2>&1; then
        note "guest SSID is intentionally open for captive portal; isolation and firewall controls are active, OWE remains recommended if client support is acceptable"
    else
        warn "guest SSID is open without complete isolation/firewall controls"
    fi
else
    ok "guest SSID is not open encryption=none"
fi

section "IPv6 Guest Safety"
remote_ok "network.guest delegate is disabled" "test \"\$(uci -q get network.guest.delegate)\" = 0"
remote_ok "guest router advertisements disabled" "test \"\$(uci -q get dhcp.guest.ra)\" = disabled"
remote_ok "guest DHCPv6 disabled" "test \"\$(uci -q get dhcp.guest.dhcpv6)\" = disabled"
remote_ok "guest NDP disabled" "test \"\$(uci -q get dhcp.guest.ndp)\" = disabled"
remote_ok "${GUEST_IFACE} has no live IPv6 address" "! ip -6 addr show dev ${GUEST_IFACE} 2>/dev/null | grep -q 'inet6'"
remote_ok "IPv6 forwarding from ${GUEST_IFACE} is dropped" "ip6tables -S FORWARD 2>/dev/null | grep -q -- '-i ${GUEST_IFACE} -j DROP'"

section "Captive Detection Domains"
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
    remote_ok "DNS override exists: $domain" "uci show dhcp 2>/dev/null | grep -q '/$domain/${GUEST_IP}'"
done

section "Portal Local Routes"
remote_ok "root portal route responds" "wget -T 3 -qO- http://127.0.0.1:${FAS_PORT}/ >/dev/null"
remote_ok "Android generate_204 route responds" "wget -T 3 -qO- http://127.0.0.1:${FAS_PORT}/generate_204 >/dev/null"
remote_ok "Android gen_204 route responds" "wget -T 3 -qO- http://127.0.0.1:${FAS_PORT}/gen_204 >/dev/null"
remote_ok "Apple hotspot-detect route responds" "wget -T 3 -qO- http://127.0.0.1:${FAS_PORT}/hotspot-detect.html >/dev/null"
remote_ok "Apple success route responds" "wget -T 3 -qO- http://127.0.0.1:${FAS_PORT}/library/test/success.html >/dev/null"
remote_ok "Windows ncsi route responds" "wget -T 3 -qO- http://127.0.0.1:${FAS_PORT}/ncsi.txt >/dev/null"
remote_ok "Windows connecttest route responds" "wget -T 3 -qO- http://127.0.0.1:${FAS_PORT}/connecttest.txt >/dev/null"

section "Runtime State"
remote_warn_if_fail "${GUEST_WIFI_IFACE} station dump is readable" "iw dev ${GUEST_WIFI_IFACE} station dump >/dev/null"
remote_warn_if_fail "guest ARP table can be read" "cat /proc/net/arp | grep -q '${GUEST_IFACE}'"
if remote "iptables -S CAPTIVE_AUTH | grep -q '^-A CAPTIVE_AUTH'" >/dev/null 2>&1; then
    if remote "iptables -S CAPTIVE_AUTH | grep '^-A CAPTIVE_AUTH' | grep -vq -- '--mac-source'" >/dev/null 2>&1; then
        warn "one or more current auth rules are not MAC-bound"
    else
        ok "current auth rules are MAC-bound"
    fi
else
    ok "no current auth rules; MAC binding will be checked after a client authenticates"
fi
if remote "command -v netstat >/dev/null 2>&1 && netstat -lntup 2>/dev/null | grep -E '0\.0\.0\.0:(22|80|443|7681|2601)[[:space:]]|:::(22|80|443|7681|2601)[[:space:]]'" >/dev/null 2>&1; then
    warn "router has admin/routing services listening broadly; firewall guard must remain enforced"
else
    ok "no broad admin/routing listeners detected"
fi

if [ "$CLIENT_MODE" -eq 1 ]; then
    section "Guest Client Checks"
    if has_local_command nc; then
        if nc -z -G 3 "$GUEST_IP" 22 >/dev/null 2>&1; then
            fail "guest client can reach router SSH port 22"
        else
            ok "guest client cannot reach router SSH port 22"
        fi
        if nc -z -G 3 "$GUEST_IP" 80 >/dev/null 2>&1; then
            fail "guest client can reach router LuCI HTTP port 80"
        else
            ok "guest client cannot reach router LuCI HTTP port 80"
        fi
        if nc -z -G 3 "$GUEST_IP" "$FAS_PORT" >/dev/null 2>&1; then
            ok "guest client can reach captive portal port ${FAS_PORT}"
        else
            fail "guest client cannot reach captive portal port ${FAS_PORT}"
        fi
    else
        skip "nc not available for guest client port tests"
    fi

    if has_local_command dig; then
        if dig +time=3 +short captive.apple.com | grep -q "^${GUEST_IP}$"; then
            ok "guest DNS resolves captive.apple.com to ${GUEST_IP}"
        else
            warn "guest DNS does not resolve captive.apple.com to ${GUEST_IP}; run this mode while connected to guest Wi-Fi"
        fi
    else
        skip "dig not available for guest DNS test"
    fi
fi

echo
echo "Summary: OK=$OK_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT SKIP=$SKIP_COUNT NOTE=$NOTE_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
