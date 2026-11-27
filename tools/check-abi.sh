#!/bin/sh
# Verifies the bindings' ABI and symbols against the Steamworks SDK in ./sdk:
#
#  1. generated   the generated modules and ABI expectations are current
#  2. probe       sizes, alignments, offsets and values measured by clang for
#                 every target, checked by dmd and ldc2 (tests/abi/check.sh)
#  3. native      the same probe compiled and run natively, compared with a D
#                 program at run time (tests/abi/native/run.sh)
#  4. verify      the compiler's own description of every D declaration,
#                 turned into C++ static_asserts against the headers for every
#                 target and configuration; completeness in both directions;
#                 vtable order; the symbols the linked configuration references
#                 against each target's library (steamworks-gen --verify)
#  5. exports     every library's export table against the bound functions
#                 (tests/exports/check.sh)
#  6. cabi        calls through the C ABI with by-value structs and mixed
#                 arguments (tests/cabi/run.sh)
#
# Usage: tools/check-abi.sh [step...]    (default: every step)
# Needs dub, dmd, ldc2, clang++, nm/objdump (Xcode's LLVM tools) and dfmt.
# DCS lists the D compilers the steps use (default "dmd ldc2"); ldc2 is
# required, dmd optional. The native step runs on macOS only, and verify and
# exports need an nm/objdump that read Mach-O, ELF and COFF.
# Steps run one at a time.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ulimit -n 65536 2>/dev/null || true
[ -d sdk/public/steam ] || { echo "no SDK in ./sdk; run tools/fetch-sdk.sh" >&2; exit 2; }
steps="${*:-generated probe native verify exports cabi}"
failed=""
run() {
    name="$1"; shift
    echo; echo "== $name"
    if "$@"; then :; else failed="$failed $name"; fi
}
for s in $steps; do
    case "$s" in
        generated) run generated tools/gen/generate.sh --check ;;
        probe) run probe tests/abi/check.sh ;;
        native) run native tests/abi/native/run.sh ;;
        verify)
            dub build -q --root=tools/gen
            case " ${DCS:-dmd ldc2} " in
                *" dmd "*) run verify tools/gen/bin/steamworks-gen --verify ;;
                *) run verify tools/gen/bin/steamworks-gen --verify --dmd '' ;;
            esac ;;
        exports) run exports tests/exports/check.sh ;;
        cabi) run cabi tests/cabi/run.sh ;;
        *) echo "unknown step: $s" >&2; exit 2 ;;
    esac
done
echo
if [ -n "$failed" ]; then
    echo "FAILED:$failed"
    exit 1
fi
echo "all ABI checks passed"
