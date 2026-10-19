#!/bin/sh
# Compares the C exports of every libsteam_api in sdk/redistributable_bin with
# the bindings: each export must be a bound function (steamworksFunctionNames)
# or a deliberately unbound one (steamworksUnboundExports), and every bound
# function must be exported. C++ runtime symbols (statically linked into the
# Android build), glibc wrappers and the Linux-only SteamRealPath helper are
# ignored.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/sdk/redistributable_bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LC_ALL=C

# Bound and unbound names, from the generated symbol table.
awk '/steamworksFunctionNames = \[/{f=1;next} f&&/\];/{f=0} f' "$ROOT/source/steamworks/raw/symbols.d" \
    | tr -d ' ",' | grep . | sort > "$TMP/bound"
awk '/steamworksUnboundExports = \[/{f=1;next} f&&/\];/{f=0} f' "$ROOT/source/steamworks/raw/symbols.d" \
    | tr -d ' ",' | grep . | sort > "$TMP/unbound"
sort -u "$TMP/bound" "$TMP/unbound" > "$TMP/known"
echo "$(wc -l < "$TMP/bound" | tr -d ' ') bound, $(wc -l < "$TMP/unbound" | tr -d ' ') unbound"

status=0
check() {
    lib="$1"; list="$2"
    grep -v -E '^(_Z|__wrap_|__cxa_|__gxx_|__emutls_|__llvm_|__dynamic_cast$|_init$|_fini$|SteamRealPath$)' "$list" | sort -u > "$list.c"
    extra="$(comm -23 "$list.c" "$TMP/known")"
    missing="$(comm -13 "$list.c" "$TMP/bound")"
    if [ -z "$extra$missing" ]; then
        echo "ok    $lib ($(wc -l < "$list.c" | tr -d ' ') C exports)"
    else
        echo "FAIL  $lib"
        [ -n "$extra" ] && echo "  exported but unknown:" && echo "$extra" | sed 's/^/    /'
        [ -n "$missing" ] && echo "  bound but not exported:" && echo "$missing" | sed 's/^/    /'
        status=1
    fi
}

for arch in arm64 x86_64; do
    nm -gU -arch "$arch" "$BIN/osx/libsteam_api.dylib" | awk '{print $3}' | sed 's/^_//' > "$TMP/osx-$arch"
    check "osx/libsteam_api.dylib ($arch)" "$TMP/osx-$arch"
done
for dir in linux64 linux32 linuxarm64 androidarm64; do
    nm -D --defined-only "$BIN/$dir/libsteam_api.so" | awk 'NF==3{print $3}' > "$TMP/$dir"
    check "$dir/libsteam_api.so" "$TMP/$dir"
done
for dll in win64/steam_api64.dll steam_api.dll; do
    name="$(echo "$dll" | tr '/' '_')"
    objdump -p "$BIN/$dll" | awk '/Ordinal +RVA +Name/{f=1;next} f&&NF>=3{print $3} f&&NF==0{f=0}' > "$TMP/$name"
    check "$dll" "$TMP/$name"
done
exit $status
