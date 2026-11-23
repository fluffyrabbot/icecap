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

    static func isOnSameRow(_ frame: CGRect, _ dividerFrame: CGRect) -> Bool {
        abs(frame.midY - dividerFrame.midY) < max(dividerFrame.height, 12)
    }
}
