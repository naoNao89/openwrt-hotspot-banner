#!/bin/sh
#
# Build an OpenWrt .ipk for openwrt-hotspot-banner without requiring the SDK.
# Format: ar archive containing debian-binary, control.tar.gz, data.tar.gz.
#

set -eu

PKG_NAME="${PKG_NAME:-openwrt-hotspot-banner}"
PKG_VERSION="${PKG_VERSION:-0.1.0-1}"
PKG_ARCH="${PKG_ARCH:-arm_cortex-a7_neon-vfpv4}"
TARGET="${TARGET:-armv7-unknown-linux-musleabihf}"
BINARY_NAME="${BINARY_NAME:-openwrt-hotspot-banner}"
LOCAL_BINARY="${LOCAL_BINARY:-target/${TARGET}/release/${BINARY_NAME}}"
PACKAGE_FILES_DIR="${PACKAGE_FILES_DIR:-openwrt-package/openwrt-hotspot-banner/files}"
OUT_DIR="${OUT_DIR:-target/ipk}"
WORK="${OUT_DIR}/work-${PKG_NAME}"

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
mkdir -p "$WORK/data/usr/bin"
cp "$LOCAL_BINARY" "$WORK/data/usr/bin/hotspot-fas"
chmod 0755 "$WORK/data/usr/bin/hotspot-fas"
chmod 0755 "$WORK/data/etc/init.d/hotspot-fas"
chmod 0755 "$WORK/data/etc/hotplug.d/iface/99-hotspot-guest"
find "$WORK/data/usr/lib/hotspot-banner" -name '*.sh' -exec chmod 0755 {} +
chmod 0644 "$WORK/data/etc/config/hotspot-fas"
find "$WORK/data/etc/hotspot-banner" "$WORK/data/usr/share/hotspot-banner" -type f -exec chmod 0644 {} +

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
Description: Rust captive portal (FAS) for OpenWrt with runtime theme support.
 Custom themes resolve from /etc/hotspot-banner/theme, falling back to
 /usr/share/hotspot-banner/default-theme, then to embedded defaults.
EOF

# conffiles list (preserve user-edited UCI + custom theme on upgrade)
cat >"$WORK/control/conffiles" <<'EOF'
/etc/config/hotspot-fas
EOF

# postinst: enable + (re)start service after install
cat >"$WORK/control/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/hotspot-fas enable >/dev/null 2>&1 || true
/etc/init.d/hotspot-fas restart >/dev/null 2>&1 || true
exit 0
EOF
chmod 0755 "$WORK/control/postinst"

# prerm: stop service before removal
cat >"$WORK/control/prerm" <<'EOF'
#!/bin/sh
[ "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/hotspot-fas stop >/dev/null 2>&1 || true
/etc/init.d/hotspot-fas disable >/dev/null 2>&1 || true
exit 0
EOF
chmod 0755 "$WORK/control/prerm"

ABS_WORK="$(cd "$WORK" && pwd)"

# Build control.tar.gz and data.tar.gz with deterministic-ish ownership
( cd "$ABS_WORK/control" && tar --no-xattrs --uid 0 --gid 0 --numeric-owner --format=ustar -cf - . | gzip -n -9 >"$ABS_WORK/control.tar.gz" )
( cd "$ABS_WORK/data"    && tar --no-xattrs --uid 0 --gid 0 --numeric-owner --format=ustar -cf - . | gzip -n -9 >"$ABS_WORK/data.tar.gz" )

printf '2.0\n' >"$WORK/debian-binary"

IPK="${OUT_DIR}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.ipk"
rm -f "$IPK"
ABS_IPK="$(cd "$(dirname "$IPK")" && pwd)/$(basename "$IPK")"

# OpenWrt ipk format: outer gzipped tar containing
# ./debian-binary, ./data.tar.gz, ./control.tar.gz (data first).
( cd "$ABS_WORK" && tar --no-xattrs --uid 0 --gid 0 --numeric-owner --format=ustar -cf - ./debian-binary ./data.tar.gz ./control.tar.gz | gzip -n -9 >"$ABS_IPK" )

echo "Built: $IPK"
ls -la "$IPK"
