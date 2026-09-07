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
    public private(set) var revision = 0

    private let store: LibraryStore
    private var drawings: [Int: PKDrawing] = [:]
    private var pagesNeedingInkRewrite: Set<Int> = []
    private var markupsSinceLastFlush: [MarkupDescriptor] = []
    private var flushTask: Task<Void, Never>?
    private var fileFingerprint: FileFingerprint?

    /// How long the app waits after the last change before rewriting the PDF.
    private let flushDelay: Duration = .seconds(4)

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
            return Prepared(
                document: document,
                markups: TextMarkupWriter.descriptors(in: document),
                hasForeignInk: scanForForeignInk(in: document)
            )
        }.value

        let session = DocumentSession(
            paper: paper,
            document: prepared.document,
            store: store,
            markups: prepared.markups,
            hasForeignInk: prepared.hasForeignInk
        )
        await session.loadDrawings()
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
        Task { [store] in
            if isEmpty {
                try? await store.removeInk(pageIndex: index, in: folder)
            } else {
                try? await store.saveInk(data, pageIndex: index, in: folder)
            }
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
        }
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
        scheduleFlush(delay: .seconds(2))
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

    public func removeMarkup(id: UUID) {
        guard let descriptor = markups.first(where: { $0.id == id }) else { return }
        if let page = document.page(at: descriptor.pageIndex) {
            TextMarkupWriter.remove(id: id, from: page)
        }
        markups.removeAll { $0.id == id }
        markupsSinceLastFlush.removeAll { $0.id == id }
        revision += 1
        saveState = .pending
        scheduleFlush(delay: .seconds(2))
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
        scheduleFlush(delay: .seconds(2))
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
    public func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard saveState == .pending || !pagesNeedingInkRewrite.isEmpty else { return }
        saveState = .saving

        let currentFingerprint = FileFingerprint(url: paper.documentURL)
        var merged = false
        if let fileFingerprint, let currentFingerprint, currentFingerprint != fileFingerprint {
            // Somebody else wrote this file while it was open here. Rebuild on
            // top of their version instead of replacing it.
            merged = reloadAndReapply()
        }

        applyPendingInk()

        guard let data = document.dataRepresentation() else {
            saveState = .failed("The document could not be prepared for saving.")
            return
        }
        do {
            try FileOperations.write(data, to: paper.documentURL)
            fileFingerprint = FileFingerprint(url: paper.documentURL)
            markupsSinceLastFlush.removeAll()
            pagesNeedingInkRewrite.removeAll()
            saveState = merged ? .mergedExternalChanges : .idle
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func applyPendingInk() {
        for index in pagesNeedingInkRewrite {
            guard let page = document.page(at: index) else { continue }
            InkConverter.apply(drawings[index] ?? PKDrawing(), to: page)
        }
    }

    /// Replaces the in-memory document with the one on disk and puts our own
    /// marks back on top of it.
    private func reloadAndReapply() -> Bool {
        guard let data = try? FileOperations.read(contentsOf: paper.documentURL),
              let reloaded = PDFDocument(data: data)
        else { return false }

        document = reloaded
        // Every page with a sidecar is regenerated, so ink is never lost even
        // if the other device's copy predates it.
        for (index, drawing) in drawings {
            guard let page = reloaded.page(at: index) else { continue }
            InkConverter.apply(drawing, to: page)
        }
        for descriptor in markupsSinceLastFlush {
            guard let page = reloaded.page(at: descriptor.pageIndex) else { continue }
            TextMarkupWriter.remove(id: descriptor.id, from: page)
            TextMarkupWriter.apply(descriptor, to: page)
        }
        markups = TextMarkupWriter.descriptors(in: reloaded)
        sortMarkups()
        revision += 1
        return true
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
