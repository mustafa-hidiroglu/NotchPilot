#!/usr/bin/env bash
# Run Swift tests and the C++ ring-buffer tests under TSan and ASan/UBSan.
#
# Usage: scripts/test.sh [--cpp-only] [--help]
set -uo pipefail

CPP_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --cpp-only) CPP_ONLY=1 ;;
        --help|-h)
            cat <<USAGE
Usage: scripts/test.sh [--cpp-only] [--help]

  --cpp-only  skip 'swift test', run only the sanitizer C++ tests
USAGE
            exit 0 ;;
        *) echo "error: unknown option '$arg'" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

command -v swift >/dev/null 2>&1 || die "'swift' not found. Install Xcode 16+ and select it with: sudo xcode-select -s /Applications/Xcode.app"
command -v xcrun >/dev/null 2>&1 || die "'xcrun' not found. Install Xcode command line tools: xcode-select --install"
xcrun --find clang++ >/dev/null 2>&1 || die "'clang++' not found via xcrun. Install Xcode or run: xcode-select --install"

cd "$(dirname "$0")/.."
OUT=build/cpp-tests
mkdir -p "$OUT"

results=()
failed=0

record() { # name status
    results+=("$2  $1")
    [[ "$2" == PASS ]] || failed=1
}

if (( ! CPP_ONLY )); then
    # Package.swift links Vendor/whisper.xcframework; build it from pinned source if missing.
    scripts/build-whisper.sh || die "building whisper.cpp failed"
    echo "==> swift test"
    if swift test; then record "swift test" PASS; else record "swift test" FAIL; fi
fi

run_cpp() { # name sanitizer-flags
    local name=$1 san=$2 bin="$OUT/ring_buffer_tests_$1"
    echo "==> C++ ring buffer tests ($name: $san)"
    if xcrun clang++ -std=c++20 -Wall -Wextra -Wpedantic -Werror -O1 -g \
            -DNP_RING_DEBUG_OWNERSHIP=1 -ISources/NPRingBuffer "$san" \
            Tests/cpp/ring_buffer_tests.cpp -o "$bin" && "$bin"; then
        record "C++ $name" PASS
    else
        record "C++ $name" FAIL
    fi
}

run_cpp tsan -fsanitize=thread
run_cpp asan-ubsan -fsanitize=address,undefined

echo
echo "==== Summary ===="
printf '%s\n' "${results[@]}"
if (( failed )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
