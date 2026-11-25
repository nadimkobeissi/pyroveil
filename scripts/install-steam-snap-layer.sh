#!/bin/bash
# Install the layer for the aarch64 Steam snap (FEX guest), where the games run
# as x86_64 inside pressure-vessel.
#
# Two placement rules matter, and neither is what the native instructions assume:
#
#  1. The manifest must land in the FEX rootfs system layer directory
#     ($SNAP_USER_COMMON/x86_rootfs/usr/share/vulkan/implicit_layer.d), which is
#     where the guest loader finds MangoHud, RenderDoc and the MESA layers.
#     ~/.local/share/vulkan does NOT work: desktop-launch sets
#     HOME=$SNAP_USER_COMMON, and pressure-vessel then mounts its own
#     $XDG_DATA_HOME/vulkan over it.
#  2. Do not rely on VK_ADD_LAYER_PATH. pressure-vessel strips it and substitutes
#     its own VK_LAYER_PATH / VK_IMPLICIT_LAYER_PATH.
#
# Files are kept under $SNAP_USER_COMMON (not inside x86_rootfs) except the
# manifest, so a rootfs refresh only costs the manifest - rerun this script.
set -e
cd "$(dirname "$0")/.."

SUC="${SUC:-$HOME/snap/steam/common}"
SRC_LIB="${SRC_LIB:-$HOME/pyroveil-x86_64/lib/libVkLayer_pyroveil_64.so}"
SRC_JSON="${SRC_JSON:-$HOME/pyroveil-x86_64/share/vulkan/implicit_layer.d/VkLayer_pyroveil_64.json}"
HACK="${HACK:-hacks/re-village-nvidia/pyroveil.json}"
NAME="$(basename "$(dirname "$HACK")")"
DEST="$SUC/pyroveil"

[ -f "$SRC_LIB" ] || { echo "no layer built at $SRC_LIB - run scripts/build-x86_64.sh first" >&2; exit 1; }
[ -f "$SRC_JSON" ] || { echo "no manifest at $SRC_JSON" >&2; exit 1; }
if ! file "$SRC_LIB" | grep -q "x86-64"; then
	echo "refusing to install: $SRC_LIB is not x86-64, but the FEX guest needs x86-64" >&2
	file "$SRC_LIB" >&2; exit 1
fi
[ -d "$SUC" ] || { echo "Steam snap data dir $SUC not found" >&2; exit 1; }

# cp/install refuse to copy a file onto itself; the build prefix may already be
# the install destination, so compare resolved paths first.
copy_as() {
	local src="$1" dst="$2"
	[ "$(realpath "$src")" = "$(realpath -m "$dst")" ] || install -m 0644 "$src" "$dst"
	chmod 0644 "$dst"
}

mkdir -p "$DEST/lib" "$DEST/$NAME/cache"
copy_as "$SRC_LIB"  "$DEST/lib/libVkLayer_pyroveil_64.so"
copy_as "$SRC_JSON" "$DEST/pyroveil.json.manifest"

# Point the manifest at the installed library.
python3 - "$DEST/pyroveil.json.manifest" "$DEST/lib/libVkLayer_pyroveil_64.so" <<PY
import json, sys
path, lib = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["layer"]["library_path"] = lib
json.dump(d, open(path, "w"), indent=4)
PY

copy_as "$HACK" "$DEST/$NAME/pyroveil.json"
# cache/ must exist and be writable: the layer writes patched SPIR-V there and
# silently skips it if the directory is missing.
chmod -R u+rwX "$DEST/$NAME"

GUEST_DIR="$SUC/x86_rootfs/usr/share/vulkan/implicit_layer.d"
mkdir -p "$GUEST_DIR"
copy_as "$DEST/pyroveil.json.manifest" "$GUEST_DIR/VkLayer_pyroveil_64.json"

echo "installed:"
echo "  library   $DEST/lib/libVkLayer_pyroveil_64.so"
echo "  manifest  $GUEST_DIR/VkLayer_pyroveil_64.json"
echo "  hack      $DEST/$NAME/pyroveil.json (+ writable cache/)"
echo
echo "Steam launch options for this game:"
echo "  PYROVEIL=1 PYROVEIL_CONFIG=$DEST/$NAME/pyroveil.json \\"
echo "  PROTON_LOG=1 PROTON_LOG_DIR=$SUC/ %command%"
echo
echo "Note: PROTON_LOG_DIR must be inside \$SNAP_USER_COMMON, otherwise pressure-vessel"
echo "drops the log outside the bind it makes of \$HOME and no log is ever written."
