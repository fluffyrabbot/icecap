import AppKit
import IcecapCore
import OSLog
import ServiceManagement

/// Owns the divider, the narrow status item that shows the chevron, and the spacer, the
/// invisible status item kept immediately left of it. The spacer hides the icons to its
/// left; the divider shows them on request and opens the panel that lists them.
@MainActor
final class DividerController: NSObject {
    static let log = Logger(subsystem: "io.github.fluffyrabbot.icecap", category: "divider")
    static let dividerAutosaveName = "icecap"
    static let spacerGenerationKey = "SpacerGeneration"
    static let positionSeededKey = "PreferredPositionSeeded"
    /// Where the divider goes when no better position can be computed: far enough from
    /// the right edge to clear most system icons, near enough to clear a notch.
    static let fallbackPreferredPosition: CGFloat = 300
    /// How long the system takes to place a new status item at its preferred position.
    static let placementDelay = Duration.milliseconds(800)

    static func preferredPositionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    static func visibilityKey(_ autosaveName: String) -> String {
        "NSStatusItem Visible \(autosaveName)"
    }

    /// The spacer's autosave name. Each placement of the spacer takes a new name: a status
    /// item added again under a name already used in this process is placed where the
    /// system last saw that name, whatever preferred position is then recorded.
    private var spacerAutosaveName: String {
        "icecap-spacer-\(defaults.integer(forKey: Self.spacerGenerationKey))"
    }

    private let defaults = UserDefaults.standard
    private var dividerItem: NSStatusItem?
    private var spacerItem: NSStatusItem?
    /// Whether the spacer has been placed beside the divider and may widen.
    private var isSpacerPlaced = false
    private var spacerPlacementTask: Task<Void, Never>?
    private var dividerMoveObserver: NSObjectProtocol?
    private let panel = GroupPanel()
    static let showsGroupKey = "ShowsGroup"
    static let restartTimesKey = "RestartTimes"
    /// More restarts than this within `restartWindow` mean that restarting does not help.
    static let restartLimit = 3
    static let restartWindow: TimeInterval = 60
    private var isRestarting = false

    /// Whether the person chose to show the group in the menu bar. Kept across restarts.
    private var isShowingByChoice: Bool {
        get { defaults.bool(forKey: Self.showsGroupKey) }
        set { defaults.set(newValue, forKey: Self.showsGroupKey) }
    }
    /// Whether the group is shown for the moment, so that one of its icons can be pressed.
    private var isShowingForPress = false
    private var pressTask: Task<Void, Never>?
    private var trustTimer: Timer?

    override init() {
        super.init()
        panel.onChoose = { [weak self] entry in self?.press(entry) }
        panel.onShowInMenuBar = { [weak self] in self?.setShowingByChoice(true) }
    }

    func start() async {
        await seedDividerPositionIfPossible()
        installDivider()
        if !AccessibilityClient.isTrusted { watchForTrust() }
    }

    // MARK: Divider and spacer

