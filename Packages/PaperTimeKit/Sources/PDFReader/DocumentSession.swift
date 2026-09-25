import Foundation
import InkEngine
import LibraryStore
import PDFKit
import PDFUpdate
import PaperCore
import PencilKit

/// Owns one open paper: its PDF, its ink sidecars, and everything about saving
/// them safely.
///
/// Saving is split in two on purpose. A page's `PKDrawing` is written the
/// moment the pencil lifts, because it is a few kilobytes and it is the copy
/// with full pressure information. The PDF follows on a longer delay. The
/// user's work is never at risk in the gap: the sidecar already holds it, and
/// the PDF is always brought to what the journals and sidecars say.
///
/// The PDF is never rewritten. Marks go in as an incremental update — the
/// paper's own bytes stay exactly as they were, and the marks are appended
/// after them (`IncrementalWriter`). Writing the whole document back out with
/// PDFKit re-subset its fonts and destroyed the text of papers set in TeX:
/// one highlight turned every "ff" in LeJEPA into "!", in the file, for every
/// reader.
@MainActor
@Observable
public final class DocumentSession {
    public enum SaveState: Equatable, Sendable {
        case idle
        case pending
        case saving
        case failed(String)
        /// Another device had changed the file; our marks were re-applied on
        /// top of theirs rather than overwriting them.
        case mergedExternalChanges
        /// The marks are safe here — in the journal and the sidecars, and on
        /// screen — and this file would not take them. Not a failure: nothing
        /// was lost, and the file was left exactly as it was.
        case keptInApp(KeptReason)
    }

    /// Why a file would not take the marks.
    public enum KeptReason: Equatable, Sendable {
        /// It asks for a password, or is locked by another kind of security.
        case locked
        /// Its permissions, or its certification, forbid annotations.
        case forbidden
        /// It is put together in a way the writer will not risk writing into.
        case unusual
        /// The update was made, but did not read back as it should have.
        case unconfirmed

        init(_ refusal: IncrementalWriter.Refusal) {
            switch refusal {
            case .encrypted, .needsPassword: self = .locked
            case .permissions: self = .forbidden
            case .verificationFailed: self = .unconfirmed
            case .unreadableStructure, .pageCountMismatch, .annotationMapping, .inPlaceEdit: self = .unusual
            }
        }
    }

    /// What one save came to.
    public enum WriteOutcome: Equatable, Sendable {
        /// The marks were appended to the file.
        case appended(bytes: Int)
        /// The file already held everything; nothing was written.
        case unchanged
        /// The file would not take them; nothing was written.
        case keptInApp(IncrementalWriter.Refusal)
    }

    public private(set) var document: PDFDocument
    public private(set) var paper: LoadedPaper
    public private(set) var saveState: SaveState = .idle
    public private(set) var markups: [MarkupDescriptor] = []
    /// True when the file contains ink drawn in another app, which this app
    /// would replace if it regenerated the page.
    public private(set) var hasForeignInk = false
    /// Bumped whenever the pages themselves change.
    ///
    /// PDFKit caches rendered pages, so adding an annotation to the document
    /// does not by itself repaint the view showing it. The view watches this
    /// and redraws — which is the difference between a highlight that appears
    /// and one that only exists in the file.
    public private(set) var revision = 0 {
        // Anyone drawing the marks — the overlay that gives highlights their
        // rounded ends — hears about every change through this, rather than
        // through each of the five methods that make one.
        didSet { NotificationCenter.default.post(name: .paperTimeMarksChanged, object: self) }
    }

    private let store: LibraryStore
    private var drawings: [Int: PKDrawing] = [:]
    private var pagesNeedingInkRewrite: Set<Int> = []
    /// The shapes, arrows and text cards on each page — the sketch layer.
    /// Like the ink, a sidecar per page is the truth and the PDF gets a copy.
    private var sketches: [Int: [SketchElement]] = [:]
    private var pagesNeedingSketchRewrite: Set<Int> = []
    private var sketchFingerprints: [Int: FileFingerprint] = [:]
    /// The marks the PDF file itself holds — ours once written, and any
    /// made in another app, which have no journal and live only there.
    private var fileMarks: [MarkupDescriptor] = []
    /// Every device's word on every mark, this device's included.
    private var journals: [String: MarkJournal] = [:]
    private let deviceID = DeviceIdentity.current
    private var journalSaveTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var fileFingerprint: FileFingerprint?
    private var inkFingerprints: [Int: FileFingerprint] = [:]
    private var watcher: DocumentWatcher?
    private var pollTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var changedWhileSaving = false
    /// The file as it was when it last would not take the marks, and why.
    /// Asking the same file again changes nothing; a file that changed — a
    /// new version from another device, a password removed — is asked again.
    private var refused: (file: FileFingerprint?, reason: KeptReason)?

