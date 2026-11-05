#!/usr/bin/env bash
# Notarizes and staples dist/Herb's Terminal.app so it opens on any Mac without Gatekeeper warnings.
#
# First build it signed with a Developer ID Application certificate:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" script/build_and_run.sh --bundle
#
# Credentials, either:
#   NOTARY_PROFILE=name     a profile saved once with: xcrun notarytool store-credentials name
#   APPLE_ID, TEAM_ID and APP_PASSWORD (an app-specific password from account.apple.com)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/Herb's Terminal.app"
ZIP="$ROOT_DIR/dist/Herbs-Terminal-notarize.zip"

if codesign -dv "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
  echo "The app is signed ad hoc. Build it with SIGN_IDENTITY set to your Developer ID Application certificate first." >&2
  exit 1
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  CREDENTIALS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
  CREDENTIALS=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
else
  echo "Set NOTARY_PROFILE, or APPLE_ID, TEAM_ID and APP_PASSWORD." >&2
  exit 2
fi

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"
xcrun notarytool submit "$ZIP" "${CREDENTIALS[@]}" --wait
xcrun stapler staple "$APP_BUNDLE"
rm -f "$ZIP"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
