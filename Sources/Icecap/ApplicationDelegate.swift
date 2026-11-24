import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var dividerController: DividerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Asked before the Accessibility permission, so that the person grants it to the
        // copy that stays.
        if Installation.offerMoveIfNeeded() { return }
        if !AccessibilityClient.isTrusted {
            AccessibilityClient.requestTrust()
        }
        let controller = DividerController()
        dividerController = controller
        Task { await controller.start() }
    }
}
