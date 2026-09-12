import Foundation
import InkEngine
import LibraryStore
import PDFKit
import PaperCore
import PencilKit

/// Owns one open paper: its PDF, its ink sidecars, and everything about saving
/// them safely.
///
/// Saving is split in two on purpose. A page's `PKDrawing` is written the
/// moment the pencil lifts, because it is a few kilobytes and it is the copy
/// with full pressure information. The PDF itself is rewritten on a longer
/// delay, because PDFKit can only serialise a whole document at once and doing
/// that after every stroke would stall on a six-hundred-page book. The user's
/// work is never at risk in the gap: the sidecar already holds it, and the PDF
/// is always rebuilt from the sidecars.
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
    private var markupsSinceLastFlush: [MarkupDescriptor] = []
    private var removalsSinceLastFlush: [UUID] = []
    private var flushTask: Task<Void, Never>?
    private var fileFingerprint: FileFingerprint?
    private var inkFingerprints: [Int: FileFingerprint] = [:]
    private var watcher: DocumentWatcher?
    private var reloadTask: Task<Void, Never>?
    private var changedWhileSaving = false

    /// How long the app waits after the last change before rewriting the PDF.
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
        self.markups = markups ?? TextMarkupWriter.descriptors(in: document)
        self.hasForeignInk = hasForeignInk ?? Self.scanForForeignInk(in: document)
        sortMarkups()
    }

    /// Fills in the marks already in the file, just after opening.
    private func readBackExistingMarks() {
        let box = DocumentBox(document: document)
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> ReadBack in
                ReadBack(
                    markups: TextMarkupWriter.descriptors(in: box.document),
                    hasForeignInk: Self.scanForForeignInk(in: box.document)
                )
            }.value
            guard let self, markups.isEmpty else { return }
            markups = found.markups
            hasForeignInk = found.hasForeignInk
            sortMarkups()
        }
    }

    /// The open document, handed to a reader on another thread. Nothing writes
    /// to it there.
    private struct DocumentBox: @unchecked Sendable {
        var document: PDFDocument
    }

    private struct ReadBack: @unchecked Sendable {
        var markups: [MarkupDescriptor]
        var hasForeignInk: Bool
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
    public static func open(paper: LoadedPaper, store: LibraryStore) async throws -> DocumentSession {
        let url = paper.documentURL
        let prepared = try await Task.detached(priority: .userInitiated) {
            FileOperations.requestDownload(of: url)
            let data = try FileOperations.read(contentsOf: url)
            guard let document = PDFDocument(data: data) else {
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
        session.readBackExistingMarks()
        session.startWatching()
        return session
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

    // MARK: - Following the file

    /// Starts listening for the file changing under the reader.
    func startWatching() {
        guard watcher == nil else { return }
        watcher = DocumentWatcher(document: paper.documentURL, record: paper.folder.url) { [weak self] in
            Task { @MainActor [weak self] in await self?.fileMayHaveChanged() }
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
    /// is doing: marks and ink from the file are merged into the open
    /// document, and anything not yet written from here is kept.
    public func reloadFromDisk() async {
        await mergeInkFromDisk()
        let url = paper.documentURL
        guard let now = FileFingerprint(url: url), now != fileFingerprint else { return }
        FileOperations.requestDownload(of: url)
        guard let found = await Task.detached(priority: .utility) { () -> ReadBack? in
            guard let data = try? FileOperations.read(contentsOf: url),
                  let document = PDFDocument(data: data) else { return nil }
            return ReadBack(
                markups: TextMarkupWriter.descriptors(in: document),
                hasForeignInk: Self.scanForForeignInk(in: document)
            )
        }.value, !Task.isCancelled else { return }
        fileFingerprint = now
        merge(found.markups)
        hasForeignInk = found.hasForeignInk
    }

    /// The file's marks laid over ours. Ours that are not yet saved stay;
    /// theirs that we did not just delete come in; what they deleted goes.
    private func merge(_ theirs: [MarkupDescriptor]) {
        let pendingAdds = Set(markupsSinceLastFlush.map(\.id))
        let pendingRemovals = Set(removalsSinceLastFlush)
        let theirIDs = Set(theirs.map(\.id))
        var changed = false

        for descriptor in theirs where !pendingRemovals.contains(descriptor.id) {
            if let index = markups.firstIndex(where: { $0.id == descriptor.id }) {
                let ours = markups[index]
                guard !pendingAdds.contains(descriptor.id),
                      ours.color != descriptor.color || ours.comment != descriptor.comment
                else { continue }
                markups[index] = descriptor
            } else {
                markups.append(descriptor)
            }
            if let page = document.page(at: descriptor.pageIndex) {
                TextMarkupWriter.remove(id: descriptor.id, from: page)
                TextMarkupWriter.apply(descriptor, to: page)
            }
            changed = true
        }
        for descriptor in markups where !theirIDs.contains(descriptor.id) && !pendingAdds.contains(descriptor.id) {
            if let page = document.page(at: descriptor.pageIndex) {
                TextMarkupWriter.remove(id: descriptor.id, from: page)
            }
            markups.removeAll { $0.id == descriptor.id }
            changed = true
        }
        guard changed else { return }
        sortMarkups()
        revision += 1
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
            markupsSinceLastFlush.append(descriptor)
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
            markupsSinceLastFlush.append(descriptor)
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
        markupsSinceLastFlush.append(markups[index])
        revision += 1
        saveState = .pending
        scheduleFlush(delay: .seconds(1))
    }

    public func removeMarkup(id: UUID) {
        guard let descriptor = markups.first(where: { $0.id == id }) else { return }
        if let page = document.page(at: descriptor.pageIndex) {
            TextMarkupWriter.remove(id: id, from: page)
        }
        markups.removeAll { $0.id == id }
        markupsSinceLastFlush.removeAll { $0.id == id }
        removalsSinceLastFlush.append(id)
        revision += 1
        saveState = .pending
        scheduleFlush(delay: .seconds(1))
    }

    public func updateComment(_ comment: String, forMarkup id: UUID) {
        guard let index = markups.firstIndex(where: { $0.id == id }) else { return }
        markups[index].comment = comment
        if let page = document.page(at: markups[index].pageIndex) {
            TextMarkupWriter.remove(id: id, from: page)
            TextMarkupWriter.apply(markups[index], to: page)
        }
        markupsSinceLastFlush.append(markups[index])
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

    /// Writes the PDF. Called on a delay, when the reader closes, and whenever
    /// the app goes to the background.
    ///
    /// The file is rebuilt from disk on a background thread rather than
    /// serialised from the open document. `PDFDocument.dataRepresentation()`
    /// takes between a third and three quarters of a second on a real paper,
    /// and doing that on the main actor froze the window every couple of
    /// seconds while marking one up. Starting from the file also means another
    /// device's changes are merged rather than overwritten, and the document on
    /// screen is never touched by the writer.
    public func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard saveState == .pending || !pagesNeedingInkRewrite.isEmpty else { return }
        saveState = .saving

        let url = paper.documentURL
        let additions = markupsSinceLastFlush
        let removals = removalsSinceLastFlush
        var inks: [Int: Data] = [:]
        for index in pagesNeedingInkRewrite {
            inks[index] = (drawings[index] ?? PKDrawing()).dataRepresentation()
        }
        let baseline = fileFingerprint

        let outcome = await Task.detached(priority: .utility) {
            Self.write(
                to: url,
                additions: additions,
                removals: removals,
                ink: inks
            )
        }.value

        switch outcome {
        case .success:
            // Whether another device had also written is no longer something
            // to report: the file is rebuilt from whatever is on disk, so
            // their marks and ours both survive.
            _ = baseline
            fileFingerprint = FileFingerprint(url: url)
            markupsSinceLastFlush.removeAll()
            removalsSinceLastFlush.removeAll()
            pagesNeedingInkRewrite.removeAll()
            saveState = .idle
        case let .failure(error):
            saveState = .failed(error.localizedDescription)
        }
        if changedWhileSaving {
            changedWhileSaving = false
            await fileMayHaveChanged()
        }
    }

    /// Applies this session's pending changes to the file, off the main actor.
    nonisolated static func write(
        to url: URL,
        additions: [MarkupDescriptor],
        removals: [UUID],
        ink: [Int: Data]
    ) -> Result<Void, any Error> {
        do {
            let data = try FileOperations.read(contentsOf: url)
            guard let document = PDFDocument(data: data) else {
                throw FileOperations.Failure.documentMissing(url)
            }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for id in removals { TextMarkupWriter.remove(id: id, from: page) }
            }
            for descriptor in additions {
                guard let page = document.page(at: descriptor.pageIndex) else { continue }
                TextMarkupWriter.remove(id: descriptor.id, from: page)
                TextMarkupWriter.apply(descriptor, to: page)
            }
            for (index, drawingData) in ink {
                guard let page = document.page(at: index),
                      let drawing = try? PKDrawing(data: drawingData)
                else { continue }
                InkConverter.apply(drawing, to: page)
            }
            guard let out = document.dataRepresentation() else {
                throw FileOperations.Failure.writeVerificationFailed(url)
            }
            try FileOperations.write(out, to: url)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func applyPendingInk() {
        for index in pagesNeedingInkRewrite {
            guard let page = document.page(at: index) else { continue }
            InkConverter.apply(drawings[index] ?? PKDrawing(), to: page)
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
    public static let paperTimeInkChanged = Notification.Name("PaperTimeInkChanged")
}
