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

    nonisolated init() {}

    fileprivate func set(progress: (done: Int, total: Int)?, ready: Bool, passages: Int) {
        self.progress = progress
        isReady = ready
        passageCount = passages
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

    /// A passage the query is close to, in the palette's units.
    struct Hit: Sendable, Hashable {
        var passage: PaperTextIndex.Passage
        var title: String
        /// The passage's own words, as many as fit a row.
        var snippet: String
        var score: Float
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

    nonisolated let status = SemanticIndexStatus()

    private var store: SemanticVectorStore?
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
                Trace.mark(String(format: "semantic: embedded %d passages in %.0f ms (%.2f ms each) · ",
                                  done, took, done > 0 ? took / Double(done) : 0) + Trace.memory())
                self.store = store
                try? store.write(to: Self.storeURL)
                if Task.isCancelled {
                    await MainActor.run { [status, have = store.count] in
                        status.set(progress: nil, ready: false, passages: have)
                    }
                    return
                }
            } catch {
                Trace.mark("semantic: embedding stopped — \(error)")
                await MainActor.run { [status, have = store.count] in
                    status.set(progress: nil, ready: false, passages: have)
                }
                return
            }
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
        var texts: [UUID: PaperText] = [:]
        for hit in found {
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
                    passage: PaperTextIndex.Passage(paperID: place.paperID, pageIndex: place.pageIndex,
                                                    location: place.location, length: place.length),
                    title: source.title,
                    snippet: String(words.prefix(160)),
                    score: hit.score
                ))
                break
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
        say("semantic: \(sources.count) papers · \(status.passageCount) passages · ready \(status.isReady ? "yes" : "NO")"
            + String(format: " · built in %.0f ms · ", took) + Trace.memory())
        if let query = Boot.setting("PAPERTIME_SEMANTIC_QUERY"), !query.isEmpty {
            let asked = DispatchTime.now().uptimeNanoseconds
            let hits = await SemanticIndex.shared.hits(for: query)
            let answered = Double(DispatchTime.now().uptimeNanoseconds - asked) / 1e6
            say("semantic: “\(query)” → \(hits.count) passages" + String(format: " in %.1f ms", answered))
            for (rank, hit) in hits.enumerated() {
                say(String(format: "semantic:   %d. %.3f  ", rank + 1, hit.score)
                    + "\(hit.title.prefix(50)) · p\(hit.passage.pageIndex + 1)"
                    + " @\(hit.passage.location)+\(hit.passage.length) | \(hit.snippet.prefix(110))")
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
