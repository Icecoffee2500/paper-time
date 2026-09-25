import Foundation
import InkEngine
import LibraryStore
import PDFKit
import PDFUpdate
import PaperCore
import PencilKit

/// Puts a paper's original text back under its marks.
///
/// Until saves became incremental, every save wrote the paper out again with
/// PDFKit, and on papers set in TeX that turned "ff" into "!" in the file
/// itself. The marks made on such a file are good; the text under them is
/// not, and there is no way to repair it from the file. There is a way from
/// the original: imports copy the file in and leave the source alone, so the
/// one that was imported is often still in Downloads. This takes that file,
/// insists it is the very one (its SHA-256 must equal the record's
/// `importDigest` — nothing that merely looks like it is accepted), and
/// writes the marks onto it as an incremental update: the marks the journals
/// and sidecars know, the marks the damaged file holds that they do not, and
/// every annotation another program put there. The damaged file goes to the
/// Trash. Nothing is fetched from anywhere; the person brings the file.
public enum PaperRestore {
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// The chosen file is not the one that was imported.
        case notTheOriginal
        /// The record has no digest, so nothing could be checked against it.
        case noDigest
        case cannotOpen
        case pageCount(original: Int, current: Int)
        /// The marks written onto the original do not read back as the ones
        /// on the current file.
        case marksDiffer(String)
        /// The writer would not write into the original.
        case writer(String)

