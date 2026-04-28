#!/bin/sh

set -eu

ROUTER_HOST="${ROUTER_HOST:-}"
ROUTER_USER="${ROUTER_USER:-root}"
FAS_PORT="${FAS_PORT:-8080}"
GUEST_BRIDGE="${GUEST_BRIDGE:-br-guest}"
GUEST_GATEWAY="${GUEST_GATEWAY:-192.168.28.1}"
CLIENT_ONE_IP="${CLIENT_ONE_IP:-127.0.0.201}"
CLIENT_TWO_IP="${CLIENT_TWO_IP:-127.0.0.202}"
DEST_IP="${DEST_IP:-127.0.0.1}"
QUEUE_RETRY_SECONDS="${QUEUE_RETRY_SECONDS:-300}"
RUN_LIVE_QUEUE_E2E="${RUN_LIVE_QUEUE_E2E:-0}"
TARGET="${TARGET:-armv7-unknown-linux-musleabihf}"
HELPER_BINARY="target/${TARGET}/release/http-bind-get"
REMOTE_HELPER="/tmp/hotspot-http-bind-get"
RUN_ID="live-queue-e2e-$(date +%s)-$$"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"

if [ "$RUN_LIVE_QUEUE_E2E" != "1" ]; then
    echo "SKIP live queue E2E is guarded. Re-run with RUN_LIVE_QUEUE_E2E=1."
    exit 0
fi

if [ -z "$ROUTER_HOST" ]; then
    echo "Set ROUTER_HOST before running live queue E2E."
    exit 2
fi

cargo build --target "$TARGET" --release --bin http-bind-get
scp -O $SSH_OPTS "$HELPER_BINARY" "${ROUTER_USER}@${ROUTER_HOST}:${REMOTE_HELPER}"
ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_HOST}" "chmod +x '$REMOTE_HELPER'"

ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_HOST}" \
    "RUN_ID='$RUN_ID' FAS_PORT='$FAS_PORT' GUEST_BRIDGE='$GUEST_BRIDGE' GUEST_GATEWAY='$GUEST_GATEWAY' DEST_IP='$DEST_IP' CLIENT_ONE_IP='$CLIENT_ONE_IP' CLIENT_TWO_IP='$CLIENT_TWO_IP' QUEUE_RETRY_SECONDS='$QUEUE_RETRY_SECONDS' REMOTE_HELPER='$REMOTE_HELPER' sh -s" <<'REMOTE_E2E'
set -eu

NS_ONE="hsq1"
NS_TWO="hsq2"
VETH_ONE_NS="hsq1v"
VETH_ONE_BR="hsq1b"
VETH_TWO_NS="hsq2v"
VETH_TWO_BR="hsq2b"
INIT_FILE="/etc/init.d/hotspot-fas"
INIT_BACKUP="/tmp/hotspot-fas.live-queue-e2e.backup"
PASS=0

cleanup() {
    ip netns delete "$NS_ONE" 2>/dev/null || true
    ip netns delete "$NS_TWO" 2>/dev/null || true
    ip link delete "$VETH_ONE_BR" 2>/dev/null || true
    ip link delete "$VETH_TWO_BR" 2>/dev/null || true
    iptables -D CAPTIVE_AUTH -s "$CLIENT_ONE_IP" -j ACCEPT 2>/dev/null || true
    iptables -D CAPTIVE_AUTH -s "$CLIENT_TWO_IP" -j ACCEPT 2>/dev/null || true
    iptables -D CAPTIVE_AUTH -s "$CLIENT_ONE_IP/32" -j ACCEPT 2>/dev/null || true
    iptables -D CAPTIVE_AUTH -s "$CLIENT_TWO_IP/32" -j ACCEPT 2>/dev/null || true
    rm -f "$REMOTE_HELPER"
    if [ -f "$INIT_BACKUP" ]; then
        cp "$INIT_BACKUP" "$INIT_FILE"
        chmod +x "$INIT_FILE"
        /etc/init.d/hotspot-fas restart >/dev/null 2>&1 || true
        rm -f "$INIT_BACKUP"
    fi
    logger -t hotspot-live-queue-e2e "run=$RUN_ID cleanup complete pass=$PASS"
}
trap cleanup EXIT INT TERM

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "FAIL missing command: $1"
        exit 1
    }
}

need_cmd ip
need_cmd iptables
need_cmd wget
need_cmd sed
need_cmd grep
need_cmd logger
test -x "$REMOTE_HELPER" || {
    echo "FAIL helper is missing or not executable: $REMOTE_HELPER"
    exit 1
}

if ! ip link show "$GUEST_BRIDGE" >/dev/null 2>&1; then
    echo "FAIL guest bridge not found: $GUEST_BRIDGE"
    exit 1
fi

if iptables -S CAPTIVE_AUTH 2>/dev/null | grep -q '^-A CAPTIVE_AUTH '; then
    echo "FAIL CAPTIVE_AUTH already has live auth rules; refusing to disrupt active clients"
    iptables -S CAPTIVE_AUTH
    exit 1
fi

