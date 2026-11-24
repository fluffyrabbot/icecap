import IcecapCore
import Testing

@Suite struct InstallLocationTests {
    @Test func translocatedBundleNeedsMove() {
        let path = "/private/var/folders/xt/kw23/T/AppTranslocation/6A1F2C/d/icecap.app"
        let location = InstallLocation(bundlePath: path, isOnReadOnlyVolume: true)
        #expect(location == .translocated)
        #expect(location.needsMove)
    }

    @Test func bundleOnMountedDiskImageNeedsMove() {
        let location = InstallLocation(bundlePath: "/Volumes/icecap/icecap.app", isOnReadOnlyVolume: true)
        #expect(location == .readOnlyVolume)
        #expect(location.needsMove)
    }

    @Test func bundleInApplicationsIsSettled() {
        let location = InstallLocation(bundlePath: "/Applications/icecap.app", isOnReadOnlyVolume: false)
        #expect(location == .settled)
        #expect(!location.needsMove)
    }

    @Test func bundleOnWritableExternalVolumeIsSettled() {
        // A writable volume, such as an external drive, is the person's choice of place.
        let location = InstallLocation(bundlePath: "/Volumes/Work/icecap/build/icecap.app", isOnReadOnlyVolume: false)
        #expect(location == .settled)
    }

    @Test func folderMerelyNamedLikeTranslocationDoesNotCount() {
        let location = InstallLocation(bundlePath: "/Users/someone/AppTranslocationNotes/icecap.app", isOnReadOnlyVolume: false)
        #expect(location == .settled)
    }
}
