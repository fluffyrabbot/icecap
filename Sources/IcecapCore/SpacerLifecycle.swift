import CoreGraphics
import Foundation

/// The life of the spacer's helpers, one at a time, as events about them arrive; see
/// `SpacerHelper`.
///
/// A helper holds the spacer at one preferred position for its whole life, so a new
/// position takes a new helper, started only once the last has exited, because both read
/// and write the same defaults. Each helper is numbered by its generation, and an event
/// about a generation other than the current one is ignored: it concerns a helper that
/// has already been replaced.
///
/// A helper that exits unexpectedly, is not placed in time, or pushes the divider off
/// every display has failed. After `failureLimit` failures at one position within
/// `failureWindow` the lifecycle gives up, leaving the group shown, until the position
/// changes or a retry is asked for. A new position starts the count afresh, so dragging
/// the divider never counts against it.
public struct SpacerLifecycle: Equatable, Sendable {
    public typealias Generation = Int

    /// How many failures at one position within `failureWindow` end the attempts to place
    /// the spacer.
    public static let failureLimit = 3
    /// How long, in seconds, a failure counts towards `failureLimit`.
    public static let failureWindow: TimeInterval = 60
    /// How long a helper may take to report that it has been placed.
    public static let placementTimeLimit = Duration.seconds(5)

    public enum Phase: Equatable, Sendable {
        /// No helper, and no position to start one at yet.
        case absent
        /// The helper has started and not yet reported that it has been placed.
        case starting(Generation)
        /// The helper's spacer lies beside the divider and may widen.
        case placed(Generation)
        /// The helper has been told to end; what follows its exit is `next`.
        case stopping(Generation, next: Next)
        /// Placing the spacer failed too often; the group stays shown.
        case failed
    }

    public enum Next: Equatable, Sendable {
        /// Start a helper at the current position.
        case start
        /// Give up.
        case fail
    }

    public enum Event: Equatable, Sendable {
        /// The spacer's preferred position, beside the divider's, is now this.
        case positionChanged(CGFloat)
        /// The helper reported that its spacer has been placed.
        case placed(Generation)
        /// The helper's process has exited, or could not be launched.
        case exited(Generation)
        /// The helper did not report that it was placed within `placementTimeLimit`.
        case placementTimedOut(Generation)
        /// The divider lay off every display after the spacer widened.
        case dividerPushedOff(Generation)
        /// The person asked to try placing the spacer again.
        case retry
    }

    public enum Effect: Equatable, Sendable {
        /// Start a helper of this generation at this preferred position.
        case start(Generation, position: CGFloat)
        /// Tell the helper of this generation to end.
        case stop(Generation)
    }

    public private(set) var phase: Phase = .absent
    /// The preferred position the spacer should have, once known.
    public private(set) var position: CGFloat?
    /// When the failures at the current position that still count happened, as system
    /// uptimes.
    private var failureTimes: [TimeInterval] = []
    private var lastGeneration: Generation = 0

    public init() {}

    /// The generation of the helper whose spacer is placed, if any.
    public var placedGeneration: Generation? {
        if case .placed(let generation) = phase { generation } else { nil }
    }

    public var isFailed: Bool { phase == .failed }

    /// The failures at the current position that counted when last recorded.
    public var failureCount: Int { failureTimes.count }

    /// Advances the lifecycle by one event, which happened at `time`, a system uptime, and
    /// returns what must be done to the helpers.
    public mutating func handle(_ event: Event, at time: TimeInterval) -> [Effect] {
        switch event {
        case .positionChanged(let newPosition):
            if let position, abs(position - newPosition) < 0.01 { return [] }
            position = newPosition
            failureTimes = []
            switch phase {
            case .absent, .failed:
                return start()
            case .starting(let generation), .placed(let generation):
                phase = .stopping(generation, next: .start)
                return [.stop(generation)]
            case .stopping(let generation, _):
                phase = .stopping(generation, next: .start)
                return []
            }

        case .placed(let generation):
            guard phase == .starting(generation) else { return [] }
            phase = .placed(generation)
            return []

        case .exited(let generation):
            switch phase {
            case .stopping(generation, .start):
                return start()
            case .stopping(generation, .fail):
                phase = .failed
                return []
            case .starting(generation), .placed(generation):
                if recordFailure(at: time) {
                    phase = .failed
                    return []
                }
                return start()
            default:
                return []
            }

        case .placementTimedOut(let generation):
            guard phase == .starting(generation) else { return [] }
            return fail(generation, at: time)

        case .dividerPushedOff(let generation):
            guard phase == .placed(generation) else { return [] }
            return fail(generation, at: time)

        case .retry:
            switch phase {
            case .failed:
                failureTimes = []
                return start()
            case .stopping(let generation, .fail):
                failureTimes = []
                phase = .stopping(generation, next: .start)
                return []
            default:
                return []
            }
        }
    }

    /// Starts a helper at the current position, if one is known.
    private mutating func start() -> [Effect] {
        guard let position else {
            phase = .absent
            return []
        }
        lastGeneration += 1
        phase = .starting(lastGeneration)
        return [.start(lastGeneration, position: position)]
    }

    /// Counts a failure of the running helper and ends it, to be followed by another
    /// unless failures have reached the limit.
    private mutating func fail(_ generation: Generation, at time: TimeInterval) -> [Effect] {
        phase = .stopping(generation, next: recordFailure(at: time) ? .fail : .start)
        return [.stop(generation)]
    }

    /// Records a failure, forgets those that no longer count, and returns whether the
    /// failures that count have reached the limit.
    private mutating func recordFailure(at time: TimeInterval) -> Bool {
        failureTimes = failureTimes.filter { time - $0 < Self.failureWindow } + [time]
        return failureTimes.count >= Self.failureLimit
    }
}
