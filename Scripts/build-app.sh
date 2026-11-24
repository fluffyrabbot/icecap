#!/bin/bash
# Builds icecap.app into build/.
# Usage: Scripts/build-app.sh [debug|release]
# A release build is universal (arm64 and x86_64); a debug build is for this Mac only.
# The bundle is signed with ICECAP_SIGN_IDENTITY when set, else with the first
# "Apple Development" identity in the keychain, else ad hoc. A stable identity keeps the
# Accessibility permission across rebuilds; an ad hoc signature loses it on every build.
# Every signature uses the hardened runtime, which notarization requires; a Developer ID
# signature also carries a secure timestamp.
set -euo pipefail

configuration="${1:-release}"
repository="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository"

architectures=()
if [[ "$configuration" == "release" ]]; then
  architectures=(--arch arm64 --arch x86_64)
fi

swift build -c "$configuration" "${architectures[@]}" --product icecap
binary="$(swift build -c "$configuration" "${architectures[@]}" --show-bin-path)/icecap"

bundle="$repository/build/icecap.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/icecap"
cp "$repository/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$repository/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"

# The build number counts the commits, so that each release has a larger one.
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$bundle/Contents/Info.plist"

identity="${ICECAP_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
identity="${identity:--}"
signing_options=(--force --options runtime --sign "$identity" --identifier io.github.fluffyrabbot.icecap)
if [[ "$identity" == "Developer ID Application:"* ]]; then
  signing_options+=(--timestamp)
fi
codesign "${signing_options[@]}" "$bundle"
codesign --verify --strict "$bundle"
echo "$bundle"
