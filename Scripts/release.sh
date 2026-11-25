#!/bin/bash
# Builds a notarized release of icecap: build/icecap-<version>.dmg and the cask
# build/icecap.rb.
# Usage: Scripts/release.sh [--publish]
#
# Requires APPLE_SIGNING_IDENTITY set to a "Developer ID Application" identity in the
# keychain and APPLE_NOTARY_PROFILE set to a stored notarytool keychain profile; without
# them it stops before building. The version is CFBundleShortVersionString in
# Resources/Info.plist. For a disk image to test on this Mac, use Scripts/build-image.sh.
#
# --publish then tags the commit v<version> and creates the GitHub release with the disk
# image. It requires a clean working tree and a commit already pushed.
set -euo pipefail

publish=false
case "${1:-}" in
  "") ;;
  --publish) publish=true ;;
  *) echo "usage: $0 [--publish]" >&2; exit 64 ;;
esac

repository="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository"

identity="${APPLE_SIGNING_IDENTITY:-}"
[[ "$identity" == "Developer ID Application:"* ]] || {
  echo "a release needs APPLE_SIGNING_IDENTITY set to a \"Developer ID Application\" identity; it is \"$identity\"" >&2
  exit 1
}
profile="${APPLE_NOTARY_PROFILE:-}"
[[ -n "$profile" ]] || { echo "a release needs APPLE_NOTARY_PROFILE set to a notarytool keychain profile" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$profile" >/dev/null || {
  echo "APPLE_NOTARY_PROFILE \"$profile\" is not a usable notarytool keychain profile" >&2
  exit 1
}

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
tag="v$version"
if $publish; then
  [[ -z "$(git status --porcelain)" ]] || { echo "--publish needs a clean working tree" >&2; exit 1; }
  git fetch --quiet origin
  [[ -n "$(git branch --remotes --contains HEAD)" ]] || { echo "--publish needs HEAD pushed to origin" >&2; exit 1; }
  ! git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || { echo "tag $tag already exists" >&2; exit 1; }
fi

Scripts/build-image.sh

bundle="$repository/build/icecap.app"
image="$repository/build/icecap-$version.dmg"
xcrun notarytool submit "$image" --keychain-profile "$profile" --wait
xcrun stapler staple "$image"
spctl --assess --type open --context context:primary-signature --verbose "$image"
spctl --assess --type execute --verbose "$bundle"

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
