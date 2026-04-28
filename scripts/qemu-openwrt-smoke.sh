#!/bin/sh

set -eu

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.6}"
OPENWRT_TARGET="${OPENWRT_TARGET:-x86/64}"
OPENWRT_IMAGE_PREFIX="openwrt-${OPENWRT_VERSION}-x86-64"
OPENWRT_IMAGE_GZ="${OPENWRT_IMAGE_PREFIX}-generic-ext4-combined.img.gz"
OPENWRT_IMAGE_SHA256="${OPENWRT_IMAGE_SHA256:-23dc6904ede514e37e9938604c9951a0601c375efdaf093c0d191d12e463f9b2}"
OPENWRT_BASE_URL="${OPENWRT_BASE_URL:-https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}}"
WORK_DIR="${QEMU_WORK_DIR:-.qemu-openwrt}"
SSH_PORT="${QEMU_SSH_PORT:-2222}"
APP_HOST_PORT="${QEMU_APP_HOST_PORT:-18080}"
QEMU_MEMORY_MB="${QEMU_MEMORY_MB:-256}"
APP_BINARY_PATH="${QEMU_APP_BINARY:-target/x86_64-unknown-linux-musl/release/openwrt-hotspot-banner}"
BENCHMARK_DIR="${QEMU_BENCHMARK_DIR:-$WORK_DIR/benchmarks}"
HEY_HEALTH_REQUESTS="${QEMU_HEY_HEALTH_REQUESTS:-1000}"
HEY_HEALTH_CONCURRENCY="${QEMU_HEY_HEALTH_CONCURRENCY:-25}"
HEY_PAGE_REQUESTS="${QEMU_HEY_PAGE_REQUESTS:-500}"
HEY_PAGE_CONCURRENCY="${QEMU_HEY_PAGE_CONCURRENCY:-10}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1"
        exit 127
    }
}

require_command curl
require_command gzip
require_command hey
require_command losetup
require_command mount
require_command qemu-system-x86_64
require_command scp
require_command sha256sum
require_command ssh
require_command ssh-keygen
require_command sudo
require_command umount

group_start() {
    echo "::group::$1"
}

group_end() {
    echo "::endgroup::"
}

if [ ! -f "$APP_BINARY_PATH" ]; then
    echo "Missing QEMU app binary: $APP_BINARY_PATH"
    exit 2
fi

mkdir -p "$WORK_DIR"
rm -rf "$BENCHMARK_DIR"
mkdir -p "$BENCHMARK_DIR"

IMAGE_GZ_PATH="$WORK_DIR/$OPENWRT_IMAGE_GZ"
IMAGE_PATH="$WORK_DIR/${OPENWRT_IMAGE_PREFIX}.img"
SSH_KEY="$WORK_DIR/id_ed25519"
MOUNT_DIR="$WORK_DIR/rootfs"
QEMU_PID=""
LOOP_DEV=""

