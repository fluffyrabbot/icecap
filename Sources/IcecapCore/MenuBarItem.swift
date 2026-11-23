import CoreGraphics

/// One icon in the status area of the menu bar, as the Accessibility API reports it.
///
/// Frames use global display coordinates with the origin at the top left of the main
/// display, the convention shared by the Accessibility API and the window server.
public struct MenuBarItem: Equatable, Sendable {
    /// The process that owns the icon.
    public var processIdentifier: Int32
    /// The owning application's bundle identifier, when it has one.
    public var bundleIdentifier: String?
    /// The owning application's localized name.
    public var applicationName: String
    /// The icon's accessibility description, when the application provides one.
    public var accessibilityDescription: String?
    /// The icon's position among the icons of its owning process.
    public var index: Int
    public var frame: CGRect

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        applicationName: String,
        accessibilityDescription: String?,
        index: Int,
        frame: CGRect
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.accessibilityDescription = accessibilityDescription
        self.index = index
        self.frame = frame
    }

    /// The name shown for the icon: its description when present, else its application's name.
    public var name: String {
        if let accessibilityDescription, !accessibilityDescription.isEmpty { return accessibilityDescription }
        return applicationName
    }

    /// Whether the two values denote the same icon, whatever its current position.
    public func isSameItem(as other: MenuBarItem) -> Bool {
        processIdentifier == other.processIdentifier && index == other.index
    }

    /// Whether the icon is laid out at all. The system reports icons that it does not
    /// lay out with an empty size.
    public var isLaidOut: Bool {
        frame.width > 0 && frame.height > 0
    }
}
