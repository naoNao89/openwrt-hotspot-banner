#!/bin/sh

FAS_PORT="${FAS_PORT:-8080}"
GUEST_IFACE="${GUEST_IFACE:-br-guest}"
GUEST_WIFI_IFACE="${GUEST_WIFI_IFACE:-ath01}"
GUEST_IP="${GUEST_IP:-192.168.28.1}"
GUEST_NET="${GUEST_NET:-192.168.28.0/24}"
GUEST_TCP_SYN_LIMIT="${GUEST_TCP_SYN_LIMIT:-100/sec}"
GUEST_TCP_SYN_BURST="${GUEST_TCP_SYN_BURST:-200}"
GUEST_BLOCK_TCP_PORTS="${GUEST_BLOCK_TCP_PORTS:-23 25 135:139 445 3389}"
GUEST_BLOCK_UDP_PORTS="${GUEST_BLOCK_UDP_PORTS:-135:139 445}"

ip link add name "$GUEST_IFACE" type bridge 2>/dev/null || true
ip link set "$GUEST_IFACE" up 2>/dev/null || true
ip addr add "$GUEST_IP/24" dev "$GUEST_IFACE" 2>/dev/null || true
ip link set "$GUEST_WIFI_IFACE" master "$GUEST_IFACE" 2>/dev/null || true
ip link set "$GUEST_WIFI_IFACE" up 2>/dev/null || true

iptables -t nat -C POSTROUTING -s "$GUEST_NET" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$GUEST_NET" -j MASQUERADE

iptables -t nat -N CAPTIVE_REDIRECT 2>/dev/null || true
iptables -t nat -F CAPTIVE_REDIRECT
iptables -t nat -A CAPTIVE_REDIRECT -p udp --dport 53 -j REDIRECT --to-port 53
iptables -t nat -A CAPTIVE_REDIRECT -p tcp --dport 53 -j REDIRECT --to-port 53
iptables -t nat -A CAPTIVE_REDIRECT -p tcp --dport 80 -j REDIRECT --to-port "$FAS_PORT"
iptables -t nat -D PREROUTING -i "$GUEST_IFACE" -j CAPTIVE_REDIRECT 2>/dev/null || true
iptables -t nat -I PREROUTING 1 -i "$GUEST_IFACE" -j CAPTIVE_REDIRECT

iptables -N CAPTIVE_AUTH 2>/dev/null || true
iptables -N CAPTIVE_BLOCK 2>/dev/null || true
iptables -N CAPTIVE_INPUT 2>/dev/null || true
iptables -N CAPTIVE_EASTWEST 2>/dev/null || true
iptables -N CAPTIVE_EGRESS_GUARD 2>/dev/null || true
iptables -F CAPTIVE_EASTWEST
iptables -A CAPTIVE_EASTWEST -s "$GUEST_NET" -d "$GUEST_NET" -j DROP
iptables -A CAPTIVE_EASTWEST -j RETURN
iptables -F CAPTIVE_EGRESS_GUARD
for dest in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    iptables -A CAPTIVE_EGRESS_GUARD -d "$dest" -j DROP
done
for port in $GUEST_BLOCK_TCP_PORTS; do
    iptables -A CAPTIVE_EGRESS_GUARD -p tcp --dport "$port" -j DROP
done
for port in $GUEST_BLOCK_UDP_PORTS; do
    iptables -A CAPTIVE_EGRESS_GUARD -p udp --dport "$port" -j DROP
done
iptables -A CAPTIVE_EGRESS_GUARD -p tcp --syn -m limit --limit "$GUEST_TCP_SYN_LIMIT" --limit-burst "$GUEST_TCP_SYN_BURST" -j RETURN
iptables -A CAPTIVE_EGRESS_GUARD -p tcp --syn -j DROP
iptables -A CAPTIVE_EGRESS_GUARD -j RETURN
iptables -F CAPTIVE_BLOCK
iptables -A CAPTIVE_BLOCK -p udp --dport 67 -j RETURN
iptables -A CAPTIVE_BLOCK -d "$GUEST_IP" -j RETURN
iptables -A CAPTIVE_BLOCK -j DROP
iptables -F CAPTIVE_INPUT
iptables -A CAPTIVE_INPUT -p udp --dport 67 -j ACCEPT
iptables -A CAPTIVE_INPUT -p udp --dport 53 -j ACCEPT
iptables -A CAPTIVE_INPUT -p tcp --dport 53 -j ACCEPT
iptables -A CAPTIVE_INPUT -p tcp --dport "$FAS_PORT" -j ACCEPT
iptables -A CAPTIVE_INPUT -j DROP

for chain in CAPTIVE_EASTWEST CAPTIVE_EGRESS_GUARD CAPTIVE_AUTH CAPTIVE_BLOCK zone_guest_forward; do
    iptables -D FORWARD -i "$GUEST_IFACE" -j "$chain" 2>/dev/null || true
done
iptables -I FORWARD 1 -i "$GUEST_IFACE" -j CAPTIVE_EASTWEST
iptables -I FORWARD 2 -i "$GUEST_IFACE" -j CAPTIVE_EGRESS_GUARD
iptables -I FORWARD 3 -i "$GUEST_IFACE" -j CAPTIVE_AUTH
iptables -I FORWARD 4 -i "$GUEST_IFACE" -j CAPTIVE_BLOCK
iptables -I FORWARD 5 -i "$GUEST_IFACE" -j zone_guest_forward

iptables -D INPUT -i "$GUEST_IFACE" -p udp --dport 67 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$GUEST_IFACE" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$GUEST_IFACE" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$GUEST_IFACE" -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$GUEST_IFACE" -p tcp --dport "$FAS_PORT" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$GUEST_IFACE" -j CAPTIVE_INPUT 2>/dev/null || true
iptables -I INPUT 1 -i "$GUEST_IFACE" -j CAPTIVE_INPUT

sysctl -w "net.ipv6.conf.${GUEST_IFACE}.disable_ipv6=1" >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.${GUEST_WIFI_IFACE}.disable_ipv6=1" >/dev/null 2>&1 || true
sysctl -w "net.bridge.bridge-nf-call-iptables=1" >/dev/null 2>&1 || true
sysctl -w "net.bridge.bridge-nf-call-ip6tables=1" >/dev/null 2>&1 || true

ip6tables -C FORWARD -i "$GUEST_IFACE" -j DROP 2>/dev/null || \
    ip6tables -I FORWARD 1 -i "$GUEST_IFACE" -j DROP 2>/dev/null || true
