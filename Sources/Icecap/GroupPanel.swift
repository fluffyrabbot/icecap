import AppKit
import IcecapCore

/// The panel that drops from the divider and lists the icons of the group. It takes key
/// status without activating icecap, so that the person can type to narrow the list,
/// move through it with the arrow keys, choose with Return and close it with Escape.
@MainActor
final class GroupPanel: NSObject, NSSearchFieldDelegate {
    struct Entry {
        let accessible: AccessibleItem
        /// The icon's name as listed, numbered where several icons share it.
        let title: String
        let icon: NSImage?
    }

    enum State {
        case needsAccessibility
        case entries([Entry], isShownInMenuBar: Bool)
        /// How to arrange the icons, shown while the group is shown for arranging.
        case arrangementHelp(shortcutTitle: String?)
    }

    /// One row that can be chosen.
    private enum Row {
        case entry(Entry)
        case showInMenuBar
        case openAccessibilitySettings
        case done
    }

    static let width: CGFloat = 260
    private static let innerWidth = width - 12

    var onChoose: ((Entry) -> Void)?
    var onShowInMenuBar: (() -> Void)?
    var onDone: (() -> Void)?

    private var window: GroupPanelWindow?
    private var monitors: [Any] = []
    private var state = State.entries([], isShownInMenuBar: false)
    private var searchField: NSSearchField?
    private let rowStack = NSStackView()
    private var rows: [Row] = []
    private var rowViews: [GroupRow] = []
    private var selection = RowSelection(rowCount: 0)

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the panel with its top edge centred below the anchor, which is in screen
    /// coordinates with a bottom-left origin.
    func show(state: State, at anchor: NSPoint) {
        close()
        self.state = state
        let content = makeContent()
        reloadRows()
        let size = content.fittingSize
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(anchor) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height - 4)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        }
        let window = GroupPanelWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.title = "icecap group"
        window.contentView = content
        window.onCommand = { [weak self] command in self?.perform(command) ?? false }
        self.window = window
        window.orderFrontRegardless()
        // The arrangement help stays open while the person drags icons and clicks
        // elsewhere, and leaves the keyboard with the application in front.
        if case .arrangementHelp = state { return }
        window.onResignKey = { [weak self] in self?.close() }
        window.makeKey()
        if let searchField { window.makeFirstResponder(searchField) }
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
    }

    func close() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        // Cleared before ordering out, which resigns key status and calls back here.
        guard let window else { return }
        self.window = nil
        searchField = nil
        window.orderOut(nil)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Keyboard

    /// Performs a command from the search field or the panel. Returns whether it was handled.
    private func perform(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            selection.moveDown()
            updateHighlight()
        case #selector(NSResponder.moveUp(_:)):
            selection.moveUp()
            updateHighlight()
        case #selector(NSResponder.insertNewline(_:)):
            if let index = selection.index { choose(rows[index]) } else { NSSound.beep() }
        case #selector(NSResponder.cancelOperation(_:)):
            if let searchField, !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                reloadRows()
            } else {
                close()
            }
        default:
            return false
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        reloadRows()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        perform(commandSelector)
    }

    // MARK: Rows

    private func choose(_ row: Row) {
        switch row {
        case .entry(let entry):
            onChoose?(entry)
        case .showInMenuBar:
            close()
            onShowInMenuBar?()
        case .openAccessibilitySettings:
            close()
            Self.openAccessibilitySettings()
        case .done:
            close()
            onDone?()
        }
    }

    /// Lists the rows that match the search field, selects the first and fits the window
    /// to them, keeping its top edge in place.
    private func reloadRows() {
        let query = searchField?.stringValue ?? ""
        switch state {
        case .needsAccessibility:
            rows = [.openAccessibilitySettings]
        case .arrangementHelp:
            rows = [.done]
        case .entries(let entries, let isShownInMenuBar):
            let matching = ItemSearch.matches(entries, query: query) { entry in
                [entry.title, entry.accessible.item.applicationName]
            }
            rows = matching.map(Row.entry)
            if query.isEmpty, !entries.isEmpty, !isShownInMenuBar { rows.append(.showInMenuBar) }
        }
        for view in rowStack.arrangedSubviews { view.removeFromSuperview() }
        rowViews = rows.enumerated().map { index, row in
            let view = GroupRow(title: title(of: row), icon: icon(of: row)) { [weak self] in
                guard let self else { return }
                self.choose(self.rows[index])
            }
            view.onHover = { [weak self] in
                self?.selection.select(index)
                self?.updateHighlight()
            }
            return view
        }
        for view in rowViews { rowStack.addArrangedSubview(fullWidth(view)) }
        if rows.isEmpty, !query.isEmpty {
            rowStack.addArrangedSubview(note("No hidden icon matches \u{201C}\(query)\u{201D}."))
        }
        selection = RowSelection(rowCount: rows.count)
        updateHighlight()
        if let window, let content = window.contentView {
            let size = content.fittingSize
            var frame = window.frame
            frame.origin.y = frame.maxY - size.height
            frame.size = size
            window.setFrame(frame, display: true)
        }
    }

    private func updateHighlight() {
        for (index, view) in rowViews.enumerated() {
            view.isHighlighted = index == selection.index
        }
    }

    private func title(of row: Row) -> String {
        switch row {
        case .entry(let entry): entry.title
        case .showInMenuBar: "Show in Menu Bar"
        case .openAccessibilitySettings: "Open Accessibility Settings…"
        case .done: "Done"
        }
    }

    private func icon(of row: Row) -> NSImage? {
        if case .entry(let entry) = row { return entry.icon }
        return nil
    }

    // MARK: Content

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            background.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        searchField = nil
        switch state {
        case .needsAccessibility:
            stack.addArrangedSubview(note("icecap needs the Accessibility permission to list and open hidden icons."))
        case .arrangementHelp(let shortcutTitle):
            let listing = shortcutTitle.map { ", or press \($0) to list them" } ?? ""
            for text in [
                "icecap hides the icons left of the chevron. They are shown while this note is open.",
                "To keep an icon in view, hold ⌘ and drag it to the right of the chevron. To hide one, drag it to the left.",
                "If some icons do not appear, switch to an application with fewer menus, such as Finder.",
                "Click the chevron to show hidden icons for a moment\(listing).",
            ] {
                stack.addArrangedSubview(note(text))
            }
        case .entries(let entries, _):
            if entries.isEmpty {
                stack.addArrangedSubview(note("No icons are hidden. Hold ⌘ and drag icons to the left of the chevron to hide them."))
            } else {
                let field = NSSearchField()
                field.placeholderString = "Filter hidden icons"
                field.setAccessibilityLabel("Filter hidden icons")
                field.focusRingType = .none
                field.delegate = self
                searchField = field
                stack.addArrangedSubview(fullWidth(field))
            }
        }
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        stack.addArrangedSubview(rowStack)
        return background
    }

    private func fullWidth(_ view: NSView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true
        return view
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.width - 28
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            container.widthAnchor.constraint(equalToConstant: Self.innerWidth),
        ])
        return container
    }
}

/// A borderless panel that can take key status without activating the application. Key
/// commands that no view handles, Escape among them, go to `onCommand`.
final class GroupPanelWindow: NSPanel {
    var onCommand: ((Selector) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        if onCommand?(selector) != true { super.doCommand(by: selector) }
    }

    override func cancelOperation(_ sender: Any?) {
        _ = onCommand?(#selector(cancelOperation(_:)))
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// One row of the panel: an icon and a name, highlighted while selected, chosen by a
/// click or by the Accessibility press action. The pointer entering it selects it.
final class GroupRow: NSView {
    private let action: () -> Void
    var onHover: (() -> Void)?
    var isHighlighted = false {
        didSet { needsDisplay = true; label.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor }
    }
    private let label: NSTextField

    init(title: String, icon: NSImage?, action: @escaping () -> Void) {
        self.action = action
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var constraints = [
            heightAnchor.constraint(equalToConstant: 26),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ]
        if let icon {
            let imageView = NSImageView(image: icon)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            constraints += [
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    /// The arrangement help never takes key status, so its rows act on the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}
