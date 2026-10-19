#!/bin/sh
# Checks the bindings' ABI against tests/abi/source/abi_expected.d, which
# tools/gen measured from the SDK headers with clang:
#  - natively with dmd and ldc2,
#  - for every platform Valve ships libsteam_api for, by cross-compiling
#    with ldc2 (only semantic analysis runs; nothing is linked),
# in both the linked and the dynamic (SteamworksDynamic) configurations.
# DCS lists the D compilers to use (default "dmd ldc2"); the cross-compiled
# targets need ldc2.
# Each target also compiles the whole library with -unittest, so the
# compile-time checks in its unittest blocks (callback packing, vtable
# order) run for that target.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SRC="tests/abi/source/abi_expected.d"
DCS="${DCS:-dmd ldc2}"
has_dc() { case " $DCS " in *" $1 "*) return 0 ;; esac; return 1; }
fail=0
# run <label> <command...>
run() {
    label="$1"; shift
    if "$@" >/dev/null 2>"$ROOT/.abi-check.log"; then
        echo "ok    $label"
    else
        echo "FAIL  $label"; cat "$ROOT/.abi-check.log"; fail=1
    fi
}
for v in "" "SteamworksDynamic"; do
    vd=${v:+-version=$v}
    vl=${v:+-d-version=$v}
    cfg=${v:-linked}
    if has_dc dmd; then run "dmd native ($cfg)" dmd $vd -c -o- -Isource "$SRC"; fi
    has_dc ldc2 || continue
    run "ldc2 native ($cfg)" ldc2 $vl -c -o- -Isource "$SRC"
    for t in arm64-apple-macos x86_64-apple-macos x86_64-windows-msvc i686-windows-msvc \
             x86_64-linux-gnu i686-linux-gnu aarch64-linux-gnu aarch64-linux-android; do
        run "ldc2 $t ($cfg)" ldc2 -mtriple=$t $vl -c -o- -Isource "$SRC"
        run "ldc2 $t library unittests ($cfg)" \
            ldc2 -mtriple=$t $vl -unittest -c -o- -Isource $(find source -name '*.d' | sort)
    done
done
rm -f "$ROOT/.abi-check.log"
exit $fail
