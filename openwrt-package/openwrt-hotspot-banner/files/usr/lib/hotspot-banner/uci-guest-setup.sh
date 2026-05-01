#!/bin/sh
# UCI-based guest network setup for OpenWrt
# Run this on the router via SSH
# Creates isolated guest WiFi with firewall rules

GUEST_SSID="${GUEST_SSID:-FreeWiFi}"
GUEST_IP="${GUEST_IP:-192.168.28.1}"
GUEST_NETMASK="${GUEST_NETMASK:-255.255.255.0}"
GUEST_START="${GUEST_START:-100}"
GUEST_LIMIT="${GUEST_LIMIT:-50}"

# Detect first 2.4G radio
WIFI_DEV=""
for dev in $(uci show wireless | grep '=wifi-device' | sed 's/wireless\.//;s/=wifi-device//' | sort -u); do
    band=$(uci get "wireless.${dev}.wband" 2>/dev/null || true)
    if [ "$band" = "2.4g" ] || [ -z "$WIFI_DEV" ]; then
        WIFI_DEV="$dev"
        [ "$band" = "2.4g" ] && break
    fi
done

if [ -z "$WIFI_DEV" ]; then
    echo "ERROR: Could not detect a WiFi radio device"
    exit 1
fi

echo "Using WiFi device: $WIFI_DEV"

# Create guest bridge device
uci -q delete network.guest_dev
uci set network.guest_dev="device"
uci set network.guest_dev.type="bridge"
uci set network.guest_dev.name="br-guest"
uci set network.guest_dev.bringup_empty_bridge='1'

# Create guest interface
uci -q delete network.guest
uci set network.guest="interface"
uci set network.guest.proto="static"
uci set network.guest.device="br-guest"
uci set network.guest.ipaddr="${GUEST_IP}"
uci set network.guest.netmask="${GUEST_NETMASK}"
uci set network.guest.delegate='0'
uci -q delete network.guest.ip6assign
uci -q delete network.guest.ip6hint
uci -q delete network.guest.ip6ifaceid

# Set channel to universally supported value (avoid channel 13)
uci set wireless.${WIFI_DEV}.channel='6'

# Create guest wireless interface
uci -q delete wireless.guest
uci set wireless.guest="wifi-iface"
uci set wireless.guest.device="$WIFI_DEV"
uci set wireless.guest.mode="ap"
uci set wireless.guest.network="guest"
uci set wireless.guest.ssid="$GUEST_SSID"
uci set wireless.guest.encryption="none"
uci set wireless.guest.isolate='1'

# Create guest DHCP pool
uci -q delete dhcp.guest
uci set dhcp.guest="dhcp"
uci set dhcp.guest.interface="guest"
uci set dhcp.guest.start="$GUEST_START"
uci set dhcp.guest.limit="$GUEST_LIMIT"
uci set dhcp.guest.leasetime="1h"
uci set dhcp.guest.ra="disabled"
uci set dhcp.guest.dhcpv6="disabled"
uci set dhcp.guest.ndp="disabled"
uci -q del_list dhcp.guest.dhcp_option="6,${GUEST_IP}"
uci add_list dhcp.guest.dhcp_option="6,${GUEST_IP}"

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
    uci -q del_list dhcp.@dnsmasq[0].address="/${domain}/${GUEST_IP}"
    uci add_list dhcp.@dnsmasq[0].address="/${domain}/${GUEST_IP}"
done

# Configure firewall zone for guest
uci -q delete firewall.guest
uci set firewall.guest="zone"
uci set firewall.guest.name="guest"
uci set firewall.guest.network="guest"
uci set firewall.guest.input="REJECT"
uci set firewall.guest.output="ACCEPT"
uci set firewall.guest.forward="REJECT"

# Allow guest to reach WAN only
uci -q delete firewall.guest_wan
uci set firewall.guest_wan="forwarding"
uci set firewall.guest_wan.src="guest"
uci set firewall.guest_wan.dest="wan"

# Allow DNS from guest
uci -q delete firewall.guest_dns
uci set firewall.guest_dns="rule"
uci set firewall.guest_dns.name="Allow-DNS-Guest"
uci set firewall.guest_dns.src="guest"
uci set firewall.guest_dns.dest_port="53"
uci set firewall.guest_dns.proto="tcp udp"
uci set firewall.guest_dns.target="ACCEPT"

# Allow DHCP from guest
uci -q delete firewall.guest_dhcp
uci set firewall.guest_dhcp="rule"
uci set firewall.guest_dhcp.name="Allow-DHCP-Guest"
uci set firewall.guest_dhcp.src="guest"
uci set firewall.guest_dhcp.dest_port="67"
uci set firewall.guest_dhcp.proto="udp"
uci set firewall.guest_dhcp.family="ipv4"
uci set firewall.guest_dhcp.target="ACCEPT"

# Block guest from LAN
uci -q delete firewall.guest_block_lan
uci set firewall.guest_block_lan="rule"
uci set firewall.guest_block_lan.name="Block-Guest-LAN"
uci set firewall.guest_block_lan.src="guest"
uci set firewall.guest_block_lan.dest="lan"
uci set firewall.guest_block_lan.proto="any"
uci set firewall.guest_block_lan.target="REJECT"

uci commit network
uci commit wireless
uci commit dhcp
uci commit firewall

echo "Configuration committed. Restarting services..."
service network restart
wifi reload
service dnsmasq restart
service firewall restart

echo "Guest network '$GUEST_SSID' created on $GUEST_IP"
echo "Clients are isolated from each other and from LAN"
