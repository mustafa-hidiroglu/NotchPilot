#!/usr/bin/env bash
# Build NotchPilot and assemble a signed build/NotchPilot.app bundle.
#
# Usage: scripts/build.sh [--debug] [--install] [--dmg] [--run] [--help]
# Env:   CODESIGN_IDENTITY  signing identity (default "-" = ad-hoc)
#
# The app is not sandboxed and ScreenCaptureKit needs no entitlement (the permission is
# a runtime TCC grant, not a capability).
#
# No entitlements file is used. whisper.cpp is linked statically into the executable
# (scripts/build-whisper.sh builds it from pinned source on first use), so the bundle
# contains no third-party dylib and the hardened runtime's library validation stays on.
#
# Apple silicon only: the executable is arm64 (every M-series Mac); Intel Macs can't open it.
set -euo pipefail

CONFIG=release
RUN=0
INSTALL=0
DMG=0

usage() {
    cat <<USAGE
Usage: scripts/build.sh [--debug] [--install] [--dmg] [--run] [--help]

  --debug   build the debug configuration instead of release
  --install copy the app to /Applications (quits a running copy first)
  --dmg     also package build/NotchPilot.dmg to send to another Mac
  --run     open the app after building (the installed copy with --install)
  --help    show this message

Builds an Apple silicon (arm64) app that runs on any M-series Mac with macOS 14+.

Environment:
  CODESIGN_IDENTITY  signing identity (default: "-", ad-hoc)
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --run) RUN=1 ;;
        --install) INSTALL=1 ;;
        --dmg) DMG=1 ;;
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

# Explicit, so a Terminal running under Rosetta still produces an arm64 app.
BUILD_ARGS=(-c "$CONFIG" --arch arm64)

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

lipo "$APP/Contents/MacOS/NotchPilot" -verify_arch arm64 || die "executable is not arm64"

# Self-contained: everything the app loads is either compiled in (whisper.cpp and its Metal
# shaders) or part of macOS. SwiftPM still records the build machine's Xcode toolchain as a
# runtime search path; nothing is loaded from it (all Swift libraries resolve to
# /usr/lib/swift), but it names a path that only exists on the developer's Mac, so drop it.
EXE="$APP/Contents/MacOS/NotchPilot"
while read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$EXE"
done < <(otool -l "$EXE" | awk '/LC_RPATH/ { getline; getline; print $2 }' | grep -v -E '^(/usr/lib/swift|@loader_path|@executable_path)' || true)
if otool -L "$EXE" | tail -n +2 | grep -v -E '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
    die "the executable links a library outside macOS; the app would not be self-contained"
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

if (( DMG )); then
    need hdiutil "hdiutil ships with macOS; this script must run on macOS"
    DMG_PATH="$ROOT/build/NotchPilot.dmg"
    STAGE="$ROOT/build/dmg"
    echo "==> packaging $DMG_PATH"
    rm -rf "$STAGE" "$DMG_PATH"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/NotchPilot.app"
    ln -s /Applications "$STAGE/Applications"
    # Ad-hoc signed and not notarized, so Gatekeeper blocks the first open of a downloaded copy.
    cat > "$STAGE/Read Me First.txt" <<'README'
NotchPilot: how to install

1. Drag NotchPilot onto the Applications folder.
2. Open NotchPilot from Applications. macOS says it can't check it for malicious
   software, because the app isn't notarized by Apple. Click Done (not Move to Trash).
3. Open System Settings > Privacy & Security, scroll down to Security and click
   Open Anyway next to the NotchPilot message. Confirm with your password, then Open.
4. From then on it opens normally. The setup guide walks you through the rest:
   allowing Screen & System Audio Recording, downloading the speech model and
   adding your API key.

Needs a Mac with Apple silicon (M1 or later) and macOS 14 or later.
README
    hdiutil create -quiet -volname NotchPilot -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG_PATH"
    rm -rf "$STAGE"
    hdiutil verify -quiet "$DMG_PATH"
    echo "DMG: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
fi

if (( INSTALL )); then
    TARGET=/Applications/NotchPilot.app
    echo "==> installing $TARGET"
    if pgrep -x NotchPilot >/dev/null; then
        osascript -e 'quit app "NotchPilot"' >/dev/null 2>&1 || true
        # Quitting stops capture first (up to ~2 s); opening during that window fails.
        for _ in $(seq 1 50); do pgrep -x NotchPilot >/dev/null || break; sleep 0.1; done
        pgrep -x NotchPilot >/dev/null && die "NotchPilot is still running; quit it and run again"
    fi
    rm -rf "$TARGET"
    ditto "$APP" "$TARGET"
    codesign --verify --strict --deep "$TARGET"
    echo "Installed: $TARGET"
    APP="$TARGET"
fi

if (( RUN )); then
    open "$APP"
fi
