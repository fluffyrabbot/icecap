import CoreGraphics
import IcecapCore
import Testing

@Suite struct SpacerLifecycleTests {
    /// A lifecycle whose first helper, generation 1, has been placed at 300.5.
    private func placed() -> SpacerLifecycle {
        var lifecycle = SpacerLifecycle()
        _ = lifecycle.handle(.positionChanged(300.5))
        _ = lifecycle.handle(.placed(1))
        return lifecycle
    }

    @Test func startsOnceAPositionIsKnown() {
        var lifecycle = SpacerLifecycle()
        #expect(lifecycle.phase == .absent)
        do { let effects = lifecycle.handle(.positionChanged(300.5)); #expect(effects == [.start(1, position: 300.5)]) }
        #expect(lifecycle.phase == .starting(1))
        do { let effects = lifecycle.handle(.placed(1)); #expect(effects == []) }
        #expect(lifecycle.placedGeneration == 1)
    }

    @Test func anUnchangedPositionDoesNothing() {
        var lifecycle = placed()
        do { let effects = lifecycle.handle(.positionChanged(300.5)); #expect(effects == []) }
        #expect(lifecycle.placedGeneration == 1)
    }

    @Test func aDragEndsTheHelperBeforeStartingTheNext() {
        var lifecycle = placed()
        do { let effects = lifecycle.handle(.positionChanged(420.5)); #expect(effects == [.stop(1)]) }
        #expect(lifecycle.placedGeneration == nil)
        do { let effects = lifecycle.handle(.exited(1)); #expect(effects == [.start(2, position: 420.5)]) }
        #expect(lifecycle.phase == .starting(2))
    }

    @Test func dragsWhileAHelperEndsStartOnlyTheLastPosition() {
        var lifecycle = placed()
        _ = lifecycle.handle(.positionChanged(420.5))
        do { let effects = lifecycle.handle(.positionChanged(460.5)); #expect(effects == []) }
        do { let effects = lifecycle.handle(.positionChanged(500.5)); #expect(effects == []) }
        do { let effects = lifecycle.handle(.exited(1)); #expect(effects == [.start(2, position: 500.5)]) }
    }

    @Test func aDragWhileStartingReplacesTheStartingHelper() {
        var lifecycle = SpacerLifecycle()
        _ = lifecycle.handle(.positionChanged(300.5))
        do { let effects = lifecycle.handle(.positionChanged(420.5)); #expect(effects == [.stop(1)]) }
        // The replaced helper's late report is ignored.
        do { let effects = lifecycle.handle(.placed(1)); #expect(effects == []) }
        #expect(lifecycle.placedGeneration == nil)
        do { let effects = lifecycle.handle(.exited(1)); #expect(effects == [.start(2, position: 420.5)]) }
    }

    @Test func eventsAboutAnEarlierGenerationAreIgnored() {
        var lifecycle = placed()
        _ = lifecycle.handle(.positionChanged(420.5))
        _ = lifecycle.handle(.exited(1))
        _ = lifecycle.handle(.placed(2))
        do { let effects = lifecycle.handle(.exited(1)); #expect(effects == []) }
        do { let effects = lifecycle.handle(.placementTimedOut(1)); #expect(effects == []) }
        do { let effects = lifecycle.handle(.dividerPushedOff(1)); #expect(effects == []) }
        #expect(lifecycle.placedGeneration == 2)
    }

    @Test func dragsDoNotCountAsFailures() {
        var lifecycle = placed()
        for (index, position) in [420.5, 460.5, 500.5, 540.5, 580.5].enumerated() {
            let generation = index + 1
            _ = lifecycle.handle(.positionChanged(CGFloat(position)))
            _ = lifecycle.handle(.exited(generation))
            _ = lifecycle.handle(.placed(generation + 1))
        }
        #expect(lifecycle.failureCount == 0)
        #expect(lifecycle.placedGeneration == 6)
    }

    @Test func anUnexpectedExitStartsAnotherHelper() {
        var lifecycle = placed()
        do { let effects = lifecycle.handle(.exited(1)); #expect(effects == [.start(2, position: 300.5)]) }
        #expect(lifecycle.failureCount == 1)
    }

    @Test func aPlacementThatTakesTooLongIsRetried() {
        var lifecycle = SpacerLifecycle()
        _ = lifecycle.handle(.positionChanged(300.5))
        do { let effects = lifecycle.handle(.placementTimedOut(1)); #expect(effects == [.stop(1)]) }
        do { let effects = lifecycle.handle(.exited(1)); #expect(effects == [.start(2, position: 300.5)]) }
        // A time limit that passes after the helper was placed changes nothing.
        _ = lifecycle.handle(.placed(2))
        do { let effects = lifecycle.handle(.placementTimedOut(2)); #expect(effects == []) }
        #expect(lifecycle.placedGeneration == 2)
    }

    @Test func givesUpAfterTheFailureLimitAtOnePosition() {
        var lifecycle = placed()
        _ = lifecycle.handle(.dividerPushedOff(1))
        _ = lifecycle.handle(.exited(1))
        _ = lifecycle.handle(.placed(2))
        _ = lifecycle.handle(.dividerPushedOff(2))
        _ = lifecycle.handle(.exited(2))
        _ = lifecycle.handle(.placed(3))
        do { let effects = lifecycle.handle(.dividerPushedOff(3)); #expect(effects == [.stop(3)]) }
        #expect(lifecycle.phase == .stopping(3, next: .fail))
        do { let effects = lifecycle.handle(.exited(3)); #expect(effects == []) }
        #expect(lifecycle.isFailed)
    }

    @Test func crashesReachTheLimitToo() {
        var lifecycle = placed()
        _ = lifecycle.handle(.exited(1))
        _ = lifecycle.handle(.exited(2))
        do { let effects = lifecycle.handle(.exited(3)); #expect(effects == []) }
        #expect(lifecycle.isFailed)
    }

    @Test func verifiedHidingClearsTheFailures() {
        var lifecycle = placed()
        _ = lifecycle.handle(.exited(1))
        _ = lifecycle.handle(.placed(2))
        _ = lifecycle.handle(.hidingVerified(2))
        #expect(lifecycle.failureCount == 0)
    }

    @Test func aRetryStartsAgainAfterGivingUp() {
        var lifecycle = placed()
        _ = lifecycle.handle(.exited(1))
        _ = lifecycle.handle(.exited(2))
        _ = lifecycle.handle(.exited(3))
        do { let effects = lifecycle.handle(.retry); #expect(effects == [.start(4, position: 300.5)]) }
        #expect(lifecycle.failureCount == 0)
    }

    @Test func aRetryWhileGivingUpStartsOnceTheHelperHasEnded() {
        var lifecycle = placed()
        _ = lifecycle.handle(.dividerPushedOff(1))
        _ = lifecycle.handle(.exited(1))
        _ = lifecycle.handle(.placed(2))
        _ = lifecycle.handle(.dividerPushedOff(2))
        _ = lifecycle.handle(.exited(2))
        _ = lifecycle.handle(.placed(3))
        _ = lifecycle.handle(.dividerPushedOff(3))
        #expect(lifecycle.phase == .stopping(3, next: .fail))
        do { let effects = lifecycle.handle(.retry); #expect(effects == []) }
        do { let effects = lifecycle.handle(.exited(3)); #expect(effects == [.start(4, position: 300.5)]) }
    }

    @Test func aNewPositionStartsAgainAfterGivingUp() {
        var lifecycle = placed()
        _ = lifecycle.handle(.exited(1))
        _ = lifecycle.handle(.exited(2))
        _ = lifecycle.handle(.exited(3))
        do { let effects = lifecycle.handle(.positionChanged(420.5)); #expect(effects == [.start(4, position: 420.5)]) }
        #expect(lifecycle.failureCount == 0)
    }

    @Test func aRetryDoesNothingWhileTheSpacerIsPlaced() {
        var lifecycle = placed()
        do { let effects = lifecycle.handle(.retry); #expect(effects == []) }
        #expect(lifecycle.placedGeneration == 1)
    }
}
