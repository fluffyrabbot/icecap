/// The keyboard shortcuts that can open the panel from any application.
///
/// Each uses ⌃⌥⌘, a combination that the system and most applications leave free.
public enum PanelShortcut: String, CaseIterable, Sendable {
    case controlOptionCommandSpace
    case controlOptionCommandH
    case controlOptionCommandM

    /// The shortcut used until the person chooses another or none.
    public static let standard = PanelShortcut.controlOptionCommandSpace

    /// The value stored in the defaults when the person chose no shortcut.
    public static let noneStoredValue = "none"

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var modifiers: Modifiers { [.control, .option, .command] }

    /// The virtual key code of the key, as defined by `Carbon.HIToolbox` (`kVK_*`).
    public var keyCode: UInt32 {
        switch self {
        case .controlOptionCommandSpace: 49
        case .controlOptionCommandH: 4
        case .controlOptionCommandM: 46
        }
    }

    public var keyName: String {
        switch self {
        case .controlOptionCommandSpace: "Space"
        case .controlOptionCommandH: "H"
        case .controlOptionCommandM: "M"
        }
    }

    /// The shortcut as macOS writes it in menus, its modifiers in the order ⌃⌥⇧⌘.
    public var title: String {
        let symbols: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyName
    }

    /// The shortcut a stored value denotes: the standard one when nothing is stored, none
    /// when the person chose none. A value no shortcut has, as from another version,
    /// also denotes the standard one.
    public static func resolved(storedValue: String?) -> PanelShortcut? {
        guard let storedValue else { return standard }
        if storedValue == noneStoredValue { return nil }
        return PanelShortcut(rawValue: storedValue) ?? standard
    }

    public static func storedValue(for shortcut: PanelShortcut?) -> String {
        shortcut?.rawValue ?? noneStoredValue
    }
}