cleanup() {
    if [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" >/dev/null 2>&1 || true
        wait "$QEMU_PID" >/dev/null 2>&1 || true
    fi
    if mountpoint -q "$MOUNT_DIR"; then
        sudo umount "$MOUNT_DIR"
    fi
    if [ -n "$LOOP_DEV" ]; then
        sudo losetup -d "$LOOP_DEV" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

if [ ! -f "$IMAGE_GZ_PATH" ]; then
    curl -fsSL "$OPENWRT_BASE_URL/$OPENWRT_IMAGE_GZ" -o "$IMAGE_GZ_PATH"
fi

printf '%s  %s\n' "$OPENWRT_IMAGE_SHA256" "$IMAGE_GZ_PATH" | sha256sum -c -

set +e
gzip -dc "$IMAGE_GZ_PATH" > "$IMAGE_PATH"
GZIP_STATUS=$?
set -e
if [ "$GZIP_STATUS" -ne 0 ] && [ "$GZIP_STATUS" -ne 2 ]; then
    exit "$GZIP_STATUS"
fi

rm -f "$SSH_KEY" "$SSH_KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"
SSH_PUBLIC_KEY=$(cat "$SSH_KEY.pub")

mkdir -p "$MOUNT_DIR"
LOOP_DEV=$(sudo losetup --find --partscan --show "$IMAGE_PATH")
sudo mount "${LOOP_DEV}p2" "$MOUNT_DIR"
sudo mkdir -p "$MOUNT_DIR/etc/dropbear"
printf '%s\n' "$SSH_PUBLIC_KEY" | sudo tee "$MOUNT_DIR/etc/dropbear/authorized_keys" >/dev/null
sudo chmod 600 "$MOUNT_DIR/etc/dropbear/authorized_keys"
sudo tee -a "$MOUNT_DIR/etc/config/firewall" >/dev/null <<'FIREWALL'

config rule
	option name 'Allow-CI-SSH'
	option src 'wan'
	option proto 'tcp'
	option dest_port '22'
	option target 'ACCEPT'

config rule
	option name 'Allow-CI-App-Benchmark'
	option src 'wan'
	option proto 'tcp'
	option dest_port '8080'
	option target 'ACCEPT'
FIREWALL
sudo umount "$MOUNT_DIR"

qemu-system-x86_64 \
    -m "$QEMU_MEMORY_MB" \
    -nographic \
    -no-reboot \
    -drive file="$IMAGE_PATH",format=raw,if=virtio \
    -nic user,model=virtio-net-pci \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${APP_HOST_PORT}-:8080" &
QEMU_PID=$!

SSH_BASE="ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"
SCP_BASE="scp -O -P $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

run_hey() {
    name="$1"
    requests="$2"
    concurrency="$3"
    url="$4"
    output="$BENCHMARK_DIR/hey-${name}.txt"

    group_start "HTTP benchmark ${name}"
    echo "url=$url"
    echo "requests=$requests"
    echo "concurrency=$concurrency"
    echo "output=$output"

    set +e
    hey -n "$requests" -c "$concurrency" "$url" > "$output" 2>&1
    status=$?
    set -e

    cat "$output"
    group_end
    if [ "$status" -ne 0 ]; then
        exit "$status"
    fi

    if grep -q 'Error distribution:' "$output"; then
        exit 1
    fi
}

CONNECTED=0
for _ in $(seq 1 60); do
    if $SSH_BASE true >/dev/null 2>&1; then
        CONNECTED=1
        break
    fi
    sleep 2
done

if [ "$CONNECTED" -ne 1 ]; then
    exit 1
fi

group_start "QEMU benchmark configuration"
echo "openwrt_version=$OPENWRT_VERSION"
echo "openwrt_target=$OPENWRT_TARGET"
echo "qemu_memory_mb=$QEMU_MEMORY_MB"
echo "ssh_host_port=$SSH_PORT"
echo "app_host_port=$APP_HOST_PORT"
echo "benchmark_dir=$BENCHMARK_DIR"
echo "app_binary_path=$APP_BINARY_PATH"
echo "hey_health_requests=$HEY_HEALTH_REQUESTS"
echo "hey_health_concurrency=$HEY_HEALTH_CONCURRENCY"
echo "hey_page_requests=$HEY_PAGE_REQUESTS"
echo "hey_page_concurrency=$HEY_PAGE_CONCURRENCY"
group_end

group_start "OpenWrt boot state"
$SSH_BASE 'cat /etc/openwrt_release'
$SSH_BASE 'free'
$SSH_BASE 'command -v uci; command -v ip; command -v logger; command -v wget'
group_end

$SSH_BASE 'rm -rf /tmp/hotspot-ci && mkdir -p /tmp/hotspot-ci'
$SCP_BASE -r deploy.sh openwrt-config scripts root@127.0.0.1:/tmp/hotspot-ci/
$SCP_BASE "$APP_BINARY_PATH" root@127.0.0.1:/tmp/hotspot-ci/hotspot-fas
$SSH_BASE 'cd /tmp/hotspot-ci && ash -n deploy.sh && ash -n openwrt-config/harden-router-services.sh && ash -n openwrt-config/hotspot-firewall.sh && ash -n openwrt-config/iptables-captive.sh && ash -n openwrt-config/setup-router.sh && ash -n openwrt-config/uci-guest-setup.sh && ash -n scripts/check-shell.sh && ash -n scripts/test-router.sh && ash -n scripts/live-queue-e2e.sh && ash -n scripts/qemu-openwrt-smoke.sh && RUN_LIVE_QUEUE_E2E=0 ash scripts/live-queue-e2e.sh'
$SSH_BASE 'chmod +x /tmp/hotspot-ci/hotspot-fas'
$SSH_BASE 'PORT=8080 SESSION_MINUTES=1 DISCONNECT_GRACE_SECONDS=1 QUEUE_RETRY_SECONDS=1 MAX_ACTIVE_SESSIONS=30 GUEST_IFACE=br-lan /tmp/hotspot-ci/hotspot-fas >/tmp/hotspot-ci/hotspot-fas.log 2>&1 & echo $! >/tmp/hotspot-ci/hotspot-fas.pid'
$SSH_BASE 'for i in 1 2 3 4 5 6 7 8 9 10; do test "$(wget -T 3 -qO- http://127.0.0.1:8080/health 2>/dev/null)" = ok && exit 0; sleep 1; done; cat /tmp/hotspot-ci/hotspot-fas.log; exit 1'
{
    echo "profile_memory_mb=$QEMU_MEMORY_MB"
    echo "app_host_url=http://127.0.0.1:${APP_HOST_PORT}"
    echo "openwrt_release:"
    $SSH_BASE 'cat /etc/openwrt_release'
    echo "free_before:"
    $SSH_BASE 'free'
    echo "process_before:"
    $SSH_BASE "ps w | grep '[h]otspot-fas'"
} | tee "$BENCHMARK_DIR/openwrt-before.txt"
$SSH_BASE 'wget -T 3 -qO- http://127.0.0.1:8080/ | grep -q "Connect & Start Internet"'
$SSH_BASE 'wget -T 3 -qO- http://127.0.0.1:8080/generate_204 | grep -q "Connect & Start Internet"'
group_start "In-guest endpoint stress"
echo "paths=/health / /generate_204 /hotspot-detect.html /ncsi.txt /connecttest.txt"
echo "requests_per_path=100"
$SSH_BASE 'for path in /health / /generate_204 /hotspot-detect.html /ncsi.txt /connecttest.txt; do i=0; while [ "$i" -lt 100 ]; do wget -T 3 -qO- "http://127.0.0.1:8080${path}" >/dev/null; i=$((i + 1)); done; done'
group_end
run_hey health "$HEY_HEALTH_REQUESTS" "$HEY_HEALTH_CONCURRENCY" "http://127.0.0.1:${APP_HOST_PORT}/health"
run_hey root "$HEY_PAGE_REQUESTS" "$HEY_PAGE_CONCURRENCY" "http://127.0.0.1:${APP_HOST_PORT}/"
run_hey generate-204 "$HEY_PAGE_REQUESTS" "$HEY_PAGE_CONCURRENCY" "http://127.0.0.1:${APP_HOST_PORT}/generate_204"
$SSH_BASE 'test "$(wget -T 3 -qO- http://127.0.0.1:8080/health 2>/dev/null)" = ok'
{
    echo "free_after:"
    $SSH_BASE 'free'
    echo "process_after:"
    $SSH_BASE "ps w | grep '[h]otspot-fas'"
    echo "dmesg_health_scan:"
    $SSH_BASE "dmesg | grep -Ei 'oom|panic|segfault|killed process' || true"
} | tee "$BENCHMARK_DIR/openwrt-after.txt"
$SSH_BASE "! dmesg | grep -Ei 'oom|panic|segfault|killed process'"
