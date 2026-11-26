#!/bin/bash
# Commits build/icecap.rb to the tap fluffyrabbot/homebrew-tap as Casks/icecap.rb, through
# the GitHub API, with the name and email git uses in this repository.
# Usage: Scripts/publish-cask.sh <version>
# Scripts/release.sh --publish runs it after creating the release.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <version>" >&2; exit 64; }
version="$1"
repository="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository"

cask="build/icecap.rb"
grep -qF "version \"$version\"" "$cask" || { echo "$cask is not the cask for $version" >&2; exit 1; }
address="repos/fluffyrabbot/homebrew-tap/contents/Casks/icecap.rb"
current="$(gh api "$address" --jq .sha)"
gh api --method PUT "$address" \
  -f message="Update icecap to $version" \
  -f content="$(base64 -i "$cask")" \
  -f sha="$current" \
  -f "committer[name]=$(git config user.name)" \
  -f "committer[email]=$(git config user.email)" \
  --jq .commit.html_url
