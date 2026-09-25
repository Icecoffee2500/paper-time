import CoreFoundation
import Foundation

/// Gives the test runner the bundle identifier PencilKit needs.
///
/// `PKDrawing(strokes:)` checks out a replica identifier for the drawing,
/// and the first time a process does that PencilKit saves its replica state
/// with `CFPreferencesSetValue` for the *current application*. A process
/// with no bundle identifier has no current application: CoreFoundation is
/// handed a NULL domain and traps (`CFEqual`, `_CFPrefsGetCacheStringForBundleID`,
/// on the `com.apple.PencilKit.replicas` queue). `swift test` runs the tests
/// in `swiftpm-testing-helper`, which has none — so the first ink test took
/// the whole test process down with signal 5, and every suite after it with
/// it. The app has an identifier and never sees this.
///
/// The runner's main bundle is a directory with no Info.plist, and its info
/// dictionary is an empty mutable one; an identifier put into it before the
/// first drawing is the one PencilKit reads. The domain is a throwaway one of
/// the tests' own — never the app's.
enum PencilKitHost {
    static let identifier = "local.papertime.package-tests"

    private static let prepared: Void = {
        let bundle = CFBundleGetMainBundle()
        guard CFBundleGetIdentifier(bundle) == nil, let info = CFBundleGetInfoDictionary(bundle) else { return }
        CFDictionarySetValue(
            unsafeDowncast(info, to: CFMutableDictionary.self),
            Unmanaged.passUnretained(kCFBundleIdentifierKey).toOpaque(),
            Unmanaged.passUnretained(identifier as CFString).toOpaque()
        )
    }()

    static func prepare() { _ = prepared }
}
