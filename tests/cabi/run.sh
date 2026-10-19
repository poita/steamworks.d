#!/bin/sh
# Builds tests/cabi/main.d against shim.cpp with each D compiler and runs it.
# On Apple silicon it also builds an x86_64 binary with ldc2 and runs it
# under Rosetta, covering the System V x86-64 ABI. DCS lists the D compilers
# to use (default "dmd ldc2").
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/tests/cabi/bin"
mkdir -p "$OUT"
cd "$ROOT"
status=0
run() {
    if "$1"; then echo "ok    $2"; else echo "FAIL  $2"; status=1; fi
}
clang++ -std=c++17 -O1 -fno-exceptions -fno-rtti -I sdk/public -c tests/cabi/shim.cpp -o "$OUT/shim.o"
DCS="${DCS:-dmd ldc2}"
for dc in $DCS; do
    "$dc" -i=steamworks -Isource tests/cabi/main.d "$OUT/shim.o" -of="$OUT/cabi-$dc"
    run "$OUT/cabi-$dc" "$dc"
done
if [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ] && case " $DCS " in *" ldc2 "*) true ;; *) false ;; esac; then
    clang++ -target x86_64-apple-macos11 -std=c++17 -O1 -fno-exceptions -fno-rtti -I sdk/public \
        -c tests/cabi/shim.cpp -o "$OUT/shim-x86_64.o"
    ldc2 -mtriple=x86_64-apple-macos -i=steamworks -Isource tests/cabi/main.d "$OUT/shim-x86_64.o" \
        -of="$OUT/cabi-ldc2-x86_64" 2>/dev/null
    run "$OUT/cabi-ldc2-x86_64" "ldc2 x86_64 (Rosetta)"
fi
exit $status
