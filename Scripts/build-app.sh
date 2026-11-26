#!/bin/bash
# Builds icecap.app into build/, with the icecap-spacer helper in Contents/Helpers.
# Usage: Scripts/build-app.sh [debug|release]
# A release build is universal (arm64 and x86_64); a debug build is for this Mac only.
# The bundle is signed with APPLE_SIGNING_IDENTITY when set, else with the first
# "Apple Development" identity in the keychain; with neither, the build stops. A stable
# identity keeps the Accessibility permission across rebuilds. Every signature uses the
# hardened runtime, which notarization requires; a Developer ID signature also carries a
# secure timestamp.
set -euo pipefail

configuration="${1:-release}"
repository="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository"

identities="$(security find-identity -v -p codesigning)"
identity="${APPLE_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' <<<"$identities" | head -n 1)"
  [[ -n "$identity" ]] || {
    echo "no \"Apple Development\" identity in the keychain; set APPLE_SIGNING_IDENTITY to a code signing identity" >&2
    exit 1
  }
fi
grep -qF "\"$identity\"" <<<"$identities" || {
  echo "APPLE_SIGNING_IDENTITY \"$identity\" is not a valid code signing identity in the keychain" >&2
  exit 1
}

architectures=()
if [[ "$configuration" == "release" ]]; then
  architectures=(--arch arm64 --arch x86_64)
fi

swift build -c "$configuration" ${architectures[@]+"${architectures[@]}"} --product icecap
swift build -c "$configuration" ${architectures[@]+"${architectures[@]}"} --product icecap-spacer
products="$(swift build -c "$configuration" ${architectures[@]+"${architectures[@]}"} --show-bin-path)"
binary="$products/icecap"

bundle="$repository/build/icecap.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Frameworks"
cp "$binary" "$bundle/Contents/MacOS/icecap"
# The executable finds Sparkle through its rpath, @executable_path/../Frameworks.
ditto "$(dirname "$binary")/Sparkle.framework" "$bundle/Contents/Frameworks/Sparkle.framework"
cp "$repository/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$repository/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
helper="$bundle/Contents/Helpers/icecap-spacer.app"
mkdir -p "$helper/Contents/MacOS"
cp "$products/icecap-spacer" "$helper/Contents/MacOS/icecap-spacer"
cp "$repository/Resources/SpacerInfo.plist" "$helper/Contents/Info.plist"

# The build number counts the commits, so that each release has a larger one. The helper
# carries the same version and build number as icecap.
build_number="$(git rev-list --count HEAD)"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$bundle/Contents/Info.plist")"
for plist in "$bundle/Contents/Info.plist" "$helper/Contents/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
done

signing_options=(--force --options runtime --sign "$identity")
if [[ "$identity" == "Developer ID Application:"* ]]; then
  signing_options+=(--timestamp)
fi
# Nested code is signed innermost first, the bundle last (fluffyfleet docs/APPLE-SIGNING.md).
sparkle="$bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${signing_options[@]}" "$sparkle/XPCServices/Installer.xpc"
codesign "${signing_options[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
codesign "${signing_options[@]}" "$sparkle/Autoupdate"
codesign "${signing_options[@]}" "$sparkle/Updater.app"
codesign "${signing_options[@]}" "$bundle/Contents/Frameworks/Sparkle.framework"
codesign "${signing_options[@]}" "$helper"
codesign "${signing_options[@]}" "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"
echo "$bundle"
