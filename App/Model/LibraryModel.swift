import Bibliography
import Foundation
import LibraryStore
import MetadataPipeline
import Observation
import PaperCore
import SwiftUI

/// The open library: the papers in it, what is selected, and what is being
/// worked on in the background.
@MainActor
@Observable
public final class LibraryModel {
    public enum SortOrder: String, CaseIterable, Identifiable, Sendable {
        case dateAdded, title, firstAuthor, year, lastOpened
        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .dateAdded: "Date Added"
            case .title: "Title"
            case .firstAuthor: "Author"
            case .year: "Year"
            case .lastOpened: "Last Opened"
            }
        }
    }

    public enum Scope: Hashable, Sendable {
        case all
        case unread
        case favorites
        case needsReview
        case collection(UUID)
        case tag(UUID)
    }

    public let store: LibraryStore
    public let location: LibraryLocation

    public private(set) var papers: [LoadedPaper] = []
    public private(set) var manifest: LibraryManifest
    public private(set) var collections = CollectionSet()
    public private(set) var loadFailures: [String] = []
    public private(set) var isScanning = false

    public var scope: Scope = .all
    public var searchText = ""
    public var sortOrder: SortOrder = .dateAdded
    public var sortAscending = false
    public var selectedPaperID: UUID?

    /// Papers currently being resolved, so rows can show a spinner.
    public private(set) var resolving: Set<UUID> = []
    public private(set) var resolutionQueueDepth = 0
    public private(set) var onDeviceModelMessage: String

    private let resolver: MetadataResolver
    private let onDeviceExtractor = OnDeviceHeaderExtractor()

    public init(store: LibraryStore, location: LibraryLocation, manifest: LibraryManifest) {
        self.store = store
        self.location = location
        self.manifest = manifest
        let network = NetworkService()
        // The on-device model is tried first where it exists and simply reports
        // itself unavailable elsewhere, so the same code path serves every
        // device the user owns.
        self.resolver = MetadataResolver(
            network: network,
            headerExtractor: CompositeHeaderExtractor([
                OnDeviceHeaderExtractor(),
                HeuristicHeaderExtractor(),
            ])
        )
        self.onDeviceModelMessage = OnDeviceHeaderExtractor().availability.message
    }

    // MARK: - Loading

    public func refresh() async {
        isScanning = true
        defer { isScanning = false }

        let result = try? await store.loadAll()
        papers = result?.papers ?? []
        loadFailures = (result?.failures ?? []).map {
            "\($0.0.lastPathComponent): \($0.1.localizedDescription)"
        }
        collections = (try? await store.loadCollections()) ?? CollectionSet()
        manifest = (try? await store.loadManifest()) ?? manifest
    }

    // MARK: - Presentation

    public var visiblePapers: [LoadedPaper] {
        var result = papers.filter { matchesScope($0) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let folded = TextNormalization.foldedTitle(query)
            result = result.filter { paper in
                let haystack = [
                    paper.meta.displayTitle,
                    paper.meta.csl.author.map(\.displayName).joined(separator: " "),
                    paper.meta.csl.containerTitle ?? "",
                    String(paper.meta.csl.year ?? 0),
                    paper.meta.file.originalName,
                ].joined(separator: " ")
                return TextNormalization.foldedTitle(haystack).contains(folded)
            }
        }
        return result.sorted(by: comparator)
    }

    public var reviewCount: Int {
        papers.filter { $0.meta.confidence == .needsReview || $0.meta.confidence == .unparsed }.count
    }

    public var selectedPaper: LoadedPaper? {
        guard let selectedPaperID else { return nil }
        return papers.first { $0.id == selectedPaperID }
    }

    public func tag(for id: UUID) -> Tag? {
        manifest.tags.first { $0.id == id }
    }

    private func matchesScope(_ paper: LoadedPaper) -> Bool {
        switch scope {
        case .all: true
        case .unread: paper.state.readingStatus != .read
        case .favorites: paper.state.isFavorite
        case .needsReview:
            paper.meta.confidence == .needsReview || paper.meta.confidence == .unparsed
        case let .collection(id): matchesCollection(id, paper: paper)
        case let .tag(id): paper.meta.tagIDs.contains(id)
        }
    }

    private func matchesCollection(_ id: UUID, paper: LoadedPaper) -> Bool {
        guard let collection = collections.collections.first(where: { $0.id == id }) else {
            return false
        }
        guard let rule = collection.rule else { return paper.meta.collectionIDs.contains(id) }
        return SmartRuleEvaluator.matches(rule, paper: paper, tags: manifest.tags)
    }

    private func comparator(_ lhs: LoadedPaper, _ rhs: LoadedPaper) -> Bool {
        let ascending = sortAscending
        func order(_ result: Bool) -> Bool { ascending ? result : !result }

        switch sortOrder {
        case .dateAdded:
            return order(lhs.meta.addedAt < rhs.meta.addedAt)
        case .title:
            return order(
                lhs.meta.displayTitle.localizedCaseInsensitiveCompare(rhs.meta.displayTitle)
                    == .orderedAscending
            )
        case .firstAuthor:
            let left = lhs.meta.csl.author.first?.sortingSurname ?? "zzz"
            let right = rhs.meta.csl.author.first?.sortingSurname ?? "zzz"
            return order(left.localizedCaseInsensitiveCompare(right) == .orderedAscending)
        case .year:
            return order((lhs.meta.csl.year ?? 0) < (rhs.meta.csl.year ?? 0))
        case .lastOpened:
            return order(
                (lhs.state.lastOpenedAt ?? .distantPast) < (rhs.state.lastOpenedAt ?? .distantPast)
            )
        }
    }

    // MARK: - Import

    @discardableResult
    public func importDocuments(at urls: [URL]) async -> (added: Int, duplicates: Int) {
        var digests: [String: PaperFolder] = [:]
        for paper in papers where !paper.meta.file.importDigest.isEmpty {
            digests[paper.meta.file.importDigest] = paper.folder
        }

        var added: [LoadedPaper] = []
        var duplicates = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let outcome = try? await store.importDocument(at: url, knownDigests: digests) else {
                continue
            }
            switch outcome {
            case let .imported(paper):
                papers.append(paper)
                added.append(paper)
                digests[paper.meta.file.importDigest] = paper.folder
            case .duplicate:
                duplicates += 1
            }
        }
        for paper in added {
            Task { await resolveMetadata(for: paper.id) }
        }
        return (added.count, duplicates)
    }

    // MARK: - Metadata

    /// Runs the resolution pipeline for one paper and stores the outcome.
    public func resolveMetadata(for paperID: UUID) async {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        let paper = papers[index]
        guard paper.meta.confidence != .manual else { return }
        guard !resolving.contains(paperID) else { return }

        resolving.insert(paperID)
        resolutionQueueDepth += 1
        defer {
            resolving.remove(paperID)
            resolutionQueueDepth = max(0, resolutionQueueDepth - 1)
        }

        let url = paper.documentURL
        guard let signals = DocumentSignalsExtractor.extract(fromFileAt: url) else { return }
        let result = await resolver.resolve(
            signals: signals,
            originalFileName: paper.meta.file.originalName
        )

        var meta = paper.meta
        meta.csl = result.csl
        meta.identifiers = result.identifiers
        meta.confidence = result.confidence
        meta.provenance = result.provenance
        meta.candidates = result.candidates
        meta.bibKey = CitationKey.make(for: result.csl, fallback: meta.file.originalName)
        meta.csl.id = meta.bibKey

        if let saved = try? await store.save(meta: meta, in: paper.folder) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    /// Re-runs resolution for everything that is not yet confirmed.
    public func resolveAllPending() async {
        let pending = papers
            .filter { $0.meta.confidence == .unparsed || $0.meta.confidence == .needsReview }
            .map(\.id)
        for id in pending {
            await resolveMetadata(for: id)
        }
    }

    /// Accepts one of the offered candidates as the record for a paper.
    public func acceptCandidate(_ candidate: MetadataCandidate, for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var meta = paper.meta
        meta.csl = candidate.csl
        meta.identifiers = candidate.identifiers
        meta.confidence = .manual
        meta.provenance = Provenance(
            source: candidate.provenance.source,
            detail: "confirmed by you"
        )
        meta.candidates = []
        meta.bibKey = CitationKey.make(for: candidate.csl, fallback: meta.file.originalName)
        meta.csl.id = meta.bibKey
        if let saved = try? await store.save(meta: meta, in: paper.folder) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    public func update(meta: PaperMeta, for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var edited = meta
        edited.confidence = .manual
        edited.candidates = []
        if let saved = try? await store.save(meta: edited, in: paper.folder) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    public func update(state: PaperState, for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        if let saved = try? await store.save(state: state, in: paper.folder) {
            if let index = papers.firstIndex(where: { $0.id == paperID }) {
                papers[index].state = saved
            }
        }
    }

    public func moveToTrash(_ paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        _ = try? await store.moveToTrash(paper.folder)
        papers.removeAll { $0.id == paperID }
        if selectedPaperID == paperID { selectedPaperID = nil }
    }

    private func applyLocally(meta: PaperMeta, to paperID: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        papers[index].meta = meta
    }

    // MARK: - Tags and collections

    public func addTag(named name: String, color: Tag.Color) async -> Tag {
        let tag = Tag(name: name, color: color)
        manifest.tags.append(tag)
        try? await store.saveManifest(manifest)
        return tag
    }

    public func setTags(_ ids: [UUID], for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var meta = paper.meta
        meta.tagIDs = ids
        if let saved = try? await store.save(meta: meta, in: paper.folder) {
            applyLocally(meta: saved, to: paperID)
        }
    }

    public func addCollection(named name: String, rule: Collection.SmartRule? = nil) async {
        var set = collections
        set.collections.append(
            Collection(name: name, rule: rule, sortIndex: set.collections.count)
        )
        collections = set
        try? await store.saveCollections(set)
    }

    public func setCollections(_ ids: [UUID], for paperID: UUID) async {
        guard let paper = papers.first(where: { $0.id == paperID }) else { return }
        var meta = paper.meta
        meta.collectionIDs = ids
        if let saved = try? await store.save(meta: meta, in: paper.folder) {
            applyLocally(meta: saved, to: paperID)
        }
    }
}

/// Evaluates a smart collection's rule against a paper.
enum SmartRuleEvaluator {
    static func matches(_ rule: Collection.SmartRule, paper: LoadedPaper, tags: [Tag]) -> Bool {
        let results = rule.conditions.map { evaluate($0, paper: paper, tags: tags) }
        guard !results.isEmpty else { return true }
        return rule.matchAll ? results.allSatisfy { $0 } : results.contains(true)
    }

    private static func evaluate(
        _ condition: Collection.SmartRule.Condition,
        paper: LoadedPaper,
        tags: [Tag]
    ) -> Bool {
        let actual: String = switch condition.field {
        case .title: paper.meta.displayTitle
        case .author: paper.meta.csl.author.map(\.displayName).joined(separator: " ")
        case .year: String(paper.meta.csl.year ?? 0)
        case .venue: paper.meta.csl.containerTitle ?? ""
        case .tag: paper.meta.tagIDs
            .compactMap { id in tags.first { $0.id == id }?.name }
            .joined(separator: " ")
        case .readingStatus: paper.state.readingStatus.rawValue
        case .confidence: paper.meta.confidence.rawValue
        case .dateAdded: ISO8601DateFormat.string(from: paper.meta.addedAt)
        }

        switch condition.comparison {
        case .contains:
            return actual.localizedCaseInsensitiveContains(condition.value)
        case .equals:
            return actual.compare(condition.value, options: .caseInsensitive) == .orderedSame
        case .notEquals:
            return actual.compare(condition.value, options: .caseInsensitive) != .orderedSame
        case .greaterThan:
            return (Double(actual) ?? 0) > (Double(condition.value) ?? 0)
        case .lessThan:
            return (Double(actual) ?? 0) < (Double(condition.value) ?? 0)
        }
    }
}

enum ISO8601DateFormat {
    static func string(from date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
