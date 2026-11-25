#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Vendor/opus/upstream"
BUILD="$ROOT/Vendor/opus/build-ios-arm64"
OUTPUT="$ROOT/Vendor/opus/lib/libopus-ios-arm64.a"

if [[ -n "${THEOS:-}" && -d "$THEOS/sdks/iPhoneOS15.6.sdk" ]]; then
  SDK="$THEOS/sdks/iPhoneOS15.6.sdk"
elif command -v xcrun >/dev/null 2>&1; then
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
else
  echo "An iPhoneOS SDK is required (set THEOS or build on macOS with Xcode)." >&2
  exit 2
fi

for tool in cmake ninja clang; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing build tool: $tool" >&2; exit 2; }
done

if [[ -n "${THEOS:-}" && -x "$THEOS/toolchain/linux/iphone/bin/clang-13" ]]; then
  IOS_CLANG="$THEOS/toolchain/linux/iphone/bin/clang-13"
else
  IOS_CLANG="$(command -v clang)"
fi

rm -rf "$BUILD"

cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_C_COMPILER="$IOS_CLANG" \
  -DCMAKE_C_COMPILER_TARGET=arm64-apple-ios15.0 \
  -DCMAKE_C_FLAGS="-O2 -isysroot $SDK -miphoneos-version-min=15.0" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPUS_BUILD_TESTING=OFF \
  -DOPUS_BUILD_PROGRAMS=OFF \
  -DOPUS_BUILD_SHARED_LIBRARY=OFF \
  -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
  -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF
cmake --build "$BUILD" --target opus --parallel "${JOBS:-2}"
mkdir -p "$(dirname "$OUTPUT")"
install -m 0644 "$BUILD/libopus.a" "$OUTPUT"
printf 'Built %s\n' "$OUTPUT"
