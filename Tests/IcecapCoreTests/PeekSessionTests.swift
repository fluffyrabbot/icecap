import CoreGraphics
import IcecapCore
import Testing

@Suite struct PeekSessionTests {
    @Test func staysWhileThePointerIsInTheMenuBar() {
        var session = PeekSession(startTime: 0)
        for time in stride(from: 0.2, through: 10, by: 0.2) {
            do { let ended = session.observe(isPointerPresent: true, isMenuOpen: false, time: time); #expect(!ended) }
        }
    }

    @Test func endsOnceThePointerHasBeenAwayForTheDepartureLimit() {
        var session = PeekSession(startTime: 0)
        session.observe(isPointerPresent: true, isMenuOpen: false, time: 0.2)
        do { let ended = session.observe(isPointerPresent: false, isMenuOpen: false, time: 1.1); #expect(!ended) }
        do { let ended = session.observe(isPointerPresent: false, isMenuOpen: false, time: 1.2); #expect(ended) }
    }

    @Test func anOpenMenuKeepsThePeekGoing() {
        var session = PeekSession(startTime: 0)
        session.observe(isPointerPresent: true, isMenuOpen: false, time: 0.2)
        do { let ended = session.observe(isPointerPresent: false, isMenuOpen: true, time: 5); #expect(!ended) }
        do { let ended = session.observe(isPointerPresent: false, isMenuOpen: false, time: 5.9); #expect(!ended) }
        do { let ended = session.observe(isPointerPresent: false, isMenuOpen: false, time: 6); #expect(ended) }
    }

    @Test func aPeekStartedAwayFromTheMenuBarAllowsTimeToReachIt() {
        var session = PeekSession(startTime: 10)
        do { let ended = session.observe(isPointerPresent: false, isMenuOpen: false, time: 12.9); #expect(!ended) }
        do { let ended = session.observe(isPointerPresent: false, isMenuOpen: false, time: 13); #expect(ended) }
    }

    @Test func staysEndedOnceEnded() {
        var session = PeekSession(startTime: 0)
        session.observe(isPointerPresent: false, isMenuOpen: false, time: 4)
        do { let ended = session.observe(isPointerPresent: true, isMenuOpen: true, time: 4.2); #expect(ended) }
        #expect(session.isFinished)
    }
}

@Suite struct AnyMenuOpenTests {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func window(_ processIdentifier: Int32, layer: Int, y: CGFloat) -> WindowDescription {
        WindowDescription(processIdentifier: processIdentifier, layer: layer, frame: CGRect(x: 900, y: y, width: 300, height: 400))
    }

    @Test func aPopUpMenuOfAnyProcessCounts() {
        #expect(MenuDetection.isAnyMenuOpen(windows: [window(99, layer: 101, y: 40)], processIdentifiers: [], displays: [display]))
    }

    @Test func aGroupOwnersRaisedWindowBelowTheMenuBarCounts() {
        #expect(MenuDetection.isAnyMenuOpen(windows: [window(7, layer: 3, y: 38)], processIdentifiers: [7], displays: [display]))
    }

    @Test func anotherProcessesRaisedWindowDoesNotCount() {
        #expect(!MenuDetection.isAnyMenuOpen(windows: [window(8, layer: 3, y: 38)], processIdentifiers: [7], displays: [display]))
    }

    @Test func aGroupOwnersOrdinaryWindowAtTheTopDoesNotCount() {
        #expect(!MenuDetection.isAnyMenuOpen(windows: [window(7, layer: 0, y: 33)], processIdentifiers: [7], displays: [display]))
    }

    @Test func aRaisedWindowFarBelowTheMenuBarDoesNotCount() {
        #expect(!MenuDetection.isAnyMenuOpen(windows: [window(7, layer: 3, y: 300)], processIdentifiers: [7], displays: [display]))
    }

    @Test func menuBarAndStatusItemWindowsDoNotCount() {
        let windows = [window(7, layer: 24, y: 0), window(7, layer: 25, y: 0)]
        #expect(!MenuDetection.isAnyMenuOpen(windows: windows, processIdentifiers: [7], displays: [display]))
    }
}
