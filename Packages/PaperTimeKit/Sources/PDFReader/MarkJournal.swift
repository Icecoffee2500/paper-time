import Foundation
import InkEngine
import LibraryStore
import PaperCore

/// The marks one device made on one paper, as a small file of its own.
///
/// The PDF is where a mark lives for good, but a PDF is big and rewriting it
/// is slow, and a folder in iCloud carries a 20 MB file at its own pace. The
/// journal is the fast path: a few kilobytes, rewritten whole on every
/// change, named after the device so no two devices ever write the same file.
/// Every device reads all of them and lets the newest word on each mark win;
/// the PDF is then written to agree.
public struct MarkJournal: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// The mark as it should be, or nil for one that was removed.
        public var descriptor: MarkupDescriptor?
        public var at: Date
    }

    public var device: String
    public var name: String
    public var updated: Date
    public var entries: [String: Entry]

    public init(device: String = DeviceIdentity.current, name: String = DeviceIdentity.platformName) {
        self.device = device
        self.name = name
        self.updated = .distantPast
        self.entries = [:]
    }

    public mutating func record(_ descriptor: MarkupDescriptor, at date: Date = .now) {
        entries[descriptor.id.uuidString] = Entry(descriptor: descriptor, at: date)
        updated = date
    }

    public mutating func recordRemoval(of id: UUID, at date: Date = .now) {
        entries[id.uuidString] = Entry(descriptor: nil, at: date)
        updated = date
    }

    /// Every device's journal in a paper's record, keyed by device.
    public static func load(from folder: PaperFolder) -> [String: MarkJournal] {
        let files = (try? FileOperations.visibleContents(of: folder.marksDirectoryURL)) ?? []
        var journals: [String: MarkJournal] = [:]
        for file in files where file.pathExtension == "json" {
            guard let journal = try? FileOperations.decode(MarkJournal.self, at: file) else { continue }
            journals[journal.device] = journal
        }
        return journals
    }

    public func save(to folder: PaperFolder) throws {
        try FileOperations.ensureDirectory(at: folder.marksDirectoryURL)
        try FileOperations.encodeAndWrite(self, to: folder.marksURL(device: device))
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(MarkJournal.self, from: data)
    }

    /// The last word on every mark any device has spoken about.
    public static func merged(_ journals: [String: MarkJournal]) -> [UUID: Entry] {
        var result: [UUID: Entry] = [:]
        for journal in journals.values.sorted(by: { $0.device < $1.device }) {
            for (key, entry) in journal.entries {
                guard let id = UUID(uuidString: key) else { continue }
                if let existing = result[id], existing.at >= entry.at { continue }
                result[id] = entry
            }
        }
        return result
    }
}
