#!/bin/sh
#
# Build all .ipk variants declared in packaging/targets.json.
#
# Iterates the JSON, sets per-target env (rust target, opkg arch, profile),
# cargo-builds the binary, then runs scripts/build-ipk.sh.
#
# Skip targets with SKIP_TARGETS="id1,id2".
# Run a single target with ONLY_TARGETS="id1[,id2,...]".
#

set -eu

TARGETS_FILE="${TARGETS_FILE:-packaging/targets.json}"
SKIP_TARGETS="${SKIP_TARGETS:-}"
ONLY_TARGETS="${ONLY_TARGETS:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

if [ ! -f "$TARGETS_FILE" ]; then
    echo "Targets file missing: $TARGETS_FILE"
    exit 2
fi

contains() {
    csv="$1"
    needle="$2"
    case ",$csv," in
        *",$needle,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Stream targets as TSV lines: id<TAB>rust_target<TAB>opkg_arch<TAB>linker_env<TAB>linker<TAB>profile
TSV="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for t in data:
    print("\t".join([t["id"], t["rust_target"], t["opkg_arch"], t["linker_env"], t["linker"], t["profile"]]))
' "$TARGETS_FILE")"

OK=""
FAIL=""

echo "$TSV" | while IFS="$(printf '\t')" read -r id rust_target opkg_arch linker_env linker profile; do
    [ -n "$id" ] || continue
    if [ -n "$ONLY_TARGETS" ] && ! contains "$ONLY_TARGETS" "$id"; then
        continue
    fi
    if contains "$SKIP_TARGETS" "$id"; then
        echo "SKIP $id"
        continue
    fi

    echo "==> $id  rust_target=$rust_target opkg_arch=$opkg_arch profile=$profile"

    if [ "$SKIP_BUILD" != "1" ]; then
        # Set linker env if a cross compiler is available; otherwise let cargo decide.
        if command -v "$linker" >/dev/null 2>&1; then
            eval "export ${linker_env}=${linker}"
        fi
        rustup target add "$rust_target" >/dev/null 2>&1 || true
        if ! cargo build --target "$rust_target" --release; then
            echo "BUILD FAILED for $id"
            exit 1
        fi
    fi

    SKIP_BUILD=1 \
    TARGET="$rust_target" \
    PKG_ARCH="$opkg_arch" \
    INSTALL_PROFILE="$profile" \
        ./scripts/build-ipk.sh
done

echo "All requested targets built."
