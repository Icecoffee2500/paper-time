#if os(macOS)
import AppKit
import Foundation
import PaperCore
import Semantic

/// What "search by meaning" is doing right now, for the palette's footer and
/// the settings pane. Kept on the main actor so views can read it.
@MainActor
@Observable
final class SemanticIndexStatus {
    /// How far the passages of the library have been embedded, while they
    /// are being embedded. Nil when nothing is under way.
    private(set) var progress: (done: Int, total: Int)?
    /// Whether every passage of the library as it was last looked at has a
    /// vector: the palette shows the section only then. Nothing is shown
    /// while the index is being built — a section with half the library in
    /// it would rank the half that happened to come first.
    private(set) var isReady = false
    /// How many passages have vectors, for the settings pane.
    private(set) var passageCount = 0
    /// How many notes are in the index, and how many passages they cut to.
    private(set) var noteCount = 0
    private(set) var notePassageCount = 0

    nonisolated init() {}

    fileprivate func set(progress: (done: Int, total: Int)?, ready: Bool, passages: Int) {
        self.progress = progress
        isReady = ready
        passageCount = passages
    }

    fileprivate func set(notes: Int, notePassages: Int) {
        noteCount = notes
        notePassageCount = notePassages
    }
}

/// The passages of every paper, as vectors, so the palette can find the one
/// that says what was typed without saying it in those words.
///
/// Built on the text index, never on the PDFs: `PaperTextIndex` has read and
/// kept every page already, and this cuts those pages into passages
/// (`SemanticChunker`) and embeds the ones whose text has no vector yet
/// (`SemanticVectorStore`, keyed by the passage's text). Two embedders, as
/// the package recommends: the GPU one for the bulk, let go of when the
/// library is done, and a CPU one that answers a query in about a
/// millisecond and never waits behind a batch.
///
/// Where it is kept: beside the S1 text cache, under the app's caches folder
/// (`…/PaperTime/Semantic`), and for a probe beside its own text cache — never
/// in the library folder, which is synced and belongs to the person. One
/// store for every folder rather than one a folder: papers are keyed by their
/// UUID and passages by their text, so nothing about a folder's identity
/// would be in the key, and a paper that sits in two folders costs one vector
/// a passage. The manifest of a paper (`passages/<id>.json`) records the
/// stamp of the text it was cut from; a paper whose text changed is cut
/// again, and only the passages that actually changed are embedded again.
/// Passages of papers that have left the library keep their vectors for a
/// month, as the text cache keeps their text, so an unplugged folder costs
/// nothing when it comes back.
actor SemanticIndex {
    static let shared = SemanticIndex()

    /// A passage the query is close to, in the palette's units: on a page
    /// of a paper, or in a note.
    struct Hit: Sendable, Hashable {
        enum Origin: Sendable, Hashable {
            case paper(PaperTextIndex.Passage)
            case note(NotePassage)
        }
        var origin: Origin
        /// The paper's title, or the note's (its first line when it has none).
        var title: String
        /// The passage's own words, as many as fit a row.
        var snippet: String
        var score: Float

        var passage: PaperTextIndex.Passage? {
            if case let .paper(passage) = origin { passage } else { nil }
        }
        var note: NotePassage? {
            if case let .note(place) = origin { place } else { nil }
        }
    }

    /// A note as the index takes it: what it is called, which paper it is
    /// about, and its words as written. Snapshotted on the main actor, cut
    /// and embedded off it.
    struct NoteSource: Sendable, Hashable {
        var id: String
        var paperID: UUID?
        var title: String
        /// The note's Markdown. The title is not in it; the passages are cut
        /// from the body, which is what the person wrote.
        var markdown: String
    }

    /// Where a passage sits: what the store's key is looked up into.
    private struct Place: Hashable {
        var paperID: UUID
        var pageIndex: Int
        var location: Int
        var length: Int
    }

    /// One paper's passages, as they were cut from the text with this stamp.
    private struct Manifest: Codable {
        struct Cut: Codable {
            var p: Int
            var l: Int
            var n: Int
            var h: UInt64
            var w: UInt64
        }
        var size: Int64
        var modified: Date
        var extent: Int64
        var head: UInt64
        var tail: UInt64
        var cuts: [Cut]

        init(stamp: PaperText.Stamp, chunks: [SemanticChunk]) {
            size = stamp.size
            modified = stamp.modified
            extent = stamp.extent
            head = stamp.head
            tail = stamp.tail
            cuts = chunks.map { Cut(p: $0.pageIndex, l: $0.location, n: $0.length, h: $0.key.high, w: $0.key.low) }
        }

        func describes(_ stamp: PaperText.Stamp) -> Bool {
            size == stamp.size && abs(modified.timeIntervalSince(stamp.modified)) < 1
                && extent == stamp.extent && head == stamp.head && tail == stamp.tail
        }
    }

    /// One note's passages, as they were cut from these words: the words'
    /// hash stands where a paper's file stamp stands, since a note has no
    /// file of its own that this can see change.
    private struct NoteManifest: Codable {
        struct Cut: Codable {
            var l: Int
            var n: Int
            var h: UInt64
            var w: UInt64
        }
        var high: UInt64
        var low: UInt64
        var paper: UUID?
        var cuts: [Cut]

        init(stamp: ChunkKey, paperID: UUID?, windows: [SemanticChunker.Window]) {
            high = stamp.high
            low = stamp.low
            paper = paperID
            cuts = windows.map { Cut(l: $0.location, n: $0.length, h: $0.key.high, w: $0.key.low) }
        }

        func describes(_ stamp: ChunkKey, paperID: UUID?) -> Bool {
            high == stamp.high && low == stamp.low && paper == paperID
        }
    }

    /// Where a note's passage sits.
    private struct NotePlace: Hashable {
        var noteID: String
        var location: Int
        var length: Int
    }

    nonisolated let status = SemanticIndexStatus()

    private var store: SemanticVectorStore?
    /// Which notes are in the index and what they say, by key.
    private var notePlaces: [ChunkKey: [NotePlace]] = [:]
    private var noteManifests: [String: NoteManifest] = [:]
    /// The notes as last snapshotted, with their words made plain — what a
    /// hit's snippet is read from.
    private var noteTexts: [String: (source: NoteSource, plain: String)] = [:]
    /// Where the notes come from, asked on the main actor at build time so
    /// a build sees the notes as they are then, not as they were when it
    /// was scheduled. Set once, when the library opens.
    private var notesProvider: (@MainActor @Sendable () -> [NoteSource])?

    func setNotesProvider(_ provider: @escaping @MainActor @Sendable () -> [NoteSource]) {
        notesProvider = provider
    }
    /// Which papers are in the index and what they say, by key.
    private var places: [ChunkKey: [Place]] = [:]
    private var manifests: [UUID: Manifest] = [:]
    private var sources: [UUID: PaperTextIndex.Source] = [:]
    private var queryEmbedder: SemanticEmbedder?
    private var building: Task<Void, Never>?
    private var ready = false
    private var swept = false

    /// How many passages between two writes of the store to disk: a build
    /// that is quit halfway keeps what it had done.
    private static let flushEvery = 512
    /// A month, like the text cache.
    private static let unclaimedFor: TimeInterval = 30 * 86_400

    // MARK: - Where

    /// Next to the text cache, whichever the text cache is using.
    private static var directory: URL {
        if let probe = PaperTextIndex.probeDirectory {
            return probe.deletingLastPathComponent()
                .appending(path: probe.lastPathComponent + "-semantic", directoryHint: .isDirectory)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return base.appending(path: "PaperTime/Semantic", directoryHint: .isDirectory)
    }

    private static var storeURL: URL { directory.appending(path: "vectors.ptsv") }
    private static var manifestFolder: URL { directory.appending(path: "passages", directoryHint: .isDirectory) }
    private static func manifestURL(_ id: UUID) -> URL { manifestFolder.appending(path: "\(id.uuidString).json") }
    private static var noteManifestFolder: URL { directory.appending(path: "notes", directoryHint: .isDirectory) }
    private static func noteManifestURL(_ id: String) -> URL { noteManifestFolder.appending(path: "\(id).json") }

    /// Whether the person wants it at all. Read from the defaults so the
    /// index needs nothing from the view layer.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettings.searchByMeaningKey) as? Bool ?? true
    }

    // MARK: - Building

    /// Brings the index up to date with these papers, in the background,
    /// once the app has had a moment to settle. Asked when the library
    /// opens and whenever the palette opens; a call while a build is under
    /// way replaces it, so a library that changed during one is finished
    /// against what it has now.
    nonisolated func schedule(_ sources: [PaperTextIndex.Source], after delay: Duration = .seconds(5)) {
        Task { await self.begin(sources, after: delay) }
    }

    /// The same, waited for — for a probe that wants the counts.
    func build(_ sources: [PaperTextIndex.Source]) async {
        await begin(sources, after: .zero)
        await building?.value
    }

    func stop() {
        building?.cancel()
        building = nil
        ready = false
        Task { @MainActor [status] in status.set(progress: nil, ready: false, passages: 0) }
    }

    private func begin(_ sources: [PaperTextIndex.Source], after delay: Duration) {
        guard Self.isEnabled else { return }
        building?.cancel()
        let previous = building
        building = Task(priority: .utility) { [self] in
            _ = await previous?.value
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self.run(sources)
        }
    }

    /// The notes again, a few seconds after one was edited: the papers are
    /// as they were, so only the notes are looked at. A note being typed
    /// into asks for this on every pause in typing, and each call replaces
    /// the one waiting — the note is cut once, when the typing has settled.
    /// Nothing until the papers are in: the first build takes the notes
    /// with it.
    nonisolated func scheduleNotes(after delay: Duration = .seconds(5)) {
        Task { await self.beginNotes(after: delay) }
    }

    /// The same, waited for — for a probe that edits a note and asks.
    func refreshNotes() async {
        beginNotes(after: .zero)
        await notesBuilding?.value
    }

    private var notesBuilding: Task<Void, Never>?

    private func beginNotes(after delay: Duration) {
        guard Self.isEnabled, ready else { return }
        notesBuilding?.cancel()
        let previous = building
        let waited = notesBuilding
        notesBuilding = Task(priority: .utility) { [self] in
            _ = await previous?.value
            _ = await waited?.value
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self.runNotes()
        }
    }

    private func runNotes() async {
        guard ready, var store else { return }
        let pending = await cutNotes(into: store)
        self.store = store
        guard !Task.isCancelled else { return }
        if !pending.isEmpty {
            guard await embed(pending, into: &store, saying: "note passages") else { return }
            self.store = store
        }
        await MainActor.run { [status, have = store.count] in
            status.set(progress: nil, ready: true, passages: have)
        }
    }

    private func run(_ wanted: [PaperTextIndex.Source]) async {
        let started = DispatchTime.now().uptimeNanoseconds
        func since() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 }
        loadIfNeeded()
        guard var store else { return }
        sources = Dictionary(wanted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Which passages the library has, cut afresh where the text changed.
        var pending: [SemanticChunk] = []
        var kept = 0
        var recut = 0
        var unread = 0
        for source in wanted {
            guard !Task.isCancelled else { return }
            guard let text = await PaperTextIndex.shared.text(for: source) else {
                unread += 1
                continue
            }
            if let manifest = manifests[source.id], manifest.describes(text.stamp) {
                kept += 1
                for cut in manifest.cuts where !store.contains(ChunkKey(high: cut.h, low: cut.w)) {
                    let page = text.page(cut.p) as NSString
                    guard cut.l + cut.n <= page.length else { continue }
                    let words = page.substring(with: NSRange(location: cut.l, length: cut.n))
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    pending.append(SemanticChunk(paperID: source.id, pageIndex: cut.p, location: cut.l,
                                                 length: cut.n, text: words, key: ChunkKey(text: words)))
                }
                continue
            }
            recut += 1
            var chunks: [SemanticChunk] = []
            for page in 0..<text.pageCount {
                chunks += SemanticChunker.chunks(ofPage: text.page(page), paperID: source.id, pageIndex: page)
            }
            let manifest = Manifest(stamp: text.stamp, chunks: chunks)
            manifests[source.id] = manifest
            Self.write(manifest, for: source.id)
            place(manifest, of: source.id)
            pending += chunks.filter { !store.contains($0.key) }
        }
        var seen = Set<ChunkKey>()
        pending = pending.filter { seen.insert($0.key).inserted }
        Trace.mark(String(format: "semantic: %d papers — %d kept, %d cut, %d unread · %d passages to embed · %.0f ms",
                          wanted.count, kept, recut, unread, pending.count, since()))
        guard !Task.isCancelled else { return }

        // The vectors that are missing, on the GPU, written down every so
        // often so that a quit halfway keeps what it had.
        if !pending.isEmpty {
            guard await embed(pending, into: &store, saying: "passages") else { return }
        }

        // Then the notes, which are small and come after the papers: the
        // person's own words on a paper, beside the paper's.
        let notes = await cutNotes(into: store)
        guard !Task.isCancelled else { return }
        if !notes.isEmpty {
            guard await embed(notes, into: &store, saying: "note passages") else { return }
        }

        // Once a session, what nobody has had for a month goes.
        sweep(keeping: Set(wanted.map(\.id)), store: &store)
        self.store = store
        ready = true
        await MainActor.run { [status, have = store.count] in
            status.set(progress: nil, ready: true, passages: have)
        }
        Trace.mark(String(format: "semantic: ready — %d passages · %.0f ms", store.count, since()))
    }

    /// Embeds these passages into the store, on the GPU, telling the status
    /// as it goes and writing the store down every so often. False when it
    /// was cancelled or failed — the caller has nothing more to do then.
    private func embed(_ pending: [SemanticChunk], into store: inout SemanticVectorStore, saying what: String) async -> Bool {
        await MainActor.run { [status, count = pending.count, have = store.count] in
            status.set(progress: (0, count), ready: false, passages: have)
        }
        do {
            let embedder = try await Trace.time("semantic: load the GPU model") {
                try await SemanticEmbedder.load(computeUnits: .cpuAndGPU)
            }
            var done = 0
            var sinceFlush = 0
            let embedding = DispatchTime.now().uptimeNanoseconds
            for try await vector in embedder.embed(chunks: pending, batchSize: 16) {
                store.insert(vector.vector, for: vector.key)
                done += 1
                sinceFlush += 1
                if sinceFlush >= Self.flushEvery {
                    sinceFlush = 0
                    self.store = store
                    try? store.write(to: Self.storeURL)
                    await MainActor.run { [status, count = pending.count, have = store.count] in
                        status.set(progress: (done, count), ready: false, passages: have)
                    }
                }
                if Task.isCancelled { break }
            }
            let took = Double(DispatchTime.now().uptimeNanoseconds - embedding) / 1e6
            Trace.mark(String(format: "semantic: embedded %d \(what) in %.0f ms (%.2f ms each) · ",
                              done, took, done > 0 ? took / Double(done) : 0) + Trace.memory())
            self.store = store
            try? store.write(to: Self.storeURL)
            if Task.isCancelled {
                await MainActor.run { [status, have = store.count] in
                    status.set(progress: nil, ready: false, passages: have)
                }
                return false
            }
            return true
        } catch {
            Trace.mark("semantic: embedding stopped — \(error)")
            await MainActor.run { [status, have = store.count] in
                status.set(progress: nil, ready: false, passages: have)
            }
            return false
        }
    }

    // MARK: - Notes

    /// Cuts the notes as they are now — afresh where the words changed,
    /// not at all where they did not — forgets the notes that are gone, and
    /// returns the passages the store has no vector for.
    private func cutNotes(into store: SemanticVectorStore) async -> [SemanticChunk] {
        guard let notesProvider else { return [] }
        let started = DispatchTime.now().uptimeNanoseconds
        let notes = await MainActor.run { notesProvider() }
        var pending: [SemanticChunk] = []
        var kept = 0
        var recut = 0
        var passages = 0
        var current = Set<String>()
        for note in notes {
            guard !Task.isCancelled else { return [] }
            let plain = NoteText.plain(note.markdown)
            let windows = SemanticChunker.windows(of: plain)
            guard !windows.isEmpty else { continue }
            current.insert(note.id)
            noteTexts[note.id] = (note, plain)
            passages += windows.count
            let stamp = ChunkKey(text: note.title + "\n" + note.markdown)
            if let manifest = noteManifests[note.id], manifest.describes(stamp, paperID: note.paperID),
               manifest.cuts.count == windows.count {
                kept += 1
            } else {
                recut += 1
                let manifest = NoteManifest(stamp: stamp, paperID: note.paperID, windows: windows)
                noteManifests[note.id] = manifest
                Self.write(manifest, for: note.id)
                place(manifest, of: note.id)
            }
            for window in windows where !store.contains(window.key) {
                pending.append(SemanticChunk(paperID: Self.noteID, pageIndex: 0, location: window.location,
                                             length: window.length, text: window.text, key: window.key))
            }
        }
        // A note that is gone is gone: nothing is waiting for it to come
        // back, and its manifest names a file nobody has.
        var gone = 0
        for id in noteManifests.keys where !current.contains(id) {
            forget(note: id)
            gone += 1
        }
        var seen = Set<ChunkKey>()
        pending = pending.filter { seen.insert($0.key).inserted }
        await MainActor.run { [status] in status.set(notes: current.count, notePassages: passages) }
        Trace.mark(String(format: "semantic: %d notes — %d kept, %d cut, %d gone · %d passages, %d to embed · %.0f ms",
                          notes.count, kept, recut, gone, passages, pending.count,
                          Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6))
        return pending
    }

    /// What a note's passage says it belongs to, for the embedder, which
    /// reads only the words and the key.
    private static let noteID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private func place(_ manifest: NoteManifest, of id: String) {
        for (key, list) in notePlaces {
            let kept = list.filter { $0.noteID != id }
            if kept.count != list.count { notePlaces[key] = kept.isEmpty ? nil : kept }
        }
        for cut in manifest.cuts {
            notePlaces[ChunkKey(high: cut.h, low: cut.w), default: []]
                .append(NotePlace(noteID: id, location: cut.l, length: cut.n))
        }
    }

    private func forget(note id: String) {
        guard let manifest = noteManifests.removeValue(forKey: id) else { return }
        noteTexts[id] = nil
        try? FileManager.default.removeItem(at: Self.noteManifestURL(id))
        for cut in manifest.cuts {
            let key = ChunkKey(high: cut.h, low: cut.w)
            notePlaces[key] = notePlaces[key]?.filter { $0.noteID != id }
            if notePlaces[key]?.isEmpty == true { notePlaces[key] = nil }
        }
    }

    private static func write(_ manifest: NoteManifest, for id: String) {
        try? FileManager.default.createDirectory(at: noteManifestFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: noteManifestURL(id), options: .atomic)
        }
    }

    private func loadIfNeeded() {
        guard store == nil else { return }
        store = Trace.time("semantic: load the store") { SemanticVectorStore.load(from: Self.storeURL) }
        let folder = Self.manifestFolder
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      let data = try? Data(contentsOf: file),
                      let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
                else { continue }
                manifests[id] = manifest
                place(manifest, of: id)
            }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.noteManifestFolder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                guard let data = try? Data(contentsOf: file),
                      let manifest = try? JSONDecoder().decode(NoteManifest.self, from: data)
                else { continue }
                noteManifests[id] = manifest
                place(manifest, of: id)
            }
        }
    }

    private func place(_ manifest: Manifest, of id: UUID) {
        for (key, list) in places {
            let kept = list.filter { $0.paperID != id }
            if kept.count != list.count { places[key] = kept.isEmpty ? nil : kept }
        }
        for cut in manifest.cuts {
            places[ChunkKey(high: cut.h, low: cut.w), default: []]
                .append(Place(paperID: id, pageIndex: cut.p, location: cut.l, length: cut.n))
        }
    }

    private static func write(_ manifest: Manifest, for id: UUID) {
        try? FileManager.default.createDirectory(at: manifestFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL(id), options: .atomic)
        }
    }

    /// Lets go of the manifests, and with them the vectors, of papers that
    /// are not in the library and have not been for a month. A paper still
    /// in the library keeps its manifest fresh by being touched here.
    private func sweep(keeping ids: Set<UUID>, store: inout SemanticVectorStore) {
        guard !swept else { return }
        swept = true
        let now = Date.now
        var keep = Set<ChunkKey>()
        var gone = 0
        for (id, manifest) in manifests {
            let file = Self.manifestURL(id)
            if ids.contains(id) {
                if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   now.timeIntervalSince(modified) > 86_400 {
                    try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path(percentEncoded: false))
                }
            } else if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) > Self.unclaimedFor {
                try? FileManager.default.removeItem(at: file)
                manifests[id] = nil
                for cut in manifest.cuts {
                    let key = ChunkKey(high: cut.h, low: cut.w)
                    places[key] = places[key]?.filter { $0.paperID != id }
                    if places[key]?.isEmpty == true { places[key] = nil }
                }
                gone += 1
                continue
            }
            for cut in manifest.cuts { keep.insert(ChunkKey(high: cut.h, low: cut.w)) }
        }
        for manifest in noteManifests.values {
            for cut in manifest.cuts { keep.insert(ChunkKey(high: cut.h, low: cut.w)) }
        }
        let before = store.count
        store.retain(keep)
        if gone > 0 || store.count != before {
            Trace.mark("semantic: let go of \(gone) paper(s) and \(before - store.count) vector(s) nobody has")
            try? store.write(to: Self.storeURL)
        }
    }

    // MARK: - Asking

    /// Whether the section can be shown: the library is embedded and the
    /// person has not turned it off.
    var isReady: Bool { ready && Self.isEnabled }

    /// The passages closest in meaning to `query`, best first, at most `k`,
    /// and no more than three of one paper — eight rows from one paper is
    /// one answer, not eight.
    func hits(for query: String, k: Int = 8) async -> [Hit] {
        guard isReady, let store, store.count > 0 else { return [] }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 2 else { return [] }
        if queryEmbedder == nil {
            queryEmbedder = try? await Trace.time("semantic: load the CPU model") {
                try await SemanticEmbedder.load(computeUnits: .cpuOnly)
            }
        }
        guard let embedder = queryEmbedder else { return [] }
        let embedded: [Float]? = try? await Trace.time("semantic: embed the query", {
            try await embedder.embed(query: text)
        })
        guard let vector = embedded else { return [] }
        let found = Trace.time("semantic: search \(store.count) passages") { store.search(vector, k: k * 4) }
        var hits: [Hit] = []
        var perPaper: [UUID: Int] = [:]
        var perNote: [String: Int] = [:]
        var texts: [UUID: PaperText] = [:]
        for hit in found {
            var taken = false
            for place in places[hit.key] ?? [] {
                guard let source = sources[place.paperID], perPaper[place.paperID, default: 0] < 3 else { continue }
                if texts[place.paperID] == nil {
                    texts[place.paperID] = await PaperTextIndex.shared.text(for: source)
                }
                guard let paperText = texts[place.paperID] else { continue }
                let page = paperText.page(place.pageIndex) as NSString
                guard place.location + place.length <= page.length else { continue }
                let words = page.substring(with: NSRange(location: place.location, length: place.length))
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                perPaper[place.paperID, default: 0] += 1
                hits.append(Hit(
                    origin: .paper(PaperTextIndex.Passage(paperID: place.paperID, pageIndex: place.pageIndex,
                                                          location: place.location, length: place.length)),
                    title: source.title,
                    snippet: String(words.prefix(160)),
                    score: hit.score
                ))
                taken = true
                break
            }
            // A note that quotes a passage of its paper has the passage's
            // key: the paper's row is the one shown, and the note is one
            // more place the same words are. Two rows a note at most — a
            // note is short, and its second passage is half its first.
            if !taken {
                for place in notePlaces[hit.key] ?? [] {
                    guard let (source, plain) = noteTexts[place.noteID], perNote[place.noteID, default: 0] < 2 else { continue }
                    let text = plain as NSString
                    guard place.location + place.length <= text.length else { continue }
                    let words = text.substring(with: NSRange(location: place.location, length: place.length))
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    perNote[place.noteID, default: 0] += 1
                    hits.append(Hit(
                        origin: .note(NotePassage(noteID: place.noteID, paperID: source.paperID,
                                                  location: place.location, length: place.length)),
                        title: source.title,
                        snippet: String(words.prefix(160)),
                        score: hit.score
                    ))
                    break
                }
            }
            if hits.count >= k { break }
        }
        return hits
    }
}

