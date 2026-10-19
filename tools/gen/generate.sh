#!/bin/sh
# Regenerates source/steamworks/raw and tests/abi from the SDK in ./sdk.
#   tools/gen/generate.sh           regenerate (runs the clang ABI probe)
#   tools/gen/generate.sh --check   fail if any generated file is stale
# Needs dub, a D compiler, clang++ and dfmt (DFMT overrides the dfmt path).
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DFMT="${DFMT:-$(command -v dfmt || echo "$HOME/.local/bin/dfmt")}"
cd "$ROOT"
dub build -q --root=tools/gen
exec tools/gen/bin/steamworks-gen --sdk sdk --abi --dfmt "$DFMT" "$@"
