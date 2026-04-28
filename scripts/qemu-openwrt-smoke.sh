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

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1"
        exit 127
    }
}

require_command curl
require_command expect
require_command gzip
require_command qemu-system-x86_64
require_command scp
require_command sha256sum
require_command ssh
require_command ssh-keygen

mkdir -p "$WORK_DIR"

IMAGE_GZ_PATH="$WORK_DIR/$OPENWRT_IMAGE_GZ"
IMAGE_PATH="$WORK_DIR/${OPENWRT_IMAGE_PREFIX}.img"
SSH_KEY="$WORK_DIR/id_ed25519"
EXPECT_SCRIPT="$WORK_DIR/qemu-smoke.expect"

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

cat > "$EXPECT_SCRIPT" <<'EXPECT'
set timeout 180
set ssh_port [lindex $argv 0]
set ssh_key [lindex $argv 1]
set ssh_public_key [lindex $argv 2]
set image_path [lindex $argv 3]

spawn qemu-system-x86_64 -m 256 -nographic -no-reboot -drive file=$image_path,format=raw,if=virtio -netdev user,id=lan -device virtio-net-pci,netdev=lan -netdev user,id=wan,hostfwd=tcp:127.0.0.1:$ssh_port-:22 -device virtio-net-pci,netdev=wan

expect {
    "Please press Enter to activate this console." { send "\r" }
    "root@OpenWrt" {}
    timeout { exit 1 }
}

expect {
    "root@OpenWrt" {}
    timeout { exit 1 }
}

proc console_run {cmd} {
    send -- "$cmd\r"
    expect {
        "root@OpenWrt" {}
        timeout { exit 1 }
    }
}

console_run "cat /etc/openwrt_release"
console_run "mkdir -p /etc/dropbear"
console_run "echo '$ssh_public_key' > /etc/dropbear/authorized_keys"
console_run "chmod 600 /etc/dropbear/authorized_keys"
console_run "/etc/init.d/firewall stop || true"
console_run "/etc/init.d/dropbear restart || /etc/init.d/dropbear start"

set ssh_base "ssh -p $ssh_port -i $ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@127.0.0.1"
set scp_base "scp -P $ssh_port -i $ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

set connected 0
for {set i 0} {$i < 30} {incr i} {
    if {[catch {exec sh -c "$ssh_base true"} result] == 0} {
        set connected 1
        break
    }
    after 2000
}
if {$connected != 1} {
    exit 1
}

exec sh -c "$ssh_base 'rm -rf /tmp/hotspot-ci && mkdir -p /tmp/hotspot-ci'"
exec sh -c "$scp_base -r deploy.sh openwrt-config scripts root@127.0.0.1:/tmp/hotspot-ci/"
exec sh -c "$ssh_base 'cd /tmp/hotspot-ci && ash -n deploy.sh && ash -n openwrt-config/harden-router-services.sh && ash -n openwrt-config/hotspot-firewall.sh && ash -n openwrt-config/iptables-captive.sh && ash -n openwrt-config/setup-router.sh && ash -n openwrt-config/uci-guest-setup.sh && ash -n scripts/check-shell.sh && ash -n scripts/test-router.sh && ash -n scripts/live-queue-e2e.sh && RUN_LIVE_QUEUE_E2E=0 ash scripts/live-queue-e2e.sh'"
exec sh -c "$ssh_base 'cat /etc/openwrt_release; command -v uci; command -v ip; command -v logger; command -v wget'"

send "\001x"
expect eof
EXPECT

expect "$EXPECT_SCRIPT" "$SSH_PORT" "$SSH_KEY" "$SSH_PUBLIC_KEY" "$IMAGE_PATH"
