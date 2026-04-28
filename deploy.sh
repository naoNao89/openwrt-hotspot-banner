#!/bin/sh

set -eu

TARGET="${TARGET:-armv7-unknown-linux-musleabihf}"
BINARY="${BINARY:-openwrt-hotspot-banner}"
ROUTER_IP="${ROUTER_IP:-}"
ROUTER_USER="${ROUTER_USER:-root}"
REMOTE_BINARY="${REMOTE_BINARY:-/usr/bin/hotspot-fas}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
LOCAL_BINARY="target/${TARGET}/release/${BINARY}"

if [ -z "$ROUTER_IP" ]; then
    echo "Set ROUTER_IP before deploying."
    exit 2
fi

if [ ! -f "$LOCAL_BINARY" ]; then
    cargo build --target "$TARGET" --release
fi

echo "Deploying $LOCAL_BINARY to ${ROUTER_USER}@${ROUTER_IP}:${REMOTE_BINARY}"
ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_IP}" "/etc/init.d/hotspot-fas stop 2>/dev/null || true; killall -9 hotspot-fas 2>/dev/null || true"
scp -O $SSH_OPTS "$LOCAL_BINARY" "${ROUTER_USER}@${ROUTER_IP}:/tmp/hotspot-fas-new"
ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_IP}" "mv /tmp/hotspot-fas-new ${REMOTE_BINARY}; chmod +x ${REMOTE_BINARY}; iptables -F CAPTIVE_AUTH 2>/dev/null || true; conntrack -F 2>/dev/null || true; /etc/init.d/hotspot-fas start"
ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_IP}" "wget -T 3 -qO- http://127.0.0.1:8080/generate_204 | grep -m1 -E 'One tap|Connect &' >/dev/null && echo 'Portal OK'"
