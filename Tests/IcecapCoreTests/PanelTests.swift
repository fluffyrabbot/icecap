import IcecapCore
import Testing

@Suite struct ItemSearchTests {
    private let names = ["Tailscale", "Google Chrome", "Snapzy", "Café Menu"]

    private func matches(_ query: String) -> [String] {
        ItemSearch.matches(names, query: query) { [$0] }
    }

    @Test func anEmptyQueryKeepsEveryEntryInOrder() {
        #expect(matches("") == names)
        #expect(matches("   ") == names)
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        #expect(matches("CHROME") == ["Google Chrome"])
        #expect(matches("cafe") == ["Café Menu"])
    }

    @Test func everyWordMustOccur() {
        #expect(matches("goo chr") == ["Google Chrome"])
        #expect(matches("goo snap").isEmpty)
    }

    @Test func entriesWithAWordBeginningWithTheQueryComeFirst() {
        // "a" begins no word of "Tailscale" or "Snapzy" but occurs in both.
        let ranked = ItemSearch.matches(["Tailscale", "Snapzy", "Apple Music"], query: "a") { [$0] }
        #expect(ranked == ["Apple Music", "Tailscale", "Snapzy"])
    }

    @Test func wordsAfterPunctuationCountAsWords() {
        let ranked = ItemSearch.matches(["Taffi", "Wi-Fi"], query: "fi") { [$0] }
        #expect(ranked == ["Wi-Fi", "Taffi"])
    }

    @Test func anyOfAnEntrysNamesMayMatch() {
        let entries = [("Wi-Fi", "Control Center"), ("Status", "Tailscale")]
        let found = ItemSearch.matches(entries, query: "tail") { [$0.0, $0.1] }
        #expect(found.map(\.0) == ["Status"])
    }
}

@Suite struct RowSelectionTests {
    @Test func theFirstRowStartsSelected() {
        #expect(RowSelection(rowCount: 3).index == 0)
        #expect(RowSelection(rowCount: 0).index == nil)
    }

    @Test func movingStopsAtEitherEnd() {
        var selection = RowSelection(rowCount: 2)
        selection.moveUp()
        #expect(selection.index == 0)
        selection.moveDown()
        selection.moveDown()
        #expect(selection.index == 1)
    }

    @Test func anEmptyListHasNothingToMoveTo() {
        var selection = RowSelection(rowCount: 0)
        selection.moveDown()
        selection.moveUp()
        #expect(selection.index == nil)
    }

    @Test func aRowCanBeSelectedDirectly() {
        var selection = RowSelection(rowCount: 4)
        selection.select(3)
        #expect(selection.index == 3)
    }
}

@Suite struct PanelShortcutTests {
    @Test func titlesFollowTheMenuOrderOfModifiers() {
        #expect(PanelShortcut.controlOptionCommandSpace.title == "⌃⌥⌘Space")
        #expect(PanelShortcut.controlOptionCommandH.title == "⌃⌥⌘H")
    }

    @Test func nothingStoredMeansTheStandardShortcut() {
        #expect(PanelShortcut.resolved(storedValue: nil) == .standard)
    }

    @Test func storedChoicesRoundTrip() {
        for shortcut in PanelShortcut.allCases + [nil] {
            #expect(PanelShortcut.resolved(storedValue: PanelShortcut.storedValue(for: shortcut)) == shortcut)
        }
    }

    @Test func anUnknownStoredValueMeansTheStandardShortcut() {
        #expect(PanelShortcut.resolved(storedValue: "controlShiftF13") == .standard)
    }
}