extension LibraryModel {
    /// The papers whose passages are embedded: every top-level paper, the
    /// one opened last first, so a library that is still being embedded has
    /// the papers being read in it first.
    @MainActor
    var semanticSources: [PaperTextIndex.Source] {
        papers
            .filter { $0.meta.parentID == nil }
            .sorted {
                let lhs = $0.state.lastOpenedAt ?? .distantPast
                let rhs = $1.state.lastOpenedAt ?? .distantPast
                return lhs != rhs ? lhs > rhs : $0.id.uuidString < $1.id.uuidString
            }
            .map { PaperTextIndex.Source(id: $0.id, url: $0.documentURL, title: $0.meta.displayTitle) }
    }
}

extension NotesModel {
    /// The notes as the index takes them: every note with words in it.
    @MainActor
    var semanticSources: [SemanticIndex.NoteSource] {
        notes.compactMap { note in
            guard !note.isEmpty else { return nil }
            return SemanticIndex.NoteSource(id: note.id, paperID: note.paperID,
                                            title: note.displayTitle, markdown: note.body)
        }
    }
}

/// The index, built and asked without a window:
///
///     Scripts/probe.sh -s 90 -- --papertime-library=<probe library> \
///         --papertime-semantic-index=1 --papertime-semantic-query="why do models forget"
///
/// Says how many papers and passages there are and how long the build took,
/// then the top passages for the query with their scores. Quits when done
/// unless the palette was asked for too (`PAPERTIME_SHOW_SEARCH`), in which
/// case the window stays for its picture.
@MainActor
enum SemanticIndexProbe {
    static func run(in model: LibraryModel) async {
        func say(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        let sources = model.semanticSources
        let started = DispatchTime.now().uptimeNanoseconds
        await SemanticIndex.shared.build(sources)
        let took = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let status = SemanticIndex.shared.status
        say("semantic: \(sources.count) papers · \(status.passageCount) passages · \(status.noteCount) notes in \(status.notePassageCount) passages"
            + " · ready \(status.isReady ? "yes" : "NO")" + String(format: " · built in %.0f ms · ", took) + Trace.memory())
        if let query = Boot.setting("PAPERTIME_SEMANTIC_QUERY"), !query.isEmpty {
            let asked = DispatchTime.now().uptimeNanoseconds
            let hits = await SemanticIndex.shared.hits(for: query)
            let answered = Double(DispatchTime.now().uptimeNanoseconds - asked) / 1e6
            let fromNotes = hits.filter { $0.note != nil }.count
            say("semantic: “\(query)” → \(hits.count) passages (\(fromNotes) from notes)" + String(format: " in %.1f ms", answered))
            for (rank, hit) in hits.enumerated() {
                let place: String
                switch hit.origin {
                case let .paper(passage):
                    place = "\(hit.title.prefix(50)) · p\(passage.pageIndex + 1) @\(passage.location)+\(passage.length)"
                case let .note(note):
                    place = "NOTE \(note.noteID) “\(hit.title.prefix(40))” @\(note.location)+\(note.length)"
                }
                say(String(format: "semantic:   %d. %.3f  ", rank + 1, hit.score) + place + " | \(hit.snippet.prefix(110))")
            }
            // The second question is what a keystroke costs: the model is
            // loaded and the store is warm.
            let again = DispatchTime.now().uptimeNanoseconds
            _ = await SemanticIndex.shared.hits(for: query)
            say(String(format: "semantic: asked again in %.1f ms", Double(DispatchTime.now().uptimeNanoseconds - again) / 1e6))
        }
        if !Boot.isSet("PAPERTIME_SHOW_SEARCH") {
            Trace.summary()
            NSApp.terminate(nil)
        }
    }
}
#endif
