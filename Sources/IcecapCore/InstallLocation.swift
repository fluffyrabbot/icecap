import Foundation

/// Where the running application bundle lies, as far as it matters to icecap. icecap
/// restarts itself by opening its own bundle path and registers that path to open at
/// login, so the bundle must stay where it is for as long as icecap is in use.
public enum InstallLocation: Equatable, Sendable {
    /// The system runs the bundle from a temporary, read-only copy, because it was
    /// downloaded and opened from where it was downloaded. The path changes on every
    /// launch.
    case translocated
    /// The bundle lies on a read-only volume, such as a mounted disk image, which goes
    /// away when the volume is ejected.
    case readOnlyVolume
    /// The bundle may stay where it is.
    case settled

    /// The path component under which the system places translocated bundles.
    public static let translocationComponent = "AppTranslocation"

    public init(bundlePath: String, isOnReadOnlyVolume: Bool) {
        if bundlePath.split(separator: "/").contains(Substring(Self.translocationComponent)) {
            self = .translocated
        } else if isOnReadOnlyVolume {
            self = .readOnlyVolume
        } else {
            self = .settled
        }
    }

    /// Whether icecap should offer to move itself to an Applications folder.
    public var needsMove: Bool { self != .settled }
}
