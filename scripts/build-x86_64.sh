#!/bin/bash
# Cross-build the layer for x86_64 on an ARM64 host (Steam snap + FEX setups).
#
# Installs into $PREFIX (default: ~/pyroveil-x86_64) as
#   $PREFIX/lib/libVkLayer_pyroveil_64.so
#   $PREFIX/share/vulkan/implicit_layer.d/VkLayer_pyroveil_64.json
# so install-steam-snap-layer.sh can pick it up.
set -e
cd "$(dirname "$0")/.."

PREFIX="${1:-$HOME/pyroveil-x86_64}"
BUILD=build-x86_64

if ! command -v x86_64-linux-gnu-g++ >/dev/null; then
	echo "Missing x86_64 cross compiler. On Ubuntu/Debian:" >&2
	echo "  sudo apt-get install g++-x86-64-linux-gnu gcc-x86-64-linux-gnu \\" >&2
	echo "       libc6-dev-amd64-cross libstdc++-13-dev-amd64-cross" >&2
	exit 1
fi

cmake . -B"$BUILD" -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/x86_64-linux-gnu.cmake \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$PREFIX"
ninja -C"$BUILD" install

echo
echo "Installed:"
file "$PREFIX/lib/libVkLayer_pyroveil_64.so"
echo "  manifest: $PREFIX/share/vulkan/implicit_layer.d/VkLayer_pyroveil_64.json"
