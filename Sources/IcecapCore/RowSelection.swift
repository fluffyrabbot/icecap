/// The selected row of a list chosen from with the keyboard or the pointer.
///
/// A list with rows always has one selected, the first to begin with, so that Return
/// chooses at once; an empty list has none. Moving past either end stays at that end,
/// as in a menu.
public struct RowSelection: Equatable, Sendable {
    public let rowCount: Int
    public private(set) var index: Int?

    public init(rowCount: Int) {
        precondition(rowCount >= 0, "a list cannot have fewer than no rows")
        self.rowCount = rowCount
        index = rowCount > 0 ? 0 : nil
    }

    public mutating func moveDown() {
        guard let index else { return }
        self.index = min(index + 1, rowCount - 1)
    }

    public mutating func moveUp() {
        guard let index else { return }
        self.index = max(index - 1, 0)
    }

    public mutating func select(_ row: Int) {
        precondition((0..<rowCount).contains(row), "row \(row) is not among \(rowCount) rows")
        index = row
    }
}
