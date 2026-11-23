import CoreGraphics
import Foundation
import IcecapCore

/// Queries of the window server, in global coordinates with a top-left origin.
enum WindowServer {
    /// The windows currently on screen.
    static func onScreenWindows() -> [WindowDescription] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard
                let processIdentifier = entry[kCGWindowOwnerPID as String] as? Int32,
                let layer = entry[kCGWindowLayer as String] as? Int,
                let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return WindowDescription(processIdentifier: processIdentifier, layer: layer, frame: frame)
        }
    }

    /// The bounds of every active display.
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }
}
