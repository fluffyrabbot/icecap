import CoreGraphics
import Foundation

/// A cached measurement of whether the hidden group fits on the active display beside the
/// front application's menu titles and any camera housing, paired with the context under
/// which it remains valid.
///
/// The group's inventory (its width and owning processes) depends only on the group and its
/// spacer placement, so it survives front-application and active-display changes. The
/// boundary (the divider's frame and the status area's left edge) is keyed by display and
/// front application so a warm chevron click can decide between peeking and opening the
/// panel without waiting for Accessibility queries.
public struct MenuBarFit: Equatable, Sendable {
    /// How long a measured hidden-group inventory remains valid without refresh.
    public static let inventoryLifetime: TimeInterval = 90
    /// How long a measured display and menu-title boundary remains valid without refresh.
    public static let boundaryLifetime: TimeInterval = 30

    /// The hidden group's measured width and the processes that own its icons.
    public struct Inventory: Equatable, Sendable {
        public var width: CGFloat
        public var processIdentifiers: Set<Int32>
        public var spacerGeneration: SpacerLifecycle.Generation
        public var measuredAt: TimeInterval

        public init(
            width: CGFloat,
            processIdentifiers: Set<Int32>,
            spacerGeneration: SpacerLifecycle.Generation,
            measuredAt: TimeInterval
        ) {
            self.width = width
            self.processIdentifiers = processIdentifiers
            self.spacerGeneration = spacerGeneration
            self.measuredAt = measuredAt
        }
    }

    /// The status area's bounds on one display while a specific application is in front.
    public struct Boundary: Equatable, Sendable {
        public var displayIdentifier: CGDirectDisplayID
        public var frontApplicationProcessIdentifier: Int32
        public var dividerFrame: CGRect
        public var statusAreaMinX: CGFloat
        public var spacerGeneration: SpacerLifecycle.Generation
        public var measuredAt: TimeInterval

        public init(
            displayIdentifier: CGDirectDisplayID,
            frontApplicationProcessIdentifier: Int32,
            dividerFrame: CGRect,
            statusAreaMinX: CGFloat,
            spacerGeneration: SpacerLifecycle.Generation,
            measuredAt: TimeInterval
        ) {
            self.displayIdentifier = displayIdentifier
            self.frontApplicationProcessIdentifier = frontApplicationProcessIdentifier
            self.dividerFrame = dividerFrame
            self.statusAreaMinX = statusAreaMinX
            self.spacerGeneration = spacerGeneration
            self.measuredAt = measuredAt
        }
    }

    /// The current display, front application, and placed spacer generation used to
    /// validate cached snapshots.
    public struct Context: Equatable, Sendable {
        public var displayIdentifier: CGDirectDisplayID?
        public var frontApplicationProcessIdentifier: Int32?
        public var spacerGeneration: SpacerLifecycle.Generation?

        public init(
            displayIdentifier: CGDirectDisplayID?,
            frontApplicationProcessIdentifier: Int32?,
            spacerGeneration: SpacerLifecycle.Generation?
        ) {
            self.displayIdentifier = displayIdentifier
            self.frontApplicationProcessIdentifier = frontApplicationProcessIdentifier
            self.spacerGeneration = spacerGeneration
        }
    }

    /// Whether the hidden group can be shown on the current display right now.
    public enum Decision: Equatable, Sendable {
        case fits(processIdentifiers: Set<Int32>)
        case doesNotFit
        case unknown
    }

    /// The action a primary click on the chevron should take immediately.
    public enum PrimaryClickPlan: Equatable, Sendable {
        case showNeedsAccessibility
        case closePanel
        case cancelPendingClick
        case endActivity
        case disableAlwaysShow
        case startPeek(processIdentifiers: Set<Int32>)
        case openPanel
        case refreshBoundaryThenRoute
        case refreshAllThenRoute
    }

    public private(set) var inventory: Inventory?
    public private(set) var boundary: Boundary?

    public init() {}

    /// Whether the cached inventory belongs to the current spacer generation and is still fresh.
    public func hasValidInventory(for context: Context, at time: TimeInterval) -> Bool {
        guard
            let inventory,
            let generation = context.spacerGeneration,
            inventory.spacerGeneration == generation,
            time >= inventory.measuredAt,
            time - inventory.measuredAt <= Self.inventoryLifetime
        else { return false }
        return true
    }

    /// Whether the cached boundary matches the current spacer generation, display, and
    /// front application, and is still fresh.
    public func hasValidBoundary(for context: Context, at time: TimeInterval) -> Bool {
        guard
            let boundary,
            let generation = context.spacerGeneration,
            let displayIdentifier = context.displayIdentifier,
            let frontApplicationProcessIdentifier = context.frontApplicationProcessIdentifier,
            boundary.spacerGeneration == generation,
            boundary.displayIdentifier == displayIdentifier,
            boundary.frontApplicationProcessIdentifier == frontApplicationProcessIdentifier,
            time >= boundary.measuredAt,
            time - boundary.measuredAt <= Self.boundaryLifetime
        else { return false }
        return true
    }

