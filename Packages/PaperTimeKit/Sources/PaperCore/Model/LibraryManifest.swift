import Foundation

/// A user-defined tag. Colors are chosen from the system palette so the
/// library looks native in both appearances.
public struct Tag: Codable, Hashable, Sendable, Identifiable {
    public enum Color: String, Codable, Hashable, Sendable, CaseIterable {
        case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    }

    public var id: UUID
    public var name: String
    public var color: Color

    public init(id: UUID = UUID(), name: String, color: Color = .blue) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// A manual folder of papers. Smart collections carry a `rule` instead of
/// explicit membership.
public struct Collection: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var symbolName: String
    /// Present only for smart collections.
    public var rule: SmartRule?
    public var sortIndex: Int

    public struct SmartRule: Codable, Hashable, Sendable {
        public enum Field: String, Codable, Hashable, Sendable {
            case title, author, year, venue, tag, readingStatus, confidence, dateAdded
        }
        public enum Comparison: String, Codable, Hashable, Sendable {
            case contains, equals, notEquals, greaterThan, lessThan
        }
        public struct Condition: Codable, Hashable, Sendable {
            public var field: Field
            public var comparison: Comparison
            public var value: String

            public init(field: Field, comparison: Comparison, value: String) {
                self.field = field
                self.comparison = comparison
                self.value = value
            }
        }

        public var matchAll: Bool
        public var conditions: [Condition]

        public init(matchAll: Bool = true, conditions: [Condition] = []) {
            self.matchAll = matchAll
            self.conditions = conditions
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        symbolName: String = "folder",
        rule: SmartRule? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.symbolName = symbolName
        self.rule = rule
        self.sortIndex = sortIndex
    }

    public var isSmart: Bool { rule != nil }
}

/// `library.json` — identity and shared vocabulary for one library folder.
public struct LibraryManifest: Codable, Hashable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var libraryID: UUID
    public var displayName: String
    public var createdAt: Date
    public var tags: [Tag]

    public init(
        schema: Int = LibraryManifest.currentSchema,
        libraryID: UUID = UUID(),
        displayName: String = "Paper Time",
        createdAt: Date = .now,
        tags: [Tag] = []
    ) {
        self.schema = schema
        self.libraryID = libraryID
        self.displayName = displayName
        self.createdAt = createdAt
        self.tags = tags
    }
}

/// `collections.json` — kept apart from the manifest because it changes more
/// often and is the file most likely to be edited on two devices at once.
public struct CollectionSet: Codable, Hashable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var collections: [Collection]
    public var updatedAt: Date
    public var updatedBy: String

    public init(
        schema: Int = CollectionSet.currentSchema,
        collections: [Collection] = [],
        updatedAt: Date = .now,
        updatedBy: String = DeviceIdentity.current
    ) {
        self.schema = schema
        self.collections = collections
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }
}
