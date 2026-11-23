import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var dividerController: DividerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AccessibilityClient.isTrusted {
            AccessibilityClient.requestTrust()
        }
        let controller = DividerController()
        dividerController = controller
        Task { await controller.start() }
    }
}
