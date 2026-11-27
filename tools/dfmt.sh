#!/bin/sh
# Prints the path of a dfmt executable of the version this repository is
# formatted with (other versions format differently): $DFMT if set, else
# dfmt on PATH if it is that version, else one built with dub (using the
# compiler in $DC, default ldc2).
set -eu
DFMT_VERSION=0.15.2
if [ -n "${DFMT:-}" ]; then
    echo "$DFMT"
    exit 0
fi
for candidate in "$(command -v dfmt 2>/dev/null || true)" "$HOME/.local/bin/dfmt"; do
    if [ -x "$candidate" ] && "$candidate" --version 2>/dev/null | grep -q "v$DFMT_VERSION"; then
        echo "$candidate"
        exit 0
    fi
done
dub fetch -q "dfmt@$DFMT_VERSION" >/dev/null 2>&1 || true
dub build -q "dfmt@$DFMT_VERSION" --compiler="${DC:-ldc2}" >&2
packages="${DUB_HOME:-$HOME/.dub}/packages/dfmt"
path="$(find "$packages" -path "*$DFMT_VERSION*" -type f -perm -u+x \( -name dfmt -o -name dfmt.exe \) | head -n 1)"
[ -n "$path" ] || { echo "cannot build dfmt $DFMT_VERSION" >&2; exit 1; }
echo "$path"
