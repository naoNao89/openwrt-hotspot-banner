#!/bin/sh

set -u

if ! command -v uci >/dev/null 2>&1; then
    echo "ERROR: uci command not found; run this on OpenWrt"
    exit 1
fi

if ! uci -q show dropbear >/dev/null 2>&1; then
    echo "WARN dropbear UCI config not found"
else
    uci set dropbear.@dropbear[0].PasswordAuth='0'
    uci set dropbear.@dropbear[0].GatewayPorts='0'
    uci set dropbear.@dropbear[0].Interface='lan'
    uci commit dropbear
    echo "OK Dropbear password auth disabled"
    echo "OK Dropbear GatewayPorts disabled"
    echo "OK Dropbear bound to LAN interface"
fi

LAN_IP="$(uci -q get network.lan.ipaddr || true)"
if [ -n "$LAN_IP" ] && uci -q show uhttpd.main >/dev/null 2>&1; then
    uci -q delete uhttpd.main.listen_http
    uci -q delete uhttpd.main.listen_https
    uci add_list uhttpd.main.listen_http="${LAN_IP}:80"
    uci add_list uhttpd.main.listen_https="${LAN_IP}:443"
    uci commit uhttpd
    echo "OK uhttpd bound to ${LAN_IP}"
elif [ -z "$LAN_IP" ]; then
    echo "WARN could not detect LAN IP for uhttpd binding"
else
    echo "WARN uhttpd UCI config not found"
fi

if [ -f /etc/init.d/dropbear ]; then
    if grep -q 'procd_set_param command "$PROG" -j -F' /etc/init.d/dropbear; then
        echo "OK Dropbear local forwarding already disabled with -j"
    else
        sed -i 's#procd_set_param command "$PROG" -F#procd_set_param command "$PROG" -j -F#' /etc/init.d/dropbear
        echo "OK Dropbear local forwarding disabled with -j"
    fi
else
    echo "WARN /etc/init.d/dropbear not found"
fi

if [ -x /etc/init.d/dropbear ]; then
    /etc/init.d/dropbear restart
    echo "OK Dropbear restarted"
fi

if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd restart
    echo "OK uhttpd restarted"
fi

if [ -x /etc/init.d/quagga ]; then
    /etc/init.d/quagga stop >/dev/null 2>&1 || true
    /etc/init.d/quagga disable >/dev/null 2>&1 || true
    echo "OK quagga/zebra disabled"
fi
