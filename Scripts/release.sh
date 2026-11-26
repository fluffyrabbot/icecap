#!/bin/bash
# Builds a notarized release of icecap: build/icecap-<version>.dmg, the Sparkle feed
# build/appcast.xml and the cask build/icecap.rb.
# Usage: Scripts/release.sh [--publish]
#
# Requires APPLE_SIGNING_IDENTITY set to a "Developer ID Application" identity in the
# keychain and APPLE_NOTARY_PROFILE set to a stored notarytool keychain profile; without
# them it stops before building. It also stops unless the Sparkle key in the login
# keychain matches SUPublicEDKey in Resources/Info.plist. The version is
# CFBundleShortVersionString in Resources/Info.plist. For a disk image to test on this
# Mac, use Scripts/build-image.sh.
#
# --publish then tags the commit v<version> and creates the GitHub release with the disk
# image and appcast.xml, and commits the cask to fluffyrabbot/homebrew-tap as
# Casks/icecap.rb. Installed copies read the feed from the latest release, at the
# SUFeedURL in Resources/Info.plist. It requires a clean working tree and a commit
# already pushed.
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

swift package resolve
sparkle_tools="$repository/.build/artifacts/sparkle/Sparkle/bin"
committed_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
keychain_key="$("$sparkle_tools/generate_keys" -p)"
[[ "$keychain_key" == "$committed_key" ]] || {
  echo "the Sparkle key in the keychain ($keychain_key) is not SUPublicEDKey ($committed_key)" >&2
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

# Signed for Sparkle after stapling, which changes the image's bytes.
enclosure_signature="$("$sparkle_tools/sign_update" "$image")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
release_address="https://github.com/fluffyrabbot/icecap/releases"
cat > build/appcast.xml <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>icecap</title>
    <item>
      <title>icecap $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum_system</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$release_address/tag/$tag</sparkle:fullReleaseNotesLink>
      <enclosure url="$release_address/download/$tag/icecap-$version.dmg" $enclosure_signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
FEED
xmllint --noout build/appcast.xml

checksum="$(shasum -a 256 "$image" | cut -d ' ' -f 1)"
sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$checksum/" Packaging/icecap.rb > build/icecap.rb

if $publish; then
  git tag "$tag"
  git push origin "$tag"
  gh release create "$tag" "$image" build/appcast.xml --title "icecap $version" --generate-notes
  Scripts/publish-cask.sh "$version"
fi

echo "$image"
echo "$repository/build/appcast.xml"
echo "$repository/build/icecap.rb"
