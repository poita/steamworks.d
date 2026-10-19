#!/bin/sh
# Runs every check: generator and library unit tests with dmd and ldc2, the
# stale-output check, the ABI checks for all platforms, the export tables,
# the C ABI calls, the C++ calls into D, and the smoke and D-layer tests
# against the SDK's library, plus the linked-configuration unit tests. Needs the
# SDK in ./sdk (tools/fetch-sdk.sh), clang++, dfmt, dmd and ldc2.
# Builds run one at a time.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ulimit -n 65536 2>/dev/null || true
step() { echo; echo "== $*"; }

for dc in dmd ldc2; do
    step "generator unit tests ($dc)"
    dub test -q --root=tools/gen --compiler=$dc
    step "library unit tests ($dc)"
    dub test -q --compiler=$dc
done
step "generated files are current"
tools/gen/generate.sh --check
step "ABI against the SDK headers"
tests/abi/check.sh
step "export tables"
tests/exports/check.sh
step "C ABI calls"
tests/cabi/run.sh
step "C++ calls into the D response classes"
tests/vtable/run.sh
for dc in dmd ldc2; do
    for c in linked dynamic; do
        step "smoke test ($c, $dc)"
        dub build -q --root=tests/smoke -c $c --compiler=$dc
        tests/smoke/bin/smoke-$c
        step "D layer against the library ($c, $dc)"
        dub build -q --root=tests/layer -c $c --compiler=$dc
        tests/layer/bin/layer-$c
    done
done
for dc in dmd ldc2; do
    step "linked-configuration unit tests ($dc)"
    LIBRARY_PATH="$ROOT/sdk/redistributable_bin/osx:$ROOT/sdk/redistributable_bin/linux64${LIBRARY_PATH:+:$LIBRARY_PATH}" \
        DYLD_LIBRARY_PATH="$ROOT/sdk/redistributable_bin/osx" LD_LIBRARY_PATH="$ROOT/sdk/redistributable_bin/linux64" \
        dub test -q -c linked --compiler=$dc
done
step "example builds"
dub build -q --root=examples/manual-dispatch
dub build -q --root=examples/dispatcher
echo
echo "all checks passed"
