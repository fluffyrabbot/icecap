import CoreGraphics
import Foundation
import IcecapCore
import Testing

private func hiddenItem(
    _ processIdentifier: Int32,
    x: CGFloat,
    width: CGFloat = 32
) -> MenuBarItem {
    MenuBarItem(
        processIdentifier: processIdentifier,
        bundleIdentifier: "com.example.app\(processIdentifier)",
        applicationName: "App \(processIdentifier)",
        accessibilityDescription: nil,
        index: 0,
        frame: CGRect(x: x, y: 0, width: width, height: 33)
    )
}

@Suite struct MenuBarFitTests {
    let displays = [
        CGRect(x: 0, y: 0, width: 1512, height: 982),
        CGRect(x: 1512, y: -64, width: 1920, height: 1080),
    ]
    let mainDisplay: CGDirectDisplayID = 1
    let externalDisplay: CGDirectDisplayID = 2
    let frontPID: Int32 = 42
    let generation: SpacerLifecycle.Generation = 1

    private func warmFit(
        width: CGFloat = 120,
        display: CGDirectDisplayID = 2,
        frontPID: Int32 = 42,
        dividerX: CGFloat = 2896,
        statusAreaMinX: CGFloat = 2140,
        at time: TimeInterval = 100
    ) -> MenuBarFit {
        var fit = MenuBarFit()
        let group = [
            hiddenItem(10, x: -4500, width: 32),
            hiddenItem(11, x: -4500 + width - 32, width: 32),
        ]
        let recorded = fit.recordHiddenGroup(group, displays: displays, spacerGeneration: generation, at: time)
        #expect(recorded)
        fit.recordBoundary(
            displayIdentifier: display,
            frontApplicationProcessIdentifier: frontPID,
            dividerFrame: CGRect(x: dividerX, y: -64, width: 28, height: 30),
            statusAreaMinX: statusAreaMinX,
            spacerGeneration: generation,
            at: time
        )
        return fit
    }

    @Test func warmFittingClickRoutesImmediatelyToPeekAndSecondClickEndsActivity() {
        let fit = warmFit()
        let context = MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        )

