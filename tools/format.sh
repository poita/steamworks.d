#!/bin/sh
# Formats every D source in the repository with dfmt (tools/dfmt.sh picks the
# pinned version; .editorconfig holds the style).
#   tools/format.sh           format in place
#   tools/format.sh --check   list unformatted files and exit 1 if any
# Generated modules are formatted by the generator with the same dfmt, so
# they are checked too.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DFMT="$(tools/dfmt.sh)"
check=0
[ "${1:-}" = "--check" ] && check=1
status=0
for f in $(git ls-files '*.d'); do
    if [ $check = 1 ]; then
        if ! "$DFMT" "$f" | cmp -s - "$f"; then
            echo "not formatted: $f"
            status=1
        fi
    else
        "$DFMT" --inplace "$f"
    fi
done
[ $status = 0 ] && [ $check = 1 ] && echo "all D sources are formatted"
exit $status
