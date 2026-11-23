import Foundation

/// The life of one reveal: the group is shown so that one icon can be pressed, and is
/// hidden again once the menu that the press opened has closed.
public struct RevealSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The icon was pressed and no menu has been seen yet.
        case awaitingMenu
        /// A menu attached to the icon is open.
        case menuOpen
        /// The menu closed, or none appeared in time; the group may be hidden again.
        case finished
    }

    /// How long to wait for a menu before concluding that the press opened none.
    public static let menuWaitLimit: TimeInterval = 3

    /// How many observations in a row must find the menu closed before it counts as
    /// closed. An owner may replace its menu window while the menu stays open, and one
    /// observation can fall between the two windows.
    public static let closedObservationsRequired = 2

    private var closedObservations = 0

    public private(set) var phase: Phase = .awaitingMenu
    public let startTime: TimeInterval

    public init(startTime: TimeInterval) {
        self.startTime = startTime
    }

    /// Advances the session by one observation of whether the menu is open.
    @discardableResult
    public mutating func observe(isMenuOpen: Bool, time: TimeInterval) -> Phase {
        switch phase {
        case .awaitingMenu:
            if isMenuOpen {
                phase = .menuOpen
            } else if time - startTime >= Self.menuWaitLimit {
                phase = .finished
            }
        case .menuOpen:
            closedObservations = isMenuOpen ? 0 : closedObservations + 1
            if closedObservations >= Self.closedObservationsRequired { phase = .finished }
        case .finished:
            break
        }
        return phase
    }
}
