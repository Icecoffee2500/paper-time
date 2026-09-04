import Foundation

/// `meta.json` — the bibliographic half of a paper folder.
///
/// Split from `PaperState` on purpose: this file changes rarely (only when
/// metadata is resolved or edited), while reading state changes constantly.
/// Two files means two devices rarely write the same bytes at the same time,
/// which is the cheapest possible conflict avoidance in a plain folder.
public struct PaperMeta: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchema = 1

    public var schema: Int
    public var id: UUID
    public var csl: CSLItem
    public var bibKey: String
    public var confidence: MetadataConfidence
    public var identifiers: Identifiers
    public var provenance: Provenance
    /// Alternatives offered in the review sheet. Cleared once confirmed.
    public var candidates: [MetadataCandidate]
    public var file: FileInfo
    public var tagIDs: [UUID]
    public var collectionIDs: [UUID]
    public var addedAt: Date
    public var updatedAt: Date
    public var updatedBy: String

    public struct FileInfo: Codable, Hashable, Sendable {
        /// File name inside the paper folder. Normally `paper.pdf`.
        public var name: String
        public var byteSize: Int64
        public var pageCount: Int
        /// SHA-256 of the file as it was imported.
        ///
        /// Deliberately not refreshed when annotations are written: its only
        /// job is to detect that the same PDF was imported twice.
        public var importDigest: String
        /// The name the file had when the user imported it, for display and
        /// for matching against an existing reference-manager export.
        public var originalName: String

        public init(
            name: String = "paper.pdf",
            byteSize: Int64 = 0,
            pageCount: Int = 0,
            importDigest: String = "",
            originalName: String = ""
        ) {
            self.name = name
            self.byteSize = byteSize
            self.pageCount = pageCount
            self.importDigest = importDigest
            self.originalName = originalName
        }
    }

    public init(
        schema: Int = PaperMeta.currentSchema,
        id: UUID = UUID(),
        csl: CSLItem = CSLItem(),
        bibKey: String = "",
        confidence: MetadataConfidence = .unparsed,
        identifiers: Identifiers = Identifiers(),
        provenance: Provenance = Provenance(source: .heuristic),
        candidates: [MetadataCandidate] = [],
        file: FileInfo = FileInfo(),
        tagIDs: [UUID] = [],
        collectionIDs: [UUID] = [],
        addedAt: Date = .now,
        updatedAt: Date = .now,
        updatedBy: String = DeviceIdentity.current
    ) {
        self.schema = schema
        self.id = id
        self.csl = csl
        self.bibKey = bibKey
        self.confidence = confidence
        self.identifiers = identifiers
        self.provenance = provenance
        self.candidates = candidates
        self.file = file
        self.tagIDs = tagIDs
        self.collectionIDs = collectionIDs
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    /// Title to show in the library when metadata has not been resolved yet.
    public var displayTitle: String {
        if let title = csl.fullTitle, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if !file.originalName.isEmpty {
            return (file.originalName as NSString).deletingPathExtension
        }
        return "Untitled"
    }

    public var displayAuthors: String {
        let names = csl.author.compactMap(\.sortingSurname)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]) et al."
        }
    }

    /// Resolves two versions of the same `meta.json` seen on different devices.
    ///
    /// Rule: a hand-edited record always wins over an automatic one, regardless
    /// of timestamps, because the user's correction is the whole point. Between
    /// records of equal standing, the newer write wins.
    public static func resolve(local: PaperMeta, remote: PaperMeta) -> PaperMeta {
        if local.confidence == .manual, remote.confidence != .manual { return local }
        if remote.confidence == .manual, local.confidence != .manual { return remote }
        if local.confidence.sortRank != remote.confidence.sortRank {
            return local.confidence.sortRank > remote.confidence.sortRank ? local : remote
        }
        var winner = local.updatedAt >= remote.updatedAt ? local : remote
        let loser = local.updatedAt >= remote.updatedAt ? remote : local
        // Tags and collections are additive: losing a tag because another
        // device happened to save later would look like data loss.
        winner.tagIDs = Self.union(winner.tagIDs, loser.tagIDs)
        winner.collectionIDs = Self.union(winner.collectionIDs, loser.collectionIDs)
        return winner
    }

    private static func union(_ first: [UUID], _ second: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return (first + second).filter { seen.insert($0).inserted }
    }
}
