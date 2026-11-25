#!/bin/bash
# Builds the universal icecap.app and the disk image build/icecap-<version>.dmg from it,
# signed with the identity that signed the bundle (see Scripts/build-app.sh).
# The image is not notarized: signed with a development identity it opens on this Mac
# only. Scripts/release.sh notarizes it.
# Usage: Scripts/build-image.sh
set -euo pipefail

repository="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository"

Scripts/build-app.sh release

bundle="$repository/build/icecap.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
image="$repository/build/icecap-$version.dmg"
identity="$(codesign --display --verbose=2 "$bundle" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
[[ -n "$identity" ]] || { echo "$bundle carries no signing authority" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$bundle" "$staging/icecap.app"
ln -s /Applications "$staging/Applications"
rm -f "$image"
hdiutil create -quiet -volname icecap -srcfolder "$staging" -format UDZO -fs HFS+ "$image"

signing_options=(--sign "$identity")
if [[ "$identity" == "Developer ID Application:"* ]]; then
  signing_options+=(--timestamp)
fi
codesign "${signing_options[@]}" "$image"
codesign --verify --strict --verbose=2 "$image"
echo "$image"
