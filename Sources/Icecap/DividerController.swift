import AppKit
import IcecapCore
import OSLog
import ServiceManagement

/// Owns the divider, the narrow status item that shows the chevron, and the spacer, the
/// invisible status item kept immediately left of it by the `icecap-spacer` helper. The
/// spacer hides the icons to its left; the divider shows them on request and opens the
/// panel that lists them.
@MainActor
final class DividerController: NSObject {
    static let log = Logger(subsystem: "com.memorysynchub.icecap", category: "divider")
    static let dividerAutosaveName = "icecap"
    static let positionSeededKey = "PreferredPositionSeeded"
    /// Where the divider goes when no better position can be computed: far enough from
    /// the right edge to clear most system icons, near enough to clear a notch.
    static let fallbackPreferredPosition: CGFloat = 300
    /// How long the system takes to place a new status item at its preferred position.
    static let placementDelay = Duration.milliseconds(800)

    static func preferredPositionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    private let defaults = UserDefaults.standard
    private var dividerItem: NSStatusItem?
    /// Whether the divider has had time to reach its own position; until then the spacer
    /// does not follow it.
    private var isDividerSettled = false
    private var dividerMoveObserver: NSObjectProtocol?
    /// The life of the spacer's helpers; see `SpacerLifecycle`.
    private var spacerLifecycle = SpacerLifecycle()
    /// The running helpers by generation: the current one and any still ending.
    private var spacerProcesses: [SpacerLifecycle.Generation: SpacerProcess] = [:]
    private struct RefreshKinds: OptionSet {
        let rawValue: Int
        static let boundary = RefreshKinds(rawValue: 1 << 0)
        static let inventory = RefreshKinds(rawValue: 1 << 1)
    }

    private let panel = GroupPanel()
    private let updater = Updater()
    static let alwaysShowsGroupWhereItFitsKey = "AlwaysShowsGroupWhereItFits"
    /// How often the active display and front-menu boundary are refreshed while the group
    /// is always shown where it fits, catching the active menu bar moving between displays.
    static let alwaysShowBoundaryInterval: TimeInterval = 1
    /// How often the status area boundary is refreshed while idle so warm clicks stay ready.
    static let idleBoundaryInterval: TimeInterval = 10
    /// How often the hidden group inventory is refreshed while hidden to catch icon changes
    /// that emit no workspace notifications.
    static let idleInventoryInterval: TimeInterval = 30
    /// Delay after hiding before reading the hidden group so icons have finished moving
    /// off-screen.
    static let settleDelay = Duration.milliseconds(700)
    static let settleRetryDelay = Duration.milliseconds(500)
    static let settleRetryLimit = 4
    static let notificationRefreshDelay = Duration.milliseconds(250)
    static let appLaunchRefreshDelay = Duration.milliseconds(450)
    /// Whether the group is shown or hidden; see `GroupVisibility`. The choice to show it
    /// always where it fits is kept in the defaults.
    private var visibility: GroupVisibility
    /// The work of the activity under way, if it has any: watching a peek, or pressing an
    /// icon. Cancelled when the activity ends or another begins.
    private var activityTask: Task<Void, Never>?
    /// How often a peek checks whether the pointer has left the menu bar.
    static let peekCheckInterval = Duration.milliseconds(200)
    /// Whether the arrangement help opens once the spacer is first placed: on the first
    /// launch with the Accessibility permission.
    private var opensArrangementHelpWhenPlaced = false
    /// The processes that own the group's icons, as last listed in the panel.
    private var listedGroupProcesses: Set<Int32> = []
    /// Cached hidden-group inventory and active-display status area boundary.
    private var fit = MenuBarFit()
    private var pendingClickTracker = PendingClickTracker()
    private var pendingClickTask: Task<Void, Never>?
    private var lastAppliedCommand: (generation: SpacerLifecycle.Generation, command: SpacerHelper.Command)?
    private var pushedOffCheckTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefreshKinds: RefreshKinds = []
    private var boundaryRevision: UInt64 = 0
    private var inventoryRevision: UInt64 = 0
    private var delayedBoundaryRefreshTask: Task<Void, Never>?
    private var delayedInventoryRefreshTask: Task<Void, Never>?
    private var settleRetryTask: Task<Void, Never>?
    private var settleRetryAttempts = 0
    private var boundaryTimer: Timer?
    private var boundaryTimerInterval: TimeInterval = 0
    private var inventoryTimer: Timer?
    private var environmentObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var trustTimer: Timer?
    /// The listing of the group's icons under way for the panel, which a second request
    /// to toggle the panel cancels.
    private var panelOpenTask: Task<Void, Never>?
    static let panelShortcutKey = "PanelShortcut"
    private var hotKey: HotKey?
    /// Why the chosen shortcut could not be registered, when it could not.
    private var hotKeyFailure: HotKey.RegistrationError?

    /// The shortcut that opens the panel from any application, or none. Kept across launches.
    private var panelShortcut: PanelShortcut? {
        get { PanelShortcut.resolved(storedValue: defaults.string(forKey: Self.panelShortcutKey)) }
        set { defaults.set(PanelShortcut.storedValue(for: newValue), forKey: Self.panelShortcutKey) }
    }

    override init() {
        visibility = GroupVisibility(
            alwaysShowsWhereItFits: UserDefaults.standard.bool(forKey: Self.alwaysShowsGroupWhereItFitsKey),
            isPermitted: AccessibilityClient.isTrusted
        )
        super.init()
        panel.onChoose = { [weak self] entry in self?.press(entry) }
        panel.onShowInMenuBar = { [weak self] in
            guard let self else { return }
            self.startPeek(groupProcesses: self.listedGroupProcesses)
        }
        panel.onClose = { [weak self] state in self?.panelClosed(state) }
        updater.onWaitingUpdateChange = { [weak self] in self?.updateChevron() }
    }

    func start() async {
        await seedDividerPositionIfPossible()
        installDivider()
        registerPanelShortcut()
        if !AccessibilityClient.isTrusted { watchForTrust() }
    }

    // MARK: Divider and spacer

