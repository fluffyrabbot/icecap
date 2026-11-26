/// Whether the group is shown or hidden, derived from what the person chose to keep and
/// from the one activity, if any, that shows the group for now.
///
/// The choice to show the group always where it fits is kept across launches. An
/// activity shows the group until it ends: a peek, the arrangement note, or the press of
/// a hidden icon. Beginning an activity ends the one under way, and each activity is
/// identified by a ticket, so that work belonging to an activity that has been
/// superseded cannot end its successor.
public struct GroupVisibility: Equatable, Sendable {
    public enum Activity: Equatable, Sendable {
        /// The group is shown on request until the pointer leaves the menu bar while no
        /// menu is open; see `PeekSession`.
        case peeking
        /// The group is shown beside the note on how to arrange it, until the note closes.
        case arranging
        /// The group is shown so that one of its icons can be pressed, until the menu
        /// that the press opened closes; see `RevealSession`.
        case pressing
    }

    /// Identifies one activity from its beginning to its end.
    public struct Ticket: Hashable, Sendable {
        public let activity: Activity
        let number: UInt64
    }

    /// Whether the person chose to show the group whenever it fits on the display whose
    /// menu bar is active.
    public var alwaysShowsWhereItFits: Bool {
        didSet { if !alwaysShowsWhereItFits { fits = false } }
    }
    /// Whether the group fit when last checked. Checked only while the group is always
    /// shown where it fits.
    public var fits = false
    /// Whether icecap holds the Accessibility permission. Without it nothing hidden could
    /// be listed or opened, so the group is never hidden.
    public var isPermitted: Bool
    /// The activity under way, if any.
    public private(set) var current: Ticket?
    private var lastNumber: UInt64 = 0

    public init(alwaysShowsWhereItFits: Bool, isPermitted: Bool) {
        self.alwaysShowsWhereItFits = alwaysShowsWhereItFits
        self.isPermitted = isPermitted
    }

    public var activity: Activity? { current?.activity }

    /// Whether the group is shown because the person chose to show it where it fits, and
    /// it does.
    public var isShownWhereItFits: Bool { alwaysShowsWhereItFits && fits }

    /// Whether the group is shown, by an activity or by the person's choice.
    public var isShown: Bool { current != nil || isShownWhereItFits }

    /// Whether the spacer should hide the group.
    public var isHidden: Bool { isPermitted && !isShown }

    /// Begins the activity, ending the one under way.
    public mutating func begin(_ activity: Activity) -> Ticket {
        lastNumber += 1
        let ticket = Ticket(activity: activity, number: lastNumber)
        current = ticket
        return ticket
    }

    /// Whether the ticket's activity is still the one under way.
    public func isCurrent(_ ticket: Ticket) -> Bool { current == ticket }

    /// Ends the ticket's activity, if it is still the one under way, and returns whether
    /// it was.
    @discardableResult
    public mutating func end(_ ticket: Ticket) -> Bool {
        guard current == ticket else { return false }
        current = nil
        return true
    }

    /// Ends whatever activity is under way.
    public mutating func endActivity() {
        current = nil
    }
}
