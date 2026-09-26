import Foundation
import InkEngine
import LibraryStore
import PaperCore
import PDFUpdate

/// Folds a paper's appended revisions back into one.
///
/// Every save appends; a paper marked over a term carries hundreds of small
/// updates, each a full copy of the pages it touched, and a comment that was
/// deleted stays readable in an earlier revision until something writes over
/// the history. Compaction takes the base — the bytes the marks were first
/// appended after — and runs the ordinary save on it once, from the app's
/// whole current state, so the result is the base plus one update. It is
/// never PDFKit's rewrite: the base bytes are kept exactly, which is what
/// keeps the text intact and the file checkable against its import digest.
///
/// It is rare and it is cautious. It runs only when the reader closes or
/// the app goes to the background, only when the tail has grown past
/// `Thresholds` (or a comment was edited or removed — the privacy case), and
/// the candidate replaces the file only when: nothing past the base was
/// changed by anything but an annotation (`RevisionAudit`), the candidate
/// shows the same marks page by page (`AnnotationComparison.markDifference`
/// — ours by what a reader shows of them, since the file may have been
/// written by the Portable build and PDFKit spells every mark differently;
/// anybody else's by their every key), it is at least half as short as what it
/// replaces, and the file is still the one that was read.
public enum Compaction {
    public struct Thresholds: Sendable {
        /// The tail must exceed both of these…
        public var minimumTail = 1 << 20
        public var tailFraction = 0.1
        /// …or the revisions since the base this many.
        public var maximumRevisions = 100

        public init() {}

        public func isDue(fileLength: Int, baseLength: Int, revisions: Int) -> Bool {
            let tail = fileLength - baseLength
            return tail > max(minimumTail, Int(Double(baseLength) * tailFraction)) || revisions > maximumRevisions
        }
    }

    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        /// The tail is small and the history short; nothing to do.
        case notDue(tail: Int, revisions: Int)
        /// No version of the file is known to be all its own.
        case noBase
        /// Something in the history is not an annotation of ours, or the
        /// candidate did not match — the file was left exactly as it was.
        case refused(String)
        /// The file was replaced.
        case compacted(before: Int, after: Int, revisions: Int)

        public var description: String {
            switch self {
            case let .notDue(tail, revisions): "not due (tail \(tail) B, \(revisions) revisions)"
            case .noBase: "no base"
            case let .refused(why): "refused: \(why)"
            case let .compacted(before, after, revisions): "compacted \(before) → \(after) B, folded \(revisions) revisions"
            }
        }
    }

    /// The whole of the app's state for one paper, from which the one
    /// update is rebuilt.
    public struct State: Sendable {
        public var additions: [MarkupDescriptor]
        public var removals: [UUID]
        public var ink: [Int: Data]
        public var sketches: [Int: Data]

        public init(additions: [MarkupDescriptor] = [], removals: [UUID] = [], ink: [Int: Data] = [:], sketches: [Int: Data] = [:]) {
            self.additions = additions
            self.removals = removals
            self.ink = ink
            self.sketches = sketches
        }
    }

    /// Compacts the file at `url` if it is due (or `force`d), and says what
    /// happened. Nothing is written unless every check passes.
    public static func run(
        url: URL,
        folder: PaperFolder,
        meta: PaperMeta,
        state: State,
        force: Bool = false,
        thresholds: Thresholds = Thresholds(),
        password: [UInt8] = []
    ) -> Outcome {
        let data: Data
        do { data = try FileOperations.read(contentsOf: url) } catch { return .refused("cannot read the file: \(error)") }
        guard let base = PDFBase.find(for: data, in: folder, meta: meta) else { return .noBase }
        let baseData = data.prefix(base.length)
        let sections = (try? PDFFile(data: data).sections.count) ?? 0
        let baseSections = (try? PDFFile(data: baseData).sections.count) ?? 0
        let revisions = max(0, sections - baseSections)
        let tail = data.count - base.length
        guard force || thresholds.isDue(fileLength: data.count, baseLength: base.length, revisions: revisions) else {
            return .notDue(tail: tail, revisions: revisions)
        }
        guard revisions > 0 else { return .notDue(tail: tail, revisions: revisions) }

        do {
            if let why = try RevisionAudit.foreignChanges(in: data, after: base.length, password: password) {
                return .refused(why)
            }
        } catch {
            return .refused("the history could not be read: \(error)")
        }

        var options = IncrementalWriter.Options()
        options.password = password
        let candidate: Data
        do {
            let outcome = try IncrementalWriter.update(baseData, options: options) { document in
                DocumentSession.edit(document, additions: state.additions, removals: state.removals, ink: state.ink, sketches: state.sketches)
            }
            switch outcome {
            case let .appended(out, _): candidate = out
            case .unchanged: candidate = baseData
            }
        } catch {
            return .refused("the update could not be rebuilt: \(error)")
        }

        do {
            if let why = try AnnotationComparison.markDifference(current: data, candidate: candidate, password: password) {
                return .refused(why)
            }
        } catch {
            return .refused("the candidate could not be compared: \(error)")
        }

        // Worth doing only when it makes a difference: at least half the
        // tail, or — when a comment's history is the reason — any less.
        let newTail = candidate.count - base.length
        guard newTail <= tail / 2 || (force && candidate.count < data.count) else {
            return .refused("the candidate would not be much shorter (\(newTail) B after \(tail) B)")
        }

        do {
            try FileOperations.replace(url, with: candidate, ifStill: data)
        } catch {
            return .refused("the file could not be replaced: \(error)")
        }
        return .compacted(before: data.count, after: candidate.count, revisions: revisions)
    }
}
