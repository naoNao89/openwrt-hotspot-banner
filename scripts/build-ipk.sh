#!/bin/sh
#
# Build an OpenWrt/Entware .ipk for openwrt-hotspot-banner without the SDK.
#
# Profiles:
#   openwrt   - procd init, /usr+/etc layout (default).
#   entware   - sysvinit S99 script, /opt-rooted layout (Padavan/Merlin/Entware).
#
# Common env (override per call):
#   PKG_NAME, PKG_VERSION, PKG_ARCH, TARGET, BINARY_NAME, INSTALL_PROFILE,
#   PACKAGE_FILES_DIR, OUT_DIR, SKIP_BUILD=1 to reuse target/<TARGET>/release.
#

set -eu
# pipefail catches silent failures inside `tar | gzip` on linux/GNU tar.
# Older POSIX sh on busybox doesn't have it, so guard.
( set -o pipefail ) 2>/dev/null && set -o pipefail || true

PKG_NAME="${PKG_NAME:-openwrt-hotspot-banner}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG_VERSION="${PKG_VERSION:-$("$HERE/pkg-version.sh")}"
PKG_ARCH="${PKG_ARCH:-arm_cortex-a7_neon-vfpv4}"
TARGET="${TARGET:-armv7-unknown-linux-musleabihf}"
BINARY_NAME="${BINARY_NAME:-openwrt-hotspot-banner}"
LOCAL_BINARY="${LOCAL_BINARY:-target/${TARGET}/release/${BINARY_NAME}}"
INSTALL_PROFILE="${INSTALL_PROFILE:-openwrt}"

case "$INSTALL_PROFILE" in
    openwrt)
        DEFAULT_FILES_DIR="openwrt-package/openwrt-hotspot-banner/files"
        ;;
    entware)
        DEFAULT_FILES_DIR="openwrt-package/openwrt-hotspot-banner/files-entware"
        ;;
    *)
        echo "Unknown INSTALL_PROFILE: $INSTALL_PROFILE"
        exit 2
        ;;
esac

PACKAGE_FILES_DIR="${PACKAGE_FILES_DIR:-$DEFAULT_FILES_DIR}"
OUT_DIR="${OUT_DIR:-target/ipk}"
WORK="${OUT_DIR}/work-${PKG_NAME}-${INSTALL_PROFILE}-${PKG_ARCH}"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    cargo build --target "$TARGET" --release
fi

if [ ! -f "$LOCAL_BINARY" ]; then
    echo "Build artifact missing: $LOCAL_BINARY"
    exit 2
fi

if [ ! -d "$PACKAGE_FILES_DIR" ]; then
    echo "Package files dir missing: $PACKAGE_FILES_DIR"
    exit 2
fi

rm -rf "$WORK"
mkdir -p "$WORK/data" "$WORK/control" "$OUT_DIR"

# Stage data tree
cp -a "$PACKAGE_FILES_DIR"/. "$WORK/data/"

if [ "$INSTALL_PROFILE" = "openwrt" ]; then
    mkdir -p "$WORK/data/usr/bin"
    cp "$LOCAL_BINARY" "$WORK/data/usr/bin/hotspot-fas"
    chmod 0755 "$WORK/data/usr/bin/hotspot-fas"
    chmod 0755 "$WORK/data/etc/init.d/hotspot-fas"
    chmod 0755 "$WORK/data/etc/hotplug.d/iface/99-hotspot-guest"
    find "$WORK/data/usr/lib/hotspot-banner" -name '*.sh' -exec chmod 0755 {} +
    chmod 0644 "$WORK/data/etc/config/hotspot-fas"
    find "$WORK/data/usr/share/hotspot-banner" -type f -exec chmod 0644 {} +
else
    mkdir -p "$WORK/data/opt/bin"
    cp "$LOCAL_BINARY" "$WORK/data/opt/bin/hotspot-fas"
    chmod 0755 "$WORK/data/opt/bin/hotspot-fas"
    chmod 0755 "$WORK/data/opt/etc/init.d/S99hotspot-fas"
    chmod 0644 "$WORK/data/opt/etc/hotspot-fas.conf"
    find "$WORK/data/opt/share/hotspot-banner" -type f -exec chmod 0644 {} +
