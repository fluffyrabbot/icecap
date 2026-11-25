import CoreGraphics
import IcecapCore
import Testing

/// Frames below were measured on a 1512-point built-in display under macOS 26.7
/// (see docs/OBSERVATIONS.md); the divider belongs to process 1.
private func item(_ processIdentifier: Int32, _ bundle: String?, x: CGFloat, width: CGFloat = 38, index: Int = 0) -> MenuBarItem {
    MenuBarItem(
        processIdentifier: processIdentifier,
        bundleIdentifier: bundle,
        applicationName: bundle ?? "Unknown",
        accessibilityDescription: nil,
        index: index,
        frame: CGRect(x: x, y: 0, width: width, height: 33)
    )
}

@Suite struct DividerGroupTests {
    let others = [
        item(10, "com.google.Chrome", x: 714),
        item(11, "com.trongduong.snapzy", x: 785, width: 34),
        item(12, "io.tailscale.ipn.macsys", x: 935),
        item(13, "com.apple.systemuiserver", x: 1002),
        item(14, "com.apple.controlcenter", x: 1357, width: 157),
    ]

    @Test func groupHoldsTheIconsLeftOfTheDivider() {
        let divider = CGRect(x: 973, y: 0, width: 38, height: 33)
        let group = Divider.groupItems(others + [item(1, "icecap", x: 973)], dividerFrame: divider, excludingProcess: 1)
        #expect(group.map(\.processIdentifier) == [10, 11, 12])
    }

    @Test func iconsPushedOffTheDisplayStayInTheGroup() {
        let divider = CGRect(x: 973, y: 0, width: 38, height: 33)
        let pushedLeft = others.map { member -> MenuBarItem in
            var moved = member
            if member.frame.maxX <= 973 { moved.frame.origin.x -= 5_000 }
            return moved
        }
        let group = Divider.groupItems(pushedLeft, dividerFrame: divider, excludingProcess: 1)
        #expect(group.map(\.processIdentifier) == [10, 11, 12])
    }

    @Test func iconsOnAnotherRowOrNotLaidOutAreNotInTheGroup() {
        let divider = CGRect(x: 973, y: 0, width: 38, height: 33)
        var otherDisplay = item(20, "com.example.other", x: 500)
        otherDisplay.frame.origin.y = -64
        var notLaidOut = item(21, "com.apple.controlcenter", x: 0)
        notLaidOut.frame.size = .zero
        let group = Divider.groupItems([otherDisplay, notLaidOut], dividerFrame: divider, excludingProcess: 1)
        #expect(group.isEmpty)
    }

    @Test func groupIsOrderedLeftToRight() {
        let divider = CGRect(x: 973, y: 0, width: 38, height: 33)
        let group = Divider.groupItems(others.reversed(), dividerFrame: divider, excludingProcess: 1)
        #expect(group.map(\.frame.minX) == [714, 785, 935])
    }
}

@Suite struct InitialPositionTests {
    @Test func divisionLandsJustLeftOfTheLeftmostSystemIcon() {
        let items = [
            item(12, "io.tailscale.ipn.macsys", x: 935),
            item(13, "com.apple.systemuiserver", x: 1002),
            item(14, "com.apple.controlcenter", x: 1357, width: 157),
        ]
        let position = Divider.initialPreferredPosition(items: items, displayMaxX: 1512, fallback: 300)
        // 510 points separate the system icon's left edge from the display's right edge.
        #expect(position == 509)
    }

    @Test func withoutSystemIconsTheFallbackApplies() {
        let items = [item(12, "io.tailscale.ipn.macsys", x: 935)]
        #expect(Divider.initialPreferredPosition(items: items, displayMaxX: 1512, fallback: 300) == 300)
    }

    @Test func systemIconsThatAreNotLaidOutAreIgnored() {
        var hidden = item(14, "com.apple.controlcenter", x: 0)
        hidden.frame.size = .zero
        let items = [hidden, item(13, "com.apple.Spotlight", x: 1283, width: 32)]
        #expect(Divider.initialPreferredPosition(items: items, displayMaxX: 1512, fallback: 300) == 228)
    }
}

@Suite struct MenuBarItemTests {
    @Test func nameFallsBackToTheApplicationName() {
        var subject = item(10, "com.google.Chrome", x: 0)
        #expect(subject.name == "com.google.Chrome")
        subject.accessibilityDescription = ""
        #expect(subject.name == "com.google.Chrome")
        subject.accessibilityDescription = "Battery"
        #expect(subject.name == "Battery")
    }

    @Test func identityIgnoresPosition() {
        let before = item(10, "com.google.Chrome", x: -2000, index: 1)
        let after = item(10, "com.google.Chrome", x: 714, index: 1)
        let sibling = item(10, "com.google.Chrome", x: 714, index: 0)
        #expect(before.isSameItem(as: after))
        #expect(!before.isSameItem(as: sibling))
    }
}

