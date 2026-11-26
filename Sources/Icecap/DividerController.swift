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
    private let panel = GroupPanel()
    private let updater = Updater()
    static let alwaysShowsGroupWhereItFitsKey = "AlwaysShowsGroupWhereItFits"
    /// How often the fit is checked again while the group is always shown where it fits.
    /// Each check reads only this application's own icons and the front application's menus.
    static let fitCheckInterval: TimeInterval = 1
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
    /// The group's width as last measured while it was hidden; see `Divider.groupFits`.
    private var hiddenGroupWidth: CGFloat = 0
    /// Whether `hiddenGroupWidth` has been measured since launch. Until it has, every fit
    /// check measures the group.
    private var isGroupMeasured = false
    private var fitTimer: Timer?
    private var fitObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isCheckingFit = false
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
        if visibility.alwaysShowsWhereItFits { watchFit() }
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
        Self.log.info("spacer \(String(describing: event), privacy: .public): \(String(describing: phase), privacy: .public)")
        if spacerLifecycle.isFailed {
            Self.log.error("the spacer could not be placed after \(SpacerLifecycle.failureLimit) tries; the group stays shown")
        }
        applyVisibility()
        if case .placed = phase { spacerPlaced() }
    }

    private func spacerExited(_ generation: SpacerLifecycle.Generation, status: Int32) {
        spacerProcesses[generation] = nil
        Self.log.info("spacer \(generation) exited with status \(status)")
        handle(.exited(generation))
    }

    private func spacerPlaced() {
        Task {
            await checkFit(measuringGroup: true)
            if opensArrangementHelpWhenPlaced {
                opensArrangementHelpWhenPlaced = false
                openArrangementHelp()
            }
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
        guard let generation = spacerLifecycle.placedGeneration, let spacer = spacerProcesses[generation] else { return }
        let isHidden = visibility.isHidden
        spacer.send(isHidden ? .hide : .show)
        guard isHidden else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.spacerLifecycle.placedGeneration == generation, self.visibility.isHidden,
                  !self.isDividerOnScreen
            else { return }
            self.handle(.dividerPushedOff(generation))
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
        defaults.set(showing, forKey: Self.alwaysShowsGroupWhereItFitsKey)
        visibility.alwaysShowsWhereItFits = showing
        if showing {
            watchFit()
            Task { await checkFit(measuringGroup: true) }
        } else {
            stopWatchingFit()
        }
        applyVisibility()
    }

    // MARK: Activities

    /// Begins the activity, ending the one under way and cancelling its work.
    private func begin(_ activity: GroupVisibility.Activity) -> GroupVisibility.Ticket {
        activityTask?.cancel()
        activityTask = nil
        let ticket = visibility.begin(activity)
        Self.log.info("\(String(describing: activity), privacy: .public) began")
        applyVisibility()
        return ticket
    }

    /// Ends the ticket's activity, unless another has superseded it.
    private func finish(_ ticket: GroupVisibility.Ticket) {
        guard visibility.end(ticket) else { return }
        activityTask = nil
        Self.log.info("\(String(describing: ticket.activity), privacy: .public) ended")
        applyVisibility()
    }

    /// Ends whatever activity is under way, at once.
    private func endActivity() {
        activityTask?.cancel()
        activityTask = nil
        visibility.endActivity()
        applyVisibility()
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
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else if panel.isVisible || panelOpenTask != nil {
            // Closing the arrangement help also ends arranging; see `panelClosed`.
            closePanel()
        } else if event?.modifierFlags.contains(.option) == true {
            openPanel()
        } else if visibility.activity != nil {
            endActivity()
        } else if visibility.isShownWhereItFits {
            setAlwaysShowsGroupWhereItFits(false)
        } else {
            Task { await peekOrOpenPanel() }
        }
    }

    /// Peeks at the group if it fits on the display whose menu bar holds the divider,
    /// beside the front application's menus and any camera housing; otherwise opens the
    /// panel.
    private func peekOrOpenPanel() async {
        guard AccessibilityClient.isTrusted else {
            panel.show(state: .needsAccessibility, at: dividerAnchor())
            return
        }
        let items = await AccessibilityClient.items()
        if let (group, dividerFrame) = group(of: items),
           let statusAreaMinX = await statusAreaMinX(around: dividerFrame) {
            let width = Divider.groupWidth(group)
            if !visibility.isShown { recordHiddenGroupWidth(of: group) }
            if Divider.groupFits(width: max(width, hiddenGroupWidth), dividerFrame: dividerFrame, statusAreaMinX: statusAreaMinX) {
                Self.log.info("group of \(group.count) fits; peeking at it")
                startPeek(groupProcesses: Set(group.map(\.processIdentifier)))
                return
            }
        }
        showPanel(listing: items)
    }

    // MARK: Fit

    /// Checks the fit again whenever it may have changed: when another application comes
    /// to the front, when one starts or ends, when the displays change, and every
    /// `fitCheckInterval`, which catches the active menu bar moving to another display.
    private func watchFit() {
        guard fitTimer == nil else { return }
        fitTimer = Timer.scheduledTimer(withTimeInterval: Self.fitCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.checkFit(measuringGroup: false) }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didActivateApplicationNotification),
            (workspace, NSWorkspace.didLaunchApplicationNotification),
            (workspace, NSWorkspace.didTerminateApplicationNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
        ]
        fitObservers = names.map { center, name in
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task {
                        // The menu bar is laid out again shortly after the change.
                        try? await Task.sleep(for: .milliseconds(400))
                        await self.checkFit(measuringGroup: true)
                    }
                }
            }
            return (center, observer)
        }
    }

    private func stopWatchingFit() {
        fitTimer?.invalidate()
        fitTimer = nil
        for (center, observer) in fitObservers { center.removeObserver(observer) }
        fitObservers = []
    }

    /// Shows or hides the group, while it is always shown where it fits, as it now fits
    /// or not on the display whose menu bar is active.
    ///
    /// - Parameter measuringGroup: Whether to read every application's icons, which takes
    ///   up to two seconds, to measure the group again; otherwise the last width measured
    ///   while the group was hidden is used.
    private func checkFit(measuringGroup: Bool) async {
        guard visibility.alwaysShowsWhereItFits, spacerLifecycle.placedGeneration != nil,
              visibility.activity != .pressing, !isCheckingFit, AccessibilityClient.isTrusted
        else { return }
        isCheckingFit = true
        defer { isCheckingFit = false }
        let ownIdentifier = ProcessInfo.processInfo.processIdentifier
        let measuringGroup = measuringGroup || !isGroupMeasured
        let items = await AccessibilityClient.items(ofProcess: measuringGroup ? nil : ownIdentifier)
        guard let (group, dividerFrame) = group(of: items),
              let statusAreaMinX = await statusAreaMinX(around: dividerFrame),
              visibility.alwaysShowsWhereItFits, visibility.activity != .pressing
        else { return }
        if measuringGroup, !visibility.isShown { recordHiddenGroupWidth(of: group) }
        guard isGroupMeasured else { return }
        var width = hiddenGroupWidth
        if measuringGroup, visibility.isShown { width = max(width, Divider.groupWidth(group)) }
        let fits = Divider.groupFits(width: width, dividerFrame: dividerFrame, statusAreaMinX: statusAreaMinX)
        guard fits != visibility.fits else { return }
        Self.log.info("group of width \(width) \(fits ? "fits again; showing it" : "no longer fits; hiding it", privacy: .public)")
        visibility.fits = fits
        applyVisibility()
    }

    /// Records the width of the hidden group, unless the menu bar is still being laid out
    /// again and the measurement would be wrong; see `Divider.isGroupPushedOff`.
    private func recordHiddenGroupWidth(of group: [MenuBarItem]) {
        guard Divider.isGroupPushedOff(group, displays: WindowServer.displayBounds()) else {
            Self.log.info("group not yet pushed off the displays; measuring it again later")
            return
        }
        hiddenGroupWidth = Divider.groupWidth(group)
        isGroupMeasured = true
    }

    /// The left bound of the status area on the display that holds the divider's frame,
    /// or nil when no display holds it or the front application's menus cannot be read.
    private func statusAreaMinX(around dividerFrame: CGRect) async -> CGFloat? {
        let center = CGPoint(x: dividerFrame.midX, y: dividerFrame.midY)
        guard let screen = NSScreen.screens.first(where: { CGDisplayBounds($0.displayIdentifier).contains(center) }) else {
            return nil
        }
        guard let menuTitleFrames = await AccessibilityClient.frontMenuTitleFrames() else {
            Self.log.error("the front application's menus could not be read; the fit is unknown")
            return nil
        }
        return Divider.statusAreaMinX(
            displayFrame: CGDisplayBounds(screen.displayIdentifier),
            menuTitleFrames: menuTitleFrames,
            unobscuredTopRightWidth: screen.auxiliaryTopRightArea?.width
        )
    }

    // MARK: Group panel

    /// Opens the panel once the group's icons are listed, unless the panel is toggled
    /// again meanwhile.
    private func openPanel() {
        panelOpenTask?.cancel()
        guard AccessibilityClient.isTrusted else {
            panel.show(state: .needsAccessibility, at: dividerAnchor())
            return
        }
        panelOpenTask = Task {
            let items = await AccessibilityClient.items()
            guard !Task.isCancelled else { return }
            panelOpenTask = nil
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

    /// The group's icons, left to right, and the divider's frame, as the Accessibility
    /// API reports them for the display whose menu bar is active.
    private func group(of items: [AccessibleItem]) -> (group: [MenuBarItem], dividerFrame: CGRect)? {
        let ownIdentifier = ProcessInfo.processInfo.processIdentifier
        // Of this application's own items, the divider is the rightmost laid-out one.
        guard let dividerFrame = items
            .filter({ $0.item.processIdentifier == ownIdentifier && $0.item.isLaidOut })
            .max(by: { $0.item.frame.maxX < $1.item.frame.maxX })?.item.frame
        else { return nil }
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
        finish(ticket)
    }

    private func closePanel() {
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
        let frame = await settledFrame(of: target)
        // A later choice took over while this one waited; it must not press as well.
        guard !Task.isCancelled else { return }
        guard let frame else {
            NSSound.beep()
            return
        }
        let pressed = AccessibilityClient.press(target.element)
        Self.log.info("pressed \(target.item.name, privacy: .public): \(pressed)")
        var session = RevealSession(startTime: ProcessInfo.processInfo.systemUptime)
        while true {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let windows = WindowServer.onScreenWindows()
            let isOpen = MenuDetection.isMenuOpen(
                windows: windows,
                ownerProcessIdentifier: target.item.processIdentifier,
                itemFrame: frame
            )
            let previousPhase = session.phase
            let phase = session.observe(isMenuOpen: isOpen, time: ProcessInfo.processInfo.systemUptime)
            if phase != previousPhase { Self.log.info("reveal session: \(String(describing: phase), privacy: .public)") }
            if phase == .finished { return }
        }
    }

    /// Waits until the icon lies on a display and has stopped moving, and returns its
    /// frame; nil if it does not settle or the wait is cancelled.
    private func settledFrame(of target: AccessibleItem) async -> CGRect? {
        var previous: CGRect?
        for _ in 0..<40 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
            guard let frame = AccessibilityClient.frame(of: target.element) else { continue }
            if frame == previous, MenuDetection.isWithinDisplay(frame, displays: WindowServer.displayBounds()) {
                return frame
            }
            previous = frame
        }
        return nil
    }

    // MARK: Context menu

    private func showContextMenu() {
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
