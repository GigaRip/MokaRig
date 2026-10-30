#!/usr/bin/env bash
# Xcode build phase: builds the Guest Tools image and copies it into the app's resources.

set -euo pipefail

# The environment is cleared so the agent builds exactly as it does from the command line, rather
# than picking up the app target's build settings. tee keeps build errors in Xcode's log.
image="$(env -i HOME="$HOME" PATH="$PATH" DEVELOPER_DIR="$DEVELOPER_DIR" \
	AGENT_SIGN_ID="${AGENT_SIGN_ID:-}" INSTALLER_SIGN_ID="${INSTALLER_SIGN_ID:-}" \
	"$SRCROOT/GuestAgent/Packaging/build-guest-tools.sh" "$MARKETING_VERSION" | tee /dev/stderr | tail -n 1)"

cp "$image" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/GuestTools.img"
