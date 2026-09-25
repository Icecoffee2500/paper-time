import CryptoKit
import Foundation
import PaperCore

/// Coordinated, crash-safe file access for a library that lives in a folder
/// somebody else is syncing.
///
/// Every read goes through `NSFileCoordinator`, which is what causes a cloud
/// provider to materialise a file that has been evicted from local storage —
/// the same call works for iCloud Drive and for any File Provider extension,
/// which is why Paper Time needs no provider-specific code.
public enum FileOperations {
    public enum Failure: LocalizedError {
        case coordinationFailed(URL, any Error)
        case notADirectory(URL)
        case documentMissing(URL)
        case writeVerificationFailed(URL)
        case stillDownloading(URL)
        /// An update that would have changed a file's existing bytes rather
        /// than adding to them.
        case notAnAppend(URL)
        /// A replacement that found the file no longer what it was read as.
        case changedUnderneath(URL)

        public var errorDescription: String? {
            switch self {
            case let .notAnAppend(url):
                "Paper Time left \(url.lastPathComponent) alone: saving would have changed what was already in it."
            case let .changedUnderneath(url):
                "\(url.lastPathComponent) changed while Paper Time was working on it, so it was left alone."
            case .stillDownloading:
                "This library is still arriving from iCloud. Give it a moment and try again."
            case let .coordinationFailed(url, error):
                "Could not access \(url.lastPathComponent): \(error.localizedDescription)"
            case let .notADirectory(url):
                "\(url.lastPathComponent) is not a folder."
            case let .documentMissing(url):
                "\(url.lastPathComponent) could not be found."
            case let .writeVerificationFailed(url):
                "Saving \(url.lastPathComponent) did not produce a readable file."
            }
        }
    }

    // MARK: - Reading

    public static func read(contentsOf url: URL) throws -> Data {
        var coordinatorError: NSError?
        var readError: (any Error)?
        var result: Data?

        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { actualURL in
            do { result = try Data(contentsOf: actualURL) } catch { readError = error }
        }

        if let coordinatorError { throw Failure.coordinationFailed(url, coordinatorError) }
        if let readError { throw readError }
        guard let result else { throw Failure.documentMissing(url) }
        return result
    }

