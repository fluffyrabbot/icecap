#!/bin/bash
# Builds a release of icecap: build/icecap-<version>.dmg and the cask build/icecap.rb.
# Usage: Scripts/release.sh [--publish]
#
# The version is CFBundleShortVersionString in Resources/Info.plist. The disk image is
# notarized and stapled when ICECAP_SIGN_IDENTITY names a "Developer ID Application"
# identity; ICECAP_NOTARY_PROFILE then names the keychain profile stored once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# Any other identity gives a disk image for testing, which Gatekeeper will refuse on
# another Mac.
#
# --publish tags the commit v<version> and creates the GitHub release with the disk image.
# It requires a notarized image, a clean working tree, and a commit already pushed.
set -euo pipefail

publish=false
case "${1:-}" in
  "") ;;
  --publish) publish=true ;;
  *) echo "usage: $0 [--publish]" >&2; exit 64 ;;
esac

repository="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
tag="v$version"
identity="${ICECAP_SIGN_IDENTITY:-}"
notarizes=false
[[ "$identity" == "Developer ID Application:"* ]] && notarizes=true

if $publish; then
  $notarizes || { echo "--publish needs ICECAP_SIGN_IDENTITY set to a Developer ID Application identity" >&2; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "--publish needs a clean working tree" >&2; exit 1; }
  git fetch --quiet origin
  [[ -n "$(git branch --remotes --contains HEAD)" ]] || { echo "--publish needs HEAD pushed to origin" >&2; exit 1; }
  ! git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || { echo "tag $tag already exists" >&2; exit 1; }
fi

Scripts/build-app.sh release

image="$repository/build/icecap-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto build/icecap.app "$staging/icecap.app"
ln -s /Applications "$staging/Applications"
rm -f "$image"
hdiutil create -quiet -volname icecap -srcfolder "$staging" -format UDZO -fs HFS+ "$image"

if $notarizes; then
  : "${ICECAP_NOTARY_PROFILE:?set ICECAP_NOTARY_PROFILE to a notarytool keychain profile}"
  codesign --sign "$identity" --timestamp "$image"
  xcrun notarytool submit "$image" --keychain-profile "$ICECAP_NOTARY_PROFILE" --wait
  xcrun stapler staple "$image"
  spctl --assess --type open --context context:primary-signature --verbose "$image"
else
  echo "warning: not notarized; ICECAP_SIGN_IDENTITY is not a Developer ID Application identity" >&2
fi

checksum="$(shasum -a 256 "$image" | cut -d ' ' -f 1)"
sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$checksum/" Packaging/icecap.rb > build/icecap.rb

if $publish; then
  git tag "$tag"
  git push origin "$tag"
  gh release create "$tag" "$image" --title "icecap $version" --generate-notes
  echo "Copy build/icecap.rb to Casks/icecap.rb in fluffyrabbot/homebrew-tap and push it."
fi

echo "$image"
echo "$repository/build/icecap.rb"
