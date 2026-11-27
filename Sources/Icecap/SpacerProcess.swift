import Foundation
import IcecapCore
import OSLog

/// A running `icecap-spacer` helper, which holds the spacer at one preferred position for
/// its whole life; to move the spacer, end the helper and start another. See `SpacerHelper`.
@MainActor
final class SpacerProcess {
    struct LaunchError: LocalizedError {
        let executableURL: URL
        let underlying: Error

        var errorDescription: String? {
            "could not start \(executableURL.path): \(underlying.localizedDescription)"
        }
    }

    static let log = Logger(subsystem: "com.memorysynchub.icecap", category: "spacer")

    /// The helper's executable, inside this application's bundle.
    static var executableURL: URL {
        Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/\(SpacerHelper.executableName).app/Contents/MacOS")
            .appending(path: SpacerHelper.executableName)
    }

    let preferredPosition: CGFloat
    var processIdentifier: Int32 { process.processIdentifier }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var lines = LineBuffer()

    /// Starts the helper.
    ///
    /// - Parameters:
    ///   - onReport: Called with each report from the helper.
    ///   - onExit: Called once the helper has exited, for whatever reason.
    init(
        preferredPosition: CGFloat,
        onReport: @escaping @MainActor (SpacerHelper.Report) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws {
        self.preferredPosition = preferredPosition
        process.executableURL = Self.executableURL
        process.arguments = [String(Double(preferredPosition))]
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data, onReport: onReport) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.output.fileHandleForReading.readabilityHandler = nil
                    onExit(status)
                }
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw LaunchError(executableURL: Self.executableURL, underlying: error)
        }
    }

    /// Tells the helper to hide or show the icons left of the spacer, returning whether the
    /// command was written to the helper's pipe.
    @discardableResult
    func send(_ command: SpacerHelper.Command) -> Bool {
        do {
            try input.fileHandleForWriting.write(contentsOf: SpacerHelper.line(command))
            return true
        } catch {
            // The helper has ended; `onExit` reports that.
            Self.log.error("could not send \(command.rawValue, privacy: .public) to the spacer: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Tells the helper to end, which removes the spacer; `onExit` reports when it has.
    func end() {
        // Closing its input ends the helper; the signal ends one that is not reading.
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func receive(_ data: Data, onReport: @MainActor (SpacerHelper.Report) -> Void) {
        for line in lines.append(data) {
            guard let report = SpacerHelper.Report(rawValue: line) else {
                Self.log.error("unknown report from the spacer: \(line, privacy: .public)")
                continue
            }
            onReport(report)
        }
    }
}
