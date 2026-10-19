#!/bin/sh
# Populates ./sdk with a Steamworks SDK for development and CI.
#
# Valve distributes the official SDK from https://partner.steamgames.com/downloads
# behind a Steamworks login. If you have it, point STEAMWORKS_SDK at the
# extracted "sdk" directory (the one containing public/ and redistributable_bin/)
# and this script copies it. Otherwise it downloads the SDK mirror embedded in
# the steamworks-sys crate on crates.io.
set -eu

SYS_VERSION="${STEAMWORKS_SYS_VERSION:-0.13.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/sdk"

if [ -d "$DEST/public/steam" ]; then
    echo "sdk already present at $DEST"
    exit 0
fi

if [ -n "${STEAMWORKS_SDK:-}" ]; then
    mkdir -p "$DEST"
    cp -R "$STEAMWORKS_SDK/public" "$STEAMWORKS_SDK/redistributable_bin" "$DEST/"
    echo "copied sdk from $STEAMWORKS_SDK"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -A "steamworks.d fetch-sdk" -o "$TMP/sys.crate" \
    "https://crates.io/api/v1/crates/steamworks-sys/$SYS_VERSION/download"
tar -xzf "$TMP/sys.crate" -C "$TMP"
mkdir -p "$DEST"
cp -R "$TMP/steamworks-sys-$SYS_VERSION/lib/steam/public" \
      "$TMP/steamworks-sys-$SYS_VERSION/lib/steam/redistributable_bin" "$DEST/"
echo "fetched sdk (steamworks-sys $SYS_VERSION mirror) into $DEST"
