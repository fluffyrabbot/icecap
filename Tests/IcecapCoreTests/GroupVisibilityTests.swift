import IcecapCore
import Testing

@Suite struct GroupVisibilityTests {
    @Test func hiddenWithNoActivityAndNoChoiceToShow() {
        let visibility = GroupVisibility(alwaysShowsWhereItFits: false, isPermitted: true)
        #expect(visibility.isHidden)
    }

    @Test func neverHiddenWithoutThePermission() {
        let visibility = GroupVisibility(alwaysShowsWhereItFits: false, isPermitted: false)
        #expect(!visibility.isHidden)
    }

    @Test func shownWhereItFitsOnlyWhileItFits() {
        var visibility = GroupVisibility(alwaysShowsWhereItFits: true, isPermitted: true)
        #expect(visibility.isHidden)
        visibility.fits = true
        #expect(visibility.isShownWhereItFits)
        #expect(!visibility.isHidden)
        visibility.fits = false
        #expect(visibility.isHidden)
    }

    @Test func turningTheChoiceOffForgetsTheFit() {
        var visibility = GroupVisibility(alwaysShowsWhereItFits: true, isPermitted: true)
        visibility.fits = true
        visibility.alwaysShowsWhereItFits = false
        #expect(!visibility.fits)
        visibility.alwaysShowsWhereItFits = true
        #expect(visibility.isHidden)
    }

    @Test func anActivityShowsTheGroupUntilItEnds() {
        var visibility = GroupVisibility(alwaysShowsWhereItFits: false, isPermitted: true)
        let ticket = visibility.begin(.peeking)
        #expect(!visibility.isHidden)
        do { let ended = visibility.end(ticket); #expect(ended) }
        #expect(visibility.isHidden)
    }

    @Test func aSupersededActivityCannotEndItsSuccessor() {
        var visibility = GroupVisibility(alwaysShowsWhereItFits: false, isPermitted: true)
        let peek = visibility.begin(.peeking)
        let press = visibility.begin(.pressing)
        #expect(!visibility.isCurrent(peek))
        do { let ended = visibility.end(peek); #expect(!ended) }
        #expect(visibility.activity == .pressing)
        #expect(!visibility.isHidden)
        do { let ended = visibility.end(press); #expect(ended) }
        #expect(visibility.isHidden)
    }

    @Test func aRepeatedActivityGetsANewTicket() {
        var visibility = GroupVisibility(alwaysShowsWhereItFits: false, isPermitted: true)
        let first = visibility.begin(.peeking)
        let second = visibility.begin(.peeking)
        #expect(first != second)
        do { let ended = visibility.end(first); #expect(!ended) }
        #expect(visibility.activity == .peeking)
    }

    @Test func endingAnActivityLeavesTheChoiceToShowWhereItFits() {
        var visibility = GroupVisibility(alwaysShowsWhereItFits: true, isPermitted: true)
        visibility.fits = true
        let press = visibility.begin(.pressing)
        visibility.end(press)
        #expect(!visibility.isHidden)
    }

    @Test func endActivityEndsWhateverIsUnderWay() {
        var visibility = GroupVisibility(alwaysShowsWhereItFits: false, isPermitted: true)
        let arranging = visibility.begin(.arranging)
        visibility.endActivity()
        #expect(visibility.activity == nil)
        do { let ended = visibility.end(arranging); #expect(!ended) }
        #expect(visibility.isHidden)
    }
}
