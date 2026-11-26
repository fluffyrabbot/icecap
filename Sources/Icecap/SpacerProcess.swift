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
    /// Whether `end()` was called, so that the helper's exit is expected.
    private var isEnding = false

    /// Starts the helper.
    ///
    /// - Parameters:
    ///   - onPlaced: Called once the spacer has reached its preferred position.
    ///   - onUnexpectedExit: Called if the helper ends without `end()` having been called.
    init(
        preferredPosition: CGFloat,
        onPlaced: @escaping @MainActor () -> Void,
        onUnexpectedExit: @escaping @MainActor (Int32) -> Void
    ) throws {
        self.preferredPosition = preferredPosition
        process.executableURL = Self.executableURL
        process.arguments = [String(Double(preferredPosition))]
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data, onPlaced: onPlaced) }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isEnding else { return }
                    self.output.fileHandleForReading.readabilityHandler = nil
                    onUnexpectedExit(status)
                }
            }
        }
        do {
            try process.run()
        } catch {
            throw LaunchError(executableURL: Self.executableURL, underlying: error)
        }
    }

    /// Tells the helper to hide or show the icons left of the spacer.
    func send(_ command: SpacerHelper.Command) {
        do {
            try input.fileHandleForWriting.write(contentsOf: SpacerHelper.line(command))
        } catch {
            // The helper has ended; its termination handler reports that.
            Self.log.error("could not send \(command.rawValue, privacy: .public) to the spacer: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ends the helper, which removes the spacer, and returns once it has exited.
    func end() async {
        isEnding = true
        output.fileHandleForReading.readabilityHandler = nil
        // Closing its input ends the helper; the signal ends one that is not reading.
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func receive(_ data: Data, onPlaced: @MainActor () -> Void) {
        guard !isEnding else { return }
        for line in lines.append(data) {
            guard let report = SpacerHelper.Report(rawValue: line) else {
                Self.log.error("unknown report from the spacer: \(line, privacy: .public)")
                continue
            }
            switch report {
            case .placed: onPlaced()
            }
        }
    }
}