        public var description: String {
            switch self {
            case .notTheOriginal: "the chosen file is not the one that was imported"
            case .noDigest: "the record has no import digest"
            case .cannotOpen: "PDFKit cannot open one of the files"
            case let .pageCount(o, c): "\(o) pages in the original, \(c) in the current file"
            case let .marksDiffer(why): "the marks do not read back the same: \(why)"
            case let .writer(why): "the writer refused: \(why)"
            }
        }
    }

    /// What a restore would do, said before it does it.
    public struct Preview: Equatable, Sendable {
        public var pageCount: Int
        /// Pages whose text PDFKit reads differently between the two files —
        /// the damage, counted.
        public var textDiffersOn: Int
        /// Marks of ours, from journals, sidecars and the current file.
        public var marks: Int
        /// Annotations another program made on the current file, which are
        /// carried across.
        public var foreign: Int
    }

    /// The bytes and the objects a restore works from, read once.
    public struct Plan: @unchecked Sendable {
        public var original: Data
        public var current: Data
        public var preview: Preview
        let originalDocument: PDFDocument
        let currentDocument: PDFDocument
        let state: Compaction.State
        let foreign: [Int: [PDFAnnotation]]
    }

    /// Reads both files, checks the chosen one against the record, and works
    /// out what would be written. Nothing is changed.
    public static func plan(
        original candidate: URL,
        for paper: LoadedPaper,
        store: LibraryStore
    ) async throws -> Plan {
        let meta = paper.meta
        guard !meta.file.importDigest.isEmpty else { throw Refusal.noDigest }
        let original = try FileOperations.read(contentsOf: candidate)
        guard FileProvenance.classify(original, importDigest: meta.file.importDigest, byteSize: meta.file.byteSize) == .pristine else {
            throw Refusal.notTheOriginal
        }
        let current = try FileOperations.read(contentsOf: paper.documentURL)
        guard let originalDocument = PDFDocument(data: original), let currentDocument = PDFDocument(data: current) else {
            throw Refusal.cannotOpen
        }
        guard originalDocument.pageCount == currentDocument.pageCount else {
            throw Refusal.pageCount(original: originalDocument.pageCount, current: currentDocument.pageCount)
        }
        var differing = 0
        for index in 0..<originalDocument.pageCount
        where (originalDocument.page(at: index)?.string ?? "") != (currentDocument.page(at: index)?.string ?? "") {
            differing += 1
        }

        // Every mark of ours: what the journals say, then whatever the file
        // holds that no journal knows (older marks, marks from a device whose
        // journal never arrived), then the sidecars, then the file's copies
        // of ink and shapes for pages without a sidecar.
        var additions: [UUID: MarkupDescriptor] = [:]
        var removals: [UUID] = []
        for (id, entry) in MarkJournal.merged(MarkJournal.load(from: paper.folder)) {
            if let descriptor = entry.descriptor { additions[id] = descriptor } else { removals.append(id) }
        }
        let removed = Set(removals)
        for descriptor in TextMarkupWriter.descriptors(in: currentDocument)
        where additions[descriptor.id] == nil && !removed.contains(descriptor.id) {
            additions[descriptor.id] = descriptor
        }
        var ink: [Int: Data] = [:]
        for index in await store.inkPageIndices(in: paper.folder) {
            if let data = try? await store.loadInk(pageIndex: index, in: paper.folder) { ink[index] = data }
        }
        var sketches: [Int: Data] = [:]
        for index in await store.sketchPageIndices(in: paper.folder) {
            if let data = try? await store.loadSketch(pageIndex: index, in: paper.folder) { sketches[index] = data }
        }
        var foreign: [Int: [PDFAnnotation]] = [:]
        var foreignCount = 0
        for index in 0..<currentDocument.pageCount {
            guard let page = currentDocument.page(at: index) else { continue }
            if ink[index] == nil {
                let drawing = InkConverter.drawing(fromOwnedInkOn: page)
                if !drawing.strokes.isEmpty { ink[index] = drawing.dataRepresentation() }
            }
            if sketches[index] == nil {
                let elements = SketchWriter.elements(fromOwnedOn: page)
                if !elements.isEmpty { sketches[index] = DocumentSession.encodeSketch(elements) }
            }
            let already = Set((originalDocument.page(at: index)?.annotations ?? []).map(key))
            let theirs = page.annotations.filter { !isOurs($0) && $0.type != "Popup" && !already.contains(key($0)) }
            if !theirs.isEmpty { foreign[index] = theirs }
            foreignCount += theirs.count
        }
        let preview = Preview(
            pageCount: originalDocument.pageCount,
            textDiffersOn: differing,
            marks: additions.count + ink.count + sketches.count,
            foreign: foreignCount
        )
        return Plan(
            original: original, current: current, preview: preview,
            originalDocument: originalDocument, currentDocument: currentDocument,
            state: Compaction.State(additions: Array(additions.values), removals: removals, ink: ink, sketches: sketches),
            foreign: foreign
        )
    }

    /// The original with the marks on it, checked against the current file
    /// before it is handed back: the same annotations, page by page, as
    /// PDFKit reads them.
    public static func restoredBytes(from plan: Plan) throws -> Data {
        let outcome: IncrementalWriter.Outcome
        do {
            outcome = try IncrementalWriter.update(plan.original) { document in
                DocumentSession.edit(
                    document, additions: plan.state.additions, removals: plan.state.removals,
                    ink: plan.state.ink, sketches: plan.state.sketches
                )
                // Another program's annotations move across as the objects
                // they are; PDFKit serialises them again, appearance and all.
                for (index, annotations) in plan.foreign {
                    guard let from = plan.currentDocument.page(at: index), let to = document.page(at: index) else { continue }
                    for annotation in annotations {
                        from.removeAnnotation(annotation)
                        to.addAnnotation(annotation)
                    }
                }
            }
        } catch let refusal as IncrementalWriter.Refusal {
            throw Refusal.writer(refusal.description)
        }
        let restored: Data
        switch outcome {
        case let .appended(out, _): restored = out
        case .unchanged: restored = plan.original
        }
        guard let reread = PDFDocument(data: restored), let current = PDFDocument(data: plan.current) else {
            throw Refusal.cannotOpen
        }
        if let why = difference(current: current, candidate: reread) {
            throw Refusal.marksDiffer(why)
        }
        return restored
    }

    /// Where the candidate's pages do not show what the current file's do,
    /// or nil. Looser than the writer's own check on purpose: the current
    /// file was written by another program — PDFKit, for the files this is
    /// for — so only what a mark means is compared: its kind, which of ours
    /// it is, and where it sits. Popups are left out, and a note is placed
    /// by its top-left corner (PDFKit reads one back at its own icon size).
    static func difference(current: PDFDocument, candidate: PDFDocument) -> String? {
        guard current.pageCount == candidate.pageCount else {
            return "\(candidate.pageCount) pages instead of \(current.pageCount)"
        }
        struct Mark: Comparable {
            var type: String
            var identity: String
            var bounds: CGRect
            static func < (a: Mark, b: Mark) -> Bool {
                if a.type != b.type { return a.type < b.type }
                if a.identity != b.identity { return a.identity < b.identity }
                if abs(a.bounds.minY - b.bounds.minY) >= 0.3 { return a.bounds.minY < b.bounds.minY }
                return a.bounds.minX < b.bounds.minX
            }
            static func == (a: Mark, b: Mark) -> Bool {
                a.type == b.type && a.identity == b.identity && a.bounds == b.bounds
            }
        }
        func marks(_ page: PDFPage?) -> [Mark] {
            (page?.annotations ?? []).filter { $0.type != "Popup" }.map { a in
                var id = ""
                if let m = TextMarkupWriter.identifier(of: a) { id = "M\(m.uuidString)" }
                if let s = SketchWriter.identifier(of: a) { id = "S\(s.uuidString)" }
                return Mark(type: a.type ?? "?", identity: id, bounds: a.bounds)
            }.sorted()
        }
        for index in 0..<current.pageCount {
            let want = marks(current.page(at: index)), got = marks(candidate.page(at: index))
            guard want.count == got.count else { return "page \(index): \(got.count) annotations instead of \(want.count)" }
            for (a, b) in zip(want, got) {
                guard a.type == b.type, a.identity == b.identity else { return "page \(index): a \(b.type) where a \(a.type) should be" }
                let near = a.type == "Text"
                    ? abs(a.bounds.minX - b.bounds.minX) < 0.6 && abs(a.bounds.maxY - b.bounds.maxY) < 0.6
                    : abs(a.bounds.minX - b.bounds.minX) < 0.6 && abs(a.bounds.minY - b.bounds.minY) < 0.6
                        && abs(a.bounds.width - b.bounds.width) < 0.6 && abs(a.bounds.height - b.bounds.height) < 0.6
                if !near { return "page \(index): a \(a.type) at \(b.bounds) instead of \(a.bounds)" }
            }
        }
        return nil
    }

    /// What a restore left behind.
    public struct Report: Equatable, Sendable {
        public var preview: Preview
        public var bytes: Int
        /// Where the file that was replaced went.
        public var trashed: URL?
    }

    /// Writes the restored file in the damaged one's place, moving the
    /// damaged one to the Trash, and records the original as the base.
    public static func perform(_ plan: Plan, for paper: LoadedPaper, libraryRoot: URL) throws -> Report {
        let restored = try restoredBytes(from: plan)
        let trashed = try FileOperations.replace(
            paper.documentURL, with: restored, ifStill: plan.current, trashingOld: true, libraryRoot: libraryRoot
        )
        try? PDFBase(length: plan.original.count, digest: paper.meta.file.importDigest).save(to: paper.folder)
        return Report(preview: plan.preview, bytes: restored.count, trashed: trashed)
    }

    // MARK: - Whose, and which

    static func isOurs(_ annotation: PDFAnnotation) -> Bool {
        TextMarkupWriter.identifier(of: annotation) != nil
            || InkConverter.isOwned(annotation)
            || SketchWriter.isOwned(annotation)
    }

    /// Enough to say two annotations in two files are the same one: its
    /// kind, where it is to half a point, and what it says.
    static func key(_ annotation: PDFAnnotation) -> String {
        let b = annotation.bounds
        func r(_ x: CGFloat) -> Int { Int((x * 2).rounded()) }
        return "\(annotation.type ?? "?")|\(r(b.minX)),\(r(b.minY)),\(r(b.width)),\(r(b.height))|\(annotation.contents ?? "")"
    }
}
