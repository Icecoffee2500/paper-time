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
    /// Set when this document belongs to another one — a supplement, an
    /// appendix, a dataset sheet. It then travels with its parent instead of
    /// standing in the library as a paper of its own.
    public var parentID: UUID?
    public var addedAt: Date
    public var updatedAt: Date
    public var updatedBy: String

    public struct FileInfo: Codable, Hashable, Sendable {
        /// Where the PDF sits, relative to the library folder.
        ///
        /// The PDF keeps its own name in the library rather than being filed
        /// into a folder named after its record, so this is how a record finds
        /// its document. When it stops matching — the file was renamed or moved
        /// outside the app — `importDigest` finds it again.
        public var relativePath: String
        public var byteSize: Int64
        public var pageCount: Int
        /// SHA-256 of the file as it was imported.
        ///
        /// Deliberately not refreshed when annotations are written: its jobs
        /// are spotting the same PDF imported twice, and re-linking a record to
        /// its document after a rename.
        public var importDigest: String
        /// The name the file had when it was imported, for display.
        public var originalName: String

        public init(
            relativePath: String = "",
            byteSize: Int64 = 0,
            pageCount: Int = 0,
            importDigest: String = "",
            originalName: String = ""
        ) {
            self.relativePath = relativePath
            self.byteSize = byteSize
            self.pageCount = pageCount
            self.importDigest = importDigest
            self.originalName = originalName
        }

        /// Libraries written before the flat layout stored `name`, the file
        /// name inside a per-paper folder.
        private enum CodingKeys: String, CodingKey {
            case relativePath, byteSize, pageCount, importDigest, originalName
            case legacyName = "name"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            byteSize = (try? container.decode(Int64.self, forKey: .byteSize)) ?? 0
            pageCount = (try? container.decode(Int.self, forKey: .pageCount)) ?? 0
            importDigest = (try? container.decode(String.self, forKey: .importDigest)) ?? ""
            originalName = (try? container.decode(String.self, forKey: .originalName)) ?? ""
            if let path = try? container.decode(String.self, forKey: .relativePath) {
                relativePath = path
            } else {
                relativePath = (try? container.decode(String.self, forKey: .legacyName)) ?? ""
            }
        }

        /// Written without the legacy key: a library that has been read once
        /// is written back in the current shape.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(relativePath, forKey: .relativePath)
            try container.encode(byteSize, forKey: .byteSize)
            try container.encode(pageCount, forKey: .pageCount)
            try container.encode(importDigest, forKey: .importDigest)
            try container.encode(originalName, forKey: .originalName)
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
        parentID: UUID? = nil,
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
        self.parentID = parentID
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
    /// A hand-edited record beats an automatic one regardless of timestamps,
    /// because the user's correction is the whole point. Otherwise the newer
    /// write wins outright — including when it *removed* a tag. Unioning the
    /// tag lists, as an earlier version did, made removing one impossible.
    ///
    /// Only reached when another device wrote the file concurrently.
    public static func resolve(local: PaperMeta, remote: PaperMeta) -> PaperMeta {
        if local.confidence == .manual, remote.confidence != .manual { return local }
        if remote.confidence == .manual, local.confidence != .manual { return remote }
        if local.confidence.sortRank != remote.confidence.sortRank {
            return local.confidence.sortRank > remote.confidence.sortRank ? local : remote
        }
        return local.updatedAt >= remote.updatedAt ? local : remote
    }
}
