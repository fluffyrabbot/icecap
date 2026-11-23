# icecap

A small menu bar organizer for macOS. It gathers the icons you choose into one group
behind a chevron. Click the chevron to list them, and pick one to open its menu.

icecap is a clean-room implementation, MIT licensed. It is written from Apple's
documentation and from the observations in [docs/OBSERVATIONS.md](docs/OBSERVATIONS.md),
without reference to the source of Ice, Thaw, IceMelt or Bartender.

Built and verified on macOS 26.7.2. It declares macOS 14 as its minimum, but has not
been tried there.

## Use

```bash
Scripts/build-app.sh
open build/icecap.app
```

On first launch macOS asks for the Accessibility permission, which icecap needs to list
the hidden icons and open their menus. It needs no Screen Recording permission. Once the
permission is granted, icecap places its chevron just left of the system's icons, so
every other application's icon starts in the group.

| Action | Effect |
|---|---|
| Click the chevron | Lists the hidden icons. Pick one to show the group, open that icon's menu, and hide the group again once the menu closes. |
| ⌥-click the chevron | Shows or hides the group in the menu bar. |
| Right-click the chevron | Show or hide icons, open at login, Accessibility settings, quit. |
| Show the group, then ⌘-drag an icon across the chevron | Moves the icon into or out of the group. |
| ⌘-drag the chevron | Moves the group's boundary. icecap restarts once to follow it. |

## How it works

icecap adds two status items. The **divider** is the chevron. The **spacer** is an
invisible item kept immediately left of it. To hide the group, the spacer widens to
5,000 points and pushes every icon to its left beyond the display's left edge. To show
the group, it shrinks to nothing. macOS 26 does not draw a status item that extends past
the display, which is why the visible chevron needs an item of its own.

The panel lists the group's icons from the Accessibility API (`AXExtrasMenuBar`), by
application icon and name. Choosing one shrinks the spacer and waits until the icon
lies on a display, then presses it with `AXPress`. icecap then watches the window list
for the icon's menu and hides the group once the menu has closed.

The pure logic (grouping, placement, menu detection, the reveal session) is in
`Sources/IcecapCore` and is unit tested. The AppKit application is in `Sources/Icecap`.

## Limitations

- One group. Icons in the panel show their application's icon, not their live picture,
  because the system will not capture an icon that has been pushed off the display.
- macOS does not reliably place a status item added again within a running process, so
  icecap restarts itself to move the spacer after the chevron is dragged. If it restarts
  more than three times in a minute, it stops and leaves the group shown. It notices the
  drag by the change in its recorded positions, and macOS rewrites those for several
  icons when any icon is dragged, so arranging other icons may also cause one restart.
- The Accessibility API reports icon positions for the display whose menu bar is active.

## Development

```bash
swift test
```
```bash
Scripts/build-app.sh debug
```

`Scripts/build-app.sh` signs with `ICECAP_SIGN_IDENTITY` when set, otherwise with the
first "Apple Development" identity in the keychain, otherwise ad hoc. A stable identity
keeps the Accessibility permission across rebuilds. An ad hoc signature loses it on
every build.

icecap writes its log under the subsystem `io.github.fluffyrabbot.icecap`:

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "io.github.fluffyrabbot.icecap"'
```
