#!/usr/bin/env bash
# Builds the disk image MokaRig attaches to macOS guests, and prints its path as the last line.
#
# Usage:
#   Packaging/build-guest-tools.sh [version]
#
# The image is reused when nothing it depends on has changed, so an app build stays fast. The signing
# variables are the ones build-pkg.sh documents.

set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT/.build/guest-tools"
IMAGE="$OUTPUT_DIR/GuestTools.img"
STAMP="$OUTPUT_DIR/stamp"
INPUTS="$VERSION|${AGENT_SIGN_ID:-}|${INSTALLER_SIGN_ID:-}"

cd "$ROOT"
if [ -f "$IMAGE" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$INPUTS" ] \
	&& [ -z "$(find Package.swift Sources Packaging -newer "$IMAGE" -print -quit)" ]; then
	echo "$IMAGE"
	exit 0
fi

PACKAGE="$(Packaging/build-pkg.sh "$VERSION" | tail -n 1)"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/contents"
cp "$PACKAGE" "$OUTPUT_DIR/contents/Install MokaRig Guest Agent.pkg"

# UDTO is an uncompressed raw image. Virtualization.framework can't attach a compressed or UDIF one,
# whatever the file extension says.
hdiutil create -quiet -srcfolder "$OUTPUT_DIR/contents" -volname "MokaRig Guest Tools" \
	-fs HFS+ -format UDTO -o "$OUTPUT_DIR/GuestTools"
mv "$OUTPUT_DIR/GuestTools.cdr" "$IMAGE"
rm -rf "$OUTPUT_DIR/contents"

echo "$INPUTS" > "$STAMP"
echo "$IMAGE"
