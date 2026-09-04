import Foundation
import PDFKit
import PaperCore

/// One paper as it exists on disk.
public struct LoadedPaper: Hashable, Sendable, Identifiable {
    public var folder: PaperFolder
    public var meta: PaperMeta
    public var state: PaperState

    public var id: UUID { meta.id }
    public var documentURL: URL { folder.documentURL(fileName: meta.file.name) }

    public init(folder: PaperFolder, meta: PaperMeta, state: PaperState) {
        self.folder = folder
        self.meta = meta
        self.state = state
    }
}

/// Reads and writes a Paper Time library folder.
///
/// An actor because every mutation is a multi-step file operation (read the
/// current version, merge, write atomically) that must not interleave with
/// another one for the same paper.
public actor LibraryStore {
    public let root: URL
    public let provider: CloudProvider

    public init(root: URL) {
        self.root = root
        self.provider = CloudProvider.detect(at: root)
    }

    public init(location: LibraryLocation) {
        self.root = location.url
        self.provider = location.provider
    }

    // MARK: - Library lifecycle

    /// Creates the folder skeleton if needed and returns the manifest.
    ///
    /// Safe to call on a folder that already holds a library: nothing existing
    /// is rewritten, so pointing a second device at the same folder just works.
    @discardableResult
    public func bootstrap(displayName: String = "Paper Time") throws -> LibraryManifest {
        try FileOperations.ensureDirectory(at: root)
        try FileOperations.ensureDirectory(at: LibraryLayout.papersDirectoryURL(inLibrary: root))

        let manifestURL = LibraryLayout.manifestURL(inLibrary: root)
        if FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) {
            return try loadManifest()
        }
        let manifest = LibraryManifest(displayName: displayName)
        try FileOperations.encodeAndWrite(manifest, to: manifestURL)
        try FileOperations.encodeAndWrite(
            CollectionSet(),
            to: LibraryLayout.collectionsURL(inLibrary: root)
        )
        return manifest
    }

    /// Whether the folder already contains a Paper Time library.
    public static func containsLibrary(at url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: LibraryLayout.manifestURL(inLibrary: url).path(percentEncoded: false)
        )
    }

    public func loadManifest() throws -> LibraryManifest {
        try FileOperations.decode(
            LibraryManifest.self,
            at: LibraryLayout.manifestURL(inLibrary: root)
        )
    }

    public func saveManifest(_ manifest: LibraryManifest) throws {
        try FileOperations.encodeAndWrite(
            manifest,
            to: LibraryLayout.manifestURL(inLibrary: root)
        )
    }

    public func loadCollections() throws -> CollectionSet {
        let url = LibraryLayout.collectionsURL(inLibrary: root)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return CollectionSet()
        }
        return try FileOperations.decode(CollectionSet.self, at: url)
    }

    public func saveCollections(_ set: CollectionSet) throws {
        var updated = set
        updated.updatedAt = .now
        updated.updatedBy = DeviceIdentity.current
        try FileOperations.encodeAndWrite(
            updated,
            to: LibraryLayout.collectionsURL(inLibrary: root)
        )
    }

    // MARK: - Scanning

    public func paperFolders() throws -> [PaperFolder] {
        let papersURL = LibraryLayout.papersDirectoryURL(inLibrary: root)
        guard FileManager.default.fileExists(atPath: papersURL.path(percentEncoded: false)) else {
            return []
        }
        return try FileOperations.subdirectories(of: papersURL).map(PaperFolder.init(url:))
    }

    /// Loads every paper, skipping folders that cannot be read.
    ///
    /// A folder still syncing, or one a person dropped in by hand, must not
    /// stop the rest of the library from opening — the failures are reported
    /// rather than thrown.
    public func loadAll() throws -> (papers: [LoadedPaper], failures: [(URL, any Error)]) {
        var papers: [LoadedPaper] = []
        var failures: [(URL, any Error)] = []
        for folder in try paperFolders() {
            do {
                papers.append(try load(folder))
            } catch {
                failures.append((folder.url, error))
            }
        }
        return (papers, failures)
    }

    public func load(_ folder: PaperFolder) throws -> LoadedPaper {
        let meta = try loadMeta(folder)
        let state = (try? loadState(folder)) ?? PaperState()
        return LoadedPaper(folder: folder, meta: meta, state: state)
    }

    public func loadMeta(_ folder: PaperFolder) throws -> PaperMeta {
        try FileOperations.decode(PaperMeta.self, at: folder.metadataURL)
    }

    public func loadState(_ folder: PaperFolder) throws -> PaperState {
        try FileOperations.decode(PaperState.self, at: folder.stateURL)
    }

    // MARK: - Saving with conflict resolution

    /// Saves metadata, merging with whatever another device may have written
    /// since this copy was loaded.
    ///
    /// Reading immediately before writing is cheap and removes the most common
    /// way a synced folder loses an edit: two devices each saving a record they
    /// loaded minutes ago.
    @discardableResult
    public func save(meta: PaperMeta, in folder: PaperFolder) throws -> PaperMeta {
        var outgoing = meta
        outgoing.updatedAt = .now
        outgoing.updatedBy = DeviceIdentity.current

        if let onDisk = try? loadMeta(folder), onDisk != meta {
            outgoing = PaperMeta.resolve(local: outgoing, remote: onDisk)
            outgoing.updatedAt = .now
            outgoing.updatedBy = DeviceIdentity.current
        }
        try FileOperations.encodeAndWrite(outgoing, to: folder.metadataURL)
        return outgoing
    }

    @discardableResult
    public func save(state: PaperState, in folder: PaperFolder) throws -> PaperState {
        var outgoing = state
        outgoing.updatedAt = .now
        outgoing.updatedBy = DeviceIdentity.current

        if let onDisk = try? loadState(folder), onDisk != state {
            outgoing = PaperState.resolve(local: outgoing, remote: onDisk)
            outgoing.updatedAt = .now
            outgoing.updatedBy = DeviceIdentity.current
        }
        try FileOperations.encodeAndWrite(outgoing, to: folder.stateURL)
        return outgoing
    }

    // MARK: - Import

    public enum ImportOutcome: Sendable {
        case imported(LoadedPaper)
        /// The same bytes are already in the library.
        case duplicate(existing: LoadedPaper)
    }

    /// Copies a PDF into the library and creates its folder.
    ///
    /// Metadata resolution is deliberately not part of this step: importing must
    /// succeed offline and instantly, and the pipeline runs afterwards.
    public func importDocument(
        at source: URL,
        knownDigests: [String: PaperFolder] = [:]
    ) throws -> ImportOutcome {
        let data = try FileOperations.read(contentsOf: source)
        let digest = FileOperations.sha256(of: data)

        if let existingFolder = knownDigests[digest], let existing = try? load(existingFolder) {
            return .duplicate(existing: existing)
        }

        let id = UUID()
        let originalName = source.lastPathComponent
        let folderURL = LibraryLayout.papersDirectoryURL(inLibrary: root)
            .appending(
                path: LibraryLayout.folderName(id: id, originalFileName: originalName),
                directoryHint: .isDirectory
            )
        try FileOperations.ensureDirectory(at: folderURL)
        let folder = PaperFolder(url: folderURL)

        let pdfName = LibraryLayout.pdfFileName(originalFileName: originalName)
        let destination = folder.documentURL(fileName: pdfName)
        try FileOperations.write(data, to: destination)

        let pageCount = PDFDocument(data: data)?.pageCount ?? 0
        var meta = PaperMeta(
            id: id,
            confidence: .unparsed,
            provenance: Provenance(source: .heuristic, detail: "awaiting resolution"),
            file: PaperMeta.FileInfo(
                name: pdfName,
                byteSize: Int64(data.count),
                pageCount: pageCount,
                importDigest: digest,
                originalName: originalName
            )
        )
        meta.csl.id = ""
        try FileOperations.encodeAndWrite(meta, to: folder.metadataURL)

        let state = PaperState()
        try FileOperations.encodeAndWrite(state, to: folder.stateURL)

        return .imported(LoadedPaper(folder: folder, meta: meta, state: state))
    }

    // MARK: - Removal

    /// Moves a paper to the library's Trash folder.
    ///
    /// Never unlinks: annotations represent hours of a person's reading, and a
    /// mis-tap in a list must be recoverable without a backup.
    public func moveToTrash(_ folder: PaperFolder) throws -> URL {
        let trashURL = root.appending(path: "Trash", directoryHint: .isDirectory)
        try FileOperations.ensureDirectory(at: trashURL)

        var destination = trashURL.appending(
            path: folder.url.lastPathComponent,
            directoryHint: .isDirectory
        )
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = trashURL.appending(
                path: "\(folder.url.lastPathComponent) \(attempt)",
                directoryHint: .isDirectory
            )
            attempt += 1
        }
        try FileManager.default.moveItem(at: folder.url, to: destination)
        return destination
    }

    // MARK: - Ink sidecars

    public func loadInk(pageIndex: Int, in folder: PaperFolder) throws -> Data? {
        let url = folder.inkURL(pageIndex: pageIndex)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        return try FileOperations.read(contentsOf: url)
    }

    public func saveInk(_ data: Data, pageIndex: Int, in folder: PaperFolder) throws {
        try FileOperations.ensureDirectory(at: folder.inkDirectoryURL)
        try FileOperations.write(data, to: folder.inkURL(pageIndex: pageIndex))
    }

    public func removeInk(pageIndex: Int, in folder: PaperFolder) throws {
        let url = folder.inkURL(pageIndex: pageIndex)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Page indices that have a stored drawing, used to decide which pages need
    /// a canvas when the reader opens.
    public func inkPageIndices(in folder: PaperFolder) -> [Int] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder.inkDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return (contents ?? [])
            .compactMap { LibraryLayout.pageIndex(fromInkFileName: $0.lastPathComponent) }
            .sorted()
    }
}
