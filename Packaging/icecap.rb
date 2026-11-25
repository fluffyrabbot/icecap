# The Homebrew cask for icecap. Scripts/release.sh writes build/icecap.rb from this file,
# with the version and checksum filled in, for the tap at fluffyrabbot/homebrew-tap.
cask "icecap" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/fluffyrabbot/icecap/releases/download/v#{version}/icecap-#{version}.dmg"
  name "icecap"
  desc "Menu bar organizer that groups icons behind a chevron"
  homepage "https://github.com/fluffyrabbot/icecap"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "icecap.app"

  uninstall quit: "com.memorysynchub.icecap"

  zap trash: "~/Library/Preferences/com.memorysynchub.icecap.plist"
end
