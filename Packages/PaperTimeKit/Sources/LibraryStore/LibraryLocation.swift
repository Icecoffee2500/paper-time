import Foundation
import PaperCore

/// A remembered library folder.
///
/// The user picks a folder once; the app stores a security-scoped bookmark so
/// it can reopen exactly that folder on later launches without asking again,
/// which is the only way a sandboxed app may keep access to a location the
/// user chose.
public final class LibraryLocation: @unchecked Sendable {
    public let url: URL
    public let provider: CloudProvider
    private let isSecurityScoped: Bool

    private init(url: URL, isSecurityScoped: Bool) {
        self.url = url
        self.provider = CloudProvider.detect(at: url)
        self.isSecurityScoped = isSecurityScoped
    }

    deinit {
        if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
    }

    /// Wraps a folder the user just chose in the document picker or open panel.
    public static func adopting(_ pickedURL: URL) -> LibraryLocation {
        let accessed = pickedURL.startAccessingSecurityScopedResource()
        return LibraryLocation(url: pickedURL, isSecurityScoped: accessed)
    }

    /// A folder inside the app's own container. Needs no bookmark.
    public static func unscoped(_ url: URL) -> LibraryLocation {
        LibraryLocation(url: url, isSecurityScoped: false)
    }

    public func bookmarkData() throws -> Data {
        #if os(macOS)
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        try url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public enum ResolveResult: Sendable {
        case resolved(LibraryLocation)
        /// The folder moved or was renamed; the caller should persist the new
        /// bookmark returned alongside it.
        case resolvedStale(LibraryLocation, refreshedBookmark: Data?)
        case unavailable(any Error)
    }

    public static func resolving(bookmark: Data) -> ResolveResult {
        var isStale = false
        do {
            #if os(macOS)
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #else
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif
            let accessed = url.startAccessingSecurityScopedResource()
            let location = LibraryLocation(url: url, isSecurityScoped: accessed)
            if isStale {
                return .resolvedStale(location, refreshedBookmark: try? location.bookmarkData())
            }
            return .resolved(location)
        } catch {
            return .unavailable(error)
        }
    }
}

/// Persists which folder the user chose, per device.
///
/// Deliberately stored in `UserDefaults` rather than in the library itself: two
/// devices may reach the same library through different paths, and one device's
/// bookmark is meaningless on the other.
public struct LibraryLocationPreference: @unchecked Sendable {
    // UserDefaults is thread-safe but not marked Sendable by Foundation.
    private let defaults: UserDefaults
    private let bookmarkKey = "com.imtaeheon.PaperTime.libraryBookmark"
    private let pathKey = "com.imtaeheon.PaperTime.libraryPathHint"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasStoredLibrary: Bool { defaults.data(forKey: bookmarkKey) != nil }

    /// A human-readable hint used only for error messages when the bookmark
    /// no longer resolves ("Paper Time can't reach ~/Google Drive/Papers").
    public var pathHint: String? { defaults.string(forKey: pathKey) }

    public func store(_ location: LibraryLocation) throws {
        defaults.set(try location.bookmarkData(), forKey: bookmarkKey)
        defaults.set(location.url.path(percentEncoded: false), forKey: pathKey)
    }

    public func storeRefreshedBookmark(_ data: Data) {
        defaults.set(data, forKey: bookmarkKey)
    }

    public func load() -> LibraryLocation.ResolveResult? {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return nil }
        let result = LibraryLocation.resolving(bookmark: bookmark)
        if case let .resolvedStale(_, refreshed) = result, let refreshed {
            storeRefreshedBookmark(refreshed)
        }
        return result
    }

    public func clear() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: pathKey)
    }
}
