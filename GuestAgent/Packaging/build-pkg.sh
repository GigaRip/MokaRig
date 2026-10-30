#!/usr/bin/env bash
# Builds the guest agent installer.
#
# Usage:
#   Packaging/build-pkg.sh [version]
#
# Without signing identities the result is ad-hoc signed, which suits `sudo installer` in a test VM.
# Set both of these to produce a distributable package, which then still needs notarizing:
#   AGENT_SIGN_ID       "Developer ID Application: ..."
#   INSTALLER_SIGN_ID   "Developer ID Installer: ..."

set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTIFIER="com.gigarip.mokarig.guest-agent"
OUTPUT_DIR="$ROOT/.build/pkg"
PAYLOAD="$OUTPUT_DIR/payload"
APP="$PAYLOAD/Library/Application Support/MokaRig/MokaRig Guest Agent.app"
PACKAGE="$OUTPUT_DIR/MokaRigGuestAgent-$VERSION.pkg"

cd "$ROOT"
# macOS guests exist only on Apple silicon, so there is no x86_64 slice to build.
swift build -c release --arch arm64

rm -rf "$OUTPUT_DIR"
mkdir -p "$APP/Contents/MacOS" "$PAYLOAD/Library/LaunchAgents"
cp "$(swift build -c release --arch arm64 --show-bin-path)/mokarig-guest-agent" "$APP/Contents/MacOS/"
sed "s/__VERSION__/$VERSION/g" Packaging/Info.plist > "$APP/Contents/Info.plist"
cp "Packaging/$IDENTIFIER.plist" "$PAYLOAD/Library/LaunchAgents/"
chmod 644 "$PAYLOAD/Library/LaunchAgents/$IDENTIFIER.plist"

# Notarization needs a secure timestamp, which an ad-hoc signature can't have.
if [ -n "${AGENT_SIGN_ID:-}" ]; then
	codesign --force --options runtime --timestamp --sign "$AGENT_SIGN_ID" "$APP"
else
	codesign --force --options runtime --timestamp=none --sign - "$APP"
fi

# Quarantine on the payload would otherwise be recorded in the package and installed in the guest.
xattr -cr "$PAYLOAD"
pkgbuild --root "$PAYLOAD" \
	--identifier "$IDENTIFIER" \
	--version "$VERSION" \
	--install-location / \
	--scripts Packaging/scripts \
	"$PACKAGE.unsigned" >/dev/null

if [ -n "${INSTALLER_SIGN_ID:-}" ]; then
	productsign --sign "$INSTALLER_SIGN_ID" "$PACKAGE.unsigned" "$PACKAGE" >/dev/null
	rm "$PACKAGE.unsigned"
else
	mv "$PACKAGE.unsigned" "$PACKAGE"
fi

echo "$PACKAGE"