    /// How long the app waits after the last change before writing the marks
    /// into the PDF.
    /// Short, because another device is waiting to see it: iCloud adds its
    /// own seconds on top.
    private let flushDelay: Duration = .milliseconds(1500)

    struct FileFingerprint: Equatable {
        var size: Int64
        var modified: Date

        init?(url: URL) {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { return nil }
            self.size = Int64(size)
            self.modified = modified
        }
    }

    public init(
        paper: LoadedPaper,
        document: PDFDocument,
        store: LibraryStore,
        markups: [MarkupDescriptor]? = nil,
        hasForeignInk: Bool? = nil
    ) {
        self.paper = paper
        self.document = document
        self.store = store
        self.fileFingerprint = FileFingerprint(url: paper.documentURL)
        self.fileMarks = markups ?? TextMarkupWriter.descriptors(in: document)
        self.markups = fileMarks
        self.hasForeignInk = hasForeignInk ?? Self.scanForForeignInk(in: document)
        sortMarkups()
        Self.live.append(Weak(self))
    }

    // MARK: - Who has this paper open

    /// Every session alive in this process, weakly.
    ///
    /// A session writes its marks back to the path it opened, so a file
    /// renamed from the library has to find whoever is holding it — in this
    /// window, in a pane beside it, or in a paper's own window — and say
    /// where the file went. One that was never told would save the paper back
    /// under its old name, and the rename would come undone the next time
    /// somebody highlighted a line.
    private final class Weak {
        weak var session: DocumentSession?
        init(_ session: DocumentSession) { self.session = session }
    }

    private static var live: [Weak] = []

    public static func open(forPaper id: UUID) -> [DocumentSession] {
        live.removeAll { $0.session == nil }
        return live.compactMap(\.session).filter { $0.paper.id == id }
    }

    /// The file this session is reading has been given another name.
    ///
    /// Everything else about the paper is unchanged — same record, same
    /// identifier, same marks — so nothing is reloaded. Only the path the
    /// next save writes to, and the watcher listening at the old one.
    public func documentMoved(to url: URL, meta: PaperMeta) {
        paper.documentURL = url
        paper.meta = meta
        fileFingerprint = FileFingerprint(url: url)
        watcher = nil
        pollTask?.cancel()
        pollTask = nil
        startWatching()
    }

