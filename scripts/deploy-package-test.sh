#!/bin/sh

set -eu

TARGET="${TARGET:-armv7-unknown-linux-musleabihf}"
BINARY="${BINARY:-openwrt-hotspot-banner}"
ROUTER_IP="${ROUTER_IP:-}"
ROUTER_USER="${ROUTER_USER:-root}"
REMOTE_BINARY="${REMOTE_BINARY:-/usr/bin/hotspot-fas}"
PACKAGE_FILES_DIR="${PACKAGE_FILES_DIR:-openwrt-package/openwrt-hotspot-banner/files}"
LOCAL_BINARY="target/${TARGET}/release/${BINARY}"
STAMP="$(date +%Y%m%d%H%M%S)"
REMOTE_STAGE="/tmp/hotspot-package-test-${STAMP}"
REMOTE_BACKUP="/tmp/hotspot-package-backup-${STAMP}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"

if [ -z "$ROUTER_IP" ]; then
    echo "Set ROUTER_IP before running package-oriented router deploy."
    exit 2
fi

if [ ! -d "$PACKAGE_FILES_DIR" ]; then
    echo "Package files directory not found: $PACKAGE_FILES_DIR"
    exit 2
fi

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    cargo build --target "$TARGET" --release
fi

if [ ! -f "$LOCAL_BINARY" ]; then
    echo "Build artifact missing: $LOCAL_BINARY"
    exit 2
fi

echo "Deploying package-oriented router test to ${ROUTER_USER}@${ROUTER_IP}"
echo "Target binary: $LOCAL_BINARY"
echo "Remote stage: $REMOTE_STAGE"
echo "Remote backup: $REMOTE_BACKUP"

ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_IP}" "mkdir -p '$REMOTE_STAGE' '$REMOTE_BACKUP'"
scp -O $SSH_OPTS "$LOCAL_BINARY" "${ROUTER_USER}@${ROUTER_IP}:${REMOTE_STAGE}/hotspot-fas"
scp -O -r $SSH_OPTS "$PACKAGE_FILES_DIR"/* "${ROUTER_USER}@${ROUTER_IP}:${REMOTE_STAGE}/"

ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_IP}" "
set -eu
/etc/init.d/hotspot-fas stop 2>/dev/null || true
killall -9 hotspot-fas 2>/dev/null || true
for path in \
    /usr/bin/hotspot-fas \
    /etc/config/hotspot-fas \
    /etc/init.d/hotspot-fas \
    /etc/hotplug.d/iface/99-hotspot-guest \
    /etc/hotspot-banner/theme \
    /usr/share/hotspot-banner/default-theme \
    /usr/lib/hotspot-banner; do
    if [ -e \"\$path\" ]; then
        mkdir -p \"$REMOTE_BACKUP\$(dirname \"\$path\")\"
        cp -a \"\$path\" \"$REMOTE_BACKUP\$path\"
    fi
done
mkdir -p /usr/bin /etc/config /etc/init.d /etc/hotplug.d/iface /etc/hotspot-banner /usr/share/hotspot-banner /usr/lib
cp '$REMOTE_STAGE/hotspot-fas' '$REMOTE_BINARY'
chmod +x '$REMOTE_BINARY'
cp '$REMOTE_STAGE/etc/config/hotspot-fas' /etc/config/hotspot-fas
cp '$REMOTE_STAGE/etc/init.d/hotspot-fas' /etc/init.d/hotspot-fas
chmod +x /etc/init.d/hotspot-fas
cp '$REMOTE_STAGE/etc/hotplug.d/iface/99-hotspot-guest' /etc/hotplug.d/iface/99-hotspot-guest
chmod +x /etc/hotplug.d/iface/99-hotspot-guest
mkdir -p /etc/hotspot-banner/theme /usr/share/hotspot-banner /usr/lib/hotspot-banner
# Drop a fixture custom theme so we can prove the /etc override layer works.
cat > /etc/hotspot-banner/theme/index.html <<'CUSTOM_HTML'
<!DOCTYPE html><html><body><main class=\"custom-test-theme\"><h1>{{title}}</h1>
<section class=\"notice\">CUSTOM_THEME_ACTIVE</section>
<form method=\"GET\" action=\"{{accept_url}}\"><button>Connect & Start Internet</button></form>
</main></body></html>
CUSTOM_HTML
cat > /etc/hotspot-banner/theme/style.css <<'CUSTOM_CSS'
body{background:#2563eb;color:#fff}
CUSTOM_CSS
cp -a '$REMOTE_STAGE/usr/share/hotspot-banner/default-theme' /usr/share/hotspot-banner/default-theme
cp -a '$REMOTE_STAGE/usr/lib/hotspot-banner/'* /usr/lib/hotspot-banner/
chmod +x /usr/lib/hotspot-banner/*.sh
/etc/init.d/hotspot-fas enable
/etc/init.d/hotspot-fas start
for i in 1 2 3 4 5 6 7 8 9 10; do
    test \"\$(wget -T 3 -qO- http://127.0.0.1:8080/health 2>/dev/null)\" = ok && break
    sleep 1
    if [ \"\$i\" = 10 ]; then
        logread | tail -80 2>/dev/null || true
        exit 1
    fi
done
wget -T 3 -qO- http://127.0.0.1:8080/ | grep -q 'CUSTOM_THEME_ACTIVE'
wget -T 3 -qO- http://127.0.0.1:8080/theme/style.css | grep -q '#2563eb'
echo 'OK package-oriented custom theme active'
echo 'Rollback backup: $REMOTE_BACKUP'
"