fi

INSTALLED_SIZE="$(du -sk "$WORK/data" | awk '{print $1 * 1024}')"

# Control metadata
cat >"$WORK/control/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Depends: libc
Source: openwrt-hotspot-banner
SourceName: openwrt-hotspot-banner
License: MIT
Section: net
SourceDateEpoch: $(date +%s)
Maintainer: openwrt-hotspot-banner <noreply@local>
Architecture: ${PKG_ARCH}
Installed-Size: ${INSTALLED_SIZE}
Description: Rust captive portal (FAS) for OpenWrt/Entware with runtime theme support.
 Profile: ${INSTALL_PROFILE}.
 Custom themes resolve from a writable theme dir, falling back to a packaged
 default theme, then to embedded defaults.
EOF

# conffiles + postinst/prerm depend on profile
if [ "$INSTALL_PROFILE" = "openwrt" ]; then
    cat >"$WORK/control/conffiles" <<'EOF'
/etc/config/hotspot-fas
EOF

    cat >"$WORK/control/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_INSTROOT}" ] && exit 0
mkdir -p /etc/hotspot-banner/theme
/etc/init.d/hotspot-fas enable >/dev/null 2>&1 || true
/etc/init.d/hotspot-fas restart >/dev/null 2>&1 || true
exit 0
EOF

    cat >"$WORK/control/prerm" <<'EOF'
#!/bin/sh
[ "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/hotspot-fas stop >/dev/null 2>&1 || true
/etc/init.d/hotspot-fas disable >/dev/null 2>&1 || true
exit 0
EOF
else
    cat >"$WORK/control/conffiles" <<'EOF'
/opt/etc/hotspot-fas.conf
EOF

    cat >"$WORK/control/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_INSTROOT}" ] && exit 0
mkdir -p /opt/etc/hotspot-banner/theme
/opt/etc/init.d/S99hotspot-fas restart >/dev/null 2>&1 || /opt/etc/init.d/S99hotspot-fas start >/dev/null 2>&1 || true
exit 0
EOF

    cat >"$WORK/control/prerm" <<'EOF'
#!/bin/sh
[ "${IPKG_INSTROOT}" ] && exit 0
/opt/etc/init.d/S99hotspot-fas stop >/dev/null 2>&1 || true
exit 0
EOF
fi

chmod 0755 "$WORK/control/postinst" "$WORK/control/prerm"

ABS_WORK="$(cd "$WORK" && pwd)"

# Build control.tar.gz and data.tar.gz with deterministic-ish ownership
# Use --owner/--group (GNU tar) instead of --uid/--gid (libarchive-only).
( cd "$ABS_WORK/control" && tar --owner=0 --group=0 --numeric-owner --format=ustar -cf - . | gzip -n -9 >"$ABS_WORK/control.tar.gz" )
( cd "$ABS_WORK/data"    && tar --owner=0 --group=0 --numeric-owner --format=ustar -cf - . | gzip -n -9 >"$ABS_WORK/data.tar.gz" )

printf '2.0\n' >"$WORK/debian-binary"

IPK="${OUT_DIR}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.ipk"
rm -f "$IPK"
ABS_IPK="$(cd "$(dirname "$IPK")" && pwd)/$(basename "$IPK")"

# OpenWrt/Entware ipk: outer gzipped tar of debian-binary, data.tar.gz, control.tar.gz.
( cd "$ABS_WORK" && tar --owner=0 --group=0 --numeric-owner --format=ustar -cf - ./debian-binary ./data.tar.gz ./control.tar.gz | gzip -n -9 >"$ABS_IPK" )

echo "Built: $IPK (profile=$INSTALL_PROFILE arch=$PKG_ARCH)"
ls -la "$IPK"
