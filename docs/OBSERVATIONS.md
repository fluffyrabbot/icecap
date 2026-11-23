# Observations of the macOS 26 menu bar

icecap is a clean-room implementation. Its design rests on Apple's public documentation
and on the observations below, made on 2026-11-23 on macOS 26.7.2 (25G320), on a
MacBook Pro with a notch and two external displays. Nobody working on icecap read the
source of Ice, Thaw, IceMelt, Bartender or any other menu bar manager. Small probe
programs, written for the purpose and not kept, made each observation. The window list
came from `CGWindowListCopyWindowInfo`, the icons from the Accessibility API, and
pictures from `screencapture`.

## Status item windows

- The window server lists every status item as a window on layer 25 owned by Control
  Center, not by the application that created the item. The window's name is often the
  owner's bundle identifier, but it varies per display (`Item-0`, `Clock`, the autosave
  name, a process identifier).
- Each display's menu bar has its own copy of every status item window.
- Icons that do not fit, such as those behind the notch, keep their windows but are
  marked as not on screen.
- A status item's window is capped at about 5,000 points wide; a requested length of
  6,000 or 10,000 gave a 5,016-point window.
- A status item whose window extends past the edge of the display is not drawn at all.
  A chevron drawn at the right end of a wide status item did not appear, while the same
  item at 24 points showed it.
- ScreenCaptureKit captured status item windows that were on screen. Windows pushed off
  the display captured as fully transparent images.

## Placement

- A status item's place is governed by `NSStatusItem Preferred Position <autosave name>`
  in the owning application's defaults. The system orders the icons by these values,
  the smallest at the right. The values approximately equal the distance in points from
  the icon's right edge to the display's right edge.
- An item that is already wide when added lands at the far left. One added narrow and
  widened later keeps its place.
- A wide item pushes every icon to its left beyond the display's left edge. Icons to its
  right, and the front application's own menus, are unaffected: hit tests at the
  application's menu titles still found its menu bar items.
- Dragging an icon with ⌘ rewrites the preferred positions of several items, not only
  the dragged one, and records the new value in the owner's defaults. Status item
  windows post no `NSWindow.didMoveNotification` when this happens.
- Within a process that has seen a drag, a status item added again (even under a new
  autosave name) was not reliably placed at its recorded preferred position. A new
  process placed the same item correctly.

## Accessibility

- Each application's `AXExtrasMenuBar` attribute lists its status items, with position,
  size, description and the `AXPress` action. Positions are reported for the display
  whose menu bar is active.
- `AXPress` opens an icon's menu even while the icon is pushed off the display, but the
  menu then appears off the display too. Some owners open the menu and still return
  `kAXErrorCannotComplete`.
- An icon's position, read through an element kept from an earlier query, can stay stale
  after the window server has moved the icon.

## Menus

- A status item's menu is a window on layer 101 owned by the item's application, its
  top edge a few points below the icon.
- An open menu's window can be missing from one listing of on-screen windows while the
  menu stays open.
