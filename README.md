# icecap

A small menu bar organizer for macOS. It gathers the icons you choose into one group
behind a chevron. Click the chevron to show them in the menu bar, or, where they do not
fit, to list them and pick one to open its menu.

icecap is a clean-room implementation, MIT licensed. It is written from Apple's
documentation and from the observations in [docs/OBSERVATIONS.md](docs/OBSERVATIONS.md),
without reference to the source of Ice, Thaw, IceMelt or Bartender.

It requires macOS 26, and was built and verified on macOS 26.7.2.

## Install

Install it with Homebrew, which loads casks from a tap outside its own only once they are
trusted:

```bash
brew trust --cask fluffyrabbot/tap/icecap
```
```bash
brew install --cask fluffyrabbot/tap/icecap
```

Or download the disk image from the latest
[release](https://github.com/fluffyrabbot/icecap/releases/latest), or build it from source
with Swift 6.2 (Xcode or the Command Line Tools) and copy it to the Applications folder:

```bash
Scripts/build-app.sh
```
```bash
ditto build/icecap.app /Applications/icecap.app
```
```bash
open /Applications/icecap.app
```

icecap restarts itself from where it lies and opens at login from there, so it needs a
lasting place. Opened from a disk image, or from where it was downloaded, it offers to
move itself to the Applications folder, replacing any older copy there.

## Use

On first launch macOS asks for the Accessibility permission, which icecap needs to list
the hidden icons and open their menus. It needs no Screen Recording permission. Until the
permission is granted, nothing is hidden. Once it is granted, icecap places its chevron
just left of the system's icons, so every other application's icon starts in the group,
and shows the group beside a note on how to ⌘-drag icons out of it.

The bundle identifier changed from `io.github.fluffyrabbot.icecap` to
`com.memorysynchub.icecap`. macOS keys the Accessibility permission and the stored
settings on it, so a copy built before the change has to be granted the permission once
more, and the group's arrangement starts afresh. The stale entry under the old identifier
can be removed with `tccutil reset Accessibility io.github.fluffyrabbot.icecap`.

| Action | Effect |
|---|---|
| Click the chevron | Shows the group in the menu bar if it fits beside the front application's menus and any camera housing, and hides it again once the pointer has been out of the menu bar for a second with no menu open. Otherwise lists the hidden icons: pick one to show the group, open that icon's menu, and hide the group again once the menu closes. Click again to hide the group at once. |
| ⌥-click the chevron, or press ⌃⌥⌘Space in any application | Lists the hidden icons, whether or not the group fits. Press the shortcut again to close the list. |
| Type in the list | Narrows it to the icons whose names match. ↑ and ↓ move the selection, Return opens the selected icon's menu, Escape clears the filter and then closes the list. |
| Right-click the chevron | Always show the group where it fits, list hidden icons, arrange icons, choose the keyboard shortcut (⌃⌥⌘Space, ⌃⌥⌘H, ⌃⌥⌘M or none), open at login, Accessibility settings, about icecap, check for updates, quit. |
| Show the group, then ⌘-drag an icon across the chevron | Moves the icon into or out of the group. |
| Choose Arrange Icons… | Shows the group beside a note on how to arrange it, until Done is clicked. The note also opens by itself when icecap first places the chevron. |
| Choose Always Show Where It Fits | Keeps the group shown whenever it fits, and hides it where it does not, until the item is chosen again or the chevron is clicked while the group is shown. |
| ⌘-drag the chevron | Moves the group's boundary. The spacer follows within a second. |

## How it works

icecap shows two status items. The **divider** is the chevron. The **spacer** is an
invisible item kept immediately left of it. To hide the group, the spacer widens to
5,000 points and pushes every icon to its left beyond the display's left edge. To show
the group, it shrinks to nothing. macOS 26 does not draw a status item that extends past
the display, which is why the visible chevron needs an item of its own.

The spacer belongs to a helper, `icecap-spacer`, in `Contents/Helpers`. The system orders
status items by the preferred position each process records for them, the smallest at
the right, so icecap starts the helper with the divider's position plus 0.5. icecap sends
`hide` and `show` on the helper's standard input, and the helper answers `placed` once
its item has settled. When the divider is ⌘-dragged, icecap ends the helper and starts
another at the new position: macOS does not reliably place a status item added again
within a process that has seen a drag, but places one from a new process correctly (see
[docs/OBSERVATIONS.md](docs/OBSERVATIONS.md)). The helper ends when its input closes,
so it ends with icecap however icecap ends.

On a click, icecap measures the group from the icons' Accessibility frames, which keep
their widths and spacing while pushed off the display. The group fits if it would end at
least 8 points right of the front application's last menu title and, on a display with a
camera housing, right of the housing (`NSScreen.auxiliaryTopRightArea`). A click that
finds room starts a peek. Five times a second icecap checks where the pointer is, and
the peek ends once the pointer has stayed out of the menu bar for a second (three, if
the peek began away from it, as from the panel) while no menu is open. A menu counts
as open while any pop-up menu is on screen, or a raised window of one of the group's
applications begins just below the top of a display, as a popover does.

With Always Show Where It Fits chosen, icecap checks the fit again when another
application comes to the front, when one starts or ends, when the displays change, and
every second, which catches the active menu bar moving to another display. It hides the
group where it no longer fits and shows it again where it does. The group's width is
measured only while it is hidden, because the icons that do not fit on a narrow display
are not laid out.

The panel lists the group's icons from the Accessibility API (`AXExtrasMenuBar`), by
application icon and name; icons of one application that share a name are numbered
from left to right. Choosing one shrinks the spacer and waits until the icon lies
on a display, then presses it with `AXPress`. icecap then watches the window list for
the icon's menu and hides the group once the menu has closed.

The panel takes key status without activating icecap, so the application in front keeps
its menus while the list is open. The keyboard shortcut is registered with Carbon's
`RegisterEventHotKey`, which needs no permission; if another application holds the same
shortcut, the Keyboard Shortcut submenu says so.

The pure logic (grouping, placement, menu detection, the reveal and peek sessions, the
panel's filter) is in
`Sources/IcecapCore` and is unit tested. The AppKit application is in `Sources/Icecap`.

## Updates

icecap updates itself with [Sparkle](https://sparkle-project.org). On its second launch
Sparkle asks whether to check for updates automatically; Check for Updates… in the
context menu checks at once. The feed is `appcast.xml` in the latest GitHub release,
and every update is signed with the EdDSA key whose public half is `SUPublicEDKey` in
`Resources/Info.plist`. icecap has no Dock icon, so an update found by an automatic check
does not open a window: a dot appears beside the chevron, and the context menu offers
Install Update….

## Limitations

- One group, shown or hidden on every display at once. Always shown where it fits, it
  follows the display whose menu bar is active, and the other displays show the same.
- Icons in the panel show their application's icon, not their live picture,
  because the system will not capture an icon that has been pushed off the display.
- The group shows for about a second while the spacer's helper restarts after the
  chevron is dragged. If the helper restarts more than three times in a minute, icecap
  stops and leaves the group shown; dragging the chevron again tries once more. icecap notices the
  drag by the change in its recorded position, and macOS rewrites that when other icons
  are dragged, so arranging other icons may also restart the helper once.
- The Accessibility API reports icon positions for the display whose menu bar is active.

## Development

```bash
swift test
```
```bash
Scripts/build-app.sh debug
```

`Scripts/build-app.sh` signs with `APPLE_SIGNING_IDENTITY` when set, otherwise with the
first "Apple Development" identity in the keychain; with neither it stops. It never signs
ad hoc: a stable identity keeps the Accessibility permission across rebuilds, and an ad
hoc signature would lose it on every build. It copies `Sparkle.framework`, which Swift
Package Manager fetches, into the bundle's `Frameworks` and signs Sparkle's nested code
before the bundle.

icecap writes its log under the subsystem `com.memorysynchub.icecap`:

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "com.memorysynchub.icecap"'
```

## Release

`Scripts/build-image.sh` builds a universal, hardened-runtime `build/icecap.app` and the
disk image `build/icecap-<version>.dmg`, both signed with the identity `Scripts/build-app.sh`
chooses. The image is not notarized, so with a development identity it opens on this Mac
only. The version is `CFBundleShortVersionString` in `Resources/Info.plist`; the build
number is the commit count.

`Scripts/release.sh` makes the disk image for other Macs. It stops before building unless
`APPLE_SIGNING_IDENTITY` names a "Developer ID Application" identity,
`APPLE_NOTARY_PROFILE` names a stored notarytool profile, and the Sparkle private key in
the login keychain, where Sparkle's `generate_keys` stores it, matches `SUPublicEDKey`:

```bash
export APPLE_TEAM_ID=<team-id>
export APPLE_SIGNING_IDENTITY="Developer ID Application: <name> (<team-id>)"
export APPLE_NOTARY_PROFILE=memorysynchub
```

The profile is stored once, from an App Store Connect API key:

```bash
xcrun notarytool store-credentials memorysynchub --key <path to AuthKey_<key-id>.p8> --key-id <key-id> --issuer <issuer-id>
```

The script builds and signs the bundle and the disk image, notarizes and staples the
image, checks both with `spctl`, signs the stapled image for Sparkle with `sign_update`,
writes the feed `build/appcast.xml`, and writes the Homebrew cask `build/icecap.rb` from
`Packaging/icecap.rb`. From a clean, pushed `main`,

```bash
Scripts/release.sh --publish
```

also tags the commit `v<version>` and creates the GitHub release with the disk image and
`appcast.xml`, which installed copies read from the latest release. It then runs
`Scripts/publish-cask.sh`, which commits `build/icecap.rb` to
[fluffyrabbot/homebrew-tap](https://github.com/fluffyrabbot/homebrew-tap) as
`Casks/icecap.rb` through the GitHub API. Raise
`CFBundleShortVersionString` before each release; Sparkle compares the build numbers.

The icon is drawn by `swift Scripts/draw-icon.swift`, which writes `Resources/AppIcon.icns`.
