import Carbon.HIToolbox
import Foundation
import IcecapCore

/// A keyboard shortcut registered with the system, so that it reaches icecap whichever
/// application is in front. Carbon's hot key API needs no permission of its own.
@MainActor
final class HotKey {
    struct RegistrationError: LocalizedError {
        let shortcut: PanelShortcut
        let status: OSStatus

        var isInUse: Bool { status == OSStatus(eventHotKeyExistsErr) }

        var errorDescription: String? {
            isInUse
                ? "\(shortcut.title) is in use by another application."
                : "\(shortcut.title) could not be registered (error \(status))."
        }
    }

    /// The four-character code that marks icecap's hot keys: "icap".
    private static let signature: OSType = 0x6963_6170
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var handler: EventHandlerRef?

    let shortcut: PanelShortcut
    private let identifier: UInt32
    private var reference: EventHotKeyRef?

    init(shortcut: PanelShortcut, action: @escaping () -> Void) throws {
        try Self.installHandlerIfNeeded(for: shortcut)
        self.shortcut = shortcut
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw RegistrationError(shortcut: shortcut, status: status)
        }
        self.reference = reference
        Self.actions[identifier] = action
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.actions[identifier] = nil
    }

    private static func installHandlerIfNeeded(for shortcut: PanelShortcut) throws {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyIdentifier = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyIdentifier
            )
            guard status == noErr else { return status }
            guard hotKeyIdentifier.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
            let identifier = hotKeyIdentifier.id
            // The application event target delivers its events on the main thread.
            MainActor.assumeIsolated { HotKey.actions[identifier]?() }
            return noErr
        }, 1, &eventType, nil, &handler)
        guard status == noErr else { throw RegistrationError(shortcut: shortcut, status: status) }
    }

    private static func carbonModifiers(_ modifiers: PanelShortcut.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }
}