    /// Fills in the marks already in the file, just after opening.
    private func readBackExistingMarks() {
        let box = DocumentBox(document: document)
        let folder = paper.folder
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> ReadBack in
                ReadBack(
                    markups: TextMarkupWriter.descriptors(in: box.document),
                    hasForeignInk: Self.scanForForeignInk(in: box.document),
                    journals: MarkJournal.load(from: folder)
                )
            }.value
            guard let self else { return }
            fileMarks = found.markups ?? []
            hasForeignInk = found.hasForeignInk
            for (device, journal) in found.journals { journals[device] = journal }
            reconcile()
        }
    }

    /// The open document, handed to a reader on another thread. Nothing writes
    /// to it there.
    private struct DocumentBox: @unchecked Sendable {
        var document: PDFDocument
    }

    private struct ReadBack: @unchecked Sendable {
        var markups: [MarkupDescriptor]?
        var hasForeignInk: Bool
        var journals: [String: MarkJournal]
    }

    nonisolated static func scanForForeignInk(in document: PDFDocument) -> Bool {
        (0..<document.pageCount)
            .compactMap { document.page(at: $0) }
            .contains(where: InkConverter.hasForeignInk(on:))
    }

    /// Reads the file, parses it, and reads back what is already marked in it
    /// — all of it away from the main actor.
    ///
    /// A paper is tens of megabytes and PDFKit parses eagerly; doing this
    /// where the interface lives is the difference between a reader that opens
    /// and a window that freezes.
    /// A PDF that asks for a password is opened by passing one in; the
    /// caller asks for it and tries again. Nothing keeps the password: it
    /// goes into PDFKit and out of memory with the string it came in.
    public static func open(
        paper: LoadedPaper, store: LibraryStore, password: String? = nil
    ) async throws -> DocumentSession {
        let url = paper.documentURL
        let prepared = try await Task.detached(priority: .userInitiated) {
            FileOperations.requestDownload(of: url)
            let data = try FileOperations.read(contentsOf: url)
            let made = PDFDocument(data: data)
            if let locked = made, locked.isLocked, let password {
                _ = locked.unlock(withPassword: password)
            }
            if let lock = PDFLock.of(document: made, data: data) {
                throw Locked(url: url, lock: lock)
            }
            guard let document = made else {
                throw FileOperations.Failure.documentMissing(url)
            }
            // Reading back the marks means a text extraction per annotation,
            // which on a well-marked paper is most of the wait. The page can be
            // on screen before the notes list is populated.
            return Prepared(document: document, markups: [], hasForeignInk: false)
        }.value

        let session = DocumentSession(
            paper: paper,
            document: prepared.document,
            store: store,
            markups: prepared.markups,
            hasForeignInk: prepared.hasForeignInk
        )
        await session.loadDrawings()
        await session.adoptInkFromFile()
        await session.loadSketches()
        await session.adoptSketchFromFile()
        session.readBackExistingMarks()
        session.startWatching()
        return session
    }

    /// The sidecar is where a page's ink lives; the PDF's copy is written
    /// from it. A page with ink in the file and no sidecar — from before
    /// there were sidecars, or written wrong by an earlier version — gets
    /// one made from the file, so every device draws, erases and syncs the
    /// same strokes. Pages written wrong are rewritten on the next save.
    private func adoptInkFromFile() async {
        var rewrite: Set<Int> = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let owned = page.annotations.filter { $0.type == "Ink" && InkConverter.isOwned($0) }
            guard !owned.isEmpty else { continue }
            if drawings[index] == nil {
                let drawing = InkConverter.drawing(fromOwnedInkOn: page)
                guard !drawing.strokes.isEmpty else { continue }
                drawings[index] = drawing
                let data = drawing.dataRepresentation()
                let folder = paper.folder
                try? await store.saveInk(data, pageIndex: index, in: folder)
                inkFingerprints[index] = FileFingerprint(url: folder.inkURL(pageIndex: index))
            }
            if owned.contains(where: InkConverter.isMisplaced), let drawing = drawings[index] {
                InkConverter.apply(drawing, to: page)
                rewrite.insert(index)
            }
        }
        guard !rewrite.isEmpty else { return }
        pagesNeedingInkRewrite.formUnion(rewrite)
        saveState = .pending
        revision += 1
        scheduleFlush()
    }

    /// A parsed document on its way from a background task to the main actor.
    /// `PDFDocument` is not `Sendable`; nothing else refers to this one until
    /// the session takes it, which is what makes the hand-off safe.
    private struct Prepared: @unchecked Sendable {
        var document: PDFDocument
        var markups: [MarkupDescriptor]
        var hasForeignInk: Bool
    }

    // MARK: - Ink

    public func drawing(forPage index: Int) -> PKDrawing {
        drawings[index] ?? PKDrawing()
    }

    /// Records a page's drawing. The sidecar is written straight away.
    public func setDrawing(_ drawing: PKDrawing, forPage index: Int) {
        drawings[index] = drawing
        pagesNeedingInkRewrite.insert(index)
        saveState = .pending

        let folder = paper.folder
        let data = drawing.dataRepresentation()
        let isEmpty = drawing.strokes.isEmpty
        Task { [store, weak self] in
            if isEmpty {
                try? await store.removeInk(pageIndex: index, in: folder)
            } else {
                try? await store.saveInk(data, pageIndex: index, in: folder)
            }
            self?.inkFingerprints[index] = FileFingerprint(url: folder.inkURL(pageIndex: index))
        }
        scheduleFlush()
    }

    private func loadDrawings() async {
        for index in await store.inkPageIndices(in: paper.folder) {
            // `try?` flattens the store's optional result, so one bind suffices.
            guard let data = try? await store.loadInk(pageIndex: index, in: paper.folder),
                  let drawing = try? PKDrawing(data: data)
            else { continue }
            drawings[index] = drawing
            inkFingerprints[index] = FileFingerprint(url: paper.folder.inkURL(pageIndex: index))
        }
    }

    // MARK: - The sketch layer

    public func sketch(forPage index: Int) -> [SketchElement] {
        sketches[index] ?? []
    }

    /// Records a page's sketch. The sidecar is written straight away; the
    /// PDF's copy follows on the usual delay. Whoever draws the pages hears
    /// about it through `paperTimeSketchChanged`.
    public func setSketch(_ elements: [SketchElement], forPage index: Int) {
        sketches[index] = elements
        pagesNeedingSketchRewrite.insert(index)
        saveState = .pending

        let folder = paper.folder
        let data = Self.encodeSketch(elements)
        let isEmpty = elements.isEmpty
        Task { [store, weak self] in
            if isEmpty {
                try? await store.removeSketch(pageIndex: index, in: folder)
            } else if let data {
                try? await store.saveSketch(data, pageIndex: index, in: folder)
            }
            self?.sketchFingerprints[index] = FileFingerprint(url: folder.sketchURL(pageIndex: index))
        }
        NotificationCenter.default.post(
            name: .paperTimeSketchChanged, object: self, userInfo: ["pages": [index]]
        )
        scheduleFlush()
    }

    nonisolated static func encodeSketch(_ elements: [SketchElement]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(elements)
    }

    nonisolated static func decodeSketch(_ data: Data) -> [SketchElement]? {
        try? JSONDecoder().decode([SketchElement].self, from: data)
    }

    private func loadSketches() async {
        for index in await store.sketchPageIndices(in: paper.folder) {
            guard let data = try? await store.loadSketch(pageIndex: index, in: paper.folder),
                  let elements = Self.decodeSketch(data)
            else { continue }
            sketches[index] = elements
            sketchFingerprints[index] = FileFingerprint(url: paper.folder.sketchURL(pageIndex: index))
        }
    }

    /// A page whose file carries our shapes and whose sidecar has not come
    /// across gets its sidecar made from the file — every annotation of ours
    /// carries the element it was written from.
    private func adoptSketchFromFile() async {
        for index in 0..<document.pageCount where sketches[index] == nil {
            guard let page = document.page(at: index) else { continue }
            let elements = SketchWriter.elements(fromOwnedOn: page)
            guard !elements.isEmpty, let data = Self.encodeSketch(elements) else { continue }
            sketches[index] = elements
            let folder = paper.folder
            try? await store.saveSketch(data, pageIndex: index, in: folder)
            sketchFingerprints[index] = FileFingerprint(url: folder.sketchURL(pageIndex: index))
        }
    }

    /// Sketch sidecars that changed on disk replace the pages' elements —
    /// except pages changed here and not yet written, which are ours to keep.
    private func mergeSketchFromDisk() async {
        let folder = paper.folder
        let onDisk = Set(await store.sketchPageIndices(in: folder))
        var changedPages: [Int] = []
        for index in onDisk.union(sketchFingerprints.keys) where !pagesNeedingSketchRewrite.contains(index) {
            let url = folder.sketchURL(pageIndex: index)
            let now = onDisk.contains(index) ? FileFingerprint(url: url) : nil
            guard now != sketchFingerprints[index] else { continue }
            sketchFingerprints[index] = now
            var elements: [SketchElement] = []
            if now != nil, let data = try? await store.loadSketch(pageIndex: index, in: folder),
               let loaded = Self.decodeSketch(data) {
                elements = loaded
            }
            guard elements != sketches[index] ?? [] else { continue }
            sketches[index] = elements
            changedPages.append(index)
        }
        guard !changedPages.isEmpty else { return }
        NotificationCenter.default.post(
            name: .paperTimeSketchChanged, object: self, userInfo: ["pages": changedPages]
        )
    }

    // MARK: - Following the file

    /// Starts listening for the file changing under the reader.
    func startWatching() {
        guard watcher == nil else { return }
        watcher = DocumentWatcher(document: paper.documentURL, record: paper.folder.url) { [weak self] in
            Task { @MainActor [weak self] in await self?.fileMayHaveChanged() }
        }
        // iCloud does not always announce what it brought, and does not
        // bring what nobody asked for. Every few seconds: ask for whatever
        // in the record is still in the cloud, and look at what is here.
        // A look costs a handful of stats when nothing changed.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let record = paper.folder.url
                await Task.detached(priority: .utility) { FileOperations.requestPendingDownloads(in: record) }.value
                await fileMayHaveChanged()
            }
        }
    }

    private func fileMayHaveChanged() async {
        if saveState == .saving {
            // Our own write; or theirs, landing during ours. Look again after.
            changedWhileSaving = true
            return
        }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.reloadFromDisk() }
    }

    /// Takes in what another device wrote, without disturbing what this one
    /// is doing. The journals are re-read whole — they are small — and the
    /// PDF only when its fingerprint moved; the page is then reconciled with
    /// the lot.
    public func reloadFromDisk() async {
        await mergeInkFromDisk()
        await mergeSketchFromDisk()
        let url = paper.documentURL
        let folder = paper.folder
        let now = FileFingerprint(url: url)
        let pdfChanged = now != nil && now != fileFingerprint
        if pdfChanged { FileOperations.requestDownload(of: url) }
        let found = await Task.detached(priority: .utility) { () -> ReadBack in
            var marks: [MarkupDescriptor]?
            var foreign = false
            if pdfChanged, let data = try? FileOperations.read(contentsOf: url),
               let document = PDFDocument(data: data) {
                marks = TextMarkupWriter.descriptors(in: document)
                foreign = Self.scanForForeignInk(in: document)
            }
            return ReadBack(markups: marks, hasForeignInk: foreign, journals: MarkJournal.load(from: folder))
        }.value
        guard !Task.isCancelled else { return }
        if let marks = found.markups {
            fileMarks = marks
            fileFingerprint = now
            hasForeignInk = found.hasForeignInk
        }
        // Other devices' journals from disk. Our own is ours; the disk copy
        // is only ever behind it.
        for (device, journal) in found.journals where device != deviceID {
            if (journals[device]?.updated ?? .distantPast) <= journal.updated { journals[device] = journal }
        }
        reconcile()
    }

    /// The marks the page should show: what the file holds, overruled mark
    /// by mark by the newest journal entry — a device's addition, change or
    /// removal. The page is brought to that, and only the differences touch it.
    private func reconcile() {
        var desired: [UUID: MarkupDescriptor] = [:]
        for mark in fileMarks { desired[mark.id] = mark }
        for (id, entry) in MarkJournal.merged(journals) {
            if let descriptor = entry.descriptor { desired[id] = descriptor } else { desired[id] = nil }
        }
        var current: [UUID: MarkupDescriptor] = [:]
        for mark in markups { current[mark.id] = mark }
        var changed = false
        for (id, descriptor) in desired where current[id] != descriptor {
            if let page = document.page(at: descriptor.pageIndex) {
                TextMarkupWriter.remove(id: id, from: page)
                TextMarkupWriter.apply(descriptor, to: page)
            }
            changed = true
        }
        for (id, mark) in current where desired[id] == nil {
            if let page = document.page(at: mark.pageIndex) { TextMarkupWriter.remove(id: id, from: page) }
            changed = true
        }
        guard changed else { return }
        markups = Array(desired.values)
        sortMarkups()
        revision += 1
    }

    // MARK: - The journal

    /// Writes a mark into this device's journal and saves it. Every change
    /// to a mark goes through here; the folder carries it to the others.
    private func record(_ descriptor: MarkupDescriptor) {
        var own = journals[deviceID] ?? MarkJournal()
        own.record(descriptor)
        journals[deviceID] = own
        publishJournal(own)
    }

    private func recordRemoval(of id: UUID) {
        var own = journals[deviceID] ?? MarkJournal()
        own.recordRemoval(of: id)
        journals[deviceID] = own
        publishJournal(own)
    }

    private func publishJournal(_ journal: MarkJournal) {
        let folder = paper.folder
        journalSaveTask?.cancel()
        journalSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            try? journal.save(to: folder)
        }
    }

    /// Ink sidecars that changed on disk replace the pages' drawings — except
    /// pages drawn on here and not yet written, which are this device's to keep.
    private func mergeInkFromDisk() async {
        let folder = paper.folder
        let onDisk = Set(await store.inkPageIndices(in: folder))
        var changedPages: [Int] = []
        for index in onDisk.union(inkFingerprints.keys) where !pagesNeedingInkRewrite.contains(index) {
            let url = folder.inkURL(pageIndex: index)
            let now = onDisk.contains(index) ? FileFingerprint(url: url) : nil
            guard now != inkFingerprints[index] else { continue }
            inkFingerprints[index] = now
            var drawing = PKDrawing()
            if now != nil, let data = try? await store.loadInk(pageIndex: index, in: folder),
               let loaded = try? PKDrawing(data: data) {
                drawing = loaded
            }
            guard drawing != drawings[index] ?? PKDrawing() else { continue }
            drawings[index] = drawing
            if let page = document.page(at: index) { InkConverter.apply(drawing, to: page) }
            changedPages.append(index)
        }
        guard !changedPages.isEmpty else { return }
        NotificationCenter.default.post(
            name: .paperTimeInkChanged, object: self, userInfo: ["pages": changedPages]
        )
        revision += 1
    }

    // MARK: - Text markup

    @discardableResult
    public func addMarkup(
        for selection: PDFSelection,
        kind: MarkupDescriptor.Kind,
        color: MarkupColor,
        comment: String = ""
    ) -> [MarkupDescriptor] {
        var descriptors = TextMarkupWriter.descriptor(
            for: selection,
            kind: kind,
            color: color,
            in: document
        )
        guard !descriptors.isEmpty else { return [] }

        for index in descriptors.indices { descriptors[index].comment = comment }
        for descriptor in descriptors {
            guard let page = document.page(at: descriptor.pageIndex) else { continue }
            TextMarkupWriter.apply(descriptor, to: page)
            markups.append(descriptor)
            record(descriptor)
        }
        sortMarkups()
        revision += 1
        saveState = .pending
        scheduleFlush(delay: .seconds(1))
        return descriptors
    }

    /// A note is a highlight with something written on it.
    ///
    /// Not a bare sticky note: a comment that does not show you what it is
    /// about is useless a week later, and every other reader displays a
    /// commented highlight the same way.
    @discardableResult
    public func addNote(
        for selection: PDFSelection,
        comment: String,
        color: MarkupColor = .yellow
    ) -> [MarkupDescriptor] {
        addMarkup(for: selection, kind: .highlight, color: color, comment: comment)
    }

    /// Marks are listed in reading order, which is where the eye looks for them.
    private func sortMarkups() {
        markups.sort { lhs, rhs in
            lhs.pageIndex != rhs.pageIndex
                ? lhs.pageIndex < rhs.pageIndex
                : (lhs.rects.first?.maxY ?? 0) > (rhs.rects.first?.maxY ?? 0)
        }
    }

    /// Puts a set of marks back, used when an undo is undone.
    public func restore(_ descriptors: [MarkupDescriptor]) {
        for descriptor in descriptors {
            guard let page = document.page(at: descriptor.pageIndex) else { continue }
            TextMarkupWriter.apply(descriptor, to: page)
            markups.append(descriptor)
            record(descriptor)
        }
        sortMarkups()
        revision += 1
        saveState = .pending
        scheduleFlush(delay: .seconds(1))
    }

    /// Takes several marks off the page at once.
    public func removeMarkups(ids: [UUID]) {
        for id in ids { removeMarkup(id: id) }
    }

    /// The mark covering a point on a page, if there is one.
    public func markup(withID id: UUID) -> MarkupDescriptor? {
        markups.first { $0.id == id }
    }

    /// Changes a mark's colour in place.
    public func recolor(id: UUID, to color: MarkupColor) {
        guard let index = markups.firstIndex(where: { $0.id == id }) else { return }
        markups[index].color = color
        if let page = document.page(at: markups[index].pageIndex) {
            TextMarkupWriter.remove(id: id, from: page)
            TextMarkupWriter.apply(markups[index], to: page)
        }
        record(markups[index])
        revision += 1
        saveState = .pending
        scheduleFlush(delay: .seconds(1))
    }

    public func removeMarkup(id: UUID) {
        guard let descriptor = markups.first(where: { $0.id == id }) else { return }
        if !descriptor.comment.isEmpty { historyHoldsOldWords = true }
        if let page = document.page(at: descriptor.pageIndex) {
            TextMarkupWriter.remove(id: id, from: page)
        }
        markups.removeAll { $0.id == id }
        recordRemoval(of: id)
        revision += 1
        saveState = .pending
        scheduleFlush(delay: .seconds(1))
    }

    public func updateComment(_ comment: String, forMarkup id: UUID) {
        guard let index = markups.firstIndex(where: { $0.id == id }) else { return }
        if !markups[index].comment.isEmpty, markups[index].comment != comment { historyHoldsOldWords = true }
        markups[index].comment = comment
        if let page = document.page(at: markups[index].pageIndex) {
            TextMarkupWriter.remove(id: id, from: page)
            TextMarkupWriter.apply(markups[index], to: page)
        }
        record(markups[index])
        revision += 1
        saveState = .pending
        scheduleFlush(delay: .seconds(1))
    }

    // MARK: - Saving

    private func scheduleFlush(delay: Duration? = nil) {
        flushTask?.cancel()
        let wait = delay ?? flushDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Writes the marks into the PDF. Called on a delay, when the reader
    /// closes, and whenever the app goes to the background.
    ///
    /// The update is worked out from the file on disk, on a background
    /// thread, never from the open document: starting from the file means
    /// another device's changes are merged rather than overwritten, and the
    /// document on screen is never touched by the writer.
    public func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard saveState == .pending || !pagesNeedingInkRewrite.isEmpty || !pagesNeedingSketchRewrite.isEmpty else { return }
        let url = paper.documentURL
        // The same file said no before. Asking again would read and parse it
        // to hear the same answer; the marks are safe where they are.
        if let refused, refused.file == FileFingerprint(url: url) {
            saveState = .keptInApp(refused.reason)
            return
        }
        saveState = .saving
        // The file is written to agree with every journal, not just with
        // what changed here: whichever device writes, the PDF ends up
        // holding what all of them have said.
        var additions: [MarkupDescriptor] = []
        var removals: [UUID] = []
        for (id, entry) in MarkJournal.merged(journals) {
            if let descriptor = entry.descriptor { additions.append(descriptor) } else { removals.append(id) }
        }
        var inks: [Int: Data] = [:]
        for (index, drawing) in drawings where !drawing.strokes.isEmpty {
            inks[index] = drawing.dataRepresentation()
        }
        for index in pagesNeedingInkRewrite {
            inks[index] = (drawings[index] ?? PKDrawing()).dataRepresentation()
        }
        var sketchData: [Int: Data] = [:]
        for (index, elements) in sketches where !elements.isEmpty {
            sketchData[index] = Self.encodeSketch(elements)
        }
        for index in pagesNeedingSketchRewrite {
            sketchData[index] = Self.encodeSketch(sketches[index] ?? [])
        }
        let baseline = fileFingerprint
        let toApply = additions
        let toRemove = removals
        let inkToWrite = inks
        let sketchToWrite = sketchData

        let folder = paper.folder
        let outcome = await Task.detached(priority: .utility) {
            Self.write(
                to: url,
                additions: toApply,
                removals: toRemove,
                ink: inkToWrite,
                sketches: sketchToWrite,
                recordingBaseIn: folder
            )
        }.value

        switch outcome {
        case let .success(written):
            // Whether another device had also written is no longer something
            // to report: the update is worked out from whatever is on disk,
            // so their marks and ours both survive.
            _ = baseline
            if case let .keptInApp(refusal) = written {
                // The pages stay pending, so a save the file does take will
                // carry them. Until the file changes, it is not asked again.
                let reason = KeptReason(refusal)
                refused = (FileFingerprint(url: url), reason)
                saveState = .keptInApp(reason)
                break
            }
            refused = nil
            // A save that wrote nothing leaves the file — and so what this
            // session knows of it — exactly as it was.
            if case .appended = written { fileFingerprint = FileFingerprint(url: url) }
            fileMarks = additions + fileMarks.filter { mark in !additions.contains { $0.id == mark.id } && !removals.contains(mark.id) }
            pagesNeedingInkRewrite.removeAll()
            pagesNeedingSketchRewrite.removeAll()
            saveState = .idle
        case let .failure(error):
            saveState = .failed(error.localizedDescription)
        }
        lastWrite = outcome
        if changedWhileSaving {
            changedWhileSaving = false
            await fileMayHaveChanged()
        }
    }

    /// What the last save came to — for the probes that check a save of
    /// nothing writes nothing.
    public private(set) var lastWrite: Result<WriteOutcome, any Error>?

    // MARK: - Closing, and folding the history

    /// A comment was changed or a mark with one removed since the last
    /// compaction. Its old words stay readable in the file's history until
    /// the history is folded, so the next close folds it whether or not the
    /// file has grown.
    private var historyHoldsOldWords = false
    /// What the last compaction came to, for the probes.
    public private(set) var lastCompaction: Compaction.Outcome?

    /// The last thing done with a paper: the marks are written, and then, if
    /// the file's history has grown long, folded back into one update.
    /// Called when the reader closes and when the app goes to the background.
    public func close() async {
        await flush()
        await compactIfDue()
    }

    /// Folds the appended revisions into one when they have grown past
    /// `Compaction.Thresholds` — or `force`d, for the probes. Nothing is
    /// touched while a save is pending or the file said no; the marks would
    /// otherwise be rebuilt from a state the file does not yet hold.
    public func compactIfDue(force: Bool = false) async {
        guard saveState == .idle, pagesNeedingInkRewrite.isEmpty, pagesNeedingSketchRewrite.isEmpty else { return }
        let url = paper.documentURL
        let folder = paper.folder
        let meta = paper.meta
        // The whole state, not what changed: every mark the page shows —
        // the file's, the journals', and the sidecars' — goes into the one
        // update, because after it the history is gone.
        var removals: [UUID] = []
        for (id, entry) in MarkJournal.merged(journals) where entry.descriptor == nil { removals.append(id) }
        var inks: [Int: Data] = [:]
        for (index, drawing) in drawings where !drawing.strokes.isEmpty { inks[index] = drawing.dataRepresentation() }
        var sketchData: [Int: Data] = [:]
        for (index, elements) in sketches where !elements.isEmpty { sketchData[index] = Self.encodeSketch(elements) }
        let state = Compaction.State(additions: markups, removals: removals, ink: inks, sketches: sketchData)
        let must = force || historyHoldsOldWords
        saveState = .saving
        let outcome = await Task.detached(priority: .utility) {
            Compaction.run(url: url, folder: folder, meta: meta, state: state, force: must)
        }.value
        saveState = .idle
        lastCompaction = outcome
        if case .compacted = outcome {
            historyHoldsOldWords = false
            fileFingerprint = FileFingerprint(url: url)
        }
        if changedWhileSaving {
            changedWhileSaving = false
            await fileMayHaveChanged()
        }
    }

    /// The file under this session was replaced — its original text put
    /// back under the marks. The document on screen is rebuilt from the new
    /// bytes; the marks are read back from it and brought to what the
    /// journals say, as at opening.
    public func fileWasReplaced() async {
        let url = paper.documentURL
        let made = await Task.detached(priority: .userInitiated) { () -> Prepared? in
            guard let data = try? FileOperations.read(contentsOf: url), let document = PDFDocument(data: data) else { return nil }
            return Prepared(
                document: document,
                markups: TextMarkupWriter.descriptors(in: document),
                hasForeignInk: Self.scanForForeignInk(in: document)
            )
        }.value
        guard let made else { return }
        document = made.document
        fileFingerprint = FileFingerprint(url: url)
        fileMarks = made.markups
        markups = fileMarks
        hasForeignInk = made.hasForeignInk
        sortMarkups()
        // The sidecars stay the truth for ink and shapes, and the overlays
        // draw from them; the file's copies of both went in with the restore.
        reconcile()
        revision += 1
        NotificationCenter.default.post(name: .paperTimeInkChanged, object: self, userInfo: ["pages": Array(drawings.keys)])
        NotificationCenter.default.post(name: .paperTimeSketchChanged, object: self, userInfo: ["pages": Array(sketches.keys)])
    }

    /// Saves again from the journals and sidecars even though nothing is
    /// pending. For probes and checks: on a file that already holds every
    /// mark it writes nothing, and `lastWrite` says so.
    public func saveAgain() async {
        refused = nil
        if saveState == .idle { saveState = .pending }
        await flush()
    }

    /// Applies this session's pending changes to the file, off the main actor,
    /// as an incremental update — never by writing the paper out again.
    ///
    /// The read, the update and the write are one coordinated access
    /// (`FileOperations.update`), so another device's version cannot land in
    /// between; and the update is checked by opening it again with PDFKit
    /// before the file is replaced (`IncrementalWriter.Options.verify`).
    public nonisolated static func write(
        to url: URL,
        additions: [MarkupDescriptor],
        removals: [UUID],
        ink: [Int: Data],
        sketches: [Int: Data] = [:],
        recordingBaseIn folder: PaperFolder? = nil
    ) -> Result<WriteOutcome, any Error> {
        do {
            var result = WriteOutcome.unchanged
            try FileOperations.update(url) { data in
                let outcome: IncrementalWriter.Outcome
                do {
                    outcome = try IncrementalWriter.update(data) { document in
                        edit(document, additions: additions, removals: removals, ink: ink, sketches: sketches)
                    }
                } catch let refusal as IncrementalWriter.Refusal {
                    result = .keptInApp(refusal)
                    return nil
                }
                switch outcome {
                case .unchanged:
                    return nil
                case let .appended(out, stats):
                    // The first append writes down what it appended after:
                    // the base that a later compaction folds back to. Once
                    // only, and before the append, so the base is the file
                    // as it was before this app ever touched it.
                    if let folder { PDFBase.recordIfAbsent(data, in: folder) }
                    result = .appended(bytes: stats.appended)
                    return out
                }
            }
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    /// Brings a document to what the journals and sidecars say — the app's
    /// own writers, on a document opened from the file.
    nonisolated static func edit(
        _ document: PDFDocument,
        additions: [MarkupDescriptor],
        removals: [UUID],
        ink: [Int: Data],
        sketches: [Int: Data]
    ) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for id in removals { TextMarkupWriter.remove(id: id, from: page) }
        }
        for descriptor in additions {
            guard let page = document.page(at: descriptor.pageIndex) else { continue }
            // Already in the file, exactly as the journals describe it:
            // writing it again would produce the same bytes and a storm of
            // notifications from this thread. See `isAlreadyWritten`.
            guard !TextMarkupWriter.isAlreadyWritten(descriptor, on: page) else { continue }
            TextMarkupWriter.remove(id: descriptor.id, from: page)
            TextMarkupWriter.apply(descriptor, to: page)
        }
        for (index, drawingData) in ink {
            guard let page = document.page(at: index),
                  let drawing = try? PKDrawing(data: drawingData)
            else { continue }
            // Stroke by stroke: a page whose ink is already there is left
            // alone, and one new stroke is one new annotation.
            InkConverter.apply(drawing, to: page)
        }
        for (index, sketchData) in sketches {
            guard let page = document.page(at: index),
                  let elements = decodeSketch(sketchData),
                  !SketchWriter.isAlreadyWritten(elements, on: page)
            else { continue }
            SketchWriter.apply(elements, to: page)
        }
    }

    private func applyPendingInk() {
        for index in pagesNeedingInkRewrite {
            guard let page = document.page(at: index) else { continue }
            InkConverter.apply(drawings[index] ?? PKDrawing(), to: page)
        }
        // The open document never carries the sketch — the overlays draw it
        // from the sidecar — so the export puts it in, visibly, first.
        for (index, elements) in sketches {
            guard let page = document.page(at: index) else { continue }
            SketchWriter.apply(elements, to: page)
        }
    }

    // MARK: - Export

    /// Writes a copy with every annotation drawn into the page content.
    ///
    /// Offered because a PDF ink annotation carries one width for a whole
    /// stroke: a flattened copy is the only way to hand somebody a file that
    /// looks exactly like what was on screen.
    public func exportFlattened(to destination: URL) throws {
        applyPendingInk()
        guard let consumer = CGDataConsumer(url: destination as CFURL) else {
            throw FileOperations.Failure.writeVerificationFailed(destination)
        }
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: 612, height: 792))
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FileOperations.Failure.writeVerificationFailed(destination)
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var pageBox = page.bounds(for: .cropBox)
            context.beginPage(mediaBox: &pageBox)
            context.saveGState()
            context.translateBy(x: -pageBox.minX, y: -pageBox.minY)
            page.draw(with: .cropBox, to: context)
            context.restoreGState()
            context.endPage()
        }
        context.closePDF()
    }
}

public extension Notification.Name {
    /// Posted by a `DocumentSession` whenever a mark is added, removed or
    /// recoloured on its pages.
    static let paperTimeMarksChanged = Notification.Name("PaperTimeMarksChanged")
    /// Posted when another device's ink arrived for pages of the open paper;
    /// `userInfo["pages"]` lists them. The canvases showing them redraw.
    static let paperTimeInkChanged = Notification.Name("PaperTimeInkChanged")
    /// Posted when pages' sketches changed — drawn here, or arrived from
    /// another device; `userInfo["pages"]` lists them.
    static let paperTimeSketchChanged = Notification.Name("PaperTimeSketchChanged")
}
