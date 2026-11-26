import AppKit
import Sparkle

/// Checks for and installs new versions of icecap with Sparkle, from the feed that
/// `SUFeedURL` names in the Info.plist. Sparkle asks the person, on the second launch,
/// whether to check automatically.
///
/// icecap has no Dock icon, so an update found by a scheduled check does not put
/// Sparkle's window in front of the person's work. The chevron is marked instead, and the
/// update is shown when the person chooses Install Update… from the context menu.
@MainActor
final class Updater: NSObject, @MainActor SPUStandardUserDriverDelegate {
    /// Called when an update starts or stops waiting for the person's attention.
    var onWaitingUpdateChange: (() -> Void)?
    private(set) var isUpdateWaiting = false {
        didSet { if isUpdateWaiting != oldValue { onWaitingUpdateChange?() } }
    }
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Checks for an update now, or shows the one already found.
    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// An update found by a scheduled check never opens a window, not even the one Sparkle
    /// would open for a background application near launch; the chevron's dot marks it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate { isUpdateWaiting = true }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        isUpdateWaiting = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        isUpdateWaiting = false
    }
}
