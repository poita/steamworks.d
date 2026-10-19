#!/bin/sh
# Compiles tests/abi/probe.cpp natively, runs it, and compares every value it
# prints (sizes, alignments, offsets, enumerator and constant values) with
# the same quantities a D program measures at run time, built with dmd and
# ldc2. On Apple silicon it repeats the comparison for x86_64 under Rosetta
# when Rosetta is installed. Needs the SDK in ./sdk and clang++.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CXXFLAGS="-std=c++17 -ffreestanding -nostdinc++ -isystem tests/abi/stub -I sdk/public -Wno-invalid-offsetof"
DFLAGS="-i -Isource -Itests/abi/source tests/abi/native/compare.d"
fail=0

# probe <arch> <outfile>
probe() {
    clang++ -arch "$1" $CXXFLAGS -c tests/abi/probe.cpp -o "$WORK/probe-$1.o"
    clang++ -arch "$1" -c tests/abi/native/main.cpp -o "$WORK/main-$1.o"
    clang++ -arch "$1" "$WORK/probe-$1.o" "$WORK/main-$1.o" -o "$WORK/probe-$1"
    arch "-$1" "$WORK/probe-$1" > "$2"
}

# compare <label> <command...>
compare() {
    label="$1"; shift
    if out="$("$@" 2>&1)"; then
        echo "ok    $label: $(echo "$out" | tail -1)"
    else
        echo "FAIL  $label"; echo "$out"; fail=1
    fi
}

if [ "$(uname)" != Darwin ]; then
    echo "skipped: the native run covers macOS (arm64 and x86_64)"
    exit 0
fi
native="$(uname -m)"
probe "$native" "$WORK/cpp-native.txt"
dmd -version=SteamworksDynamic $DFLAGS -of="$WORK/compare-dmd" >/dev/null
compare "dmd $native" "$WORK/compare-dmd" "$WORK/cpp-native.txt"
ldc2 -d-version=SteamworksDynamic $DFLAGS -of="$WORK/compare-ldc2" >/dev/null 2>&1
compare "ldc2 $native" "$WORK/compare-ldc2" "$WORK/cpp-native.txt"
if [ "$native" = arm64 ] && arch -x86_64 /usr/bin/true 2>/dev/null; then
    probe x86_64 "$WORK/cpp-x86_64.txt"
    ldc2 -mtriple=x86_64-apple-macos11 -d-version=SteamworksDynamic $DFLAGS -of="$WORK/compare-x86_64" \
        >/dev/null 2>&1
    compare "ldc2 x86_64 (Rosetta)" arch -x86_64 "$WORK/compare-x86_64" "$WORK/cpp-x86_64.txt"
fi
exit $fail
