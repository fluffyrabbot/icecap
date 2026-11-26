import AppKit
import ApplicationServices
import IcecapCore

/// A menu bar icon together with the Accessibility element that controls it.
struct AccessibleItem: @unchecked Sendable {
    var item: MenuBarItem
    let element: AXUIElement
}

/// The owner of a running process, captured on the main actor for use elsewhere.
private struct ProcessOwner: Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let name: String
}

/// Reads and presses other applications' menu bar icons through the Accessibility API.
enum AccessibilityClient {
    /// How long one Accessibility request may take before the application is skipped.
    static let requestTimeout: Float = 0.25

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system to show its prompt for granting the Accessibility permission.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Every menu bar icon of every running application, including this one, or of the
    /// given process alone. The requests run off the main thread, so that this
    /// application can answer its own.
    @MainActor
    static func items(ofProcess processIdentifier: Int32? = nil) async -> [AccessibleItem] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            processIdentifier == nil || $0.processIdentifier == processIdentifier
        }
        let owners = applications.map { application in
            ProcessOwner(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                name: application.localizedName ?? application.bundleIdentifier ?? "Unknown"
            )
        }
        return await Task.detached(priority: .userInitiated) {
            owners.flatMap(readItems(of:))
        }.value
    }

    /// The frames of the front application's menu titles, the Apple menu included, as
    /// laid out on the display whose menu bar is active: none for an application that has
    /// no menu bar, and nil when the menu bar could not be read, as when its owner does
    /// not answer in time.
    @MainActor
    static func frontMenuTitleFrames() async -> [CGRect]? {
        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let application = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(application, requestTimeout)
            var bar: CFTypeRef?
            switch AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &bar) {
            case .success: break
            case .noValue, .attributeUnsupported: return []
            default: return nil
            }
            guard let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
            var children: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
                let elements = children as? [AXUIElement]
            else { return nil }
            return elements.compactMap(frame(of:))
        }.value
    }

    /// The current frame of the element, in global coordinates with a top-left origin.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let position = point(of: element, attribute: kAXPositionAttribute),
            let size = size(of: element, attribute: kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Presses the icon as a click would. Some owners open their menu yet report that the
    /// action could not complete, so that result is treated as success.
    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return result == .success || result == .cannotComplete
    }

    private static func readItems(of owner: ProcessOwner) -> [AccessibleItem] {
        let application = AXUIElementCreateApplication(owner.processIdentifier)
        AXUIElementSetMessagingTimeout(application, requestTimeout)
        var bar: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &bar) == .success,
            let bar, CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return [] }
        var children: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
            let elements = children as? [AXUIElement]
        else { return [] }
        return elements.enumerated().compactMap { index, element in
            guard let frame = frame(of: element) else { return nil }
            var description: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
            let item = MenuBarItem(
                processIdentifier: owner.processIdentifier,
                bundleIdentifier: owner.bundleIdentifier,
                applicationName: owner.name,
                accessibilityDescription: description as? String,
                index: index,
                frame: frame
            )
            return AccessibleItem(item: item, element: element)
        }
    }

    private static func axValue(of element: AXUIElement, attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
            let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        return (raw as! AXValue)
    }

    private static func point(of element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = axValue(of: element, attribute: attribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func size(of element: AXUIElement, attribute: String) -> CGSize? {
        guard let value = axValue(of: element, attribute: attribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
}
