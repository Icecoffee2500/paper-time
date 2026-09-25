import Foundation
import PDFKit
// In the app the folding comes from the package. Compiled on its own with
// `Scripts/search-probe.swift`, the one file it needs from there is compiled
// alongside instead — see that script.
#if canImport(PaperCore)
import PaperCore
#endif

/// The words inside the papers, so search can find a sentence and not only a
/// title.
///
/// Spotlight over a library of papers is half a search: you remember that
/// somebody defined the thing, not who, and the title you are being offered
/// does not contain the word you are thinking of — the fourth page does. This
/// keeps the text of every paper so the word can be found in it, and keeps
/// enough of where it was found to walk back to it: the page, and the range of
/// characters on that page, which is all `PDFPage.selection(for:)` needs to
/// hand back the line itself.
///
/// The text is read once and kept in the caches folder, folded for searching
/// as well as it was read (`PaperText`), because extracting it is most of a
/// second per paper and the answer never changes while the file does not.
/// Nothing here belongs in the library folder: it is derived, it is
/// rebuildable, and a folder people sync should hold what they wrote, not what
/// we worked out.
///
/// Deliberately free of everything but Foundation, PDFKit and `PaperText`, so
/// the whole thing can be compiled on its own and run over the real corpus
/// from a terminal — see `Scripts/search-probe.swift`.
actor PaperTextIndex {
    static let shared = PaperTextIndex()

    /// A paper as the index needs it: something to read, and something to
    /// call it in a result.
    struct Source: Sendable, Hashable {
        var id: UUID
        var url: URL
        var title: String

        init(id: UUID, url: URL, title: String) {
            self.id = id
            self.url = url
            self.title = title
        }
    }

    /// Where a word was found, in the coordinates the reader can act on.
    struct Passage: Sendable, Hashable {
        var paperID: UUID
        var pageIndex: Int
        /// Into `PDFPage.string`, which is what a selection is made from.
        var location: Int
        var length: Int
    }

    /// One paper's answer to a query: where the first match is, what it says,
    /// and how many more there are.
    struct Hit: Sendable, Hashable {
        var passage: Passage
        var title: String
        /// The sentence around the match, whitespace tidied.
        var snippet: String
        var count: Int
    }

    /// The text of every paper read so far in this session. Not asked again
    /// while the app runs, as before: a paper whose file changes under it is
    /// read afresh next time.
    private var texts: [UUID: PaperText] = [:]
    /// Papers being read right now, so a second request waits for the first
    /// read rather than starting another.
    private var reading: [UUID: Task<PaperText?, Never>] = [:]

    /// How many papers are read at once.
    ///
    /// Reading one is PDFKit laying out every page to find its text, which is
    /// one core's work for a quarter of a second; four at a time read the
    /// corpus in 4.1 s instead of 15.1 s. Not more: each reader holds a whole
    /// document, and four already took the app from 270 to 435 MB while they
    /// ran.
    static let width = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
    private var running = 0
    private var queued: [CheckedContinuation<Void, Never>] = []
    /// Papers let go of in this session, so a read still under way for one
    /// does not bring it back.
    private var forgotten: Set<UUID> = []

    /// How many papers already read are searched side by side in one go.
    private static let batch = 64

    /// How far ahead of the paper being searched papers are sent to be read.
    ///
    /// Further than there are readers, on purpose. The answers have to come
    /// out in order, so the search waits for the paper it is at; if only as
    /// many papers as there are readers had been sent, one slow book — the
    /// corpus has a 1,000-page one that takes most of half a minute — leaves
    /// the other three readers with nothing to do until it is done. The ones
    /// sent ahead queue for a reader and start the moment one is free. Past
    /// this, what a search that is given up leaves behind to be read is at
    /// most this many papers, and they are kept for the next one.
    private static let lookahead = 4 * width

    // MARK: - Searching

    /// Every paper that holds the query, one at a time, in the order given.
    ///
    /// A stream rather than an array: the first search of a session may have
    /// to read papers nobody has read yet, and a palette that shows the first
    /// paper after a hundred milliseconds is a different thing from one that
    /// shows nothing for eight seconds. Order the sources by what the reader
    /// touched last and the answer they wanted is usually the first to land.
    ///
    /// The order is kept whatever happens underneath: papers are read a few
    /// at a time ahead of the one being searched, and papers already read are
    /// searched together, but the answers still come out in the order the
    /// papers went in — the palette keeps the first four, and they have to be
    /// the same four.
    nonisolated func hits(for query: String, in sources: [Source]) -> AsyncStream<Hit> {
        AsyncStream { continuation in
            let work = Task {
                await self.walk(query, in: sources) { found in
                    for hit in found { continuation.yield(hit) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// The same answers in the same order, in the handfuls they were found
    /// in: every paper already read in one go, and each paper that had to be
    /// read on its own, as soon as it has been.
    ///
    /// For the list, which lays itself out again for every change to what it
    /// shows. Once the papers are read, "le" answers in six hundred papers
    /// within a few milliseconds, and six hundred changes one after another
    /// were six hundred layouts on the main thread; a paper still being read
    /// is shown the moment it is, as it always was.
    nonisolated func hitBatches(for query: String, in sources: [Source]) -> AsyncStream<[Hit]> {
        AsyncStream { continuation in
            let work = Task {
                await self.walk(query, in: sources) { found in
                    if !found.isEmpty { continuation.yield(found) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// The search itself, handing over what it finds as it goes.
    private nonisolated func walk(_ query: String, in sources: [Source],
                                  deliver: ([Hit]) -> Void) async {
        let needle = SearchFolding.fold(query)
        guard needle.utf16.count > 1 else { return }
        let known = await resident(sources.map(\.id))
        var ahead: [Int: Task<PaperText?, Never>] = [:]
        var next = 0
        var index = 0
        while index < sources.count {
            if Task.isCancelled { return }
            if known[index] != nil {
                var end = index
                while end < sources.count, end - index < Self.batch, known[end] != nil { end += 1 }
                let run = (index..<end).map { (sources[$0], known[$0]!) }
                deliver(Self.hits(for: needle, in: run))
                index = end
                continue
            }
            // Not read yet: this one and the ones after it start reading, and
            // this one is waited for.
            next = max(next, index)
            while next < sources.count, next < index + Self.lookahead {
                if known[next] == nil, ahead[next] == nil {
                    ahead[next] = await reader(for: sources[next], priority: nil)
                }
                next += 1
            }
            let text = await ahead.removeValue(forKey: index)?.value
            if let text, let hit = Self.hit(for: needle, in: text, source: sources[index]) {
                deliver([hit])
            }
            index += 1
        }
    }

    /// Reads the papers without searching them, so the first query does not
    /// have to wait for the library.
    ///
    /// A few at a time, taken in the order given, and no further once the
    /// palette that asked has gone: the reads already under way finish and
    /// are kept, and nothing new starts. The next paper starts when any of
    /// the ones being read is done, not when the oldest is — the oldest can
    /// be the book.
    nonisolated func warm(_ sources: [Source]) -> Task<Void, Never> {
        Task {
            await withTaskGroup(of: Void.self) { group in
                var underway = 0
                for source in sources {
                    if Task.isCancelled { break }
                    guard await !self.isResident(source.id) else { continue }
                    let read = await self.reader(for: source, priority: .utility)
                    group.addTask { _ = await read.value }
                    underway += 1
                    if underway >= Self.width {
                        await group.next()
                        underway -= 1
                    }
                }
            }
        }
    }

    /// Some pages of one paper as `PDFPage.string` gives them — for the
    /// echoes, which weigh how rare a word is against the paper being read —
    /// or nil when the file does not have `count` pages or cannot be read
    /// here (a locked file opens for the reader, who has its password, and
    /// not for the index).
    ///
    /// Out of what is kept when there is any. Otherwise just those pages, from
    /// a document of its own: the echoes want forty pages of a book, and
    /// reading all thousand to keep them would have them wait half a minute
    /// for what the reader used to give them in a fifth of a second. Either
    /// way off the main thread, which is where those forty pages used to be
    /// read.
    func sample(_ indices: [Int], of source: Source, expecting count: Int) async -> [String]? {
        if let known = texts[source.id], known.pageCount == count { return indices.map(known.page) }
        if texts[source.id] == nil,
           let kept = await Task.detached(priority: .userInitiated, operation: { Self.kept(source) }).value {
            if !forgotten.contains(source.id), texts[source.id] == nil { texts[source.id] = kept }
            if kept.pageCount == count { return indices.map(kept.page) }
        }
        return await Task.detached(priority: .userInitiated) { () -> [String]? in
            autoreleasepool {
                guard let document = PDFDocument(url: source.url), !document.isLocked,
                      document.pageCount == count else { return nil }
                return indices.map { document.page(at: $0)?.string ?? "" }
            }
        }.value
    }

    /// The whole text of one paper: what is kept, or a read of it — through
    /// the same few readers as a search, so that an index built on top of
    /// this one (the passages by meaning) never reads a PDF of its own.
    func text(for source: Source) async -> PaperText? {
        if let known = texts[source.id] { return known }
        return await reader(for: source, priority: .utility).value
    }

    /// Where a passage sits on its page, so the reader can be sent there.
    ///
    /// The document is opened again rather than kept: this happens once, when
    /// a result is chosen, and holding sixty PDFs open to save it would be a
    /// poor trade.
    func rect(for passage: Passage, at url: URL) -> CGRect? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: passage.pageIndex),
              let selection = page.selection(
                  for: NSRange(location: passage.location, length: passage.length)
              )
        else { return nil }
        let bounds = selection.bounds(for: page)
        return bounds.isEmpty ? nil : bounds
    }

    /// Lets go of a paper that is gone from the library, and of what was
    /// kept of it on disk.
    func forget(_ id: UUID) {
        forgotten.insert(id)
        texts[id] = nil
        let folder = Self.directory
        try? FileManager.default.removeItem(at: folder.appending(path: "\(id.uuidString).text"))
        try? FileManager.default.removeItem(at: folder.appending(path: "\(id.uuidString).json"))
    }

    // MARK: - Finding it in the text

    /// One paper's answer: how many times, and the first of them, pointed
    /// back at the characters of the page it is on.
    static func hit(for needle: String, in text: PaperText, source: Source) -> Hit? {
        guard let match = text.search(needle) else { return nil }
        let original = text.page(match.page)
        // Only as much of the page as it takes to reach the end of the match.
        let map = SearchFolding.map(original, through: match.location + match.length)
        let length = original.utf16.count
        let start = match.location < map.count ? map[match.location] : 0
        let end = match.location + match.length < map.count
            ? map[match.location + match.length] : length
        let range = NSRange(location: start, length: max(end - start, 1))
        return Hit(
            passage: Passage(paperID: source.id, pageIndex: match.page,
                             location: range.location, length: range.length),
            title: source.title,
            snippet: snippet(around: range, in: original as NSString),
            count: match.count
        )
    }

    /// Several papers already read, searched side by side, answered in the
    /// order they were given.
    private static func hits(for needle: String, in run: [(Source, PaperText)]) -> [Hit] {
        guard run.count > 4 else { return run.compactMap { hit(for: needle, in: $1, source: $0) } }
        let lock = NSLock()
        nonisolated(unsafe) var found = [Hit?](repeating: nil, count: run.count)
        DispatchQueue.concurrentPerform(iterations: run.count) { index in
            let hit = hit(for: needle, in: run[index].1, source: run[index].0)
            lock.lock()
            found[index] = hit
            lock.unlock()
        }
        return found.compactMap { $0 }
    }

    /// The words around a match, as they are set on the page.
    static func snippet(around range: NSRange, in text: NSString,
                        room: Int = 64) -> String {
        let start = max(range.location - room, 0)
        let end = min(range.location + range.length + room, text.length)
        var piece = text.substring(with: NSRange(location: start, length: end - start))
        piece = piece.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        // Half a word at either end reads as a typo; a leading ellipsis reads
        // as "this goes on".
        if start > 0, let space = piece.firstIndex(of: " "), piece.count > 12 {
            piece = String(piece[piece.index(after: space)...])
        }
        if end < text.length, let space = piece.lastIndex(of: " "), piece.count > 12 {
            piece = String(piece[..<space])
        }
        return (start > 0 ? "…" : "") + piece + (end < text.length ? "…" : "")
    }

    // MARK: - Reading, a few at a time

    private func resident(_ ids: [UUID]) -> [PaperText?] { ids.map { texts[$0] } }

    private func isResident(_ id: UUID) -> Bool { texts[id] != nil }

    /// The read of one paper: the one under way, or a new one. The work is
    /// done off this actor, which only keeps the books — a read here would be
    /// an actor answering nothing else for a quarter of a second, and what it
    /// would not be answering is the search the reader is typing.
    private func reader(for source: Source, priority: TaskPriority?) -> Task<PaperText?, Never> {
        if let known = texts[source.id] { return Task { known } }
        if let underway = reading[source.id] { return underway }
        let task = Task.detached(priority: priority) { () -> PaperText? in
            await self.acquire()
            let text = Self.read(source)
            await self.finished(source.id, text)
            return text
        }
        reading[source.id] = task
        return task
    }

    private func acquire() async {
        if running < Self.width {
            running += 1
            return
        }
        await withCheckedContinuation { queued.append($0) }
    }

    /// Not remembered when it fails: a paper the cloud has not brought down
    /// yet is a paper that will read fine in a minute.
    private func finished(_ id: UUID, _ text: PaperText?) {
        reading[id] = nil
        if forgotten.contains(id) {
            // Trashed while it was being read: what the read just kept goes
            // too. Once — a paper put back from the Trash is read afresh.
            forget(id)
            forgotten.remove(id)
        } else if let text {
            texts[id] = text
        }
        if queued.isEmpty {
            running -= 1
        } else {
            queued.removeFirst().resume()
        }
    }

    /// The text of one paper: kept on disk if what is kept still describes
    /// the file, read from the PDF otherwise.
    nonisolated static func read(_ source: Source) -> PaperText? {
        autoreleasepool {
            let now = stamp(of: source.url)
            if let kept = kept(source.id, now: now, url: source.url) { return kept }
            // The fingerprint before the pages, not after: a file saved while
            // it is being read then carries the stamp of the bytes from
            // before, which is the stamp that sends it to be read again.
            // Taken after, the stamp would vouch for bytes the text may not
            // have come from.
            let stamp = stamp(now, of: source.url)
            // A document of its own, never the one a reader has open: PDFKit
            // documents are not to be read from two threads at once.
            let started = DispatchTime.now().uptimeNanoseconds
            guard let document = PDFDocument(url: source.url) else { return nil }
            var pages: [String] = []
            pages.reserveCapacity(document.pageCount)
            for index in 0..<document.pageCount {
                pages.append(document.page(at: index)?.string ?? "")
            }
            report?(String(format: "text index: read %d pages of %@ from the PDF in %.0f ms", pages.count,
                           source.url.lastPathComponent,
                           Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6))
            let text = PaperText(pages: pages, stamp: stamp)
            keep(text, for: source.id)
            // Read back from the file just written, which maps it: the pages
            // then live in the file rather than in the app's own memory.
            return reopened(source.id) ?? text
        }
    }

    // MARK: - Keeping it

    private static func stamp(of url: URL) -> (size: Int64, modified: Date) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
    }

    /// The stamp for text read from the file as it is now. Without a
    /// fingerprint — a file that would not give up its first bytes — the
    /// text can only ever be matched by size and date again.
    private static func stamp(_ now: (size: Int64, modified: Date), of url: URL) -> PaperText.Stamp {
        let fingerprint = PaperText.fingerprint(of: url, extent: now.size)
        return PaperText.Stamp(
            size: now.size, modified: now.modified,
            extent: fingerprint == nil ? -1 : now.size,
            head: fingerprint?.head ?? 0, tail: fingerprint?.tail ?? 0
        )
    }

    /// Told what the index does, when the app is tracing: which papers were
    /// read from the PDF and how long that took, and which were kept although
    /// their file had changed. The index knows nothing of the app's trace,
    /// so that it can still be built on its own.
    nonisolated(unsafe) static var report: (@Sendable (String) -> Void)?

    /// Where a probe's run keeps its text instead, set before the first
    /// search. The app is sandboxed per bundle id, so the caches folder of a
    /// probe is the reader's own: a probe that read its papers there would be
    /// adding to theirs, and one that cleared it to time a cold search would
    /// be clearing theirs.
    nonisolated(unsafe) static var probeDirectory: URL?

    private static var directory: URL {
        if let probeDirectory { return probeDirectory }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return base.appending(path: "PaperTime/Text", directoryHint: .isDirectory)
    }

    /// What is kept of a paper, if it still describes the file.
    ///
    /// Still describes it when the file has the size and date it had, as it
    /// always was — or when it has only grown, and its first bytes are the
    /// bytes the text was read from. That is what an incremental save does:
    /// it adds to the end and leaves everything before where it was. Asking
    /// costs two reads of 64 KB, not the file.
    ///
    /// A cache from before the folded text was kept (`<id>.json`) is taken
    /// in once: folded, written the new way, and let go of.
    private static func kept(_ id: UUID, now: (size: Int64, modified: Date), url: URL) -> PaperText? {
        let file = directory.appending(path: "\(id.uuidString).text")
        if let data = try? Data(contentsOf: file, options: .alwaysMapped),
           var text = PaperText(encoded: data) {
            if text.stamp.matches(size: now.size, modified: now.modified) {
                freshen(file)
                return text
            }
            let checking = DispatchTime.now().uptimeNanoseconds
            if text.stamp.extent >= 0, now.size > text.stamp.extent,
               let fingerprint = PaperText.fingerprint(of: url, extent: text.stamp.extent),
               fingerprint.head == text.stamp.head, fingerprint.tail == text.stamp.tail {
                report?(String(format: "text index: %@ grew by %lld bytes and still starts with the bytes"
                               + " it was read from — kept (checked in %.1f ms)",
                               url.lastPathComponent, now.size - text.stamp.size,
                               Double(DispatchTime.now().uptimeNanoseconds - checking) / 1e6))
                text.stamp.size = now.size
                text.stamp.modified = now.modified
                keep(text, for: id)
                return text
            }
            report?("text index: \(url.lastPathComponent) changed — read again")
            return nil
        }
        let old = directory.appending(path: "\(id.uuidString).json")
        guard let data = try? Data(contentsOf: old) else { return nil }
        try? FileManager.default.removeItem(at: old)
        guard let cached = try? JSONDecoder().decode(OldCache.self, from: data),
              cached.size == now.size, abs(cached.modified.timeIntervalSince(now.modified)) < 1
        else { return nil }
        let text = PaperText(pages: cached.pages, stamp: stamp(now, of: url))
        keep(text, for: id)
        return reopened(id) ?? text
    }

    /// What is kept of a paper, if it still describes the file as it is now;
    /// nil rather than a read of the PDF.
    nonisolated static func kept(_ source: Source) -> PaperText? {
        autoreleasepool { kept(source.id, now: stamp(of: source.url), url: source.url) }
    }

    /// The format this cache had before: the pages and nothing else.
    private struct OldCache: Decodable {
        var size: Int64
        var modified: Date
        var pages: [String]
    }

    private static func keep(_ text: PaperText, for id: UUID) {
        let folder = directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.encoded().write(to: folder.appending(path: "\(id.uuidString).text"), options: .atomic)
    }

    private static func reopened(_ id: UUID) -> PaperText? {
        let file = directory.appending(path: "\(id.uuidString).text")
        return (try? Data(contentsOf: file, options: .alwaysMapped)).flatMap(PaperText.init(encoded:))
    }

    // MARK: - Letting go

    /// How long a paper nobody has is kept before it is let go of.
    private static let unclaimedFor: TimeInterval = 30 * 86_400

    /// Marks a kept paper as used, at most once a day, so that the sweep can
    /// tell what is still being read from what was left behind.
    private static func freshen(_ file: URL) {
        let now = Date.now
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate, now.timeIntervalSince(modified) > 86_400 else { return }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path(percentEncoded: false))
    }

    private var swept = false

    /// Lets go of what is kept for papers that are not in the library and
    /// have not been read for a month — once a session, when a search first
    /// warms up, never at launch.
    ///
    /// Not simply "not in the library": a folder that is unplugged is not in
    /// the library either, and reading its papers again when it comes back
    /// would be a quarter of a second each for nothing.
    func sweep(keeping ids: Set<UUID>) {
        guard !swept else { return }
        swept = true
        let folder = Self.directory
        Task.detached(priority: .background) {
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys
            ) else { return }
            let now = Date.now
            var gone = 0
            for file in files where ["text", "json"].contains(file.pathExtension) {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      !ids.contains(id),
                      let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate,
                      now.timeIntervalSince(modified) > Self.unclaimedFor
                else { continue }
                try? FileManager.default.removeItem(at: file)
                gone += 1
            }
            if gone > 0 { print("text index: let go of \(gone) paper(s) nobody has") }
        }
    }
}
