import CoreGraphics
import Foundation

/// The spacer runs in a helper process of its own, `icecap-spacer`, so that it can be added
/// again after the divider is dragged: a status item added again within a process that
/// has seen a drag is not reliably placed, while one added by a new process is (see
/// docs/OBSERVATIONS.md).
///
/// icecap starts the helper with the spacer's preferred position as its only argument,
/// sends it commands as lines on its standard input, and reads its reports as lines on its
/// standard output. The helper ends when its standard input closes, which happens however
/// icecap ends.
public enum SpacerHelper {
    public static let bundleIdentifier = "com.memorysynchub.icecap.spacer"
    public static let executableName = "icecap-spacer"
    public static let autosaveName = "icecap-spacer"

    /// Commands from icecap to the helper.
    public enum Command: String, Sendable, CaseIterable {
        /// Widen the spacer, pushing the icons to its left off the display.
        case hide
        /// Shrink the spacer to nothing, showing the icons to its left.
        case show

        public var spacerLength: CGFloat {
            switch self {
            case .hide: Divider.spacerHidingLength
            case .show: Divider.spacerShowingLength
            }
        }
    }

    /// Reports from the helper to icecap.
    public enum Report: String, Sendable, CaseIterable {
        /// The spacer has been added and given time to reach its preferred position.
        case placed
    }

    public static func line(_ command: Command) -> Data { Data((command.rawValue + "\n").utf8) }
    public static func line(_ report: Report) -> Data { Data((report.rawValue + "\n").utf8) }
}

/// Splits bytes read from a pipe into lines, holding back an incomplete last line until
/// the rest of it arrives.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// Appends the bytes and returns the lines they complete, without their line breaks.
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }
}
