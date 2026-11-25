import Foundation

/// Narrowing the panel's list of icons to those whose names match what the person types.
public enum ItemSearch {
    /// The entries that match the query, ignoring case and diacritics. An entry matches
    /// when every word of the query occurs in one of its names. Entries with a name word
    /// that begins with the query's first word come first; otherwise the given order is
    /// kept, so that the list keeps the icons' order in the menu bar. An empty query
    /// matches every entry.
    public static func matches<Entry>(
        _ entries: [Entry],
        query: String,
        names: (Entry) -> [String]
    ) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let firstWord = words.first else { return entries }
        var leading: [Entry] = []
        var others: [Entry] = []
        for entry in entries {
            let entryNames = names(entry)
            let matchesEveryWord = words.allSatisfy { word in
                entryNames.contains { $0.range(of: word, options: comparison) != nil }
            }
            guard matchesEveryWord else { continue }
            if entryNames.contains(where: { hasWord(beginningWith: firstWord, in: $0) }) {
                leading.append(entry)
            } else {
                others.append(entry)
            }
        }
        return leading + others
    }

    private static let comparison: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func hasWord(beginningWith prefix: String, in name: String) -> Bool {
        name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { word in
            word.range(of: prefix, options: comparison.union(.anchored)) != nil
        }
    }
}
