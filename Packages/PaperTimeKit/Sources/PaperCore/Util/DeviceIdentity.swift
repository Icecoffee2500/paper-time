import Foundation

/// A stable, human-readable identifier for this device.
///
/// Written into every file the app saves so a sync conflict can be described
/// as "edited on your iPad" rather than as two opaque timestamps.
public enum DeviceIdentity {
    private static let defaultsKey = "com.imtaeheon.PaperTime.deviceIdentifier"

    public static let current: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let created = "\(platformName)-\(UUID().uuidString.prefix(8))"
        defaults.set(created, forKey: defaultsKey)
        return created
    }()

    /// The part of the identifier a person can recognise.
    public static var platformName: String {
        #if os(macOS)
        return "Mac"
        #elseif os(visionOS)
        return "Vision"
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac ? "Mac" : deviceClass
        #endif
    }

    #if !os(macOS)
    private static var deviceClass: String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #else
        return UIDeviceIdiomName
        #endif
    }
    #endif
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

private var UIDeviceIdiomName: String {
    switch UIDevice.current.userInterfaceIdiom {
    case .pad: "iPad"
    case .phone: "iPhone"
    case .mac: "Mac"
    default: "Device"
    }
}
#endif
