import CoreGraphics
import IcecapCore
import Testing

@Suite struct MenuDetectionTests {
    /// Observed under macOS 26.7: the icon at (-729, 180) opened a menu at (-743, 208).
    let icon = CGRect(x: -729, y: 180, width: 35, height: 24)
    let observedMenu = WindowDescription(
        processIdentifier: 40317,
        layer: 101,
        frame: CGRect(x: -743, y: 208, width: 305, height: 248)
    )

    @Test func observedMenuCountsAsOpen() {
        #expect(MenuDetection.isMenuOpen(windows: [observedMenu], ownerProcessIdentifier: 40317, itemFrame: icon))
    }

    @Test func popUpMenuCountsEvenAgainstAStaleItemFrame() {
        // Observed: the Accessibility API kept reporting (-806, 180) for an icon that the
        // window server had already moved to another display.
        let stale = CGRect(x: -806, y: 180, width: 35, height: 24)
        let menu = WindowDescription(processIdentifier: 40317, layer: 101, frame: CGRect(x: 2612, y: -33, width: 305, height: 248))
        #expect(MenuDetection.isMenuOpen(windows: [menu], ownerProcessIdentifier: 40317, itemFrame: stale))
    }

    @Test func anotherProcessesMenuDoesNotCount() {
        #expect(!MenuDetection.isMenuOpen(windows: [observedMenu], ownerProcessIdentifier: 1, itemFrame: icon))
    }

    @Test func statusItemAndMenuBarWindowsDoNotCount() {
        let status = WindowDescription(processIdentifier: 40317, layer: MenuDetection.statusLayer, frame: icon)
        let bar = WindowDescription(processIdentifier: 40317, layer: MenuDetection.menuBarLayer, frame: icon)
        #expect(!MenuDetection.isMenuOpen(windows: [status, bar], ownerProcessIdentifier: 40317, itemFrame: icon))
    }

    @Test func distantWindowOfTheOwnerDoesNotCount() {
        let document = WindowDescription(
            processIdentifier: 40317,
            layer: 0,
            frame: CGRect(x: 200, y: 400, width: 800, height: 600)
        )
        #expect(!MenuDetection.isMenuOpen(windows: [document], ownerProcessIdentifier: 40317, itemFrame: icon))
    }

    @Test func popoverOnTheNormalLayerCounts() {
        let popover = WindowDescription(
            processIdentifier: 40317,
            layer: 0,
            frame: CGRect(x: -880, y: 206, width: 320, height: 400)
        )
        #expect(MenuDetection.isMenuOpen(windows: [popover], ownerProcessIdentifier: 40317, itemFrame: icon))
    }

    @Test func frameMustLieWhollyWithinADisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1080, y: 177, width: 1080, height: 1920)]
        #expect(MenuDetection.isWithinDisplay(CGRect(x: 714, y: 0, width: 38, height: 33), displays: displays))
        #expect(MenuDetection.isWithinDisplay(icon, displays: displays))
        #expect(!MenuDetection.isWithinDisplay(CGRect(x: -2264, y: 0, width: 33, height: 33), displays: displays))
        #expect(!MenuDetection.isWithinDisplay(CGRect(x: -10, y: 0, width: 33, height: 33), displays: displays))
        #expect(!MenuDetection.isWithinDisplay(.zero, displays: displays))
    }
}

@Suite struct RevealSessionTests {
    @Test func finishesWhenTheMenuCloses() {
        var session = RevealSession(startTime: 100)
        #expect(session.observe(isMenuOpen: false, time: 100.25) == .awaitingMenu)
        #expect(session.observe(isMenuOpen: true, time: 100.5) == .menuOpen)
        #expect(session.observe(isMenuOpen: true, time: 160) == .menuOpen)
        #expect(session.observe(isMenuOpen: false, time: 160.25) == .menuOpen)
        #expect(session.observe(isMenuOpen: false, time: 160.5) == .finished)
    }

    /// Observed under macOS 26.7: an open menu's window was missing from one listing of
    /// on-screen windows while the menu stayed open.
    @Test func oneMissedObservationDoesNotCloseTheMenu() {
        var session = RevealSession(startTime: 0)
        session.observe(isMenuOpen: true, time: 0.25)
        #expect(session.observe(isMenuOpen: false, time: 0.5) == .menuOpen)
        #expect(session.observe(isMenuOpen: true, time: 0.75) == .menuOpen)
        #expect(session.observe(isMenuOpen: false, time: 1.0) == .menuOpen)
        #expect(session.observe(isMenuOpen: false, time: 1.25) == .finished)
    }

    @Test func finishesWhenNoMenuAppearsInTime() {
        var session = RevealSession(startTime: 100)
        #expect(session.observe(isMenuOpen: false, time: 102.9) == .awaitingMenu)
        #expect(session.observe(isMenuOpen: false, time: 100 + RevealSession.menuWaitLimit) == .finished)
    }

    @Test func staysFinished() {
        var session = RevealSession(startTime: 0)
        session.observe(isMenuOpen: false, time: 10)
        #expect(session.observe(isMenuOpen: true, time: 11) == .finished)
    }
}
