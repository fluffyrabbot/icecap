import AppKit
import IcecapCore
import OSLog

/// Opening icecap again in a new process.
enum Relaunch {
    /// Opens the bundle at `bundlePath` half a second from now, from a process of its own,
    /// so that the calling process can end first.
    static func scheduleOpen(bundlePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"$0\"", bundlePath]
        try process.run()
    }
}

/// Moving icecap to an Applications folder when it runs from a place it cannot stay.
@MainActor
enum Installation {
    static let log = Logger(subsystem: "com.memorysynchub.icecap", category: "installation")
    /// How long to wait for an older copy to quit before replacing it.
    static let terminationWaitLimit: TimeInterval = 5

    /// Offers to move icecap to an Applications folder if it runs from a disk image or a
    /// translocated copy. Returns whether this process is ending so that the moved copy
    /// can start in its place.
    static func offerMoveIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let isReadOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let location = InstallLocation(bundlePath: bundleURL.path, isOnReadOnlyVolume: isReadOnly)
        guard location.needsMove else { return false }
        log.info("running from a place it cannot stay: \(bundleURL.path, privacy: .public)")

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move icecap to the Applications folder?"
        let reason = location == .translocated
            ? "macOS is running icecap from a temporary copy, because it was opened where it was downloaded."
            : "icecap is running from a disk image."
        alert.informativeText = reason + " It needs a lasting place to restart itself and to open at login."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            let destination = try install(bundleURL)
            try Relaunch.scheduleOpen(bundlePath: destination.path)
            NSApp.terminate(nil)
            return true
        } catch {
            log.error("could not move: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Copies the bundle into the first Applications folder that accepts it, replacing an
    /// older copy there, and returns the copy's location.
    private static func install(_ bundleURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let folders = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var lastError: Error?
        for folder in folders {
            let destination = folder.appendingPathComponent(bundleURL.lastPathComponent)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    terminateCopies(at: destination)
                    try fileManager.trashItem(at: destination, resultingItemURL: nil)
                }
                try fileManager.copyItem(at: bundleURL, to: destination)
                removeQuarantine(from: destination)
                log.info("moved to \(destination.path, privacy: .public)")
                return destination
            } catch {
                log.error("could not install in \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    /// Asks any running icecap launched from `bundleURL` to quit, and waits a while for it.
    private static func terminateCopies(at bundleURL: URL) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let ownIdentifier = ProcessInfo.processInfo.processIdentifier
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
            $0.processIdentifier != ownIdentifier
                && $0.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL
        }
        copies.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(terminationWaitLimit)
        while copies.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Removes the quarantine attribute from the copy. This copy already passed Gatekeeper
    /// to be running; left quarantined in its new place, it would be translocated again.
    private static func removeQuarantine(from bundleURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "-r", "com.apple.quarantine", bundleURL.path]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
