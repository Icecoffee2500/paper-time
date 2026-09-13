import Foundation

/// Which sync service a library folder lives in.
///
/// Paper Time does not integrate with any provider's SDK: the library is a
/// plain folder, and whichever service the user already syncs it with does the
/// work. Detection exists only so the interface can say something accurate
/// ("waiting for Google Drive") instead of a generic spinner.
public enum CloudProvider: String, Hashable, Sendable, Codable {
    case iCloudDrive
    case googleDrive
    case dropbox
    case oneDrive
    case box
    case local
    case unknown

    public var displayName: String {
        switch self {
        case .iCloudDrive: "iCloud Drive"
        case .googleDrive: "Google Drive"
        case .dropbox: "Dropbox"
        case .oneDrive: "OneDrive"
        case .box: "Box"
        case .local: "This Device"
        case .unknown: "Cloud Folder"
        }
    }

    public var symbolName: String {
        switch self {
        case .iCloudDrive: "icloud"
        case .local: "internaldrive"
        default: "cloud"
        }
    }

    /// True when files can be evicted and need materialising before reading.
    public var mayEvictFiles: Bool {
        switch self {
        case .local: false
        default: true
        }
    }

    public static func detect(at url: URL) -> CloudProvider {
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            return .iCloudDrive
        }
        let path = url.path(percentEncoded: false)
        if path.contains("/Mobile Documents/com~apple~CloudDocs") { return .iCloudDrive }
        if path.contains("/CloudStorage/GoogleDrive-") { return .googleDrive }
        if path.contains("/CloudStorage/Dropbox") { return .dropbox }
        if path.contains("/CloudStorage/OneDrive") { return .oneDrive }
        if path.contains("/CloudStorage/Box") { return .box }
        // The iOS document picker hands back File Provider paths that name the
        // provider's bundle identifier.
        let lowered = path.lowercased()
        if lowered.contains("com.google.drive") || lowered.contains("googledrive") {
            return .googleDrive
        }
        if lowered.contains("com.getdropbox") { return .dropbox }
        if lowered.contains("com.microsoft.skydrive") { return .oneDrive }
        if path.hasPrefix(NSHomeDirectory()) || path.hasPrefix("/Users/") { return .local }
        return .unknown
    }
}
