#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
WORK="${LIBDAVE_BUILD_ROOT:-/tmp/coralcord-libdave-ios}"
SOURCE="$WORK/libdave"
SDK="$THEOS/sdks/iPhoneOS15.6.sdk"
CLANG="$THEOS/toolchain/linux/host/bin/clang"
CLANGXX="$THEOS/toolchain/linux/host/bin/clang++"
AR="$THEOS/toolchain/linux/host/bin/llvm-ar"
LIBDAVE_COMMIT="b5463c443df74db75a713c775b09a847621e6d62"

for required in "$SDK" "$CLANG" "$CLANGXX" "$AR"; do
    if [[ ! -e "$required" ]]; then
        echo "Missing required Theos iOS toolchain component: $required" >&2
        exit 1
    fi
done
mkdir -p "$WORK"
if [[ ! -d "$SOURCE/.git" ]]; then
    git clone https://github.com/discord/libdave.git "$SOURCE"
fi
git -C "$SOURCE" fetch --tags origin
git -C "$SOURCE" checkout --detach "$LIBDAVE_COMMIT"
git -C "$SOURCE" submodule update --init --recursive

VCPKG="$SOURCE/cpp/vcpkg/vcpkg"
VCPKG_ROOT="$SOURCE/cpp/vcpkg"
if [[ ! -x "$VCPKG" ]]; then
    "$SOURCE/cpp/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
fi

cat > "$WORK/ios-toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT "$SDK" CACHE PATH "iOS SDK")
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum iOS version")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "iOS architecture")
set(CMAKE_C_COMPILER "$CLANG" CACHE FILEPATH "Theos Clang")
set(CMAKE_CXX_COMPILER "$CLANGXX" CACHE FILEPATH "Theos Clang++")
set(CMAKE_C_COMPILER_TARGET "arm64-apple-ios15.0" CACHE STRING "iOS target triple")
set(CMAKE_CXX_COMPILER_TARGET "arm64-apple-ios15.0" CACHE STRING "iOS target triple")
set(CMAKE_INSTALL_NAME_TOOL "/bin/true" CACHE FILEPATH "Static cross-build")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOF

cat > "$WORK/arm64-ios-theos.cmake" <<EOF
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE "$WORK/ios-toolchain.cmake")
EOF

# OpenSSL's vcpkg port probes the Apple SDK with xcrun. This shim reports the
# real Theos iPhoneOS SDK path; no Apple-hosted compiler is substituted.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/xcrun" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        --show-sdk-path) printf '%s\\n' "$SDK"; exit 0 ;;
        --show-sdk-version) printf '15.6\\n'; exit 0 ;;
    esac
done
echo "xcrun shim: unsupported invocation: \$*" >&2
exit 2
EOF
chmod +x "$WORK/bin/xcrun"
export PATH="$WORK/bin:$PATH"
export VCPKG_ROOT
export VCPKG_DISABLE_METRICS=1

MANIFEST="$SOURCE/cpp/vcpkg-alts/openssl_3"
INSTALLED="$MANIFEST/vcpkg_installed"
mkdir -p "$INSTALLED"
(cd "$MANIFEST" && "$VCPKG" install --triplet arm64-ios-theos --overlay-triplets="$WORK")

CMAKE="$(find "$VCPKG_ROOT/downloads/tools" -path '*/bin/cmake' -type f -executable | sort -V | tail -n 1)"
if [[ -z "$CMAKE" ]]; then
    echo "vcpkg did not provide CMake" >&2
    exit 1
fi
BUILD="$SOURCE/cpp/build-ios-theos-arm64"
INSTALL="$WORK/install"
"$CMAKE" -S "$SOURCE/cpp" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$WORK/ios-toolchain.cmake" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_PREFIX_PATH="$INSTALLED/arm64-ios-theos" \
    -DCMAKE_FIND_ROOT_PATH="$INSTALLED/arm64-ios-theos" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DBUILD_SHARED_LIBS=OFF -DTESTING=OFF -DPERSISTENT_KEYS=OFF \
    -DREQUIRE_BORINGSSL=OFF
"$CMAKE" --build "$BUILD" --parallel "${JOBS:-2}"
"$CMAKE" --install "$BUILD"

DEST="$ROOT/Vendor/libdave"
mkdir -p "$DEST/include" "$DEST/lib/arm64" "$DEST/licenses"
rm -rf "$DEST/include/dave"
cp -a "$INSTALL/include/dave" "$DEST/include/"
cp "$SOURCE/LICENSE" "$DEST/LICENSE"
cp "$BUILD/libdave.a" "$DEST/lib/arm64/libdave.a"
for lib in mlspp hpke tls_syntax bytes crypto; do
    cp "$INSTALLED/arm64-ios-theos/lib/lib${lib}.a" "$DEST/lib/arm64/lib${lib}.a"
done
cp "$INSTALLED/arm64-ios-theos/share/openssl/copyright" "$DEST/licenses/OpenSSL.txt"
cp "$INSTALLED/arm64-ios-theos/share/mlspp/copyright" "$DEST/licenses/mlspp.txt"
cp "$INSTALLED/arm64-ios-theos/share/nlohmann-json/copyright" "$DEST/licenses/nlohmann-json.txt"

for archive in "$DEST"/lib/arm64/*.a; do
    # Repack GNU-format archives into a Mach-O linker-friendly archive. This
    # also writes the symbol table expected by Apple's ld64-compatible linker.
    REPACK="$(mktemp -d "$WORK/repack.XXXXXX")"
    (cd "$REPACK" && "$AR" x "$archive" && "$AR" rcsD "$(basename "$archive")" ./*.o)
    mv "$REPACK/$(basename "$archive")" "$archive"
    rm -rf "$REPACK"
    if ! "$AR" -t "$archive" | head -n 1 | grep -q .; then
        echo "Empty or invalid archive: $archive" >&2
        exit 1
    fi
done
TMP="$WORK/verify"
rm -rf "$TMP" && mkdir -p "$TMP"
(cd "$TMP" && "$AR" x "$DEST/lib/arm64/libdave.a" && file ./*.o | grep -q 'Mach-O 64-bit arm64')
echo "Built and vendored libdave $LIBDAVE_COMMIT for arm64-apple-ios15.0."
