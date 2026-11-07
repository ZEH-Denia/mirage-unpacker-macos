#!/bin/bash
# update-make-fault-feed.sh — build an isolated update candidate for fault injection
# (version-bumped copy of the current 1.8.1 build), package it as a DMG, and sign a
# local Sparkle feed with it.
#
# Usage: tools/dev/update-make-fault-feed.sh <work-dir> [candidate-version] [port]
#   <work-dir>          directory created by the caller (e.g. app/.build/update-e2e-*/faults)
#   [candidate-version] default 1.8.2
#   [port]              default 18731 (only used for the download-url-prefix)
#
# Never touches /Applications, the real DMG, or the Sparkle private key
# (generate_appcast reads it from the login Keychain; it is never exported).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"          # repo root
APP_DIR="$ROOT/app"
DIST_APP="$APP_DIR/dist/PKD.app"
SPARKLE_BIN="$APP_DIR/.build/artifacts/Sparkle/Sparkle/bin"

WORK="${1:?usage: $0 <work-dir> [candidate-version] [port]}"
CANDIDATE_VERSION="${2:-1.8.2}"
PORT="${3:-18731}"

mkdir -p "$WORK/candidate-$CANDIDATE_VERSION" "$WORK/feed-$CANDIDATE_VERSION"

if [ ! -d "$DIST_APP" ]; then
  echo "missing $DIST_APP — run app/scripts/make-app.sh first" >&2
  exit 1
fi

CAND="$WORK/candidate-$CANDIDATE_VERSION/PKD.app"
echo "==> copy current build as candidate $CANDIDATE_VERSION"
rm -rf "$CAND"
ditto "$DIST_APP" "$CAND"

echo "==> bump version to $CANDIDATE_VERSION (isolated copy only)"
plutil -replace CFBundleShortVersionString -string "$CANDIDATE_VERSION" "$CAND/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$CANDIDATE_VERSION" "$CAND/Contents/Info.plist"
plutil -lint "$CAND/Contents/Info.plist" >/dev/null

echo "==> re-sign candidate ad-hoc (layered, same style as make-app.sh)"
codesign --force --sign - --identifier com.zeh.pkd.repkg "$CAND/Contents/MacOS/repkg"
codesign --force --sign - --identifier com.zeh.pkd "$CAND/Contents/MacOS/PKD"
codesign --force --sign - --identifier com.zeh.pkd "$CAND"
xattr -cr "$CAND" || true
codesign --verify --deep --strict "$CAND"

echo "==> package DMG"
TMP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pkd-fault-dmg.XXXXXX")"
trap 'rm -rf "$TMP_STAGE"' EXIT
ditto "$CAND" "$TMP_STAGE/PKD.app"
ln -s /Applications "$TMP_STAGE/Applications"
DMG="$WORK/feed-$CANDIDATE_VERSION/Mirage-Unpacker-for-macOS-$CANDIDATE_VERSION.dmg"
rm -f "$DMG"
diskutil image create from \
  --volumeName "Mirage Unpacker $CANDIDATE_VERSION" \
  --format UDZO \
  "$TMP_STAGE" \
  "$DMG" >/dev/null

echo "==> sign appcast"
"$SPARKLE_BIN/generate_appcast" \
  --account ed25519 \
  --download-url-prefix "http://127.0.0.1:$PORT/" \
  "$WORK/feed-$CANDIDATE_VERSION"

test -s "$WORK/feed-$CANDIDATE_VERSION/appcast.xml"
echo "candidate app : $CAND"
echo "candidate dmg : $DMG"
echo "signed appcast: $WORK/feed-$CANDIDATE_VERSION/appcast.xml"
