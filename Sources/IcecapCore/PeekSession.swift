import Foundation

/// The life of one peek: the group is shown on request and hidden again once the pointer
/// has stayed away from the menu bar for a moment while no menu is open.
public struct PeekSession: Equatable, Sendable {
    /// How long the pointer may take to reach the menu bar when the peek starts away from
    /// it, as when it is started from the panel.
    public static let arrivalAllowance: TimeInterval = 3
    /// How long the pointer may stay away from the menu bar, while no menu is open, before
    /// the peek ends.
    public static let departureLimit: TimeInterval = 1

    public let startTime: TimeInterval
    /// When the pointer was last in the menu bar or a menu was last open.
    private var lastPresenceTime: TimeInterval?
    public private(set) var isFinished = false

    public init(startTime: TimeInterval) {
        self.startTime = startTime
    }

    /// Records one observation and returns whether the peek has ended. Once ended, it
    /// stays ended.
    ///
    /// - Parameters:
    ///   - isPointerPresent: Whether the pointer is in the menu bar, or over icecap's panel.
    ///   - isMenuOpen: Whether a menu or popover is open, which may be one of the group's.
    @discardableResult
    public mutating func observe(isPointerPresent: Bool, isMenuOpen: Bool, time: TimeInterval) -> Bool {
        guard !isFinished else { return true }
        if isPointerPresent || isMenuOpen {
            lastPresenceTime = time
            return false
        }
        let deadline = lastPresenceTime.map { $0 + Self.departureLimit } ?? startTime + Self.arrivalAllowance
        isFinished = time >= deadline
        return isFinished
    }
}

extension MenuDetection {
    /// How far below a display's top edge a window of a group icon's owner may begin and
    /// still count as that icon's menu or popover.
    public static let popoverTopLimit: CGFloat = 88

    /// Whether any menu or popover is open: a pop-up menu window of any process, or a
    /// window above the normal layer, other than the menu bar and status items, that
    /// belongs to one of the given processes and begins just below a display's top edge.
    ///
    /// Windows on the normal layer are left out, so that an owner's ordinary window
    /// placed at the top of the display does not count as a popover.
    public static func isAnyMenuOpen(
        windows: [WindowDescription],
        processIdentifiers: Set<Int32>,
        displays: [CGRect]
    ) -> Bool {
        windows.contains { window in
            guard window.frame.width > 0, window.frame.height > 0 else { return false }
            if window.layer == popUpMenuLayer { return true }
            return window.layer > 0
                && window.layer != menuBarLayer
                && window.layer != statusLayer
                && processIdentifiers.contains(window.processIdentifier)
                && displays.contains { display in
                    display.intersects(window.frame)
                        && window.frame.minY >= display.minY
                        && window.frame.minY - display.minY <= popoverTopLimit
                }
        }
    }
}
