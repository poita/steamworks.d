#!/bin/sh
# Populates ./sdk with a Steamworks SDK for development and CI.
#
# Valve distributes the official SDK from https://partner.steamgames.com/downloads
# behind a Steamworks login. If you have it, point STEAMWORKS_SDK at the
# extracted "sdk" directory (the one containing public/ and redistributable_bin/)
# and this script copies it. Otherwise it downloads the copy of the SDK's
# public/ and redistributable_bin/ directories embedded in the steamworks-sys
# crate on crates.io (version 0.13.0 carries Steamworks SDK 1.64) and checks
# it against the checksum the crates.io index publishes.
#
# The SDK is Valve's property, licensed under the Steamworks SDK Access
# Agreement; ./sdk is gitignored and must never be committed.
set -eu

SYS_VERSION="${STEAMWORKS_SYS_VERSION:-0.13.0}"
SYS_SHA256="${STEAMWORKS_SYS_SHA256:-ae139f051204a4af015d4f0ed3a1f7a51020d03a44c7cf249168c543d88131e9}"
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

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -A "steamworks.d fetch-sdk" -o "$TMP/sys.crate" \
    "https://crates.io/api/v1/crates/steamworks-sys/$SYS_VERSION/download"
actual="$(sha256 "$TMP/sys.crate")"
if [ "$actual" != "$SYS_SHA256" ]; then
    echo "steamworks-sys $SYS_VERSION checksum mismatch: expected $SYS_SHA256, got $actual" >&2
    exit 1
fi
tar -xzf "$TMP/sys.crate" -C "$TMP"
mkdir -p "$DEST"
cp -R "$TMP/steamworks-sys-$SYS_VERSION/lib/steam/public" \
      "$TMP/steamworks-sys-$SYS_VERSION/lib/steam/redistributable_bin" "$DEST/"
echo "fetched sdk (steamworks-sys $SYS_VERSION mirror) into $DEST"
