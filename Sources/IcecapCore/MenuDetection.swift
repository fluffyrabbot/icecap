import CoreGraphics

/// A window as the window server lists it, in global coordinates with a top-left origin.
public struct WindowDescription: Equatable, Sendable {
    public var processIdentifier: Int32
    public var layer: Int
    public var frame: CGRect

    public init(processIdentifier: Int32, layer: Int, frame: CGRect) {
        self.processIdentifier = processIdentifier
        self.layer = layer
        self.frame = frame
    }
}

public enum MenuDetection {
    /// The window layer of the menu bar itself.
    public static let menuBarLayer = 24
    /// The window layer of status items.
    public static let statusLayer = 25
    /// The window layer of pop-up menus, where a status item's menu appears.
    public static let popUpMenuLayer = 101
    /// How far below the icon a menu or popover may begin and still count as the icon's.
    public static let verticalTolerance: CGFloat = 48
    /// How far beside the icon a menu or popover may lie and still count as the icon's.
    public static let horizontalTolerance: CGFloat = 64

    /// Whether the icon's owner shows a menu or popover: a pop-up menu window of the
    /// owning process anywhere, or another window of it, other than the menu bar and
    /// status items, whose top edge lies just below the icon and which overlaps it
    /// horizontally.
    ///
    /// A pop-up menu counts wherever it lies because the Accessibility API at times
    /// reports a stale frame for a status item, against which a real menu would not line up.
    public static func isMenuOpen(
        windows: [WindowDescription],
        ownerProcessIdentifier: Int32,
        itemFrame: CGRect
    ) -> Bool {
        windows.contains { window in
            guard
                window.processIdentifier == ownerProcessIdentifier,
                window.frame.width > 0,
                window.frame.height > 0
            else { return false }
            if window.layer == popUpMenuLayer { return true }
            return window.layer != menuBarLayer
                && window.layer != statusLayer
                && window.frame.minY >= itemFrame.minY
                && window.frame.minY - itemFrame.maxY <= verticalTolerance
                && window.frame.minX <= itemFrame.maxX + horizontalTolerance
                && window.frame.maxX >= itemFrame.minX - horizontalTolerance
        }
    }

    /// Whether the frame lies wholly within one of the displays.
    public static func isWithinDisplay(_ frame: CGRect, displays: [CGRect]) -> Bool {
        frame.width > 0 && displays.contains { $0.contains(frame) }
    }
}