        let first = fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 105
        )
        #expect(first == .startPeek(processIdentifiers: [10, 11]))

        let second = fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: .peeking,
            isShownWhereItFits: false,
            context: context,
            at: 106
        )
        #expect(second == .endActivity)
    }

    @Test func warmNonFittingClickRoutesToPanel() {
        // Width 358 + 8 clearance = 366; divider at 1000 - 366 = 634 < notch boundary 848.
        let fit = warmFit(
            width: 358,
            display: mainDisplay,
            dividerX: 1000,
            statusAreaMinX: 848,
            at: 100
        )
        let context = MenuBarFit.Context(
            displayIdentifier: mainDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        )

        let plan = fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 102
        )
        #expect(plan == .openPanel)
    }

    @Test func confirmedEmptyHiddenGroupOpensPanelEvenWithoutBoundary() {
        var fit = MenuBarFit()
        let recorded = fit.recordHiddenGroup([], displays: displays, spacerGeneration: generation, at: 100)
        #expect(recorded)
        let context = MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: 999,
            spacerGeneration: generation
        )

        #expect(fit.decision(for: context, at: 101) == .doesNotFit)
        #expect(fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 101
        ) == .openPanel)
    }

    @Test func midMoveGroupIsRejectedAndPreservesValidInventory() {
        var fit = warmFit(width: 120, at: 100)
        let midMoveGroup = [
            hiddenItem(10, x: -2375, width: 32),
            hiddenItem(11, x: 2855, width: 38),
        ]

        let recorded = fit.recordHiddenGroup(midMoveGroup, displays: displays, spacerGeneration: generation, at: 105)
        #expect(!recorded)
        #expect(fit.inventory?.width == 120)

        var coldFit = MenuBarFit()
        let coldRecorded = coldFit.recordHiddenGroup(midMoveGroup, displays: displays, spacerGeneration: generation, at: 105)
        #expect(!coldRecorded)
        let context = MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        )
        #expect(coldFit.decision(for: context, at: 105) == .unknown)
        #expect(coldFit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 105
        ) == .refreshAllThenRoute)
    }

    @Test func emptyDisplayListRejectsHiddenMeasurement() {
        var fit = MenuBarFit()
        let group = [hiddenItem(10, x: 900, width: 32)]
        let recorded = fit.recordHiddenGroup(group, displays: [], spacerGeneration: generation, at: 100)
        #expect(!recorded)
        #expect(fit.inventory == nil)
    }

    @Test func recordShownGroupExpandsWidthAndUnionsProcessesOnlyWithExistingBaseline() {
        var cold = MenuBarFit()
        let shown = [hiddenItem(10, x: 800, width: 32), hiddenItem(12, x: 900, width: 32)]
        cold.recordShownGroup(shown, spacerGeneration: generation, at: 100)
        #expect(cold.inventory == nil)

        var warm = warmFit(width: 200, at: 100)
        // Narrower shown group (e.g. clipped on a narrow display) must not shrink hidden width
        // or drop items from the cached panel inventory.
        warm.recordShownGroup([hiddenItem(12, x: 900, width: 32)], spacerGeneration: generation, at: 105)
        #expect(warm.inventory?.width == 200)
        #expect(warm.inventory?.items.count == 2)
        #expect(warm.inventory?.processIdentifiers == [10, 11, 12])
        #expect(warm.inventory?.measuredAt == 105)

        // Wider shown group with at least as many items updates both width and cached items.
        let expandedShown = [hiddenItem(10, x: 600, width: 32), hiddenItem(12, x: 900, width: 32)]
        warm.recordShownGroup(expandedShown, spacerGeneration: generation, at: 110)
        #expect(warm.inventory?.width == 332)
        #expect(warm.inventory?.items == expandedShown)
    }

    @Test func cachedGroupItemsReturnsOrderedItemsOnlyWhenInventoryIsValid() {
        var fit = warmFit(width: 120, at: 100)
        let context = MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        )
        #expect(fit.cachedGroupItems(for: context, at: 150)?.map(\.processIdentifier) == [10, 11])
        #expect(fit.cachedGroupItems(for: context, at: 100 + MenuBarFit.inventoryLifetime + 0.1) == nil)
        #expect(fit.cachedGroupItems(for: MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation + 1
        ), at: 110) == nil)

        let emptyRecorded = fit.recordHiddenGroup([], displays: displays, spacerGeneration: generation, at: 200)
        #expect(emptyRecorded)
        #expect(fit.cachedGroupItems(for: context, at: 205) == [])

        fit.invalidateInventory()
        #expect(fit.cachedGroupItems(for: context, at: 205) == nil)
    }

    @Test func perDisplayBoundariesStayWarmAcrossDisplaysUntilInvalidated() {
        let portraitDisplay: CGDirectDisplayID = 3
        var fit = warmFit(width: 240, display: mainDisplay, dividerX: 1000, statusAreaMinX: 848, at: 100)
        fit.recordBoundary(
            displayIdentifier: portraitDisplay,
            frontApplicationProcessIdentifier: frontPID,
            dividerFrame: CGRect(x: 600, y: 177, width: 28, height: 30),
            statusAreaMinX: 480,
            spacerGeneration: generation,
            at: 101
        )
        fit.recordBoundary(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            dividerFrame: CGRect(x: 2896, y: -64, width: 28, height: 30),
            statusAreaMinX: 2140,
            spacerGeneration: generation,
            at: 102
        )

        #expect(fit.decision(for: MenuBarFit.Context(
            displayIdentifier: mainDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        ), at: 105) == .doesNotFit)
        #expect(fit.decision(for: MenuBarFit.Context(
            displayIdentifier: portraitDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        ), at: 105) == .doesNotFit)
        #expect(fit.decision(for: MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        ), at: 105) == .fits(processIdentifiers: [10, 11]))

        fit.invalidateBoundary()
        #expect(fit.boundaries.isEmpty)
        #expect(fit.boundary(for: externalDisplay) == nil)
        #expect(fit.inventory != nil)
    }

    @Test func displayOrFrontApplicationMismatchRefreshesOnlyBoundary() {
        let fit = warmFit(display: externalDisplay, frontPID: 42, at: 100)

        let otherDisplay = MenuBarFit.Context(
            displayIdentifier: mainDisplay,
            frontApplicationProcessIdentifier: 42,
            spacerGeneration: generation
        )
        #expect(fit.hasValidInventory(for: otherDisplay, at: 105))
        #expect(!fit.hasValidBoundary(for: otherDisplay, at: 105))
        #expect(fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: otherDisplay,
            at: 105
        ) == .refreshBoundaryThenRoute)

        let otherApp = MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: 88,
            spacerGeneration: generation
        )
        #expect(fit.hasValidInventory(for: otherApp, at: 105))
        #expect(!fit.hasValidBoundary(for: otherApp, at: 105))
        #expect(fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: otherApp,
            at: 105
        ) == .refreshBoundaryThenRoute)
    }

    @Test func generationChangeInvalidatesBothInventoryAndBoundary() {
        let fit = warmFit(at: 100)
        let newGenerationContext = MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation + 1
        )

        #expect(!fit.hasValidInventory(for: newGenerationContext, at: 101))
        #expect(!fit.hasValidBoundary(for: newGenerationContext, at: 101))
        #expect(fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: newGenerationContext,
            at: 101
        ) == .refreshAllThenRoute)
    }

    @Test func lifetimeExpiryInvalidatesBoundaryThenInventory() {
        let fit = warmFit(at: 100)
        let context = MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        )

        #expect(fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 100 + MenuBarFit.boundaryLifetime
        ) == .startPeek(processIdentifiers: [10, 11]))

        #expect(fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 100 + MenuBarFit.boundaryLifetime + 0.01
        ) == .refreshBoundaryThenRoute)

        #expect(fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 100 + MenuBarFit.inventoryLifetime + 0.01
        ) == .refreshAllThenRoute)
    }

    @Test func permissionLossAndAlwaysShowAndPanelPriority() {
        let fit = warmFit(at: 100)
        let context = MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        )

        #expect(fit.primaryClickPlan(
            isPermitted: false,
            isPanelOpen: true,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 101
        ) == .closePanel)

        #expect(fit.primaryClickPlan(
            isPermitted: false,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 101
        ) == .showNeedsAccessibility)

        #expect(fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: false,
            activity: nil,
            isShownWhereItFits: true,
            context: context,
            at: 101
        ) == .disableAlwaysShow)
    }

    @Test func invalidationAndOwnershipQueries() {
        var fit = warmFit(at: 100)
        #expect(fit.ownsGroupProcess(10))
        #expect(fit.ownsGroupProcess(11))
        #expect(!fit.ownsGroupProcess(99))

        fit.invalidateBoundary()
        #expect(fit.boundary(for: externalDisplay) == nil)
        #expect(fit.boundaries.isEmpty)
        #expect(fit.inventory != nil)

        fit.invalidateInventory()
        #expect(fit.inventory == nil)
        #expect(!fit.ownsGroupProcess(10))

        fit = warmFit(at: 100)
        fit.invalidateAll()
        #expect(fit.inventory == nil)
        #expect(fit.boundaries.isEmpty)
    }

    @Test func pendingClickTrackerCancelsAndSupersedesCleanly() {
        let fit = MenuBarFit()
        let context = MenuBarFit.Context(
            displayIdentifier: externalDisplay,
            frontApplicationProcessIdentifier: frontPID,
            spacerGeneration: generation
        )
        #expect(fit.primaryClickPlan(
            isPermitted: true,
            isPanelOpen: false,
            hasPendingClick: true,
            activity: nil,
            isShownWhereItFits: false,
            context: context,
            at: 100
        ) == .cancelPendingClick)

        var tracker = PendingClickTracker()
        #expect(!tracker.isPending)
        let cancelledBeforeStart = tracker.cancel()
        #expect(!cancelledBeforeStart)

        let first = tracker.begin()
        #expect(tracker.isPending)
        let second = tracker.begin()
        #expect(first != second)
        let consumedFirst = tracker.consume(first)
        #expect(!consumedFirst)
        #expect(tracker.isPending)

        let cancelledSecond = tracker.cancel()
        #expect(cancelledSecond)
        #expect(!tracker.isPending)
        let consumedAfterCancel = tracker.consume(second)
        #expect(!consumedAfterCancel)

        let third = tracker.begin()
        let consumedThird = tracker.consume(third)
        #expect(consumedThird)
        #expect(!tracker.isPending)
    }
}
