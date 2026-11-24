import CoreGraphics

/// The geometry of the divider and its spacer.
///
/// The divider is an ordinary narrow status item that shows a chevron. The spacer is an
/// invisible status item kept immediately left of the divider; while hiding, it becomes
/// wide enough to push every icon to its left beyond the display's left edge. Two items
/// are needed because macOS 26 draws nothing of a status item whose window extends past
/// the display, so a wide item cannot also show the chevron.
public enum Divider {
    /// The width of the spacer while it hides icons: wider than the menu bar of any
    /// display. macOS 26 clips a status item's window at about 5,000 points.
    public static let spacerHidingLength: CGFloat = 5_000

    /// The width of the spacer while the icons to its left are shown.
    public static let spacerShowingLength: CGFloat = 0

    /// How far, in points, an icon's right edge may extend past the divider's left edge
    /// while the icon still counts as left of the divider.
    public static let boundaryTolerance: CGFloat = 2

    /// The icons that belong to the group: those laid out on the divider's row whose
    /// right edge lies at or left of the divider's left edge, ordered left to right.
    public static func groupItems(
        _ items: [MenuBarItem],
        dividerFrame: CGRect,
        excludingProcess processIdentifier: Int32
    ) -> [MenuBarItem] {
        items
            .filter { item in
                item.processIdentifier != processIdentifier
                    && item.isLaidOut
                    && isOnSameRow(item.frame, dividerFrame)
                    && item.frame.maxX <= dividerFrame.minX + boundaryTolerance
            }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The amount by which the spacer's preferred position exceeds the divider's.
    /// Observed preferred positions are whole numbers, so no other icon can come between.
    public static let spacerPositionOffset: CGFloat = 0.5

    /// The preferred position that keeps the spacer immediately left of the divider.
    ///
    /// The system orders status items by their preferred positions, the smallest at the
    /// right, and records a new position whenever an item is dragged with ⌘.
    public static func spacerPreferredPosition(dividerPreferredPosition: CGFloat) -> CGFloat {
        dividerPreferredPosition + spacerPositionOffset
    }

    /// Whether the spacer's recorded preferred position still places it immediately left
    /// of the divider. A person who drags the divider with ⌘ changes the divider's.
    public static func isSpacerBesideDivider(
        spacerPreferredPosition: CGFloat,
        dividerPreferredPosition: CGFloat
    ) -> Bool {
        abs(spacerPreferredPosition - Self.spacerPreferredPosition(dividerPreferredPosition: dividerPreferredPosition)) < 0.01
    }

    /// The preferred position to give the divider on first launch: immediately left of
    /// the leftmost icon that belongs to the system, so that every other application's
    /// icon starts in the group.
    ///
    /// Preferred positions order the icons and approximately equal the distance from an
    /// icon's right edge to the display's right edge, so the distance stands in for the
    /// system icon's own preferred position, which only its owner records.
    public static func initialPreferredPosition(
        items: [MenuBarItem],
        displayMaxX: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        let systemItems = items.filter { item in
            item.isLaidOut && (item.bundleIdentifier?.hasPrefix("com.apple.") ?? false)
        }
        guard let leftmost = systemItems.min(by: { $0.frame.minX < $1.frame.minX }) else {
            return fallback
        }
        let distance = displayMaxX - leftmost.frame.minX
        guard distance > 1 else { return fallback }
        return distance - 1
    }

    /// The clearance, in points, that the shown group must keep from whatever bounds the
    /// status area on its left.
    public static let expansionClearance: CGFloat = 8

    /// The width of the group once shown: from its leftmost icon's left edge to its
    /// rightmost icon's right edge. The icons keep their spacing while pushed off the
    /// display, so the width is the same hidden or shown.
    public static func groupWidth(_ group: [MenuBarItem]) -> CGFloat {
        guard
            let minX = group.map(\.frame.minX).min(),
            let maxX = group.map(\.frame.maxX).max()
        else { return 0 }
        return maxX - minX
    }

    /// The right edge of whatever bounds the status area on the left of a display's menu
    /// bar: the front application's menu titles, the camera housing, or the display's
    /// own left edge, whichever lies furthest right.
    ///
    /// - Parameters:
    ///   - displayFrame: The display's bounds in global coordinates.
    ///   - menuTitleFrames: The frames of the front application's menu titles. Those not
    ///     on this display are ignored.
    ///   - unobscuredTopRightWidth: The width of the menu bar right of the camera housing,
    ///     on a display that has one.
    public static func statusAreaMinX(
        displayFrame: CGRect,
        menuTitleFrames: [CGRect],
        unobscuredTopRightWidth: CGFloat?
    ) -> CGFloat {
        var minX = displayFrame.minX
        if let unobscuredTopRightWidth {
            minX = max(minX, displayFrame.maxX - unobscuredTopRightWidth)
        }
        for frame in menuTitleFrames where frame.width > 0 && displayFrame.intersects(frame) {
            minX = max(minX, frame.maxX)
        }
        return minX
    }

    /// Whether a group of the given width, once shown, lies wholly between the status
    /// area's left bound and the divider. An empty group does not fit: there is nothing
    /// to show.
    ///
    /// Measure the width while the group is hidden. Shown on a display too narrow for it,
    /// the icons that do not fit are not laid out, and the group measures narrower than
    /// it is.
    public static func groupFits(width: CGFloat, dividerFrame: CGRect, statusAreaMinX: CGFloat) -> Bool {
        guard width > 0 else { return false }
        return dividerFrame.minX - width - expansionClearance >= statusAreaMinX
    }

    static func isOnSameRow(_ frame: CGRect, _ dividerFrame: CGRect) -> Bool {
        abs(frame.midY - dividerFrame.midY) < max(dividerFrame.height, 12)
    }
}
