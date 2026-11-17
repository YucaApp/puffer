#!/bin/bash
# Builds the disk image that goes on a GitHub release:
#
#   dist/Puffer-<version>.dmg          the app (Apple silicon + Intel) and a
#                                      shortcut to /Applications
#   dist/Puffer-<version>.dmg.sha256   its checksum
#
# Usage: scripts/release.sh [version]     (default: the version in Info.plist)
#
# Signing. A release is never signed with the "Puffer Local Signing"
# development certificate (see scripts/make-signing-cert.sh for why).
#   - With SIGN_ID="Developer ID Application: Name (TEAMID)" the app and the
#     disk image are signed with it, and if notarisation credentials are also
#     given the image is notarised and stapled. That is a release macOS opens
#     without complaint.
#   - Without SIGN_ID the app is ad-hoc signed. It works, but macOS makes the
#     user approve it by hand, and the Accessibility permission has to be
#     granted again after every update. The README tells users how.
#
# Notarisation credentials, either:
#   NOTARY_PROFILE=name            a profile saved with
#                                  `xcrun notarytool store-credentials`
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#                                  an Apple ID, its team, and an
#                                  app-specific password (what CI uses)
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "error: version must look like 1.2 or 1.2.3, not \"$version\"" >&2
  exit 1
fi

identity="${SIGN_ID:--}"
UNIVERSAL=1 VERSION="$version" SIGN_ID="$identity" ./scripts/build-app.sh

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto dist/Puffer.app "$stage/Puffer.app"
ln -s /Applications "$stage/Applications"

dmg="dist/Puffer-$version.dmg"
rm -f "$dmg" "$dmg.sha256"
hdiutil create -quiet -volname "Puffer $version" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"

if [[ "$identity" != "-" ]]; then
  codesign --sign "$identity" --timestamp "$dmg"

  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg" --wait --keychain-profile "$NOTARY_PROFILE"
    xcrun stapler staple "$dmg"
  elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    xcrun notarytool submit "$dmg" --wait \
      --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD"
    xcrun stapler staple "$dmg"
  else
    echo "warning: signed but not notarised; macOS will still warn users about this download" >&2
  fi
else
  echo "warning: ad-hoc signed and not notarised; users must approve the app by hand (see README)" >&2
fi

(cd dist && shasum -a 256 "Puffer-$version.dmg" > "Puffer-$version.dmg.sha256")
echo "Built $dmg"
cat "$dmg.sha256"
