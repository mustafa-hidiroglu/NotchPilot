#!/usr/bin/env bash
# Build NotchPilot and assemble a signed build/NotchPilot.app bundle.
#
# Usage: scripts/build.sh [--debug] [--universal] [--run] [--help]
# Env:   CODESIGN_IDENTITY  signing identity (default "-" = ad-hoc)
#
# The app is not sandboxed and ScreenCaptureKit needs no entitlement (the permission is
# a runtime TCC grant, not a capability).
#
# No entitlements file is used. whisper.cpp is linked statically into the executable
# (scripts/build-whisper.sh builds it from pinned source on first use), so the bundle
# contains no third-party dylib and the hardened runtime's library validation stays on.
set -euo pipefail

CONFIG=release
RUN=0
UNIVERSAL=0

usage() {
    cat <<USAGE
Usage: scripts/build.sh [--debug] [--universal] [--run] [--help]

  --debug      build the debug configuration instead of release
  --universal  build for both Apple silicon and Intel (use this when the app
               is for someone else's Mac)
  --run        open the app after building
  --help       show this message

Environment:
  CODESIGN_IDENTITY  signing identity (default: "-", ad-hoc)
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --universal) UNIVERSAL=1 ;;
        --run) RUN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "error: unknown option '$arg'" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"
}

need xcrun "Install Xcode 16+ and select it with: sudo xcode-select -s /Applications/Xcode.app"
need swift "Install Xcode 16+ (Swift 6 toolchain) and select it with: sudo xcode-select -s /Applications/Xcode.app"
need codesign "Install the Xcode command line tools: xcode-select --install"
need plutil "plutil ships with macOS; this script must run on macOS"
need lipo "Install the Xcode command line tools: xcode-select --install"

swift_version_line=$(swift --version 2>&1 | head -n 1)
swift_major=$(printf '%s\n' "$swift_version_line" | sed -nE 's/.*Swift version ([0-9]+)\..*/\1/p')
[[ -n "$swift_major" ]] || die "could not parse Swift version from: $swift_version_line"
(( swift_major >= 6 )) || die "Swift 6+ required, found $swift_major. Install Xcode 16+ and select it with: sudo xcode-select -s /Applications/Xcode.app"

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/build/NotchPilot.app"
IDENTITY=${CODESIGN_IDENTITY:--}

"$ROOT/scripts/build-whisper.sh"

BUILD_ARGS=(-c "$CONFIG")
if (( UNIVERSAL )); then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ${BUILD_ARGS[*]} --product NotchPilot"
swift build "${BUILD_ARGS[@]}" --product NotchPilot
BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
[[ -f "$BIN_DIR/NotchPilot" ]] || die "built executable not found in $BIN_DIR"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/NotchPilot" "$APP/Contents/MacOS/NotchPilot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

if (( UNIVERSAL )); then
    for arch in arm64 x86_64; do
        lipo "$APP/Contents/MacOS/NotchPilot" -verify_arch "$arch" || die "executable lacks $arch"
    done
fi

echo "==> codesign (identity: $IDENTITY)"
# A real identity gets a secure timestamp (needed for notarization and for the signature
# to outlive the certificate); ad-hoc signatures can't be timestamped.
if [[ "$IDENTITY" == "-" ]]; then
    TIMESTAMP=--timestamp=none
else
    TIMESTAMP=--timestamp
fi
codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "App built: $APP ($(lipo -archs "$APP/Contents/MacOS/NotchPilot"))"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Note: ad-hoc signatures change on every rebuild, so macOS will ask for"
    echo "      Screen & System Audio Recording permission again after each rebuild."
fi

if (( RUN )); then
    open "$APP"
fi