    private func installDivider() {
        removeItems()
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
            MainActor.assumeIsolated { self?.dividerMoved() }
        }
        placeSpacer(after: Self.placementDelay)
    }

    private func removeItems() {
        spacerPlacementTask?.cancel()
        if let dividerMoveObserver { NotificationCenter.default.removeObserver(dividerMoveObserver) }
        dividerMoveObserver = nil
        for item in [dividerItem, spacerItem].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        dividerItem = nil
        spacerItem = nil
        isSpacerPlaced = false
    }

    /// Removes the spacer, if any, and adds it again immediately left of the divider. The
    /// spacer is added narrow and widened only once placed, because the system places a
    /// status item that is already wide at the far left.
    private func placeSpacer(after delay: Duration) {
        spacerPlacementTask?.cancel()
        isSpacerPlaced = false
        spacerPlacementTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let dividerPosition = dividerPreferredPosition() else { return }
            if let spacerItem { NSStatusBar.system.removeStatusItem(spacerItem) }
            spacerItem = nil
            defaults.removeObject(forKey: Self.preferredPositionKey(spacerAutosaveName))
            defaults.removeObject(forKey: Self.visibilityKey(spacerAutosaveName))
            defaults.set(defaults.integer(forKey: Self.spacerGenerationKey) + 1, forKey: Self.spacerGenerationKey)
            defaults.set(
                Double(Divider.spacerPreferredPosition(dividerPreferredPosition: dividerPosition)),
                forKey: Self.preferredPositionKey(spacerAutosaveName)
            )
            let spacer = NSStatusBar.system.statusItem(withLength: Divider.spacerShowingLength)
            spacer.autosaveName = spacerAutosaveName
            spacer.button?.setAccessibilityElement(false)
            spacerItem = spacer
            try? await Task.sleep(for: Self.placementDelay)
            guard !Task.isCancelled else { return }
            isSpacerPlaced = true
            Self.log.info("spacer placed at preferred position \(self.defaults.double(forKey: Self.preferredPositionKey(self.spacerAutosaveName)))")
            applyLength()
        }
    }

    /// The divider's preferred position as the system last recorded it, else the distance
    /// from its right edge to the right edge of its display.
    private func dividerPreferredPosition() -> CGFloat? {
        let key = Self.preferredPositionKey(Self.dividerAutosaveName)
        if defaults.object(forKey: key) != nil {
            return CGFloat(defaults.double(forKey: key))
        }
        guard
            let frame = dividerItem?.button?.window?.frame,
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) })
        else { return nil }
        return screen.frame.maxX - frame.maxX
    }

    /// Whether the spacer's recorded position still places it beside the divider's.
    private var isSpacerBesideDivider: Bool {
        let spacerKey = Self.preferredPositionKey(spacerAutosaveName)
        let dividerKey = Self.preferredPositionKey(Self.dividerAutosaveName)
        guard defaults.object(forKey: spacerKey) != nil, defaults.object(forKey: dividerKey) != nil else {
            return false
        }
        return Divider.isSpacerBesideDivider(
            spacerPreferredPosition: CGFloat(defaults.double(forKey: spacerKey)),
            dividerPreferredPosition: CGFloat(defaults.double(forKey: dividerKey))
        )
    }

    /// The defaults changed. If the person dragged the divider with ⌘, the spacer must
    /// follow it. A status item
    /// added again within a process that has seen a drag is not reliably placed at its
    /// preferred position, while one added by a new process is; so icecap restarts.
    private func dividerMoved() {
        guard isSpacerPlaced, !isSpacerBesideDivider else { return }
        restart(reason: "divider dragged")
    }

    /// Whether the divider lies on some display. A misplaced spacer can push the divider
    /// itself off every display, where it could no longer be clicked.
    private var isDividerOnScreen: Bool {
        guard let frame = dividerItem?.button?.window?.frame else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    /// Starts a new instance of icecap and ends this one, unless restarts have stopped
    /// helping; then the group stays shown, so that nothing is lost from view.
    private func restart(reason: String) {
        // Recording the restart changes the defaults, which calls back into `dividerMoved`.
        guard !isRestarting else { return }
        isRestarting = true
        let now = Date().timeIntervalSince1970
        let recent = (defaults.array(forKey: Self.restartTimesKey) as? [Double] ?? [])
            .filter { now - $0 < Self.restartWindow }
        guard recent.count < Self.restartLimit else {
            Self.log.error("not restarting after \(reason, privacy: .public): too many restarts; showing the group")
            spacerItem?.length = Divider.spacerShowingLength
            isSpacerPlaced = false
            isRestarting = false
            return
        }
        defaults.set(recent + [now], forKey: Self.restartTimesKey)
        Self.log.info("restarting: \(reason, privacy: .public)")
        spacerItem?.length = Divider.spacerShowingLength
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            Self.log.error("could not restart: \(error.localizedDescription, privacy: .public)")
            isRestarting = false
        }
    }

    private var isShowing: Bool { isShowingByChoice || isShowingForPress }

    private func applyLength() {
        updateChevron()
        guard let spacerItem, isSpacerPlaced else { return }
        spacerItem.length = isShowing ? Divider.spacerShowingLength : Divider.spacerHidingLength
        guard !isShowing else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard self.spacerItem === spacerItem, !self.isShowing, !self.isDividerOnScreen else { return }
            self.restart(reason: "the spacer pushed the divider off every display")
        }
    }

    private func updateChevron() {
        let name = isShowing ? "chevron.right" : "chevron.left"
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "icecap")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        dividerItem?.button?.image = image
    }

    private func setShowingByChoice(_ showing: Bool) {
        isShowingByChoice = showing
        applyLength()
    }

    @objc private func dividerClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else if panel.isVisible {
            panel.close()
        } else if event?.modifierFlags.contains(.option) == true {
            Task { await openPanel() }
        } else if isShowingByChoice {
            setShowingByChoice(false)
        } else {
            Task { await showGroupOrOpenPanel() }
        }
    }

    /// Shows the group in the menu bar if it fits on the display whose menu bar holds the
    /// divider, beside the front application's menus and any camera housing; otherwise
    /// opens the panel.
    private func showGroupOrOpenPanel() async {
        guard AccessibilityClient.isTrusted else {
            panel.show(state: .needsAccessibility, at: dividerAnchor())
            return
        }
        let items = await AccessibilityClient.items()
        if let (group, dividerFrame) = group(of: items),
           let statusAreaMinX = await statusAreaMinX(around: dividerFrame),
           Divider.groupFits(group, dividerFrame: dividerFrame, statusAreaMinX: statusAreaMinX) {
            Self.log.info("group of \(group.count) fits; showing it")
            setShowingByChoice(true)
        } else {
            showPanel(listing: items)
        }
    }

    /// The left bound of the status area on the display that holds the divider's frame,
    /// or nil when no display holds it.
    private func statusAreaMinX(around dividerFrame: CGRect) async -> CGFloat? {
        let center = CGPoint(x: dividerFrame.midX, y: dividerFrame.midY)
        guard let screen = NSScreen.screens.first(where: { CGDisplayBounds($0.displayIdentifier).contains(center) }) else {
            return nil
        }
        return Divider.statusAreaMinX(
            displayFrame: CGDisplayBounds(screen.displayIdentifier),
            menuTitleFrames: await AccessibilityClient.frontMenuTitleFrames(),
            unobscuredTopRightWidth: screen.auxiliaryTopRightArea?.width
        )
    }

    // MARK: Group panel

    private func openPanel() async {
        guard AccessibilityClient.isTrusted else {
            panel.show(state: .needsAccessibility, at: dividerAnchor())
            return
        }
        showPanel(listing: await AccessibilityClient.items())
    }

    private func showPanel(listing items: [AccessibleItem]) {
        panel.show(state: .entries(groupEntries(of: items), isShownInMenuBar: isShowingByChoice), at: dividerAnchor())
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
        let group = Divider.groupItems(items.map(\.item), dividerFrame: dividerFrame, excludingProcess: ownIdentifier)
        return (group, dividerFrame)
    }

    private func groupEntries(of items: [AccessibleItem]) -> [GroupPanel.Entry] {
        guard let (group, _) = group(of: items) else { return [] }
        return group.compactMap { member in
            guard let accessible = items.first(where: { $0.item.isSameItem(as: member) }) else { return nil }
            let icon = NSRunningApplication(processIdentifier: member.processIdentifier)?.icon
            return GroupPanel.Entry(accessible: accessible, icon: icon)
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

    // MARK: Pressing a hidden icon

    private func press(_ entry: GroupPanel.Entry) {
        panel.close()
        pressTask?.cancel()
        pressTask = Task { await reveal(andPress: entry.accessible) }
    }

    private func reveal(andPress target: AccessibleItem) async {
        // A press that cancels an earlier one takes over the duty to hide the group again.
        let hidesAfterward = !isShowingByChoice
        if hidesAfterward {
            isShowingForPress = true
            applyLength()
        }
        defer {
            if hidesAfterward && !Task.isCancelled {
                isShowingForPress = false
                applyLength()
            }
        }
        guard let frame = await settledFrame(of: target) else {
            NSSound.beep()
            return
        }
        let pressed = AccessibilityClient.press(target.element)
        Self.log.info("pressed \(target.item.name, privacy: .public): \(pressed)")
        guard hidesAfterward else { return }
        var session = RevealSession(startTime: ProcessInfo.processInfo.systemUptime)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
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

    /// Waits until the icon lies on a display and has stopped moving, and returns its frame.
    private func settledFrame(of target: AccessibleItem) async -> CGRect? {
        var previous: CGRect?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
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
        panel.close()
        guard let button = dividerItem?.button else { return }
        let menu = NSMenu()
        let showItem = NSMenuItem(
            title: isShowingByChoice ? "Hide Icons" : "Show Hidden Icons",
            action: #selector(toggleShowing),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())
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
        menu.addItem(NSMenuItem(title: "Quit icecap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let bounds = button.bounds
        let location = NSPoint(x: bounds.minX, y: button.isFlipped ? bounds.maxY + 6 : bounds.minY - 6)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func toggleShowing() {
        setShowingByChoice(!isShowingByChoice)
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
    }

    /// Until the Accessibility permission is granted, checks for it every two seconds;
    /// once granted, restarts to place the divider as on a first launch.
    private func watchForTrust() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AccessibilityClient.isTrusted else { return }
            timer.invalidate()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trustTimer = nil
                guard !self.defaults.bool(forKey: Self.positionSeededKey) else { return }
                self.defaults.removeObject(forKey: Self.preferredPositionKey(Self.dividerAutosaveName))
                self.restart(reason: "Accessibility permission granted; placing the divider")
            }
        }
    }
}
