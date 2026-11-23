#!/bin/bash
# Builds icecap.app into build/.
# Usage: Scripts/build-app.sh [debug|release]
# The bundle is signed with ICECAP_SIGN_IDENTITY when set, else with the first
# "Apple Development" identity in the keychain, else ad hoc. A stable identity keeps the
# Accessibility permission across rebuilds; an ad hoc signature loses it on every build.
set -euo pipefail

configuration="${1:-release}"
repository="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository"

swift build -c "$configuration" --product icecap
binary="$(swift build -c "$configuration" --show-bin-path)/icecap"

bundle="$repository/build/icecap.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
cp "$binary" "$bundle/Contents/MacOS/icecap"
cp "$repository/Resources/Info.plist" "$bundle/Contents/Info.plist"

identity="${ICECAP_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
identity="${identity:--}"
codesign --force --sign "$identity" --identifier io.github.fluffyrabbot.icecap "$bundle"
codesign --verify --strict "$bundle"
echo "$bundle"
