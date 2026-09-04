import Foundation
import PaperCore

/// One `@type{key, ...}` record.
///
/// Fields are held as an ordered array rather than a dictionary so exported
/// files are byte-stable: a `.bib` that lands in a synced folder or a Git
/// repository should only change when its content changes.
public struct BibTeXEntry: Hashable, Sendable {
    public var type: EntryType
    public var key: String
    public var fields: [Field]

    public struct Field: Hashable, Sendable {
        public var name: String
        /// Already LaTeX-escaped and, where needed, brace-protected.
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public enum EntryType: String, Hashable, Sendable, CaseIterable {
        case article
        case inproceedings
        case incollection
        case book
        case inbook
        case phdthesis
        case mastersthesis
        case techreport
        case misc
        case unpublished
        case online

        public static func forCSL(_ type: CSLType, hasContainer: Bool) -> EntryType {
            switch type {
            case .articleJournal: .article
            case .paperConference: .inproceedings
            case .book: .book
            case .chapter: hasContainer ? .incollection : .inbook
            case .thesis: .phdthesis
            case .report: .techreport
            case .manuscript: .misc
            case .webpage: .online
            case .dataset, .software, .patent, .speech, .other: .misc
            }
        }
    }

    public init(type: EntryType, key: String, fields: [Field]) {
        self.type = type
        self.key = key
        self.fields = fields
    }

    public subscript(name: String) -> String? {
        get { fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            let index = fields.firstIndex {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            switch (index, newValue) {
            case let (index?, value?): fields[index].value = value
            case let (index?, nil): fields.remove(at: index)
            case let (nil, value?): fields.append(Field(name: name, value: value))
            case (nil, nil): break
            }
        }
    }
}