    /// Evaluates whether the hidden group fits under `context` at `time`, returning
    /// `.unknown` if either required measurement is missing or stale.
    public func decision(for context: Context, at time: TimeInterval) -> Decision {
        guard hasValidInventory(for: context, at: time), let inventory else {
            return .unknown
        }
        if inventory.width <= 0 {
            return .doesNotFit
        }
        guard hasValidBoundary(for: context, at: time), let boundary else {
            return .unknown
        }
        if Divider.groupFits(
            width: inventory.width,
            dividerFrame: boundary.dividerFrame,
            statusAreaMinX: boundary.statusAreaMinX
        ) {
            return .fits(processIdentifiers: inventory.processIdentifiers)
        }
        return .doesNotFit
    }

    /// Chooses the immediate action for a primary click on the chevron.
    public func primaryClickPlan(
        isPermitted: Bool,
        isPanelOpen: Bool,
        hasPendingClick: Bool,
        activity: GroupVisibility.Activity?,
        isShownWhereItFits: Bool,
        context: Context,
        at time: TimeInterval
    ) -> PrimaryClickPlan {
        if isPanelOpen { return .closePanel }
        if hasPendingClick { return .cancelPendingClick }
        if activity != nil { return .endActivity }
        if isShownWhereItFits { return .disableAlwaysShow }
        if !isPermitted { return .showNeedsAccessibility }

        switch decision(for: context, at: time) {
        case .fits(let processIdentifiers):
            return .startPeek(processIdentifiers: processIdentifiers)
        case .doesNotFit:
            return .openPanel
        case .unknown:
            return hasValidInventory(for: context, at: time)
                ? .refreshBoundaryThenRoute
                : .refreshAllThenRoute
        }
    }

    /// Records the hidden group's width and owning processes, rejecting samples captured
    /// while the menu bar is still moving icons off-screen.
    @discardableResult
    public mutating func recordHiddenGroup(
        _ group: [MenuBarItem],
        displays: [CGRect],
        spacerGeneration: SpacerLifecycle.Generation,
        at time: TimeInterval
    ) -> Bool {
        guard !displays.isEmpty, Divider.isGroupPushedOff(group, displays: displays) else {
            return false
        }
        inventory = Inventory(
            width: Divider.groupWidth(group),
            processIdentifiers: Set(group.map(\.processIdentifier)),
            spacerGeneration: spacerGeneration,
            measuredAt: time
        )
        return true
    }

    /// Updates an existing inventory for the same spacer generation while the group is shown,
    /// keeping the maximum observed width so icons clipped on narrow displays never shrink
    /// the stored width.
    public mutating func recordShownGroup(
        _ group: [MenuBarItem],
        spacerGeneration: SpacerLifecycle.Generation,
        at time: TimeInterval
    ) {
        guard var existing = inventory, existing.spacerGeneration == spacerGeneration else {
            return
        }
        existing.width = max(existing.width, Divider.groupWidth(group))
        existing.processIdentifiers.formUnion(group.map(\.processIdentifier))
        existing.measuredAt = time
        inventory = existing
    }

    /// Records a validated status-area boundary for one display and front application.
    public mutating func recordBoundary(
        displayIdentifier: CGDirectDisplayID,
        frontApplicationProcessIdentifier: Int32,
        dividerFrame: CGRect,
        statusAreaMinX: CGFloat,
        spacerGeneration: SpacerLifecycle.Generation,
        at time: TimeInterval
    ) {
        boundary = Boundary(
            displayIdentifier: displayIdentifier,
            frontApplicationProcessIdentifier: frontApplicationProcessIdentifier,
            dividerFrame: dividerFrame,
            statusAreaMinX: statusAreaMinX,
            spacerGeneration: spacerGeneration,
            measuredAt: time
        )
    }

    public mutating func invalidateBoundary() {
        boundary = nil
    }

    public mutating func invalidateInventory() {
        inventory = nil
    }

    public mutating func invalidateAll() {
        inventory = nil
        boundary = nil
    }

    /// Whether `processIdentifier` owns at least one icon in the cached group inventory.
    public func ownsGroupProcess(_ processIdentifier: Int32) -> Bool {
        inventory?.processIdentifiers.contains(processIdentifier) ?? false
    }
}

/// Tracks an in-flight primary chevron click that had to wait for an asynchronous refresh
/// before deciding between peeking and opening the panel, so a second click or other user
/// action cancels the pending route cleanly.
public struct PendingClickTracker: Equatable, Sendable {
    public struct Token: Hashable, Sendable {
        let number: UInt64
    }

    public private(set) var current: Token?
    private var lastNumber: UInt64 = 0

    public init() {}

    public var isPending: Bool { current != nil }

    /// Starts a new pending click, superseding any previous token.
    public mutating func begin() -> Token {
        lastNumber += 1
        let token = Token(number: lastNumber)
        current = token
        return token
    }

    /// Consumes `token` and returns `true` only if it is still the active pending click.
    public mutating func consume(_ token: Token) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }

    /// Cancels any active pending click and returns whether one was active.
    @discardableResult
    public mutating func cancel() -> Bool {
        guard current != nil else { return false }
        current = nil
        return true
    }
}
