#!/bin/sh
# Regenerates source/steamworks/raw and tests/abi from the SDK in ./sdk.
#   tools/gen/generate.sh           regenerate (runs the clang ABI probe)
#   tools/gen/generate.sh --check   fail if any generated file is stale
# Needs dub, a D compiler and clang++. Output is formatted with the dfmt that
# tools/dfmt.sh picks (DFMT overrides it).
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
DFMT="$(tools/dfmt.sh)"
dub build -q --root=tools/gen
exec tools/gen/bin/steamworks-gen --sdk sdk --abi --dfmt "$DFMT" "$@"
