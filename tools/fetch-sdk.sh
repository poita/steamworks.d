#!/bin/sh
# Populates ./sdk with a Steamworks SDK for development and CI.
#
# Valve distributes the official SDK from https://partner.steamgames.com/downloads
# behind a Steamworks login. If you have it, point STEAMWORKS_SDK at the
# extracted "sdk" directory (the one containing public/ and redistributable_bin/)
# and this script copies it. Otherwise it downloads a copy of the SDK's public/
# and redistributable_bin/ directories that another binding project carries:
#
#   STEAMWORKS_SDK_VERSION=1.65 (default)
#       steamworks-sys/lib/steam/ of the steamworks-rs repository at a pinned
#       commit, as a GitHub tarball. GitHub generates tarballs on demand and does
#       not guarantee they are byte-identical over time, so the SHA-256 of the
#       extracted steam_api.json, steam_api_flat.h, every redistributable library
#       and a digest of all extracted files are what must match; a different
#       tarball hash alone only prints a note.
#   STEAMWORKS_SDK_VERSION=1.64
#       the steamworks-sys 0.13.0 crate from crates.io, checked against the
#       checksum the crates.io index publishes (crates are immutable), for
#       comparing with the previous release.
#
# The SDK is Valve's property, licensed under the Steamworks SDK Access
# Agreement; ./sdk is gitignored and must never be committed.
set -eu

VERSION="${STEAMWORKS_SDK_VERSION:-1.65}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/sdk"

if [ -d "$DEST/public/steam" ]; then
    echo "sdk already present at $DEST (move it away to fetch another)"
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

# Prints one "<sha256>  <path>" line per file under public/ and
# redistributable_bin/ of directory $1, in byte order, and returns the SHA-256
# of that listing: one value covering every file's path and content.
tree_digest() {
    (
        cd "$1"
        find public redistributable_bin -type f | LC_ALL=C sort | while IFS= read -r f; do
            echo "$(sha256 "$f")  $f"
        done
    ) >"$TMP/listing"
    sha256 "$TMP/listing"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$VERSION" in
1.65)
    COMMIT=5a72a6a10e6a30810575ff4db104f0a2d0cbcffa
    TARBALL_SHA256=9c3cf3c7991b825da027d69f041cd35e07685e3864b2f11ea8ffc1fae27670fa
    TREE_SHA256=f44e8241dee22ea0ef72550c5a97a125546c305b0e9942aa6b5fa9647f85e26e
    curl -fsSL --retry 3 -A "steamworks.d fetch-sdk" -o "$TMP/rs.tar.gz" \
        "https://codeload.github.com/Noxime/steamworks-rs/tar.gz/$COMMIT"
    actual="$(sha256 "$TMP/rs.tar.gz")"
    if [ "$actual" != "$TARBALL_SHA256" ]; then
        echo "note: steamworks-rs tarball hash $actual differs from the recorded" \
            "$TARBALL_SHA256 (GitHub tarballs are not byte-stable); checking the extracted files" >&2
    fi
    tar -xzf "$TMP/rs.tar.gz" -C "$TMP"
    SRC="$TMP/steamworks-rs-$COMMIT/steamworks-sys/lib/steam"
    failed=0
    while read -r want path; do
        if [ ! -f "$SRC/$path" ]; then
            echo "SDK $VERSION: $path is missing from steamworks-rs $COMMIT" >&2
            failed=1
        else
            got="$(sha256 "$SRC/$path")"
            if [ "$got" != "$want" ]; then
                echo "SDK $VERSION: $path checksum mismatch: expected $want, got $got" >&2
                failed=1
            fi
        fi
    done <<EOF
8c1038d41b236571c69dfdeb3f26171a7ff3659372d897ecec7f9d66d8e17d20 public/steam/steam_api.json
de13c310b5df6a02c8e5f97211a2b28c82980960f4c8011342fea37730308e39 public/steam/steam_api_flat.h
0bb3f27e4d789d1ffc1b082f184a9163969aa30a786009ba4389d97596b5a5b1 redistributable_bin/androidarm64/libsteam_api.so
25193f895e74caf84de11babff25b6fcdc4190efa9e98dfd7a6a53e39f7d429a redistributable_bin/linux32/libsteam_api.so
eb2dd015b84177cf4f4326fe578aab375fd8931bbbd719c7492420d9777007fe redistributable_bin/linux64/libsteam_api.so
6010ff5049f0154a270092cb93729f1fc691d28e3b8a6f5fc6f8fcccfbd1e508 redistributable_bin/linuxarm64/libsteam_api.so
a37faf19675b943a3c9717d25d9a881f5addb7f0ee728e03de7aac143ba759d2 redistributable_bin/osx/libsteam_api.dylib
1cb8b7cb77923762d4e49b27e44295369a79e93b5d4282c5e840b268d28fe771 redistributable_bin/steam_api.dll
1f80f7a8d0f46aca691b67203e5ee6d7456d063b8a3839fb42027712a13147c1 redistributable_bin/steam_api.lib
e6d9bafb9a41e42fba7b21553db49f8719027af3f0deb23ff86cfc44d60e776d redistributable_bin/win64/steam_api64.dll
7b68c738457211a088bdcf583ca08a294b48345dbb59a8aa3c8c63f3646c894c redistributable_bin/win64/steam_api64.lib
EOF
    got="$(tree_digest "$SRC")"
    if [ "$got" != "$TREE_SHA256" ]; then
        echo "SDK $VERSION: digest of all extracted files mismatch: expected $TREE_SHA256, got $got" >&2
        failed=1
    fi
    if [ "$failed" != 0 ]; then
        echo "SDK $VERSION from steamworks-rs $COMMIT failed verification; nothing was written to $DEST" >&2
        exit 1
    fi
    mkdir -p "$DEST"
    cp -R "$SRC/public" "$SRC/redistributable_bin" "$DEST/"
    echo "fetched sdk $VERSION (steamworks-rs $COMMIT mirror) into $DEST"
    ;;
1.64)
    SYS_VERSION=0.13.0
    SYS_SHA256=ae139f051204a4af015d4f0ed3a1f7a51020d03a44c7cf249168c543d88131e9
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
    echo "fetched sdk $VERSION (steamworks-sys $SYS_VERSION mirror) into $DEST"
    ;;
*)
    echo "unknown STEAMWORKS_SDK_VERSION $VERSION: this script fetches 1.65 or 1.64;" \
        "set STEAMWORKS_SDK to an official SDK for other releases" >&2
    exit 1
    ;;
esac
