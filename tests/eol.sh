#!/bin/sh
# Checks that every tracked file is checked out with LF line endings
# whatever core.autocrlf says (the Windows CI runners set it to true, and
# shell scripts with CRLF endings do not run).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
bad=$(git ls-files -z | xargs -0 git check-attr eol -- | grep -v ': eol: lf$' || true)
if [ -n "$bad" ]; then
    echo "files without eol=lf (see .gitattributes):"
    echo "$bad"
    exit 1
fi
echo "every tracked file checks out with LF line endings"
