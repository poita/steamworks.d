#!/bin/sh
# Builds tests/vtable/main.d against shim.cpp, which calls the D response
# classes through the SDK's C++ declarations, with each D compiler, and runs
# it. On Apple silicon it also builds and runs an x86_64 binary (Rosetta).
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/tests/vtable/bin"
mkdir -p "$OUT"
cd "$ROOT"
status=0
run() {
    if "$1"; then echo "passed $2"; else echo "FAILED $2"; status=1; fi
}
CXXFLAGS="-std=c++17 -O1 -fno-exceptions -fno-rtti -Wno-everything -I sdk/public"
# The response classes need no library functions, so the dynamic
# configuration avoids linking libsteam_api.
DFLAGS="-i=steamworks -Isource"
version_flag() { if [ "$1" = dmd ]; then echo -version=SteamworksDynamic; else echo -d-version=SteamworksDynamic; fi; }
clang++ $CXXFLAGS -c tests/vtable/shim.cpp -o "$OUT/shim.o"
for dc in dmd ldc2; do
    "$dc" $(version_flag "$dc") $DFLAGS tests/vtable/main.d "$OUT/shim.o" -of="$OUT/vtable-$dc"
    run "$OUT/vtable-$dc" "$dc"
done
if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ]; then
    clang++ -target x86_64-apple-macos11 $CXXFLAGS -c tests/vtable/shim.cpp -o "$OUT/shim-x86_64.o"
    ldc2 -mtriple=x86_64-apple-macos $(version_flag ldc2) $DFLAGS tests/vtable/main.d "$OUT/shim-x86_64.o" \
        -of="$OUT/vtable-ldc2-x86_64" 2>/dev/null
    run "$OUT/vtable-ldc2-x86_64" "ldc2 x86_64 (Rosetta)"
fi
exit $status
