#!/bin/sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
GUEST_SSID="${GUEST_SSID:-FreeWiFi}"
GUEST_IP="${GUEST_IP:-192.168.28.1}"
GUEST_WIFI_IFACE="${GUEST_WIFI_IFACE:-ath01}"
FAS_PORT="${FAS_PORT:-8080}"
SESSION_MINUTES="${SESSION_MINUTES:-60}"
DISCONNECT_GRACE_SECONDS="${DISCONNECT_GRACE_SECONDS:-300}"
QUEUE_RETRY_SECONDS="${QUEUE_RETRY_SECONDS:-300}"
MAX_ACTIVE_SESSIONS="${MAX_ACTIVE_SESSIONS:-30}"

echo "=== OpenWrt Hotspot Banner setup ==="
echo "SSID: $GUEST_SSID"
echo "Guest gateway: $GUEST_IP"
echo "Portal port: $FAS_PORT"
echo "Max active sessions: $MAX_ACTIVE_SESSIONS"
echo "Queue retry seconds: $QUEUE_RETRY_SECONDS"

echo "[1/6] Configuring guest network"
GUEST_SSID="$GUEST_SSID" GUEST_IP="$GUEST_IP" sh "$SCRIPT_DIR/uci-guest-setup.sh"

echo "[2/6] Installing captive firewall rules"
FAS_PORT="$FAS_PORT" GUEST_IP="$GUEST_IP" GUEST_WIFI_IFACE="$GUEST_WIFI_IFACE" sh "$SCRIPT_DIR/iptables-captive.sh"

echo "[3/6] Hardening router services"
sh "$SCRIPT_DIR/harden-router-services.sh"

echo "[4/6] Installing binary if bundled"
if [ -f "$SCRIPT_DIR/hotspot-fas" ]; then
    cp "$SCRIPT_DIR/hotspot-fas" /usr/bin/hotspot-fas
    chmod +x /usr/bin/hotspot-fas
else
    echo "No bundled hotspot-fas binary found; deploy the Rust binary to /usr/bin/hotspot-fas."
fi

echo "[5/6] Installing init service"
cat > /etc/init.d/hotspot-fas << EOF
#!/bin/sh /etc/rc.common
START=99
STOP=1
USE_PROCD=1

start_service() {
    ip link add name br-guest type bridge 2>/dev/null || true
    ip link set br-guest up 2>/dev/null || true
    ip addr add ${GUEST_IP}/24 dev br-guest 2>/dev/null || true
    ip link set ${GUEST_WIFI_IFACE} master br-guest 2>/dev/null || true
    ip link set ${GUEST_WIFI_IFACE} up 2>/dev/null || true
    sh /etc/hotspot-firewall.sh 2>/dev/null || true

    procd_open_instance
    procd_set_param command /usr/bin/hotspot-fas
    procd_set_param env PORT=${FAS_PORT} SESSION_MINUTES=${SESSION_MINUTES} DISCONNECT_GRACE_SECONDS=${DISCONNECT_GRACE_SECONDS} QUEUE_RETRY_SECONDS=${QUEUE_RETRY_SECONDS} MAX_ACTIVE_SESSIONS=${MAX_ACTIVE_SESSIONS} GUEST_IFACE=${GUEST_WIFI_IFACE}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
EOF
chmod +x /etc/init.d/hotspot-fas
/etc/init.d/hotspot-fas enable

echo "[6/6] Installing bridge hotplug hook"
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-hotspot-guest << EOF
#!/bin/sh
[ "\$INTERFACE" = "guest" ] || exit 0
sh /etc/hotspot-firewall.sh 2>/dev/null || true
EOF
chmod +x /etc/hotplug.d/iface/99-hotspot-guest

if [ -x /usr/bin/hotspot-fas ]; then
    /etc/init.d/hotspot-fas restart
fi

echo "=== Setup complete ==="
echo "Connect to $GUEST_SSID and tap Connect & Start Internet in the captive popup."
