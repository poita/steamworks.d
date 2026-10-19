#!/bin/sh
# Runs every check: generator and library unit tests with dmd and ldc2, the
# stale-output check, the ABI checks for all platforms, the export tables,
# the C ABI calls and the smoke tests against the SDK's library. Needs the
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
for dc in dmd ldc2; do
    for c in linked dynamic; do
        step "smoke test ($c, $dc)"
        dub build -q --root=tests/smoke -c $c --compiler=$dc
        tests/smoke/bin/smoke-$c
    done
done
step "example builds"
dub build -q --root=examples/manual-dispatch
echo
echo "all checks passed"
