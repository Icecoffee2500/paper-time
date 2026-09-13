import Foundation
import PDFKit
import PaperCore

/// One paper as it exists on disk: its record, and the PDF the record points at.
public struct LoadedPaper: Hashable, Sendable, Identifiable {
    public var folder: PaperFolder
    public var meta: PaperMeta
    public var state: PaperState
    /// Resolved when the paper is loaded, because the PDF lives beside the
    /// library's other PDFs rather than inside the record folder.
    public var documentURL: URL

    public var id: UUID { meta.id }

    public init(folder: PaperFolder, meta: PaperMeta, state: PaperState, documentURL: URL) {
        self.folder = folder
        self.meta = meta
        self.state = state
        self.documentURL = documentURL
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
        try migrateFromFoldersPerPaperIfNeeded()
        try FileOperations.ensureDirectory(at: LibraryLayout.supportDirectoryURL(inLibrary: root))
        try FileOperations.ensureDirectory(at: LibraryLayout.recordsDirectoryURL(inLibrary: root))

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
        let manager = FileManager.default
        if manager.fileExists(
            atPath: LibraryLayout.manifestURL(inLibrary: url).path(percentEncoded: false)
        ) { return true }
        // A library written before the flat layout.
        return manager.fileExists(atPath: url.appending(path: "library.json").path(percentEncoded: false))
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

    // MARK: - Migration

    /// Moves a library written in the old shape — one folder per paper, each
    /// holding the PDF — into the flat one.
    ///
    /// The PDFs come up to the library root under the names they were imported
    /// with, and their records move into `.papertime`. Runs once; afterwards
    /// there is no `papers/` directory at the root to find.
    private func migrateFromFoldersPerPaperIfNeeded() throws {
        let manager = FileManager.default
        // The library list and the collections are the user's own filing, and
        // they are adopted whether or not there are papers to migrate beside
        // them — losing a collection because the papers had already moved
        // would be the worst kind of quiet data loss.
        try adoptTopLevelManifests()

        let oldPapers = root.appending(path: "papers", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(
            atPath: oldPapers.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return }

        try FileOperations.ensureDirectory(at: LibraryLayout.supportDirectoryURL(inLibrary: root))
        try FileOperations.ensureDirectory(at: LibraryLayout.recordsDirectoryURL(inLibrary: root))

        for oldFolder in (try? FileOperations.subdirectories(of: oldPapers)) ?? [] {
            let contents = (try? manager.contentsOfDirectory(
                at: oldFolder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            guard let metaURL = contents.first(where: { $0.lastPathComponent == "meta.json" }),
                  var meta = try? FileOperations.decode(PaperMeta.self, at: metaURL)
            else { continue }

            if let pdf = contents.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
                let preferred = meta.file.originalName.isEmpty
                    ? pdf.lastPathComponent
                    : meta.file.originalName
                let name = LibraryLayout.availableFileName(for: preferred, inLibrary: root)
                try? manager.moveItem(at: pdf, to: root.appending(path: name))
                meta.file.relativePath = name
                if meta.file.originalName.isEmpty { meta.file.originalName = name }
            }

            let record = PaperFolder(
                url: LibraryLayout.recordURL(forPaper: meta.id, inLibrary: root)
            )
            try FileOperations.ensureDirectory(at: record.url)
            try FileOperations.encodeAndWrite(meta, to: record.metadataURL)

            if let stateURL = contents.first(where: { $0.lastPathComponent == "state.json" }) {
                try? manager.moveItem(at: stateURL, to: record.stateURL)
            }
            if let inkURL = contents.first(where: { $0.lastPathComponent == "ink" }) {
                try? manager.moveItem(at: inkURL, to: record.inkDirectoryURL)
            }
            try? manager.removeItem(at: oldFolder)
        }

        try? manager.removeItem(at: oldPapers)
    }

    /// Moves a first-version library's `library.json` and `collections.json`
    /// out of the way of the user's PDFs, keeping what they hold.
    private func adoptTopLevelManifests() throws {
        let manager = FileManager.default
        let names = [LibraryLayout.manifestFileName, LibraryLayout.collectionsFileName]
        var present: [String] = []
        for name in names
        where manager.fileExists(atPath: root.appending(path: name).path(percentEncoded: false)) {
            present.append(name)
        }
        guard !present.isEmpty else { return }

        try FileOperations.ensureDirectory(at: LibraryLayout.supportDirectoryURL(inLibrary: root))
        for name in present {
            let old = root.appending(path: name)
            let new = LibraryLayout.supportDirectoryURL(inLibrary: root).appending(path: name)
            if manager.fileExists(atPath: new.path(percentEncoded: false)) {
                // The new location already has one; the old file is a leftover.
                try? manager.removeItem(at: old)
            } else {
                try? manager.moveItem(at: old, to: new)
            }
        }
    }

    // MARK: - Scanning

    /// Every record in the library.
    public func recordFolders() throws -> [PaperFolder] {
        let records = LibraryLayout.recordsDirectoryURL(inLibrary: root)
        guard FileManager.default.fileExists(atPath: records.path(percentEncoded: false)) else {
            return []
        }
        return try FileOperations.subdirectories(of: records).map(PaperFolder.init(url:))
    }

    /// Loads every paper, skipping records that cannot be read.
    public func loadAll() throws -> (papers: [LoadedPaper], failures: [(URL, any Error)]) {
        var papers: [LoadedPaper] = []
        var failures: [(URL, any Error)] = []
        for folder in try recordFolders() {
            do {
                papers.append(try load(folder))
            } catch {
                failures.append((folder.url, error))
            }
        }
        return (papers, failures)
    }

    public func load(_ folder: PaperFolder) throws -> LoadedPaper {
        var meta = try loadMeta(folder)
        let state = (try? loadState(folder)) ?? PaperState()

        var url = root.appending(path: meta.file.relativePath)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            // Renamed or moved outside the app. The digest still identifies it.
            if let recovered = findDocument(matching: meta.file.importDigest) {
                url = recovered
                meta.file.relativePath = relativePath(of: recovered)
                try? FileOperations.encodeAndWrite(meta, to: folder.metadataURL)
            }
        }
        return LoadedPaper(folder: folder, meta: meta, state: state, documentURL: url)
    }

    public func loadMeta(_ folder: PaperFolder) throws -> PaperMeta {
        try FileOperations.decode(PaperMeta.self, at: folder.metadataURL)
    }

    /// The reader's own notes on a paper.
    ///
    /// Markdown in a file of its own rather than a field in the record: notes
    /// grow, and a note is worth being able to open, search and keep without
    /// this app.
    // MARK: - Sidecars

    /// Something the app works out from the library and would rather not work
    /// out again — an index, a cache — kept beside the library so it travels
    /// with it and can be deleted without losing anything.
    public func loadSidecar<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
        try FileOperations.decode(
            type, at: LibraryLayout.supportDirectoryURL(inLibrary: root).appending(path: name)
        )
    }

    public func saveSidecar(_ value: some Encodable, named name: String) throws {
        try FileOperations.encodeAndWrite(
            value, to: LibraryLayout.supportDirectoryURL(inLibrary: root).appending(path: name)
        )
    }

    // MARK: - The slip-box

    /// Every note in the library, newest first.
    ///
    /// Notes written before the box existed — one file per paper — are moved
    /// in on the first read, keeping the paper they were written against.
    public func loadNotes() -> [Zettel] {
        migrateNotesIntoSlipBox()
        let directory = LibraryLayout.slipBoxURL(inLibrary: root)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return ZettelFile.note(
                    from: text,
                    id: url.deletingPathExtension().lastPathComponent,
                    modified: modified
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    public func saveNote(_ note: Zettel) throws {
        let url = noteURL(note.id)
        if note.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileOperations.write(Data(ZettelFile.text(of: note).utf8), to: url)
    }

    public func deleteNote(_ id: String) throws {
        let url = noteURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func noteURL(_ id: String) -> URL {
        LibraryLayout.slipBoxURL(inLibrary: root).appending(path: "\(id).md")
    }

    /// Moves the notes of the one-note-per-paper days into the box.
    private func migrateNotesIntoSlipBox() {
        let manager = FileManager.default
        let recordsDirectory = LibraryLayout.recordsDirectoryURL(inLibrary: root)
        guard let records = try? manager.contentsOfDirectory(
            at: recordsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        var taken = Set(
            ((try? manager.contentsOfDirectory(
                at: LibraryLayout.slipBoxURL(inLibrary: root),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []).map { $0.deletingPathExtension().lastPathComponent }
        )

        for record in records {
            let paperID = UUID(uuidString: record.lastPathComponent)
            let folder = PaperFolder(url: record)
            var sources: [URL] = []
            if manager.fileExists(atPath: folder.legacyNoteURL.path) {
                sources.append(folder.legacyNoteURL)
            }
            sources += ((try? manager.contentsOfDirectory(
                at: folder.notesDirectoryURL, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension == "md" }

            for source in sources {
                guard let text = try? String(contentsOf: source, encoding: .utf8) else { continue }
                let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .now
                let id = Zettel.makeID(at: modified, avoiding: taken)
                taken.insert(id)
                var note = ZettelFile.note(from: text, id: id, modified: modified)
                note.id = id
                note.paperID = note.paperID ?? paperID
                if note.title.isEmpty { note.title = Self.firstHeading(in: note.body) }
                guard !note.isEmpty else {
                    try? manager.removeItem(at: source)
                    continue
                }
                try? FileOperations.write(Data(ZettelFile.text(of: note).utf8), to: noteURL(id))
                try? manager.removeItem(at: source)
            }
            try? manager.removeItem(at: folder.notesDirectoryURL)
        }
    }

    /// The first line of a note, used as its title when it has none.
    static func firstHeading(in body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(line)
            while text.hasPrefix("#") { text.removeFirst() }
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return String(text.prefix(80)) }
        }
        return ""
    }

    public func loadState(_ folder: PaperFolder) throws -> PaperState {
        try FileOperations.decode(PaperState.self, at: folder.stateURL)
    }

    /// Every PDF in the library, wherever it sits under the root.
    public func documentURLs() -> [URL] {
        let support = Self.normalizedPath(LibraryLayout.supportDirectoryURL(inLibrary: root))
        let trash = Self.normalizedPath(LibraryLayout.trashURL(inLibrary: root))

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let path = Self.normalizedPath(item)
            if path == support || path.hasPrefix(support + "/")
                || path == trash || path.hasPrefix(trash + "/") {
                enumerator.skipDescendants()
                continue
            }
            guard item.pathExtension.lowercased() == "pdf" else { continue }
            found.append(item)
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// PDFs in the library that no record points at yet.
    public func looseDocumentURLs() -> [URL] {
        let claimed = Set(
            ((try? recordFolders()) ?? [])
                .compactMap { try? loadMeta($0) }
                .map(\.file.relativePath)
        )
        return documentURLs().filter { !claimed.contains(relativePath(of: $0)) }
    }

    /// PDFs in the library that the given records do not account for.
    ///
    /// The cheap counterpart to `looseDocumentURLs()`: it lists the folder and
    /// compares, without reading every record from disk. Used when the folder
    /// reports a change and the answer is usually "nothing new".
    public func unclaimedDocumentURLs(claiming claimed: Set<String>) -> [URL] {
        documentURLs().filter { !claimed.contains(relativePath(of: $0)) }
    }

    /// Whether every one of these relative paths still names a file.
    public func documentsAreMissing(among relativePaths: Set<String>) -> Bool {
        relativePaths.contains { path in
            !FileManager.default.fileExists(
                atPath: root.appending(path: path).path(percentEncoded: false)
            )
        }
    }

    private func findDocument(matching digest: String) -> URL? {
        guard !digest.isEmpty else { return nil }
        return documentURLs().first { url in
            (try? FileOperations.sha256(ofFileAt: url)) == digest
        }
    }

    private func relativePath(of url: URL) -> String {
        let rootPath = Self.normalizedPath(root)
        let path = Self.normalizedPath(url)
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// A comparable path: symlinks resolved, no trailing separator.
    ///
    /// A URL built with `directoryHint: .isDirectory` carries a trailing
    /// slash, and comparing it against a file's path with a plain prefix test
    /// silently fails — which is how a PDF already inside the library came to
    /// be copied in again as "paper 2.pdf".
    static func normalizedPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - Saving with conflict resolution

    /// Saves metadata.
    ///
    /// `baseline` is the version the caller started from. When the file on disk
    /// still matches it, nothing else has touched the record and the new value
    /// is written as-is. Only when disk and baseline differ has another device
    /// written concurrently, and only then is a merge appropriate.
    @discardableResult
    public func save(
        meta: PaperMeta,
        in folder: PaperFolder,
        baseline: PaperMeta? = nil
    ) throws -> PaperMeta {
        var outgoing = meta
        outgoing.updatedAt = .now
        outgoing.updatedBy = DeviceIdentity.current

        if let onDisk = try? loadMeta(folder), onDisk != baseline {
            outgoing = PaperMeta.resolve(local: outgoing, remote: onDisk)
            outgoing.updatedAt = .now
            outgoing.updatedBy = DeviceIdentity.current
        }
        try FileOperations.encodeAndWrite(outgoing, to: folder.metadataURL)
        return outgoing
    }

    /// Saves reading state. See `save(meta:in:baseline:)` for why the baseline
    /// matters.
    @discardableResult
    public func save(
        state: PaperState,
        in folder: PaperFolder,
        baseline: PaperState? = nil
    ) throws -> PaperState {
        var outgoing = state
        outgoing.updatedAt = .now
        outgoing.updatedBy = DeviceIdentity.current

        if let onDisk = try? loadState(folder), onDisk != baseline {
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

    /// Brings a PDF into the library.
    ///
    /// A file from outside is copied in under its own name; the original is
    /// left alone. A file already inside the library is left exactly where it
    /// is — only a record is created for it. Nothing is ever moved or renamed
    /// on the user's behalf.
    public func importDocument(
        at source: URL,
        knownDigests: [String: PaperFolder] = [:]
    ) throws -> ImportOutcome {
        let data = try FileOperations.read(contentsOf: source)
        let digest = FileOperations.sha256(of: data)

        if let existingFolder = knownDigests[digest], let existing = try? load(existingFolder) {
            return .duplicate(existing: existing)
        }

        let alreadyInside = Self.normalizedPath(source)
            .hasPrefix(Self.normalizedPath(root) + "/")

        let destination: URL
        if alreadyInside {
            destination = source
        } else {
            let name = LibraryLayout.availableFileName(
                for: source.lastPathComponent,
                inLibrary: root
            )
            destination = root.appending(path: name)
            try FileOperations.write(data, to: destination)
        }

        let id = UUID()
        let record = PaperFolder(url: LibraryLayout.recordURL(forPaper: id, inLibrary: root))
        try FileOperations.ensureDirectory(at: record.url)

        let pageCount = PDFDocument(data: data)?.pageCount ?? 0
        var meta = PaperMeta(
            id: id,
            confidence: .unparsed,
            provenance: Provenance(source: .heuristic, detail: "awaiting resolution"),
            file: PaperMeta.FileInfo(
                relativePath: relativePath(of: destination),
                byteSize: Int64(data.count),
                pageCount: pageCount,
                importDigest: digest,
                originalName: source.lastPathComponent
            )
        )
        meta.csl.id = ""
        try FileOperations.encodeAndWrite(meta, to: record.metadataURL)

        let state = PaperState()
        try FileOperations.encodeAndWrite(state, to: record.stateURL)

        return .imported(
            LoadedPaper(folder: record, meta: meta, state: state, documentURL: destination)
        )
    }

    // MARK: - Removal

    /// Moves a paper's PDF to the library's Trash folder and drops its record.
    ///
    /// Never unlinks: annotations represent hours of a person's reading, and a
    /// mis-tap in a list must be recoverable without a backup.
    @discardableResult
    public func moveToTrash(_ paper: LoadedPaper) throws -> URL {
        let trash = LibraryLayout.trashURL(inLibrary: root)
        try FileOperations.ensureDirectory(at: trash)

        let name = LibraryLayout.availableFileName(
            for: paper.documentURL.lastPathComponent,
            inLibrary: trash
        )
        let destination = trash.appending(path: name)
        if FileManager.default.fileExists(
            atPath: paper.documentURL.path(percentEncoded: false)
        ) {
            try FileManager.default.moveItem(at: paper.documentURL, to: destination)
        }
        try? FileManager.default.removeItem(at: paper.folder.url)
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

    /// Page indices that have a stored drawing.
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