    private func installDivider() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.dividerAutosaveName
        dividerItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(dividerClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("icecap")
            button.imagePosition = .imageOnly
        }
        updateChevron()
        // The system records a new preferred position in this application's defaults
        // when the divider is dragged with ⌘. Status item windows on macOS 26 post no
        // move notifications, so the defaults are watched instead.
        dividerMoveObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followDivider() }
        }
        startObservingEnvironment()
        // The divider is given time to reach its own position before the spacer is
        // placed beside it.
        Task {
            try? await Task.sleep(for: Self.placementDelay)
            isDividerSettled = true
            followDivider()
        }
    }

    /// Keeps the spacer immediately left of the divider, wherever the divider now lies.
    private func followDivider() {
        guard isDividerSettled else { return }
        guard let dividerPosition = dividerPreferredPosition() else {
            Self.log.error("the divider has no position yet; the spacer is not started")
            return
        }
        handle(.positionChanged(Divider.spacerPreferredPosition(dividerPreferredPosition: dividerPosition)))
    }

    /// Advances the spacer's lifecycle by the event and carries out what it requires: a
    /// helper started narrow, which widens only once placed, because the system places a
    /// status item that is already wide at the far left; or a helper ended.
    private func handle(_ event: SpacerLifecycle.Event) {
        let previousPhase = spacerLifecycle.phase
        let previousPlacedGeneration = spacerLifecycle.placedGeneration
        let time = ProcessInfo.processInfo.systemUptime
        var effects = spacerLifecycle.handle(event, at: time)
        while !effects.isEmpty {
            switch effects.removeFirst() {
            case .start(let generation, let position):
                do {
                    spacerProcesses[generation] = try SpacerProcess(
                        preferredPosition: position,
                        onReport: { [weak self] report in
                            switch report {
                            case .placed: self?.handle(.placed(generation))
                            }
                        },
                        onExit: { [weak self] status in self?.spacerExited(generation, status: status) }
                    )
                    Self.log.info("spacer \(generation) started at preferred position \(position)")
                    Task { [weak self] in
                        try? await Task.sleep(for: SpacerLifecycle.placementTimeLimit)
                        self?.handle(.placementTimedOut(generation))
                    }
                } catch {
                    Self.log.error("\(error.localizedDescription, privacy: .public)")
                    effects += spacerLifecycle.handle(.exited(generation), at: time)
                }
            case .stop(let generation):
                spacerProcesses[generation]?.end()
            }
        }
        let phase = spacerLifecycle.phase
        guard phase != previousPhase else { return }
        if spacerLifecycle.placedGeneration != previousPlacedGeneration {
            cancelPendingClick()
            pushedOffCheckTask?.cancel()
            pushedOffCheckTask = nil
            lastAppliedCommand = nil
            invalidateAllFit()
        }
        Self.log.info("spacer \(String(describing: event), privacy: .public): \(String(describing: phase), privacy: .public)")
        if spacerLifecycle.isFailed {
            Self.log.error("the spacer could not be placed after \(SpacerLifecycle.failureLimit) tries; the group stays shown")
        }
        applyVisibility()
        updateRefreshTimers()
        if case .placed = phase { spacerPlaced() }
    }

    private func spacerExited(_ generation: SpacerLifecycle.Generation, status: Int32) {
        spacerProcesses[generation] = nil
        Self.log.info("spacer \(generation) exited with status \(status)")
        handle(.exited(generation))
    }

    private func spacerPlaced() {
        scheduleRefresh(visibility.isHidden ? .boundary : [.boundary, .inventory])
        if opensArrangementHelpWhenPlaced {
            opensArrangementHelpWhenPlaced = false
            openArrangementHelp()
        }
    }

    @objc private func retrySpacer() {
        handle(.retry)
    }

    /// The divider's preferred position as the system last recorded it, else the distance
    /// from its right edge to the right edge of its display.
    private func dividerPreferredPosition() -> CGFloat? {
        let key = Self.preferredPositionKey(Self.dividerAutosaveName)
        if defaults.object(forKey: key) != nil { return CGFloat(defaults.double(forKey: key)) }
        guard
            let frame = dividerItem?.button?.window?.frame,
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) })
        else { return nil }
        return screen.frame.maxX - frame.maxX
    }

    /// Whether the divider lies on some display. A misplaced spacer can push the divider
    /// itself off every display, where it could no longer be clicked.
    private var isDividerOnScreen: Bool {
        guard let frame = dividerItem?.button?.window?.frame else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    /// Whether the spacer now hides the group: it is placed, and the group should be hidden.
    private var isGroupHidden: Bool { visibility.isHidden && spacerLifecycle.placedGeneration != nil }

    /// Widens or shrinks the placed spacer as the group should be hidden or shown, and
    /// checks, once it has widened, that it left the divider on a display.
    private func applyVisibility() {
        visibility.isPermitted = AccessibilityClient.isTrusted
        updateChevron()
        if !visibility.isPermitted {
            cancelPendingClick()
            pushedOffCheckTask?.cancel()
            pushedOffCheckTask = nil
            invalidateAllFit()
            updateRefreshTimers()
        }
        guard let generation = spacerLifecycle.placedGeneration, let spacer = spacerProcesses[generation] else { return }
        let desiredCommand: SpacerHelper.Command = visibility.isHidden ? .hide : .show
        let commandChanged = lastAppliedCommand?.generation != generation || lastAppliedCommand?.command != desiredCommand
        guard commandChanged else { return }
        guard spacer.send(desiredCommand) else { return }
        lastAppliedCommand = (generation, desiredCommand)
        pushedOffCheckTask?.cancel()
        pushedOffCheckTask = nil
        guard desiredCommand == .hide else { return }
        pushedOffCheckTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self,
                  self.spacerLifecycle.placedGeneration == generation,
                  self.visibility.isHidden,
                  self.lastAppliedCommand?.generation == generation,
                  self.lastAppliedCommand?.command == .hide,
                  !self.isDividerOnScreen
            else { return }
            self.handle(.dividerPushedOff(generation))
        }
        let now = ProcessInfo.processInfo.systemUptime
        let context = MenuBarFit.Context(
            displayIdentifier: nil,
            frontApplicationProcessIdentifier: nil,
            spacerGeneration: generation
        )
        if !fit.hasValidInventory(for: context, at: now) {
            scheduleInventoryRefresh(after: Self.settleDelay, includeBoundary: true)
        }
    }

    private func updateChevron() {
        let name = isGroupHidden ? "chevron.left" : "chevron.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let chevron = NSImage(systemSymbolName: name, accessibilityDescription: "icecap")?
            .withSymbolConfiguration(configuration)
        else { return }
        let image = updater.isUpdateWaiting ? Self.markedForUpdate(chevron) : chevron
        image.isTemplate = true
        dividerItem?.button?.image = image
        dividerItem?.button?.setAccessibilityLabel(updater.isUpdateWaiting ? "icecap, update available" : "icecap")
    }

    /// The chevron with a dot at its upper right, which marks an update waiting to be shown.
    private static func markedForUpdate(_ chevron: NSImage) -> NSImage {
        let dotDiameter: CGFloat = 5
        let size = NSSize(width: chevron.size.width + dotDiameter, height: chevron.size.height)
        return NSImage(size: size, flipped: false) { _ in
            chevron.draw(in: NSRect(origin: .zero, size: chevron.size))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: size.width - dotDiameter,
                y: size.height - dotDiameter,
                width: dotDiameter,
                height: dotDiameter
            )).fill()
            return true
        }
    }

    private func setAlwaysShowsGroupWhereItFits(_ showing: Bool) {
        cancelPendingClick()
        defaults.set(showing, forKey: Self.alwaysShowsGroupWhereItFitsKey)
        visibility.alwaysShowsWhereItFits = showing
        if showing, let generation = spacerLifecycle.placedGeneration {
            let context = MenuBarFit.Context(
                displayIdentifier: currentDisplayIdentifier(),
                frontApplicationProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                spacerGeneration: generation
            )
            if case .fits = fit.decision(for: context, at: ProcessInfo.processInfo.systemUptime) {
                visibility.fits = true
            }
        }
        updateRefreshTimers()
        applyVisibility()
        if showing {
            scheduleRefresh([.boundary, .inventory])
        }
    }

    // MARK: Activities

    /// Begins the activity, ending the one under way and cancelling its work.
    private func begin(_ activity: GroupVisibility.Activity) -> GroupVisibility.Ticket {
        cancelPendingClick()
        activityTask?.cancel()
        activityTask = nil
        let ticket = visibility.begin(activity)
        Self.log.info("\(String(describing: activity), privacy: .public) began")
        applyVisibility()
        updateRefreshTimers()
        return ticket
    }

    /// Ends the ticket's activity, unless another has superseded it.
    private func finish(_ ticket: GroupVisibility.Ticket) {
        let wasHidden = visibility.isHidden
        guard visibility.end(ticket) else { return }
        activityTask = nil
        Self.log.info("\(String(describing: ticket.activity), privacy: .public) ended")
        applyVisibility()
        updateRefreshTimers()
        if !wasHidden, visibility.isHidden, ticket.activity != .arranging {
            scheduleInventoryRefresh(after: Self.settleDelay, includeBoundary: false)
        }
    }

    /// Ends whatever activity is under way, at once.
    private func endActivity() {
        let wasHidden = visibility.isHidden
        let endedActivity = visibility.activity
        cancelPendingClick()
        activityTask?.cancel()
        activityTask = nil
        visibility.endActivity()
        applyVisibility()
        updateRefreshTimers()
        if !wasHidden, visibility.isHidden, endedActivity != .arranging {
            scheduleInventoryRefresh(after: Self.settleDelay, includeBoundary: false)
        }
    }

    // MARK: Peek

    /// Shows the group until the pointer has stayed away from the menu bar for a moment
    /// while no menu is open; see `PeekSession`.
    ///
    /// - Parameter groupProcesses: The processes that own the group's icons, whose
    ///   popovers keep the peek going as menus do.
    private func startPeek(groupProcesses: Set<Int32>) {
        let ticket = begin(.peeking)
        activityTask = Task { [weak self] in
            var session = PeekSession(startTime: ProcessInfo.processInfo.systemUptime)
            while true {
                do { try await Task.sleep(for: Self.peekCheckInterval) } catch { return }
                guard let self else { return }
                let isPointerPresent = self.panel.isVisible || Self.isPointerInMenuBar
                let isMenuOpen = !isPointerPresent && MenuDetection.isAnyMenuOpen(
                    windows: WindowServer.onScreenWindows(),
                    processIdentifiers: groupProcesses,
                    displays: WindowServer.displayBounds()
                )
                let time = ProcessInfo.processInfo.systemUptime
                if session.observe(isPointerPresent: isPointerPresent, isMenuOpen: isMenuOpen, time: time) {
                    self.finish(ticket)
                    return
                }
            }
        }
    }

    /// Whether the pointer lies in the menu bar of any display.
    private static var isPointerInMenuBar: Bool {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            let menuBarHeight = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
            return screen.frame.contains(pointer) && pointer.y >= screen.frame.maxY - menuBarHeight
        }
    }

    @objc private func dividerClicked(_ sender: Any?) {
        let clickStarted = ContinuousClock.now
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            cancelPendingClick()
            showContextMenu()
            return
        }
        if event?.modifierFlags.contains(.option) == true {
            cancelPendingClick()
            openPanel()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let context = currentClickContext()
        let plan = fit.primaryClickPlan(
            isPermitted: AccessibilityClient.isTrusted,
            isPanelOpen: panel.isVisible || panelOpenTask != nil,
            hasPendingClick: pendingClickTracker.isPending,
            activity: visibility.activity,
            isShownWhereItFits: visibility.isShownWhereItFits,
            context: context,
            at: now
        )
        switch plan {
        case .closePanel:
            // Closing the arrangement help also ends arranging; see `panelClosed`.
            closePanel()
        case .cancelPendingClick:
            cancelPendingClick()
        case .endActivity:
            endActivity()
        case .disableAlwaysShow:
            setAlwaysShowsGroupWhereItFits(false)
        case .showNeedsAccessibility:
            panel.show(state: .needsAccessibility, at: dividerAnchor())
        case .startPeek(let groupProcesses):
            startPeek(groupProcesses: groupProcesses)
            let elapsed = clickStarted.duration(to: .now)
            Self.log.info("warm chevron expand in \(Self.formattedMilliseconds(elapsed), privacy: .public) ms")
        case .openPanel:
            openPanel()
        case .refreshBoundaryThenRoute:
            routeClickAfterBoundaryRefresh(context: context, clickStarted: clickStarted)
        case .refreshAllThenRoute:
            routeClickAfterFullRefresh(context: context, clickStarted: clickStarted)
        }
    }

    private func cancelPendingClick() {
        _ = pendingClickTracker.cancel()
        pendingClickTask?.cancel()
        pendingClickTask = nil
    }

    private func routeClickAfterBoundaryRefresh(
        context: MenuBarFit.Context,
        clickStarted: ContinuousClock.Instant
    ) {
        cancelPendingClick()
        let token = pendingClickTracker.begin()
        let ownIdentifier = ProcessInfo.processInfo.processIdentifier
        let startBoundaryRevision = boundaryRevision
        let frontPID = context.frontApplicationProcessIdentifier
        let generation = context.spacerGeneration
        pendingClickTask = Task { [weak self] in
            async let ownItemsTask = AccessibilityClient.items(ofProcess: ownIdentifier, includeDescriptions: false)
            async let menuTitlesTask: [CGRect]? = {
                guard let frontPID else { return nil }
                return await AccessibilityClient.frontMenuTitleFrames(ofProcess: frontPID)
            }()
            let ownItems = await ownItemsTask
            let menuTitleFrames = await menuTitlesTask
            guard let self, !Task.isCancelled else { return }
            self.pendingClickTask = nil
            guard
                self.pendingClickTracker.consume(token),
                AccessibilityClient.isTrusted,
                self.visibility.activity == nil,
                !self.panel.isVisible,
                self.panelOpenTask == nil
            else { return }

            let now = ProcessInfo.processInfo.systemUptime
            let latestContext = self.currentClickContext()
            if let generation,
               self.spacerLifecycle.placedGeneration == generation,
               let dividerFrame = self.dividerFrame(in: ownItems) {
                self.recordBoundaryIfCurrent(
                    dividerFrame: dividerFrame,
                    menuTitleFrames: menuTitleFrames,
                    frontPID: frontPID,
                    generation: generation,
                    startBoundaryRevision: startBoundaryRevision,
                    at: now
                )
            } else if self.boundaryRevision == startBoundaryRevision,
                      frontPID == NSWorkspace.shared.frontmostApplication?.processIdentifier {
                self.fit.invalidateBoundary()
            }

            switch self.fit.decision(for: latestContext, at: now) {
            case .fits(let groupProcesses):
                self.startPeek(groupProcesses: groupProcesses)
                let elapsed = clickStarted.duration(to: .now)
                Self.log.info("boundary-refreshed chevron expand in \(Self.formattedMilliseconds(elapsed), privacy: .public) ms")
            case .doesNotFit, .unknown:
                self.openPanel()
            }
        }
    }

    private func routeClickAfterFullRefresh(
        context: MenuBarFit.Context,
        clickStarted: ContinuousClock.Instant
    ) {
        cancelPendingClick()
        let token = pendingClickTracker.begin()
        let startInventoryRevision = inventoryRevision
        let startBoundaryRevision = boundaryRevision
        let startWasHidden = visibility.isHidden
        let frontPID = context.frontApplicationProcessIdentifier
        let generation = context.spacerGeneration
        pendingClickTask = Task { [weak self] in
            async let itemsTask = AccessibilityClient.items(includeDescriptions: true)
            async let menuTitlesTask: [CGRect]? = {
                guard let frontPID else { return nil }
                return await AccessibilityClient.frontMenuTitleFrames(ofProcess: frontPID)
            }()
            let items = await itemsTask
            let menuTitleFrames = await menuTitlesTask
            guard let self, !Task.isCancelled else { return }
            self.pendingClickTask = nil
            guard
                self.pendingClickTracker.consume(token),
                AccessibilityClient.isTrusted,
                self.visibility.activity == nil,
                !self.panel.isVisible,
                self.panelOpenTask == nil
            else { return }

            let now = ProcessInfo.processInfo.systemUptime
            let latestContext = self.currentClickContext()
            if let (group, dividerFrame) = self.group(of: items) {
                if let generation, self.spacerLifecycle.placedGeneration == generation {
                    self.recordInventoryIfCurrent(
                        group: group,
                        generation: generation,
                        startInventoryRevision: startInventoryRevision,
                        startWasHidden: startWasHidden,
                        scheduleRetryOnMidMove: true,
                        at: now
                    )
                    self.recordBoundaryIfCurrent(
                        dividerFrame: dividerFrame,
                        menuTitleFrames: menuTitleFrames,
                        frontPID: frontPID,
                        generation: generation,
                        startBoundaryRevision: startBoundaryRevision,
                        at: now
                    )
                } else if self.spacerLifecycle.placedGeneration == nil,
                          let screen = self.screen(containingAXFrame: dividerFrame),
                          let menuTitleFrames,
                          Divider.groupFits(
                              width: Divider.groupWidth(group),
                              dividerFrame: dividerFrame,
                              statusAreaMinX: self.statusAreaMinX(on: screen, menuTitleFrames: menuTitleFrames)
                          ) {
                    self.startPeek(groupProcesses: Set(group.map(\.processIdentifier)))
                    return
                }
            } else if self.boundaryRevision == startBoundaryRevision,
                      frontPID == NSWorkspace.shared.frontmostApplication?.processIdentifier {
                self.fit.invalidateBoundary()
            }

            if case .fits(let groupProcesses) = self.fit.decision(for: latestContext, at: now) {
                self.startPeek(groupProcesses: groupProcesses)
                let elapsed = clickStarted.duration(to: .now)
                Self.log.info("cold chevron expand in \(Self.formattedMilliseconds(elapsed), privacy: .public) ms")
                return
            }
            self.showPanel(listing: items)
        }
    }

    // MARK: Fit background refresh

    private func startObservingEnvironment() {
        guard environmentObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let entries: [(NotificationCenter, Notification.Name, @MainActor @Sendable (Int32?, NSApplication.ActivationPolicy?) -> Void)] = [
            (workspace, NSWorkspace.didActivateApplicationNotification, { [weak self] _, _ in
                self?.invalidateBoundaryAndRefresh(delay: Self.notificationRefreshDelay)
            }),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification, { [weak self] _, _ in
                self?.invalidateBoundaryAndRefresh(delay: Self.notificationRefreshDelay)
            }),
            (workspace, NSWorkspace.didLaunchApplicationNotification, { [weak self] _, policy in
                guard let self else { return }
                if policy == .prohibited { return }
                if self.visibility.isHidden {
                    self.invalidateInventoryAndRefresh(delay: Self.appLaunchRefreshDelay)
                } else {
                    self.scheduleInventoryRefresh(after: Self.appLaunchRefreshDelay, includeBoundary: false)
                }
            }),
            (workspace, NSWorkspace.didTerminateApplicationNotification, { [weak self] processIdentifier, policy in
                guard let self else { return }
                if let processIdentifier {
                    let owned = self.fit.ownsGroupProcess(processIdentifier)
                    if !owned && policy == .prohibited { return }
                }
                if self.visibility.isHidden {
                    self.invalidateInventoryAndRefresh(delay: Self.notificationRefreshDelay)
                } else {
                    self.scheduleInventoryRefresh(after: Self.notificationRefreshDelay, includeBoundary: false)
                }
            }),
            (workspace, NSWorkspace.didWakeNotification, { [weak self] _, _ in
                self?.invalidateAllAndRefresh(delay: Self.appLaunchRefreshDelay)
            }),
            (workspace, NSWorkspace.screensDidWakeNotification, { [weak self] _, _ in
                self?.invalidateAllAndRefresh(delay: Self.appLaunchRefreshDelay)
            }),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, { [weak self] _, _ in
                self?.invalidateAllAndRefresh(delay: Self.appLaunchRefreshDelay)
            }),
        ]
        environmentObservers = entries.map { center, name, handler in
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let processIdentifier = application?.processIdentifier
                let activationPolicy = application?.activationPolicy
                MainActor.assumeIsolated { handler(processIdentifier, activationPolicy) }
            }
            return (center, observer)
        }
        updateRefreshTimers()
    }

    private func updateRefreshTimers() {
        let shouldRunTimers = spacerLifecycle.placedGeneration != nil && AccessibilityClient.isTrusted
        guard shouldRunTimers else {
            boundaryTimer?.invalidate()
            boundaryTimer = nil
            boundaryTimerInterval = 0
            inventoryTimer?.invalidate()
            inventoryTimer = nil
            return
        }
        let interval = visibility.alwaysShowsWhereItFits ? Self.alwaysShowBoundaryInterval : Self.idleBoundaryInterval
        if boundaryTimerInterval != interval || boundaryTimer == nil {
            boundaryTimer?.invalidate()
            boundaryTimerInterval = interval
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let needsInventory = (self.visibility.isHidden || self.visibility.isShownWhereItFits)
                        && !self.fit.hasValidInventory(
                            for: MenuBarFit.Context(
                                displayIdentifier: nil,
                                frontApplicationProcessIdentifier: nil,
                                spacerGeneration: self.spacerLifecycle.placedGeneration
                            ),
                            at: ProcessInfo.processInfo.systemUptime
                        )
                    self.scheduleRefresh(needsInventory ? [.boundary, .inventory] : .boundary)
                }
            }
            timer.tolerance = interval * 0.2
            boundaryTimer = timer
        }
        if inventoryTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: Self.idleInventoryInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.visibility.isHidden || self.visibility.isShownWhereItFits else { return }
                    self.scheduleRefresh(.inventory)
                }
            }
            timer.tolerance = 5
            inventoryTimer = timer
        }
    }

    private func invalidateBoundaryAndRefresh(delay: Duration?) {
        boundaryRevision &+= 1
        fit.invalidateBoundary()
        guard let delay else {
            scheduleRefresh(.boundary)
            return
        }
        delayedBoundaryRefreshTask?.cancel()
        delayedBoundaryRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.delayedBoundaryRefreshTask = nil
            self.scheduleRefresh(.boundary)
        }
    }

    private func invalidateInventoryAndRefresh(delay: Duration?) {
        inventoryRevision &+= 1
        fit.invalidateInventory()
        settleRetryTask?.cancel()
        settleRetryTask = nil
        settleRetryAttempts = 0
        guard let delay else {
            scheduleRefresh(.inventory)
            return
        }
        scheduleInventoryRefresh(after: delay, includeBoundary: false)
    }

    private func invalidateAllAndRefresh(delay: Duration?) {
        invalidateAllFit()
        guard let delay else {
            scheduleRefresh([.boundary, .inventory])
            return
        }
        scheduleInventoryRefresh(after: delay, includeBoundary: true)
    }

    private func invalidateAllFit() {
        boundaryRevision &+= 1
        inventoryRevision &+= 1
        fit.invalidateAll()
        delayedBoundaryRefreshTask?.cancel()
        delayedBoundaryRefreshTask = nil
        delayedInventoryRefreshTask?.cancel()
        delayedInventoryRefreshTask = nil
        settleRetryTask?.cancel()
        settleRetryTask = nil
        settleRetryAttempts = 0
    }

    private func scheduleInventoryRefresh(after delay: Duration, includeBoundary: Bool) {
        delayedInventoryRefreshTask?.cancel()
        delayedInventoryRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.delayedInventoryRefreshTask = nil
            self.scheduleRefresh(includeBoundary ? [.boundary, .inventory] : .inventory)
        }
    }

    private func scheduleSettleRetryIfNeeded(for generation: SpacerLifecycle.Generation) {
        guard settleRetryAttempts < Self.settleRetryLimit else { return }
        settleRetryAttempts += 1
        settleRetryTask?.cancel()
        settleRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.settleRetryDelay) } catch { return }
            guard let self,
                  !Task.isCancelled,
                  self.spacerLifecycle.placedGeneration == generation,
                  self.visibility.isHidden
            else { return }
            self.settleRetryTask = nil
            self.scheduleRefresh([.boundary, .inventory])
        }
    }

    private func scheduleRefresh(_ kinds: RefreshKinds) {
        guard AccessibilityClient.isTrusted, spacerLifecycle.placedGeneration != nil else { return }
        pendingRefreshKinds.formUnion(kinds)
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.drainRefreshQueue()
        }
    }

    private func drainRefreshQueue() async {
        defer { refreshTask = nil }
        while !pendingRefreshKinds.isEmpty, !Task.isCancelled {
            guard AccessibilityClient.isTrusted, let generation = spacerLifecycle.placedGeneration else {
                pendingRefreshKinds = []
                return
            }
            let kinds = pendingRefreshKinds
            pendingRefreshKinds = []
            await performRefresh(kinds, generation: generation)
        }
    }

    private func performRefresh(_ kinds: RefreshKinds, generation: SpacerLifecycle.Generation) async {
        let needsInventory = kinds.contains(.inventory)
        let needsBoundary = kinds.contains(.boundary)
        guard needsInventory || needsBoundary else { return }

        let ownIdentifier = ProcessInfo.processInfo.processIdentifier
        let startInventoryRevision = inventoryRevision
        let startBoundaryRevision = boundaryRevision
        let startWasHidden = visibility.isHidden
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        async let itemsTask = AccessibilityClient.items(
            ofProcess: needsInventory ? nil : ownIdentifier,
            includeDescriptions: false
        )
        async let menuTitlesTask: [CGRect]? = {
            guard needsBoundary, let frontPID else { return nil }
            return await AccessibilityClient.frontMenuTitleFrames(ofProcess: frontPID)
        }()

        let items = await itemsTask
        let menuTitleFrames = await menuTitlesTask

        guard
            !Task.isCancelled,
            AccessibilityClient.isTrusted,
            spacerLifecycle.placedGeneration == generation
        else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let parsedGroup = group(of: items)

        if needsInventory, let (group, _) = parsedGroup {
            recordInventoryIfCurrent(
                group: group,
                generation: generation,
                startInventoryRevision: startInventoryRevision,
                startWasHidden: startWasHidden,
                scheduleRetryOnMidMove: true,
                at: now
            )
        }

        if needsBoundary {
            if let (_, dividerFrame) = parsedGroup {
                recordBoundaryIfCurrent(
                    dividerFrame: dividerFrame,
                    menuTitleFrames: menuTitleFrames,
                    frontPID: frontPID,
                    generation: generation,
                    startBoundaryRevision: startBoundaryRevision,
                    at: now
                )
            } else if boundaryRevision == startBoundaryRevision,
                      frontPID == NSWorkspace.shared.frontmostApplication?.processIdentifier {
                fit.invalidateBoundary()
            }
        }

        if visibility.alwaysShowsWhereItFits, visibility.activity != .pressing {
            let activeDisplay = parsedGroup.flatMap { screen(containingAXFrame: $0.dividerFrame)?.displayIdentifier }
            let context = MenuBarFit.Context(
                displayIdentifier: activeDisplay,
                frontApplicationProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                spacerGeneration: generation
            )
            switch fit.decision(for: context, at: now) {
            case .fits:
                if !visibility.fits {
                    Self.log.info("group fits again; showing it")
                    visibility.fits = true
                    applyVisibility()
                }
            case .doesNotFit:
                if visibility.fits {
                    Self.log.info("group no longer fits; hiding it")
                    visibility.fits = false
                    applyVisibility()
                }
            case .unknown:
                break
            }
        }
    }

    private func recordInventoryIfCurrent(
        group: [MenuBarItem],
        generation: SpacerLifecycle.Generation,
        startInventoryRevision: UInt64,
        startWasHidden: Bool,
        scheduleRetryOnMidMove: Bool,
        at now: TimeInterval
    ) {
        guard
            inventoryRevision == startInventoryRevision,
            visibility.isHidden == startWasHidden
        else { return }
        if startWasHidden {
            if fit.recordHiddenGroup(
                group,
                displays: WindowServer.displayBounds(),
                spacerGeneration: generation,
                at: now
            ) {
                settleRetryTask?.cancel()
                settleRetryTask = nil
                settleRetryAttempts = 0
            } else if scheduleRetryOnMidMove {
                Self.log.info("group not yet pushed off the displays; measuring it again later")
                scheduleSettleRetryIfNeeded(for: generation)
            }
        } else {
            fit.recordShownGroup(group, spacerGeneration: generation, at: now)
        }
    }

    private func recordBoundaryIfCurrent(
        dividerFrame: CGRect,
        menuTitleFrames: [CGRect]?,
        frontPID: Int32?,
        generation: SpacerLifecycle.Generation,
        startBoundaryRevision: UInt64,
        at now: TimeInterval
    ) {
        guard boundaryRevision == startBoundaryRevision else { return }
        guard
            let frontPID,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID,
            let screen = screen(containingAXFrame: dividerFrame),
            let menuTitleFrames
        else {
            if frontPID == NSWorkspace.shared.frontmostApplication?.processIdentifier {
                fit.invalidateBoundary()
            }
            return
        }
        fit.recordBoundary(
            displayIdentifier: screen.displayIdentifier,
            frontApplicationProcessIdentifier: frontPID,
            dividerFrame: dividerFrame,
            statusAreaMinX: statusAreaMinX(on: screen, menuTitleFrames: menuTitleFrames),
            spacerGeneration: generation,
            at: now
        )
    }

    private func currentClickContext() -> MenuBarFit.Context {
        MenuBarFit.Context(
            displayIdentifier: currentDisplayIdentifier(),
            frontApplicationProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            spacerGeneration: spacerLifecycle.placedGeneration
        )
    }

    private func currentDisplayIdentifier() -> CGDirectDisplayID? {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(pointer) }
            ?? dividerItem?.button?.window?.screen
        return screen?.displayIdentifier
    }

    private func screen(containingAXFrame frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { CGDisplayBounds($0.displayIdentifier).contains(center) }
    }

    private func statusAreaMinX(on screen: NSScreen, menuTitleFrames: [CGRect]) -> CGFloat {
        Divider.statusAreaMinX(
            displayFrame: CGDisplayBounds(screen.displayIdentifier),
            menuTitleFrames: menuTitleFrames,
            unobscuredTopRightWidth: screen.auxiliaryTopRightArea?.width
        )
    }

    private static func formattedMilliseconds(_ duration: Duration) -> String {
        let milliseconds = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.2f", milliseconds)
    }

    // MARK: Group panel

    /// Opens the panel once the group's icons are listed, unless the panel is toggled
    /// again meanwhile.
    private func openPanel() {
        cancelPendingClick()
        panelOpenTask?.cancel()
        guard AccessibilityClient.isTrusted else {
            panel.show(state: .needsAccessibility, at: dividerAnchor())
            return
        }
        let startInventoryRevision = inventoryRevision
        let startWasHidden = visibility.isHidden
        let generation = spacerLifecycle.placedGeneration
        panelOpenTask = Task {
            let items = await AccessibilityClient.items()
            guard !Task.isCancelled else { return }
            panelOpenTask = nil
            if let generation,
               spacerLifecycle.placedGeneration == generation,
               startWasHidden,
               let (group, _) = group(of: items) {
                recordInventoryIfCurrent(
                    group: group,
                    generation: generation,
                    startInventoryRevision: startInventoryRevision,
                    startWasHidden: startWasHidden,
                    scheduleRetryOnMidMove: false,
                    at: ProcessInfo.processInfo.systemUptime
                )
            }
            showPanel(listing: items)
        }
    }

    private func showPanel(listing items: [AccessibleItem]) {
        guard let (group, _) = group(of: items) else {
            Self.log.error("the divider could not be read; the group is unknown")
            listedGroupProcesses = []
            panel.show(state: .unreadable, at: dividerAnchor())
            return
        }
        let entries = groupEntries(of: group, in: items)
        listedGroupProcesses = Set(entries.map(\.accessible.item.processIdentifier))
        panel.show(state: .entries(entries, isShownInMenuBar: visibility.isShown), at: dividerAnchor())
    }

    private func dividerFrame(in items: [AccessibleItem]) -> CGRect? {
        let ownIdentifier = ProcessInfo.processInfo.processIdentifier
        return items
            .filter { $0.item.processIdentifier == ownIdentifier && $0.item.isLaidOut }
            .max(by: { $0.item.frame.maxX < $1.item.frame.maxX })?.item.frame
    }

    /// The group's icons, left to right, and the divider's frame, as the Accessibility
    /// API reports them for the display whose menu bar is active.
    private func group(of items: [AccessibleItem]) -> (group: [MenuBarItem], dividerFrame: CGRect)? {
        let ownIdentifier = ProcessInfo.processInfo.processIdentifier
        // Of this application's own items, the divider is the rightmost laid-out one.
        guard let dividerFrame = dividerFrame(in: items) else { return nil }
        let excluded = Set([ownIdentifier] + spacerProcesses.values.map(\.processIdentifier))
        let group = Divider.groupItems(items.map(\.item), dividerFrame: dividerFrame, excludingProcesses: excluded)
        return (group, dividerFrame)
    }

    private func groupEntries(of group: [MenuBarItem], in items: [AccessibleItem]) -> [GroupPanel.Entry] {
        zip(group, MenuBarItem.listedNames(of: group)).compactMap { member, title in
            guard let accessible = items.first(where: { $0.item.isSameItem(as: member) }) else { return nil }
            let icon = NSRunningApplication(processIdentifier: member.processIdentifier)?.icon
            return GroupPanel.Entry(accessible: accessible, title: title, icon: icon)
        }
    }

    /// The point, in screen coordinates with a bottom-left origin, below the divider
    /// where the panel's top edge is centred.
    private func dividerAnchor() -> NSPoint {
        if let frame = dividerItem?.button?.window?.frame {
            let point = NSPoint(x: frame.midX, y: frame.minY)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: 0, dy: -1).contains(point) }) {
                return point
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return NSPoint(x: mouse.x, y: screen?.visibleFrame.maxY ?? mouse.y)
    }

    // MARK: Keyboard shortcut

    private func registerPanelShortcut() {
        hotKey?.unregister()
        hotKey = nil
        hotKeyFailure = nil
        guard let shortcut = panelShortcut else { return }
        do {
            hotKey = try HotKey(shortcut: shortcut) { [weak self] in self?.panelShortcutPressed() }
        } catch let error as HotKey.RegistrationError {
            Self.log.error("\(error.localizedDescription, privacy: .public)")
            hotKeyFailure = error
        } catch {
            preconditionFailure("HotKey throws only RegistrationError: \(error)")
        }
    }

    /// Opens the panel, whether or not the group fits, or closes it if it is open or
    /// opening.
    private func panelShortcutPressed() {
        if panel.isVisible || panelOpenTask != nil {
            closePanel()
        } else {
            openPanel()
        }
    }

    // MARK: Arrangement help

    /// Shows the group and, beside it, how to arrange its icons, until the help closes;
    /// see `panelClosed`.
    private func openArrangementHelp() {
        guard AccessibilityClient.isTrusted else {
            panel.show(state: .needsAccessibility, at: dividerAnchor())
            return
        }
        guard visibility.activity != .arranging else { return }
        panel.show(state: .arrangementHelp(shortcutTitle: hotKey?.shortcut.title), at: dividerAnchor())
        _ = begin(.arranging)
    }

    /// The panel closed. Closing the arrangement help, by Done or a click on the chevron,
    /// ends arranging.
    private func panelClosed(_ state: GroupPanel.State) {
        guard case .arrangementHelp = state, let ticket = visibility.current, ticket.activity == .arranging else {
            return
        }
        invalidateInventoryAndRefresh(delay: Self.settleDelay)
        finish(ticket)
    }

    private func closePanel() {
        cancelPendingClick()
        panelOpenTask?.cancel()
        panelOpenTask = nil
        panel.close()
    }

    @objc private func arrangeIcons() {
        openArrangementHelp()
    }

    // MARK: Pressing a hidden icon

    /// Shows the group, presses the chosen icon, and keeps the group shown until the
    /// icon's menu closes.
    private func press(_ entry: GroupPanel.Entry) {
        panel.close()
        let ticket = begin(.pressing)
        activityTask = Task { [weak self] in
            await self?.reveal(andPress: entry.accessible)
            self?.finish(ticket)
        }
    }

    private func reveal(andPress target: AccessibleItem) async {
        let settled = await settledTarget(for: target)
        // A later choice took over while this one waited; it must not press as well.
        guard !Task.isCancelled else { return }
        guard let settled else {
            NSSound.beep()
            return
        }
        let pressed = await AccessibilityClient.press(settled.element)
        Self.log.info("pressed \(settled.item.name, privacy: .public): \(pressed)")
        var session = RevealSession(startTime: ProcessInfo.processInfo.systemUptime)
        while true {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let windows = WindowServer.onScreenWindows()
            let isOpen = MenuDetection.isMenuOpen(
                windows: windows,
                ownerProcessIdentifier: settled.item.processIdentifier,
                itemFrame: settled.item.frame
            )
            let previousPhase = session.phase
            let phase = session.observe(isMenuOpen: isOpen, time: ProcessInfo.processInfo.systemUptime)
            if phase != previousPhase { Self.log.info("reveal session: \(String(describing: phase), privacy: .public)") }
            if phase == .finished { return }
        }
    }

    /// Waits until the icon lies on a display and has stopped moving, returning a freshly
    /// resolved target so neither its frame nor its AX element is stale.
    private func settledTarget(for target: AccessibleItem) async -> AccessibleItem? {
        var previous: CGRect?
        for _ in 0..<40 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
            let processItems = await AccessibilityClient.items(
                ofProcess: target.item.processIdentifier,
                includeDescriptions: false
            )
            guard let current = processItems.first(where: { $0.item.isSameItem(as: target.item) }) else {
                continue
            }
            if current.item.frame == previous,
               MenuDetection.isWithinDisplay(current.item.frame, displays: WindowServer.displayBounds()) {
                return current
            }
            previous = current.item.frame
        }
        return nil
    }

    // MARK: Context menu

    private func showContextMenu() {
        cancelPendingClick()
        closePanel()
        guard let button = dividerItem?.button else { return }
        let menu = NSMenu()
        if spacerLifecycle.isFailed {
            let failure = NSMenuItem(
                title: "The spacer could not be placed, so no icons are hidden.",
                action: nil,
                keyEquivalent: ""
            )
            failure.isEnabled = false
            menu.addItem(failure)
            let retryItem = NSMenuItem(title: "Try Hiding Icons Again", action: #selector(retrySpacer), keyEquivalent: "")
            retryItem.target = self
            menu.addItem(retryItem)
            menu.addItem(.separator())
        }
        let alwaysItem = NSMenuItem(
            title: "Always Show Where It Fits",
            action: #selector(toggleAlwaysShowsGroupWhereItFits),
            keyEquivalent: ""
        )
        alwaysItem.target = self
        alwaysItem.state = visibility.alwaysShowsWhereItFits ? .on : .off
        menu.addItem(alwaysItem)
        let listItem = NSMenuItem(title: "List Hidden Icons", action: #selector(listHiddenIcons), keyEquivalent: "")
        listItem.target = self
        menu.addItem(listItem)
        let arrangeItem = NSMenuItem(title: "Arrange Icons…", action: #selector(arrangeIcons), keyEquivalent: "")
        arrangeItem.target = self
        menu.addItem(arrangeItem)
        menu.addItem(.separator())
        menu.addItem(shortcutMenuItem())
        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        let settingsItem = NSMenuItem(
            title: "Accessibility Settings…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "About icecap", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        let updateItem = NSMenuItem(
            title: updater.isUpdateWaiting ? "Install Update…" : "Check for Updates…",
            action: updater.canCheckForUpdates ? #selector(checkForUpdates) : nil,
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit icecap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let bounds = button.bounds
        let location = NSPoint(x: bounds.minX, y: button.isFlipped ? bounds.maxY + 6 : bounds.minY - 6)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    private func shortcutMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Keyboard Shortcut", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if let hotKeyFailure {
            let failure = NSMenuItem(title: hotKeyFailure.localizedDescription, action: nil, keyEquivalent: "")
            failure.isEnabled = false
            submenu.addItem(failure)
            submenu.addItem(.separator())
        }
        let choices: [PanelShortcut?] = PanelShortcut.allCases + [nil]
        for choice in choices {
            let choiceItem = NSMenuItem(
                title: choice?.title ?? "None",
                action: #selector(choosePanelShortcut(_:)),
                keyEquivalent: ""
            )
            choiceItem.target = self
            choiceItem.representedObject = PanelShortcut.storedValue(for: choice)
            choiceItem.state = choice == panelShortcut ? .on : .off
            submenu.addItem(choiceItem)
        }
        item.submenu = submenu
        return item
    }

    /// Registers the chosen shortcut before releasing the current one, and keeps it only
    /// if it could be registered; otherwise the current one stays and the person is told why.
    @objc private func choosePanelShortcut(_ sender: NSMenuItem) {
        guard let storedValue = sender.representedObject as? String else {
            preconditionFailure("each shortcut item carries its stored value")
        }
        let choice = PanelShortcut.resolved(storedValue: storedValue)
        var replacement: HotKey?
        if let choice {
            do {
                replacement = try HotKey(shortcut: choice) { [weak self] in self?.panelShortcutPressed() }
            } catch let error as HotKey.RegistrationError {
                Self.log.error("\(error.localizedDescription, privacy: .public)")
                NSApp.activate()
                NSAlert(error: error).runModal()
                return
            } catch {
                preconditionFailure("HotKey throws only RegistrationError: \(error)")
            }
        }
        hotKey?.unregister()
        hotKey = replacement
        hotKeyFailure = nil
        panelShortcut = choice
    }

    @objc private func listHiddenIcons() {
        openPanel()
    }

    @objc private func toggleAlwaysShowsGroupWhereItFits() {
        setAlwaysShowsGroupWhereItFits(!visibility.alwaysShowsWhereItFits)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        GroupPanel.openAccessibilitySettings()
    }

    // MARK: First position

    /// On first launch, places the divider immediately left of the system's icons, so
    /// that every other application's icon starts in the group.
    private func seedDividerPositionIfPossible() async {
        guard !defaults.bool(forKey: Self.positionSeededKey) else { return }
        let key = Self.preferredPositionKey(Self.dividerAutosaveName)
        guard AccessibilityClient.isTrusted else {
            if defaults.object(forKey: key) == nil {
                defaults.set(Double(Self.fallbackPreferredPosition), forKey: key)
            }
            return
        }
        let ownIdentifier = ProcessInfo.processInfo.processIdentifier
        let items = await AccessibilityClient.items().map(\.item).filter {
            $0.isLaidOut && $0.processIdentifier != ownIdentifier
        }
        let displays = WindowServer.displayBounds()
        guard
            let sample = items.first,
            let display = displays.first(where: { $0.intersects(sample.frame) })
        else { return }
        let rowItems = items.filter { abs($0.frame.midY - sample.frame.midY) < 12 }
        let position = Divider.initialPreferredPosition(
            items: rowItems,
            displayMaxX: display.maxX,
            fallback: Self.fallbackPreferredPosition
        )
        defaults.set(Double(position), forKey: key)
        defaults.set(true, forKey: Self.positionSeededKey)
        opensArrangementHelpWhenPlaced = true
    }

    /// Until the Accessibility permission is granted, checks for it every two seconds;
    /// once granted, starts icecap again to place the divider as on a first launch.
    private func watchForTrust() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AccessibilityClient.isTrusted else { return }
            timer.invalidate()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trustTimer = nil
                guard !self.defaults.bool(forKey: Self.positionSeededKey) else {
                    Self.log.info("Accessibility permission granted; hiding the group")
                    self.applyVisibility()
                    self.updateRefreshTimers()
                    return
                }
                self.defaults.removeObject(forKey: Self.preferredPositionKey(Self.dividerAutosaveName))
                Self.log.info("Accessibility permission granted; starting again to place the divider")
                do {
                    try Relaunch.scheduleOpen(bundlePath: Bundle.main.bundlePath)
                    NSApp.terminate(nil)
                } catch {
                    Self.log.error("could not start again: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
