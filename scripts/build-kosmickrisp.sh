#!/bin/bash
# Builds an x86_64 KosmicKrisp Vulkan driver + Vulkan loader for Cask (Wine runs under Rosetta).
# Runs on an Intel macOS runner with Xcode 26 (Metal 4 SDK).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.kk}"
OUT="$WORK/out"
mkdir -p "$WORK" "$ROOT/dist"
rm -rf "$OUT" && mkdir -p "$OUT"

echo "== Toolchain"
uname -m
XCODE="$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$XCODE" ] || { echo "error: Xcode 26 (Metal 4 SDK) not found"; ls /Applications | grep -i xcode; exit 1; }
sudo xcode-select -s "$XCODE"
xcrun --show-sdk-version
export MACOSX_DEPLOYMENT_TARGET=26.0
# Metal 4 headers live only in Xcode 26's SDK; make every compiler use it (not the CLT macOS 15 SDK).
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
echo "SDKROOT=$SDKROOT"
ls "$SDKROOT/System/Library/Frameworks/Metal.framework/Headers/MTL4ArgumentTable.h"
export CC=/usr/bin/clang CXX=/usr/bin/clang++ OBJC=/usr/bin/clang OBJCXX=/usr/bin/clang++

brew install --quiet meson ninja cmake pkg-config llvm libclc spirv-llvm-translator spirv-tools spirv-headers glslang bison flex >/dev/null
export PATH="$(brew --prefix llvm)/bin:$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
llvm-config --version
python3 -m venv "$WORK/venv"
source "$WORK/venv/bin/activate"
pip install --quiet mako packaging pyyaml "meson>=1.9.1"

echo "== Vulkan loader"
cd "$WORK"
[ -d Vulkan-Loader ] || git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Loader.git
LOADER_REV=$(git -C Vulkan-Loader rev-parse --short HEAD)
cmake -S Vulkan-Loader -B loader-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DUPDATE_DEPS=ON -DBUILD_TESTS=OFF -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DAPPLE_USE_SYSTEM_ICD_LOCATIONS=OFF >/dev/null
cmake --build loader-build
LOADER=$(find loader-build -name 'libvulkan.1.*.dylib' -type f | head -1)
[ -n "$LOADER" ] || LOADER=$(find loader-build -name 'libvulkan*.dylib' -type f | head -1)
cp "$LOADER" "$OUT/libvulkan.1.dylib"
install_name_tool -id @rpath/libvulkan.1.dylib "$OUT/libvulkan.1.dylib"

echo "== Mesa (KosmicKrisp)"
[ -d mesa ] || git clone --depth 1 https://gitlab.freedesktop.org/mesa/mesa.git
MESA_REV=$(git -C mesa rev-parse --short HEAD)
MESA_VER=$(cat mesa/VERSION)
rm -rf mesa-build
meson setup mesa mesa-build --buildtype=release \
  -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false \
  -Dzstd=disabled --prefer-static -Dbuild-tests=false
ninja -C mesa-build

DRIVER=$(find mesa-build -name 'libvulkan_kosmickrisp.dylib' | head -1)
[ -n "$DRIVER" ] || { echo "error: libvulkan_kosmickrisp.dylib not produced"; find mesa-build -name '*.dylib'; exit 1; }
cp "$DRIVER" "$OUT/libvulkan_kosmickrisp.dylib"
install_name_tool -id @rpath/libvulkan_kosmickrisp.dylib "$OUT/libvulkan_kosmickrisp.dylib"

echo "== Bundle non-system dependencies"
# Copy any Homebrew dylibs the driver/loader link against and point them at @loader_path.
for pass in 1 2 3; do
  for lib in "$OUT"/*.dylib; do
    otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -E '^/(usr/local|opt/homebrew)' | while read -r dep; do
      base=$(basename "$dep")
      [ -f "$OUT/$base" ] || { cp "$dep" "$OUT/$base"; chmod u+w "$OUT/$base"; install_name_tool -id "@loader_path/$base" "$OUT/$base"; }
      install_name_tool -change "$dep" "@loader_path/$base" "$lib"
    done
  done
done
for lib in "$OUT"/*.dylib; do
  echo "-- $(basename "$lib"): $(lipo -archs "$lib")"
  otool -L "$lib" | tail -n +2
  codesign --force --sign - "$lib"
done
lipo -archs "$OUT/libvulkan_kosmickrisp.dylib" | grep -q x86_64

cp mesa/docs/license.rst "$OUT/LICENSE-mesa.rst" 2>/dev/null || true
cp Vulkan-Loader/LICENSE.txt "$OUT/LICENSE-vulkan-loader.txt" 2>/dev/null || true
cat > "$OUT/SOURCE.txt" <<EOF
KosmicKrisp from Mesa $MESA_VER ($MESA_REV): https://gitlab.freedesktop.org/mesa/mesa (MIT)
Vulkan-Loader ($LOADER_REV): https://github.com/KhronosGroup/Vulkan-Loader (Apache-2.0)
Built for x86_64 by p1e2r/cask CI so Wine under Rosetta can load it.
EOF
tar -czf "$ROOT/dist/kosmickrisp-x86_64.tar.gz" -C "$OUT" .
echo "mesa-$MESA_VER-$MESA_REV" > "$ROOT/dist/kosmickrisp-version.txt"
ls -la "$OUT"
echo "Built KosmicKrisp x86_64 (mesa $MESA_VER $MESA_REV)"
