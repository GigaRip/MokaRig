#!/usr/bin/env bash
# release.sh — build, sign, notarize, package, and publish a MokaRig release.
#
# Usage:
#   ./release.sh 0.1.1     explicit version (must be > the current published release)
#   ./release.sh           auto-increment the patch of the current published release
#
# One-time prerequisites (already done on your machine unless noted):
#   brew install create-dmg
#   xcrun notarytool store-credentials "mokarig-notary" \
#       --apple-id <apple-id> --team-id G3RSHR4W5U --password <app-specific-pw>
#   npm install -g wrangler && wrangler login        # for R2 upload
#
# The script expects to be run from the repo root (where MokaRig.xcodeproj lives).

set -euo pipefail

# ----------------------------- configuration -------------------------------
SCHEME="MokaRig"
PROJECT="MokaRig.xcodeproj"          # switch to -workspace if you adopt one
SIGN_ID="Developer ID Application: GigaRip LLC (G3RSHR4W5U)"
NOTARY_PROFILE="mokarig-notary"
BUCKET="mokarig-releases"
PUBLIC_BASE="https://downloads.mokarig.com"
RELEASES_DIR="$HOME/MokaRigReleases"
# HiDPI-aware background for the DMG window. A single .tiff carrying both the
# 540x360 and 1080x720 reps (built with `tiffutil -cathidpicheck`); Finder picks
# the rep matching the display, so Retina Macs get the sharp 2x image. create-dmg
# 1.3.0 copies whatever single file it's given, so the Retina rep must be baked
# into this one file rather than left as a sibling @2x.png.
BG_IMAGE="packaging/dmg-background.tiff"
# ---------------------------------------------------------------------------

# --- Resolve the target version against R2 (the source of truth) -----------
# The appcast in R2 lists every published DMG; the highest version there is the
# current release. Fetch it before anything else — both auto-versioning and the
# no-downgrade guard below must agree with what clients actually see. A missing
# appcast means a genuine first release; any other failure means we can't read
# the source of truth, so we refuse to guess a version and exit.
APPCAST_TMP="$(mktemp)"
R2_ERR="$(mktemp)"
trap 'rm -f "$APPCAST_TMP" "$R2_ERR"' EXIT
if wrangler r2 object get "$BUCKET/appcast.xml" --file "$APPCAST_TMP" --remote 2>"$R2_ERR"; then
	HAVE_APPCAST=1
	CURRENT_VERSION=$(grep -oE 'MokaRig-[0-9]+\.[0-9]+\.[0-9]+\.dmg' "$APPCAST_TMP" \
		| sed -E 's/^MokaRig-([0-9.]+)\.dmg$/\1/' | sort -V | tail -1 || true)
elif grep -qiE 'does not exist|not found|no such key|nosuchkey|404|10007' "$R2_ERR"; then
	# The bucket has no appcast yet — a genuine first release, not an R2 failure.
	HAVE_APPCAST=0
	CURRENT_VERSION=""
else
	echo "error: cannot read the release feed (appcast.xml) from R2 — refusing to guess" >&2
	echo "       the current version. R2 is the source of truth; fix access and retry." >&2
	echo "----- wrangler output -----" >&2
	cat "$R2_ERR" >&2
	exit 1
fi

