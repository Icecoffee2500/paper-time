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

        public var errorDescription: String? {
            switch self {
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
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
