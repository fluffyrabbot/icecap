// icecap-spacer: the invisible status item kept immediately left of icecap's divider. See
// SpacerHelper in IcecapCore for why it runs in a process of its own, and for the lines it
// exchanges with icecap.
import AppKit
import IcecapCore
import OSLog

let log = Logger(subsystem: "com.memorysynchub.icecap", category: "spacer-helper")

let arguments = CommandLine.arguments
guard arguments.count == 2, let preferredPosition = Double(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: \(SpacerHelper.executableName) <preferred position>\n".utf8))
    exit(64)
}

// The system places a new status item by the preferred position recorded under its
// autosave name, so the position is written before the item is added. The item is added
// narrow, because one that is already wide when added lands at the far left.
let defaults = UserDefaults.standard
defaults.set(preferredPosition, forKey: "NSStatusItem Preferred Position \(SpacerHelper.autosaveName)")
defaults.removeObject(forKey: "NSStatusItem Visible \(SpacerHelper.autosaveName)")

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let spacer = NSStatusBar.system.statusItem(withLength: Divider.spacerShowingLength)
spacer.autosaveName = SpacerHelper.autosaveName
spacer.button?.setAccessibilityElement(false)

/// How long the system takes to place a new status item at its preferred position.
let placementDelay: TimeInterval = 0.8
DispatchQueue.main.asyncAfter(deadline: .now() + placementDelay) {
    FileHandle.standardOutput.write(SpacerHelper.line(.placed))
}

var lines = LineBuffer()

/// Reads what icecap has written and applies each complete command line.
@MainActor func readCommands() {
    var bytes = [UInt8](repeating: 0, count: 256)
    let count = read(STDIN_FILENO, &bytes, bytes.count)
    // icecap has ended, closing its end of the pipe.
    guard count > 0 else { exit(0) }
    for line in lines.append(Data(bytes[0..<count])) {
        guard let command = SpacerHelper.Command(rawValue: line) else {
            FileHandle.standardError.write(Data("unknown command: \(line)\n".utf8))
            exit(65)
        }
        let started = ContinuousClock.now
        spacer.length = command.spacerLength
        let elapsed = started.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        log.debug("applied \(command.rawValue, privacy: .public) in \(milliseconds, privacy: .public) ms")
    }
}

// The read source delivers on the main queue, where the status item lives.
let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
input.setEventHandler { MainActor.assumeIsolated { readCommands() } }
input.resume()
application.run()