    public static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONCoding.decode(type, from: read(contentsOf: url))
    }

    // MARK: - Writing

    /// Writes through a temporary file in the same directory and swaps it in.
    ///
    /// Replacing rather than truncating means a crash or a sync engine reading
    /// mid-write can never observe a half-written `meta.json`.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var coordinatorError: NSError?
        var writeError: (any Error)?

        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinatorError
        ) { actualURL in
            do {
                let temporary = directory.appending(
                    path: ".\(actualURL.lastPathComponent).\(UUID().uuidString.prefix(6)).tmp"
                )
                try data.write(to: temporary, options: .atomic)
                if FileManager.default.fileExists(atPath: actualURL.path(percentEncoded: false)) {
                    _ = try FileManager.default.replaceItemAt(actualURL, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: actualURL)
                }
            } catch {
                writeError = error
            }
        }

        if let coordinatorError { throw Failure.coordinationFailed(url, coordinatorError) }
        if let writeError { throw writeError }
    }

    /// Reads a file and replaces it with what `transform` makes of it, in one
    /// coordinated access — nobody else's version can land between the read
    /// and the write. `transform` returns nil to leave the file alone.
    ///
    /// Only for files that grow at the end: the new bytes must begin with the
    /// old ones, byte for byte, or nothing is written. That is what an
    /// incremental update to a PDF is, and checking it here means a mistake
    /// anywhere above cannot take a paper's own bytes with it. The new file
    /// goes through a temporary one and is swapped in, as `write` does.
    ///
    /// Returns whether it wrote.
    @discardableResult
    public static func update(_ url: URL, _ transform: (Data) throws -> Data?) throws -> Bool {
        var coordinatorError: NSError?
        var failure: (any Error)?
        var wrote = false

        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinatorError
        ) { actualURL in
            do {
                let old = try Data(contentsOf: actualURL)
                guard let new = try transform(old), new.count != old.count || new != old else { return }
                guard new.count > old.count, new.prefix(old.count) == old else {
                    throw Failure.notAnAppend(url)
                }
                let temporary = actualURL.deletingLastPathComponent().appending(
                    path: ".\(actualURL.lastPathComponent).\(UUID().uuidString.prefix(6)).tmp"
                )
                do {
                    try new.write(to: temporary, options: .atomic)
                    _ = try FileManager.default.replaceItemAt(actualURL, withItemAt: temporary)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
                // What is there now is what was meant to be: one stat, not a
                // second read of a file that may be a hundred megabytes.
                let size = (try? FileManager.default.attributesOfItem(atPath: actualURL.path(percentEncoded: false)))?[.size] as? Int
                guard size == new.count else { throw Failure.writeVerificationFailed(url) }
                wrote = true
            } catch {
                failure = error
            }
        }

        if let coordinatorError { throw Failure.coordinationFailed(url, coordinatorError) }
        if let failure { throw failure }
        return wrote
    }

    /// Replaces a file's contents outright — the one write here that is not
    /// an append — but only if the file is still byte for byte what
    /// `expected` says it was when the caller read it. Compaction and a
    /// restore both work from a copy they read a moment ago; a version that
    /// landed from another device in between must not be written over.
    ///
    /// With `trashingOld`, the file being replaced goes to the Trash rather
    /// than being overwritten, and its new place is returned. The system
    /// Trash first; failing that (a folder whose provider has none), the
    /// library's own `Trash` folder, which is where a paper deleted from the
    /// list goes too. Never simply deleted.
    @discardableResult
    public static func replace(
        _ url: URL,
        with new: Data,
        ifStill expected: Data?,
        trashingOld: Bool = false,
        libraryRoot: URL? = nil
    ) throws -> URL? {
        var coordinatorError: NSError?
        var failure: (any Error)?
        var trashed: URL?

        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinatorError
        ) { actualURL in
            do {
                if let expected {
                    let current = try Data(contentsOf: actualURL)
                    guard current == expected else { throw Failure.changedUnderneath(url) }
                }
                let temporary = actualURL.deletingLastPathComponent().appending(
                    path: ".\(actualURL.lastPathComponent).\(UUID().uuidString.prefix(6)).tmp"
                )
                do {
                    try new.write(to: temporary, options: .atomic)
                    if trashingOld {
                        var resting: NSURL?
                        do {
                            try FileManager.default.trashItem(at: actualURL, resultingItemURL: &resting)
                            trashed = resting as URL?
                        } catch {
                            let bin = LibraryLayout.trashURL(inLibrary: libraryRoot ?? actualURL.deletingLastPathComponent())
                            try ensureDirectory(at: bin)
                            let name = LibraryLayout.availableFileName(for: actualURL.lastPathComponent, inLibrary: bin)
                            let place = bin.appending(path: name)
                            try FileManager.default.moveItem(at: actualURL, to: place)
                            trashed = place
                        }
                        try FileManager.default.moveItem(at: temporary, to: actualURL)
                    } else {
                        _ = try FileManager.default.replaceItemAt(actualURL, withItemAt: temporary)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: actualURL.path(percentEncoded: false)))?[.size] as? Int
                guard size == new.count else { throw Failure.writeVerificationFailed(url) }
            } catch {
                failure = error
            }
        }

        if let coordinatorError { throw Failure.coordinationFailed(url, coordinatorError) }
        if let failure { throw failure }
        return trashed
    }

    public static func encodeAndWrite(_ value: some Encodable, to url: URL) throws {
        try write(JSONCoding.encode(value), to: url)
    }

    /// Copies a file into the library, coordinating both sides.
    public static func copyIn(from source: URL, to destination: URL) throws {
        let data = try read(contentsOf: source)
        try write(data, to: destination)
    }

    // MARK: - Availability

    /// Asks the sync provider to bring a file's contents onto this device.
    ///
    /// A coordinated read is enough for a File Provider, but iCloud also
    /// exposes an explicit request that starts the download without blocking.
    public static func requestDownload(of url: URL) {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        if values?.isUbiquitousItem == true {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// Asks iCloud for everything under a directory that is still only a
    /// placeholder, and waits — up to `timeout` — for the one file named.
    ///
    /// A library in iCloud Drive arrives on a new device as placeholders:
    /// each file is a hidden `.name.icloud` stub until something asks for it,
    /// and nothing asks for a hidden folder of records on its own. Without
    /// this the app saw no manifest, made a fresh empty one, and the iPad
    /// showed a library of nothing beside a Mac showing sixty papers.
    public static func ensureDownloaded(directory: URL, waitingFor file: URL, timeout: TimeInterval = 20) {
        let manager = FileManager.default
        guard (try? directory.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
            || hasPlaceholders(in: directory)
        else { return }
        // The file this would wait for is already here and whole, so there is
        // nothing to wait for. Asking anyway walked the whole folder first —
        // every record and every PDF in the library, each one asked for its
        // download status — to hurry along a file that had already arrived:
        // close to two seconds of every launch, on the launches where nothing
        // was missing. Whatever else is still out there is asked for without
        // anybody waiting on it.
        if manager.fileExists(atPath: file.path(percentEncoded: false)), isMaterialised(file) {
            Task.detached(priority: .utility) { requestPendingDownloads(in: directory) }
            return
        }
        func request() {
            guard let items = manager.enumerator(at: directory, includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey], options: []) else { return }
            for case let url as URL in items {
                if url.lastPathComponent.hasSuffix(".icloud") {
                    // The stub names the file: `.name.icloud` → `name`.
                    let real = url.deletingLastPathComponent()
                        .appending(path: String(url.lastPathComponent.dropFirst().dropLast(".icloud".count)))
                    try? manager.startDownloadingUbiquitousItem(at: real)
                } else if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                          values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try? manager.startDownloadingUbiquitousItem(at: url)
                }
            }
            try? manager.startDownloadingUbiquitousItem(at: file)
        }
        request()
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if manager.fileExists(atPath: file.path(percentEncoded: false)), isMaterialised(file) { return }
            Thread.sleep(forTimeInterval: 0.4)
            request()
        }
    }

    /// Asks iCloud for whatever under a folder is not on this device yet, and
    /// returns at once. Cheap on a small folder; what an open paper's record
    /// needs every few seconds.
    public static func requestPendingDownloads(in directory: URL) {
        let manager = FileManager.default
        guard let items = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
            options: []
        ) else { return }
        for case let url as URL in items {
            if url.lastPathComponent.hasSuffix(".icloud") {
                let real = url.deletingLastPathComponent()
                    .appending(path: String(url.lastPathComponent.dropFirst().dropLast(".icloud".count)))
                try? manager.startDownloadingUbiquitousItem(at: real)
            } else if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                      values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? manager.startDownloadingUbiquitousItem(at: url)
            }
        }
    }

    /// Whether a directory holds iCloud stubs for files not yet on this device.
    public static func hasPlaceholders(in directory: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return items.contains { $0.hasSuffix(".icloud") }
    }

    /// Whether the file's contents are on this device right now.
    public static func isMaterialised(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        if values.isUbiquitousItem == true {
            return values.ubiquitousItemDownloadingStatus == .current
                || values.ubiquitousItemDownloadingStatus == .downloaded
        }
        // A File Provider placeholder reports a size but cannot be opened; the
        // cheap check that works everywhere is whether the bytes are readable.
        return (values.fileSize ?? 0) > 0
    }

    // MARK: - Digests

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(ofFileAt url: URL) throws -> String {
        sha256(of: try read(contentsOf: url))
    }

    // MARK: - Directory helpers

    public static func ensureDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw Failure.notADirectory(url) }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public static func subdirectories(of url: URL) throws -> [URL] {
        try visibleContents(of: url, keys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The entries of a directory whose names do not start with a dot.
    ///
    /// Deliberately not `.skipsHiddenFiles`: iCloud Drive on iOS marks
    /// everything under a dot-folder as hidden, so listing `.papertime/papers`
    /// with that option returned nothing — sixty-two records on the Mac, an
    /// empty library on the iPad, with every file present and readable.
    public static func visibleContents(of url: URL, keys: [URLResourceKey]? = nil) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
    }
}
