#!/usr/bin/env bash
# Build whisper.cpp from pinned upstream source into a static, Apple silicon (arm64)
# Vendor/whisper.xcframework that Package.swift links as the `whisper` module.
#
# Usage: scripts/build-whisper.sh [--force] [--help]
#
# Why static: linking whisper into the NotchPilot executable means the app loads no
# third-party dylib, so the hardened runtime's library validation stays on even for
# ad-hoc signed builds, and nobody can swap in a different whisper inside the bundle.
#
# Supply chain: the source is fetched at tag v1.9.5 and accepted only if the checked-out
# commit is exactly WHISPER_COMMIT. Idempotent: a stamp file records the commit (and this
# script's configuration version) of the existing build; matching stamps skip the work.
set -euo pipefail

WHISPER_TAG=v1.9.5
WHISPER_COMMIT=d1be6fde11ac6e0407606b4e42fe72d34add8037
# Bump when the cmake flags or packaging below change, to force a rebuild.
CONFIG_VERSION=2
MACOS_MIN=14.0

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --help|-h)
            cat <<USAGE
Usage: scripts/build-whisper.sh [--force] [--help]

  --force  rebuild even if Vendor/whisper.xcframework matches the pinned commit
USAGE
            exit 0 ;;
        *) echo "error: unknown option '$arg'" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"; }

need git "Install the Xcode command line tools: xcode-select --install"
need cmake "Install CMake 3.28+: brew install cmake"
need libtool "Install the Xcode command line tools: xcode-select --install"
need plutil "plutil ships with macOS; this script must run on macOS"
need lipo "Install the Xcode command line tools: xcode-select --install"

cd "$(dirname "$0")/.."
ROOT=$(pwd)
SRC="$ROOT/.build/whisper-src"
WORK="$ROOT/.build/whisper-build"
OUT="$ROOT/Vendor/whisper.xcframework"
STAMP="$ROOT/Vendor/whisper.stamp"
STAMP_VALUE="$WHISPER_COMMIT config=$CONFIG_VERSION"

if (( ! FORCE )) && [[ -d "$OUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_VALUE" ]]; then
    echo "==> whisper.cpp $WHISPER_TAG ($WHISPER_COMMIT) already built: $OUT"
    exit 0
fi

echo "==> fetching whisper.cpp $WHISPER_TAG"
rm -rf "$SRC"
mkdir -p "$(dirname "$SRC")"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$WHISPER_TAG" \
    https://github.com/ggml-org/whisper.cpp.git "$SRC"
actual=$(git -C "$SRC" rev-parse HEAD)
[[ "$actual" == "$WHISPER_COMMIT" ]] || die "whisper.cpp $WHISPER_TAG is commit $actual, expected $WHISPER_COMMIT; refusing to build"
echo "    verified commit $actual"

echo "==> building whisper.cpp (static, arm64, macOS $MACOS_MIN)"
rm -rf "$WORK"
# Flags follow upstream's build-xcframework.sh for macOS, minus Core ML (NotchPilot uses
# plain ggml models) and parakeet. Metal is embedded (no .metallib to ship); Accelerate
# provides BLAS. NotchPilot targets Apple silicon only: Metal runs the model on every
# M-series GPU, and the CPU kernels are compiled for the M1 baseline (-mcpu=apple-m1:
# ARMv8.5 with NEON, fp16 and dot-product), which every later Apple chip runs natively.
# A per-chip CPU build (e.g. i8mm on M2+) would need ggml's dynamically loaded backends,
# which a statically linked app can't use; the CPU only handles the light work anyway.
cmake -S "$SRC" -B "$WORK" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_C_FLAGS="-mcpu=apple-m1 -Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument" \
    -DCMAKE_CXX_FLAGS="-mcpu=apple-m1 -Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_COREML=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_METAL_USE_BF16=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_DEFAULT=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    >/dev/null
cmake --build "$WORK" --config Release --target whisper --parallel "$(sysctl -n hw.ncpu)" >/dev/null

LIBS=(
    "$WORK/src/libwhisper.a"
    "$WORK/ggml/src/libggml.a"
    "$WORK/ggml/src/libggml-base.a"
    "$WORK/ggml/src/libggml-cpu.a"
    "$WORK/ggml/src/ggml-metal/libggml-metal.a"
    "$WORK/ggml/src/ggml-blas/libggml-blas.a"
)
for lib in "${LIBS[@]}"; do [[ -f "$lib" ]] || die "expected build output missing: $lib"; done

echo "==> packaging $OUT"
STAGE="$WORK/package"
mkdir -p "$STAGE/include"
libtool -static -no_warning_for_no_symbols -o "$STAGE/libwhisper.a" "${LIBS[@]}"
lipo "$STAGE/libwhisper.a" -verify_arch arm64 || die "libwhisper.a lacks arm64"
cp "$SRC/include/whisper.h" \
   "$SRC/ggml/include/ggml.h" "$SRC/ggml/include/ggml-alloc.h" "$SRC/ggml/include/ggml-backend.h" \
   "$SRC/ggml/include/ggml-metal.h" "$SRC/ggml/include/ggml-cpu.h" "$SRC/ggml/include/ggml-blas.h" \
   "$SRC/ggml/include/gguf.h" \
   "$STAGE/include/"
# Same link lines as upstream's framework module map, so SwiftPM links the system
# frameworks the static library needs.
cat > "$STAGE/include/module.modulemap" <<'MODULEMAP'
module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
MODULEMAP

# The XCFramework is written directly (same layout and Info.plist that
# `xcodebuild -create-xcframework -library … -headers …` produces), so the build needs
# only the command line tools, not a working Xcode plug-in setup.
rm -rf "$OUT"
SLICE=macos-arm64
mkdir -p "$OUT/$SLICE/Headers"
cp "$STAGE/libwhisper.a" "$OUT/$SLICE/libwhisper.a"
cp "$STAGE/include/"* "$OUT/$SLICE/Headers/"
cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>BinaryPath</key>
            <string>libwhisper.a</string>
            <key>HeadersPath</key>
            <string>Headers</string>
            <key>LibraryIdentifier</key>
            <string>$SLICE</string>
            <key>LibraryPath</key>
            <string>libwhisper.a</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
PLIST
plutil -lint "$OUT/Info.plist" >/dev/null
printf '%s\n' "$STAMP_VALUE" > "$STAMP"
echo "==> whisper.cpp ready: $OUT"
