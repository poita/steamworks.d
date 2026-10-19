#!/bin/sh
# Runs D-Scanner's static analysis with dscanner.ini over every D source
# (the library, its generated modules, examples, tests and the generator).
# Uses $DSCANNER, else dscanner on PATH if it is the pinned version, else
# the pinned version through dub (built with the compiler in $DC, default
# ldc2).
set -eu
DSCANNER_VERSION=0.16.0-beta.4
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
paths="source examples tests tools/gen/source"
if [ -n "${DSCANNER:-}" ]; then
    exec "$DSCANNER" --config dscanner.ini --styleCheck $paths
fi
if command -v dscanner >/dev/null 2>&1 && dscanner --version 2>/dev/null | grep -q "v$DSCANNER_VERSION"; then
    exec dscanner --config dscanner.ini --styleCheck $paths
fi
exec dub run -q "dscanner@$DSCANNER_VERSION" --compiler="${DC:-ldc2}" -- \
    --config "$ROOT/dscanner.ini" --styleCheck $paths
