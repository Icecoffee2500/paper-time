import Foundation

/// `state.json` — everything about *reading* a paper, as opposed to citing it.
public struct PaperState: Codable, Hashable, Sendable {
    public static let currentSchema = 1

    public enum ReadingStatus: String, Codable, Hashable, Sendable, CaseIterable {
        case unread, reading, read

        public var symbolName: String {
            switch self {
            case .unread: "circle"
            case .reading: "circle.lefthalf.filled"
            case .read: "checkmark.circle.fill"
            }
        }
    }

    public var schema: Int
    public var readingStatus: ReadingStatus
    public var isFavorite: Bool
    public var rating: Int?
    /// Zero-based page index of the last reading position.
    public var lastPageIndex: Int
    /// Normalized 0...1 vertical offset within that page, so resuming lands in
    /// the same paragraph rather than at the page top.
    public var lastPageOffset: Double
    public var summaryNote: String
    public var lastOpenedAt: Date?
    public var updatedAt: Date
    public var updatedBy: String

    public init(
        schema: Int = PaperState.currentSchema,
        readingStatus: ReadingStatus = .unread,
        isFavorite: Bool = false,
        rating: Int? = nil,
        lastPageIndex: Int = 0,
        lastPageOffset: Double = 0,
        summaryNote: String = "",
        lastOpenedAt: Date? = nil,
        updatedAt: Date = .now,
        updatedBy: String = DeviceIdentity.current
    ) {
        self.schema = schema
        self.readingStatus = readingStatus
        self.isFavorite = isFavorite
        self.rating = rating
        self.lastPageIndex = lastPageIndex
        self.lastPageOffset = lastPageOffset
        self.summaryNote = summaryNote
        self.lastOpenedAt = lastOpenedAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    /// Resolves two versions of this file that were written independently.
    ///
    /// Newest write wins, whole record. An earlier version tried to be clever
    /// — keeping a favourite that either side had set, never letting a paper
    /// move back from Read — and the result was that turning either one *off*
    /// was impossible: the old value was merged back in every time. A merge
    /// rule that can only ever add is not a merge rule, it is a ratchet.
    ///
    /// This runs only when another device genuinely wrote the file while this
    /// one held it; an ordinary save does not go through here.
    public static func resolve(local: PaperState, remote: PaperState) -> PaperState {
        local.updatedAt >= remote.updatedAt ? local : remote
    }
}
