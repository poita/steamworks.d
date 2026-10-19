#!/bin/sh
# Runs every check: generator and library unit tests with dmd and ldc2, the
# ABI and symbol checks of tools/check-abi.sh (stale output, layouts and
# signatures for all platforms, export tables, C ABI calls), the C++ calls
# into D, and the smoke and D-layer tests against the SDK's library, plus the
# linked-configuration unit tests, the examples, formatting and lint. Needs
# the SDK in ./sdk (tools/fetch-sdk.sh), clang++, dmd and ldc2; dfmt and
# D-Scanner are built with dub when the pinned versions are not installed.
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
step "ABI and symbols against the SDK (tools/check-abi.sh)"
tools/check-abi.sh
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
for dc in dmd ldc2; do
    for e in examples/*/; do
        step "example $(basename "$e") ($dc)"
        dub build -q --root="$e" --compiler=$dc
    done
done
step "formatting (tools/format.sh --check)"
tools/format.sh --check
step "lint (tools/lint.sh)"
tools/lint.sh
echo
echo "all checks passed"
