import Foundation
import IcecapCore
import Testing

@Suite struct SpacerHelperTests {
    @Test func eachCommandIsOneLineThatReadsBackAsItself() {
        for command in SpacerHelper.Command.allCases {
            var buffer = LineBuffer()
            let lines = buffer.append(SpacerHelper.line(command))
            #expect(lines.compactMap(SpacerHelper.Command.init(rawValue:)) == [command])
        }
    }

    @Test func hidingWidensTheSpacerAndShowingShrinksIt() {
        #expect(SpacerHelper.Command.hide.spacerLength == Divider.spacerHidingLength)
        #expect(SpacerHelper.Command.show.spacerLength == Divider.spacerShowingLength)
    }

    @Test func aLineSplitAcrossReadsIsHeldUntilComplete() {
        var buffer = LineBuffer()
        do { let lines = buffer.append(Data("pla".utf8)); #expect(lines.isEmpty) }
        do { let lines = buffer.append(Data("ced\nhi".utf8)); #expect(lines == ["placed"]) }
        do { let lines = buffer.append(Data("de\nshow\n".utf8)); #expect(lines == ["hide", "show"]) }
    }
}