@Suite struct SpacerPlacementTests {
    @Test func spacerOrdersBetweenTheDividerAndTheNextIcon() {
        // Observed preferred positions: divider 503, Karabiner 512. With 513 the spacer
        // landed left of Karabiner; it must lie in (503, 512).
        let position = Divider.spacerPreferredPosition(dividerPreferredPosition: 503)
        #expect(position > 503)
        #expect(position < 504)
    }

    @Test func spacerIsBesideTheDividerUntilTheDividerIsDragged() {
        #expect(Divider.isSpacerBesideDivider(spacerPreferredPosition: 503.5, dividerPreferredPosition: 503))
        // Dragging the divider with ⌘ records a new preferred position for it alone.
        #expect(!Divider.isSpacerBesideDivider(spacerPreferredPosition: 503.5, dividerPreferredPosition: 620))
    }
}

@Suite struct ExpansionTests {
    /// The built-in display of docs/OBSERVATIONS.md: 1512 points wide, 664 of them right
    /// of the camera housing, so the status area cannot start left of 848.
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// An external display above and right of it, as arranged on the observed machine.
    let external = CGRect(x: 1512, y: -64, width: 1920, height: 1080)

    @Test func groupWidthSpansFromTheLeftmostToTheRightmostIcon() {
        let group = [item(10, "a", x: -4286), item(11, "b", x: -4248, width: 34), item(12, "c", x: -4100)]
        #expect(Divider.groupWidth(group) == 224)
        #expect(Divider.groupWidth([]) == 0)
    }

    @Test func cameraHousingBoundsTheStatusAreaOnTheBuiltInDisplay() {
        let minX = Divider.statusAreaMinX(displayFrame: builtIn, menuTitleFrames: [], unobscuredTopRightWidth: 664)
        #expect(minX == 848)
    }

    @Test func menuTitlesBoundTheStatusAreaOnADisplayWithoutAHousing() {
        let titles = [
            CGRect(x: 1522, y: -64, width: 34, height: 30),
            CGRect(x: 2092, y: -64, width: 48, height: 30),
        ]
        let minX = Divider.statusAreaMinX(displayFrame: external, menuTitleFrames: titles, unobscuredTopRightWidth: nil)
        #expect(minX == 2140)
    }

    @Test func menuTitlesOnAnotherDisplayAreIgnored() {
        let titles = [CGRect(x: 2092, y: -64, width: 48, height: 30)]
        let minX = Divider.statusAreaMinX(displayFrame: builtIn, menuTitleFrames: titles, unobscuredTopRightWidth: 664)
        #expect(minX == 848)
    }

    @Test func groupFitsWhenItsWidthAndClearanceLieRightOfTheBound() {
        // 224 points of icons and 8 of clearance end at 2140 for a divider at 2372.
        #expect(Divider.groupFits(width: 224, dividerFrame: CGRect(x: 2372, y: -64, width: 24, height: 30), statusAreaMinX: 2140))
        #expect(!Divider.groupFits(width: 224, dividerFrame: CGRect(x: 2371, y: -64, width: 24, height: 30), statusAreaMinX: 2140))
    }

    @Test func groupMeasuredOnTheExternalDisplayDoesNotFitBesideTheHousing() {
        // The observed group of ten measured 358 points; on the built-in display the
        // divider sits near 1000, so the group would reach behind the housing at 848.
        let divider = CGRect(x: 1000, y: 0, width: 29, height: 24)
        let minX = Divider.statusAreaMinX(displayFrame: builtIn, menuTitleFrames: [], unobscuredTopRightWidth: 664)
        #expect(!Divider.groupFits(width: 358, dividerFrame: divider, statusAreaMinX: minX))
        let external = CGRect(x: 2896, y: -61, width: 29, height: 24)
        #expect(Divider.groupFits(width: 358, dividerFrame: external, statusAreaMinX: 2140))
    }

    @Test func emptyGroupNeverFits() {
        #expect(!Divider.groupFits(width: 0, dividerFrame: CGRect(x: 3000, y: 0, width: 24, height: 30), statusAreaMinX: 0))
    }
}

@Suite struct GroupPushedOffTests {
    let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -64, width: 1920, height: 1080)]

    @Test func aGroupWhollyLeftOfEveryDisplayIsPushedOff() {
        let group = [item(10, "a", x: -2375), item(11, "b", x: -2266)]
        #expect(Divider.isGroupPushedOff(group, displays: displays))
    }

    @Test func aGroupCaughtMidMoveIsNotPushedOff() {
        // Measured on the external display 0.66 s after the spacer widened: one icon had
        // moved off the displays and another had not, giving a width of 5,268 points.
        let group = [item(10, "a", x: -2375), item(11, "b", x: 2855)]
        #expect(!Divider.isGroupPushedOff(group, displays: displays))
    }

    @Test func anEmptyGroupIsPushedOff() {
        #expect(Divider.isGroupPushedOff([], displays: displays))
    }
}
