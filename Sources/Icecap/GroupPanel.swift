import AppKit

/// The panel that drops from the divider and lists the icons of the group.
@MainActor
final class GroupPanel: NSObject {
    struct Entry {
        let accessible: AccessibleItem
        let icon: NSImage?
    }

    enum State {
        case needsAccessibility
        case entries([Entry], isShownInMenuBar: Bool)
    }

    static let width: CGFloat = 260

    var onChoose: ((Entry) -> Void)?
    var onShowInMenuBar: (() -> Void)?

    private var window: GroupPanelWindow?
    private var monitors: [Any] = []

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the panel with its top edge centred below the anchor, which is in screen
    /// coordinates with a bottom-left origin.
    func show(state: State, at anchor: NSPoint) {
        close()
        let content = makeContent(for: state)
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
        window.onCancel = { [weak self] in self?.close() }
        window.orderFrontRegardless()
        window.makeKey()
        self.window = window
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
        window?.orderOut(nil)
        window = nil
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Content

    private func makeContent(for state: State) -> NSView {
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
        stack.spacing = 2
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

        switch state {
        case .needsAccessibility:
            stack.addArrangedSubview(note("icecap needs the Accessibility permission to list and open hidden icons."))
            stack.addArrangedSubview(fullWidth(GroupRow(title: "Open Accessibility Settings…", icon: nil) { [weak self] in
                self?.close()
                Self.openAccessibilitySettings()
            }, in: stack))
        case .entries(let entries, let isShownInMenuBar):
            if entries.isEmpty {
                stack.addArrangedSubview(note("No icons are hidden. Hold ⌘ and drag icons to the left of the chevron to hide them."))
            } else {
                stack.addArrangedSubview(heading("Hidden icons"))
                for entry in entries {
                    let row = GroupRow(title: entry.accessible.item.name, icon: entry.icon) { [weak self] in
                        self?.onChoose?(entry)
                    }
                    stack.addArrangedSubview(fullWidth(row, in: stack))
                }
                if !isShownInMenuBar {
                    stack.addArrangedSubview(fullWidth(GroupRow(title: "Show in Menu Bar", icon: nil) { [weak self] in
                        self?.close()
                        self?.onShowInMenuBar?()
                    }, in: stack))
                }
            }
        }
        return background
    }

    private func fullWidth(_ view: NSView, in stack: NSStackView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Self.width - stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
        return view
    }

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
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
            container.widthAnchor.constraint(equalToConstant: Self.width - 12),
        ])
        return container
    }
}

/// A borderless panel that can take key status without activating the application, so
/// that Escape closes it.
final class GroupPanelWindow: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// One row of the panel: an icon and a name, highlighted under the pointer, chosen by a
/// click or by the Accessibility press action.
final class GroupRow: NSView {
    private let action: () -> Void
    private var isHighlighted = false {
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

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }
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