if [ -n "${1:-}" ]; then
	VERSION="$1"
	[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: '$VERSION' is not semver (x.y.z)"; exit 1; }
	if [ -n "$CURRENT_VERSION" ]; then
		if [ "$VERSION" = "$CURRENT_VERSION" ]; then
			echo "error: $VERSION is already the published release — versions are immutable. Bump it."
			exit 1
		fi
		# sort -V puts the newer version last; if that isn't $VERSION, it's a downgrade.
		if [ "$(printf '%s\n%s\n' "$VERSION" "$CURRENT_VERSION" | sort -V | tail -1)" != "$VERSION" ]; then
			echo "error: $VERSION is older than the published release $CURRENT_VERSION."
			echo "       Releases must move forward — choose a version above $CURRENT_VERSION."
			exit 1
		fi
	fi
else
	# No version given: ship the next patch after the current published release.
	if [ -z "$CURRENT_VERSION" ]; then
		echo "error: no published release found in R2 — specify the first version explicitly,"
		echo "       e.g. ./release.sh 0.1.0"
		exit 1
	fi
	IFS=. read -r _maj _min _pat <<< "$CURRENT_VERSION"
	VERSION="$_maj.$_min.$((_pat + 1))"
	echo "==> No version given; auto-incrementing $CURRENT_VERSION -> $VERSION"
fi

WORK="$RELEASES_DIR/MokaRig-$VERSION"
ARCHIVE="$WORK/MokaRig.xcarchive"
EXPORT_DIR="$WORK/export"
DMG="$RELEASES_DIR/MokaRig-$VERSION.dmg"
APP="$EXPORT_DIR/MokaRig.app"

echo "==> Releasing MokaRig $VERSION"
mkdir -p "$WORK"

# --- 1. Stamp version numbers ----------------------------------------------
# CFBundleVersion (build number) must increase monotonically for Sparkle.
# A UTC timestamp (yymmddHHMM) always increases and — unlike a commit count —
# survives history rewrites such as squashing. It stays below 2^32, so it is a
# valid CFBundleVersion component. Don't cut two releases within the same minute.
BUILD_NUMBER=$(date -u +%y%m%d%H%M)
echo "==> Version $VERSION (build $BUILD_NUMBER)"
#xcrun agvtool new-marketing-version "$VERSION" >/dev/null
#xcrun agvtool new-version -all "$BUILD_NUMBER" >/dev/null

# --- 2. Archive (Release, arm64) --------------------------------------------
echo "==> Archiving"
#xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
#  -destination 'generic/platform=macOS' \
#  archive -archivePath "$ARCHIVE" -quiet
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
	-destination 'generic/platform=macOS' \
	MARKETING_VERSION="$VERSION" \
	CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	archive -archivePath "$ARCHIVE" -quiet

# --- 3. Export with Developer ID signing ------------------------------------
echo "==> Exporting signed app"
EXPORT_PLIST="$WORK/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
	-exportOptionsPlist "$EXPORT_PLIST" -exportPath "$EXPORT_DIR" -quiet

[ -d "$APP" ] || { echo "error: export did not produce $APP"; exit 1; }

# --- 4. Build the DMG --------------------------------------------------------
echo "==> Building DMG"
# R2 is the source of truth for what's published, and the guard above already
# rejected any already-released version, so a leftover local DMG from an aborted
# run is safe to discard (create-dmg refuses to overwrite an existing file).
rm -f "$DMG"
STAGING="$WORK/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
[ -f "$BG_IMAGE" ] || { echo "error: DMG background '$BG_IMAGE' is missing"; exit 1; }
create-dmg --volname "MokaRig" \
	--background "$BG_IMAGE" \
	--window-size 540 360 --icon-size 128 \
	--icon "MokaRig.app" 130 160 \
	--app-drop-link 400 160 \
	"$DMG" "$STAGING/" >/dev/null

# --- 5. Sign, notarize, staple the DMG ---------------------------------------
# Notarizing the DMG scans and notarizes the nested app as well.
echo "==> Signing DMG"
codesign --sign "$SIGN_ID" --timestamp "$DMG"

echo "==> Notarizing (this blocks until Apple responds)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"

# --- 6. Verify like a stranger ------------------------------------------------
echo "==> Verifying"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | grep -q "accepted" \
	|| { echo "error: Gatekeeper did not accept the DMG"; exit 1; }
xcrun stapler validate "$DMG" >/dev/null

# --- 7. Upload to R2 -----------------------------------------------------------
echo "==> Uploading to R2"
wrangler r2 object put "$BUCKET/MokaRig-$VERSION.dmg" --file "$DMG" --remote
# Stable alias for the website download button:
wrangler r2 object put "$BUCKET/MokaRig.dmg" --file "$DMG" --remote

# --- 8. Sync the published feed state from R2 ---------------------------------
# generate_appcast rebuilds the feed from whatever DMGs are in RELEASES_DIR, so a
# release from a machine missing older DMGs would silently drop them from the feed.
# Treat R2 as the source of truth: pull every DMG referenced by the appcast we
# already fetched above, so the regenerated feed stays complete no matter which
# machine releases.
echo "==> Syncing published feed from R2"
mkdir -p "$RELEASES_DIR"
if [ "$HAVE_APPCAST" -eq 1 ]; then
	for name in $(grep -oE 'MokaRig-[0-9.]+\.dmg' "$APPCAST_TMP" | sort -u); do
		[ -f "$RELEASES_DIR/$name" ] && continue
		echo "    fetching $name"
		wrangler r2 object get "$BUCKET/$name" --file "$RELEASES_DIR/$name" --remote 2>/dev/null \
			|| echo "    warning: $name is in the appcast but missing from R2"
	done
else
	echo "    no existing appcast in R2 (first release?) — continuing"
fi

# --- 9. Generate and publish the Sparkle appcast ------------------------------
# generate_appcast (re)writes appcast.xml from the DMGs now in RELEASES_DIR (synced
# from R2 above plus this release), EdDSA-signing each enclosure whose embedded app
# has a SUPublicEDKey matching the login-keychain key.
echo "==> Generating appcast"
# Sparkle's tools ship as an SPM binary artifact, resolved into DerivedData by
# the archive step above. Override SPARKLE_BIN to point elsewhere.
SPARKLE_BIN="${SPARKLE_BIN:-$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/MokaRig-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)}"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
[ -x "$GENERATE_APPCAST" ] || { echo "error: generate_appcast not found; set SPARKLE_BIN (looked in '$SPARKLE_BIN')"; exit 1; }

# --maximum-deltas 0 keeps every release a single self-contained DMG; enable
# deltas later by also uploading the generated *.delta files alongside appcast.xml.
"$GENERATE_APPCAST" \
	--download-url-prefix "$PUBLIC_BASE/" \
	--maximum-deltas 0 \
	"$RELEASES_DIR"

APPCAST="$RELEASES_DIR/appcast.xml"
[ -f "$APPCAST" ] || { echo "error: generate_appcast did not produce $APPCAST"; exit 1; }

# generate_appcast signs an enclosure only if the app inside the DMG carries a
# SUPublicEDKey matching the keychain key; on mismatch it emits an *unsigned*
# entry with only a warning. Since MokaRig ships SUPublicEDKey, clients reject
# unsigned updates — so refuse to publish a feed whose new entry isn't signed.
if ! grep -F "MokaRig-$VERSION.dmg" "$APPCAST" | grep -q 'edSignature'; then
	echo "error: appcast entry for $VERSION is not EdDSA-signed."
	echo "       The app's SUPublicEDKey likely doesn't match the keychain key."
	echo "       Run '$SPARKLE_BIN/generate_keys -p' and compare to Info.plist."
	exit 1
fi

echo "==> Uploading appcast"
# appcast.xml is mutable (rewritten each release), unlike the immutable versioned
# DMGs — keep its CDN cache TTL short so clients see new versions promptly.
wrangler r2 object put "$BUCKET/appcast.xml" --file "$APPCAST" --remote

echo ""
echo "==> Done."
echo "    $PUBLIC_BASE/MokaRig-$VERSION.dmg"
echo "    $PUBLIC_BASE/MokaRig.dmg  (stable alias)"
echo "    $PUBLIC_BASE/appcast.xml  (Sparkle feed)"
echo ""
echo "    Next: test the download in Safari on another Mac,"
echo "    then tag the release:  git tag v$VERSION && git push --tags"
