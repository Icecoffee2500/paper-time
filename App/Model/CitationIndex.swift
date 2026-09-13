import Foundation
import LibraryStore
import PDFKit
import PaperCore

/// Which papers in the library cite which others.
///
/// Nothing in a PDF says "this is a reference to that file", so the link has to
/// be found: every paper's text is read once and searched for the other papers'
/// identifiers — a DOI, an arXiv number, or the title itself. That is the one
/// connection in the graph that is about the ideas rather than about the
/// filing, so it is worth the pass over the text.
///
/// The result is kept beside the library and rebuilt only for papers whose file
/// changed, because reading sixty PDFs takes seconds and reading none takes
/// none.
actor CitationIndex {
    struct Cache: Codable {
        var version: Int = 1
        /// Paper → the papers it names, and the fingerprint of the file that
        /// was read to find them.
        var entries: [String: Entry] = [:]

        struct Entry: Codable {
            var digest: String
            var cites: [UUID]
        }
    }

    private let store: LibraryStore
    private var cache = Cache()
    private var isLoaded = false

    init(store: LibraryStore) {
        self.store = store
    }

    /// What each paper cites, reading only the files that have changed.
    ///
    /// `progress` is called on the main actor as papers are read, so a first
    /// build can say what it is doing instead of appearing to hang.
    func citations(
        among papers: [LoadedPaper],
        progress: @Sendable @MainActor (Int, Int) -> Void = { _, _ in }
    ) async -> [UUID: Set<UUID>] {
        await loadCacheIfNeeded()

        let targets = papers.compactMap(Target.init)
        let stale = papers.filter { paper in
            cache.entries[paper.id.uuidString]?.digest != Self.digest(of: paper)
        }

        for (index, paper) in stale.enumerated() {
            await progress(index, stale.count)
            let found = Self.references(in: paper, among: targets)
            cache.entries[paper.id.uuidString] = Cache.Entry(
                digest: Self.digest(of: paper), cites: Array(found)
            )
        }
        // Papers that have left the library take their row with them.
        let living = Set(papers.map(\.id.uuidString))
        cache.entries = cache.entries.filter { living.contains($0.key) }

        if !stale.isEmpty {
            await progress(stale.count, stale.count)
            try? await store.saveSidecar(cache, named: "citations.json")
        }

        var result: [UUID: Set<UUID>] = [:]
        for (key, entry) in cache.entries {
            guard let id = UUID(uuidString: key) else { continue }
            result[id] = Set(entry.cites)
        }
        return result
    }

    private func loadCacheIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true
        if let stored = try? await store.loadSidecar(Cache.self, named: "citations.json"),
           stored.version == 1 {
            cache = stored
        }
    }

    /// What a paper looks like when another paper refers to it.
    private struct Target {
        let id: UUID
        let doi: String?
        let arxiv: String?
        let title: String?

        init?(_ paper: LoadedPaper) {
            id = paper.id
            doi = paper.meta.csl.doi?.lowercased().trimmingCharacters(in: .whitespaces)
            arxiv = paper.meta.identifiers.arxiv?.lowercased()
            let normalized = paper.meta.csl.fullTitle.map(CitationIndex.normalize)
            // A short title matches by accident; a long one does not.
            title = (normalized?.count ?? 0) >= 30 ? normalized : nil
            if doi == nil, arxiv == nil, title == nil { return nil }
        }
    }

    private static func digest(of paper: LoadedPaper) -> String {
        "\(paper.meta.file.byteSize)-\(paper.meta.file.pageCount)"
    }

    /// Reads one paper and returns the papers it names.
    private static func references(in paper: LoadedPaper, among targets: [Target]) -> Set<UUID> {
        guard let document = PDFDocument(url: paper.documentURL),
              let raw = document.string
        else { return [] }
        let text = normalize(raw)
        guard text.count > 200 else { return [] }

        var found: Set<UUID> = []
        for target in targets where target.id != paper.id {
            if let doi = target.doi, !doi.isEmpty, text.contains(doi) {
                found.insert(target.id)
                continue
            }
            if let arxiv = target.arxiv, !arxiv.isEmpty, text.contains("arxiv:\(arxiv)") {
                found.insert(target.id)
                continue
            }
            if let title = target.title, text.contains(title) {
                found.insert(target.id)
            }
        }
        return found
    }

    /// Text as it can be searched: one case, one kind of space, and words that
    /// were broken across a line put back together.
    nonisolated static func normalize(_ text: String) -> String {
        var result = text.lowercased()
        result = result.replacingOccurrences(of: "-\n", with: "")
        result = result.replacingOccurrences(of: "\u{00AD}", with: "")
        result = result.replacingOccurrences(
            of: "[\\s]+", with: " ", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "[\u{2018}\u{2019}\u{201C}\u{201D}]", with: "'", options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespaces)
    }
}