cp "$INIT_FILE" "$INIT_BACKUP"
logger -t hotspot-live-queue-e2e "run=$RUN_ID start max=1 retry=$QUEUE_RETRY_SECONDS client1=$CLIENT_ONE_IP client2=$CLIENT_TWO_IP"

sed -i \
    -e "s/QUEUE_RETRY_SECONDS=[0-9][0-9]*/QUEUE_RETRY_SECONDS=$QUEUE_RETRY_SECONDS/" \
    -e 's/MAX_ACTIVE_SESSIONS=[0-9][0-9]*/MAX_ACTIVE_SESSIONS=1/' \
    "$INIT_FILE"
/etc/init.d/hotspot-fas restart >/dev/null
sleep 2

test "$(wget -T 3 -qO- "http://127.0.0.1:$FAS_PORT/health")" = ok || {
    echo "FAIL hotspot health failed after temporary queue config"
    exit 1
}

FIRST_BODY="$("$REMOTE_HELPER" "$CLIENT_ONE_IP" "$DEST_IP" "$FAS_PORT" /accept)"
echo "$FIRST_BODY" | grep -q 'You are connected' || {
    echo "FAIL first client did not receive connected page"
    echo "$FIRST_BODY" | head -20
    exit 1
}

iptables -S CAPTIVE_AUTH | grep -q -- "-s $CLIENT_ONE_IP/32 -j ACCEPT\|-s $CLIENT_ONE_IP -j ACCEPT" || {
    echo "FAIL first client did not create a live CAPTIVE_AUTH rule"
    iptables -S CAPTIVE_AUTH
    exit 1
}

QUEUE_BODY="$("$REMOTE_HELPER" "$CLIENT_TWO_IP" "$DEST_IP" "$FAS_PORT" /)"
echo "$QUEUE_BODY" | grep -q 'FreeWiFi is full' || {
    echo "FAIL second client did not receive queue page"
    echo "$QUEUE_BODY" | head -40
    exit 1
}
echo "$QUEUE_BODY" | grep -q 'Active sessions: 1 / 1' || {
    echo "FAIL queue page did not report 1 / 1 active sessions"
    echo "$QUEUE_BODY" | grep 'Active sessions' || true
    exit 1
}
echo "$QUEUE_BODY" | grep -q "refresh\" content=\"$QUEUE_RETRY_SECONDS\"" || {
    echo "FAIL queue page did not include expected refresh seconds"
    echo "$QUEUE_BODY" | grep refresh || true
    exit 1
}

SECOND_ACCEPT_BODY="$("$REMOTE_HELPER" "$CLIENT_TWO_IP" "$DEST_IP" "$FAS_PORT" /accept)"
echo "$SECOND_ACCEPT_BODY" | grep -q 'FreeWiFi is full' || {
    echo "FAIL second client /accept did not remain queued"
    echo "$SECOND_ACCEPT_BODY" | head -40
    exit 1
}

if iptables -S CAPTIVE_AUTH | grep -q -- "-s $CLIENT_TWO_IP/32 -j ACCEPT\|-s $CLIENT_TWO_IP -j ACCEPT"; then
    echo "FAIL queued second client unexpectedly received CAPTIVE_AUTH rule"
    iptables -S CAPTIVE_AUTH
    exit 1
fi

PASS=1
logger -t hotspot-live-queue-e2e "run=$RUN_ID pass client1=$CLIENT_ONE_IP accepted client2=$CLIENT_TWO_IP queued"
echo "PASS live queue E2E: $CLIENT_ONE_IP accepted, $CLIENT_TWO_IP queued by live hotspot-fas"
echo "PROOF auth rule:"
iptables -S CAPTIVE_AUTH | grep -- "$CLIENT_ONE_IP" || true
echo "PROOF queue page:"
echo "$QUEUE_BODY" | grep -E 'FreeWiFi is full|Active sessions: 1 / 1|refresh'
REMOTE_E2E

ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_HOST}" "RUN_ID='$RUN_ID' sh -s" <<'REMOTE_LOG_ASSERT'
set -eu

LOGS=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    LOGS="$(logread 2>/dev/null | grep 'hotspot-live-queue-e2e' | grep "run=$RUN_ID" || true)"
    if echo "$LOGS" | grep -q "run=$RUN_ID start " &&
        echo "$LOGS" | grep -q "run=$RUN_ID pass " &&
        echo "$LOGS" | grep -q "run=$RUN_ID cleanup complete pass=1"; then
        break
    fi
    sleep 1
done

echo "PROOF router logs:"
echo "$LOGS"

echo "$LOGS" | grep -q "run=$RUN_ID start " || {
    echo "FAIL missing router log start marker for $RUN_ID"
    exit 1
}
echo "$LOGS" | grep -q "run=$RUN_ID pass " || {
    echo "FAIL missing router log pass marker for $RUN_ID"
    exit 1
}
echo "$LOGS" | grep -q "run=$RUN_ID cleanup complete pass=1" || {
    echo "FAIL missing router log cleanup marker for $RUN_ID"
    exit 1
}

echo "PASS router log assertions for $RUN_ID"
REMOTE_LOG_ASSERT
