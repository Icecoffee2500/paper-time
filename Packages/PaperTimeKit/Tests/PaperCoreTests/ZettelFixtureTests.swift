import Foundation
import Testing
@testable import PaperCore

/// The slip-box's file format, pinned for the other build.
///
/// `Fixtures/zettel-files.json` is what this code writes and reads, made by
/// `Scripts/zettel-fixtures.swift`, and the Windows and Linux build runs the
/// same file (`Portable/src/test/zettel.ts`). A note is one file both builds
/// write in the same folder, so a change here that this test catches is a
/// change the other build has to make in the same commit — then the fixture is
/// made again.
@Suite("The slip-box's files, as the other build reads them")
struct ZettelFixtureTests {
    struct Fields: Decodable {
        var id: String
        var kind: String
        var title: String
        var body: String
        var paperID: String?
        var created: Double
    }

    struct WriteCase: Decodable {
        var name: String
        var note: Fields
        var text: String
    }

    struct ReadCase: Decodable {
        var name: String
        var text: String
        var fallbackID: String
        var modified: Double
        var note: Fields
    }

    struct DerivedCase: Decodable {
        var name: String
        var title: String
        var body: String
        var tags: [String]
        var links: [String]
        var preview: String
        var previewBody: String
        var displayTitle: String
        var isEmpty: Bool
        var linkMarkdown: String
    }

    struct Fixture: Decodable {
        var write: [WriteCase]
        var read: [ReadCase]
        var derived: [DerivedCase]
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "zettel-files", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "zettel-files", withExtension: "json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url!))
    }()

    static func note(_ fields: Fields) -> Zettel {
        Zettel(
            id: fields.id,
            kind: Zettel.Kind(rawValue: fields.kind) ?? .note,
            title: fields.title,
            body: fields.body,
            paperID: fields.paperID.flatMap(UUID.init(uuidString:)),
            created: Date(timeIntervalSince1970: fields.created)
        )
    }

    @Test("A note is written as the fixture says")
    func writing() {
        for one in Self.fixture.write {
            #expect(ZettelFile.text(of: Self.note(one.note)) == one.text, "\(one.name)")
        }
    }

    @Test("A file is read as the fixture says")
    func reading() {
        for one in Self.fixture.read {
            let read = ZettelFile.note(
                from: one.text, id: one.fallbackID,
                modified: Date(timeIntervalSince1970: one.modified)
            )
            #expect(read.id == one.note.id, "\(one.name)")
            #expect(read.kind.rawValue == one.note.kind, "\(one.name)")
            #expect(read.title == one.note.title, "\(one.name)")
            #expect(read.body == one.note.body, "\(one.name)")
            #expect(read.paperID?.uuidString == one.note.paperID, "\(one.name)")
            #expect(abs(read.created.timeIntervalSince1970 - one.note.created) < 0.000_001, "\(one.name)")
        }
    }

    @Test("What a row and a link say about a note is as the fixture says")
    func deriving() {
        for one in Self.fixture.derived {
            let note = Zettel(id: "202609081530", title: one.title, body: one.body,
                              created: Date(timeIntervalSince1970: 1_757_000_000))
            #expect(note.tags == one.tags, "\(one.name)")
            #expect(note.links == one.links, "\(one.name)")
            #expect(note.preview == one.preview, "\(one.name)")
            #expect(note.previewBody == one.previewBody, "\(one.name)")
            #expect(note.displayTitle == one.displayTitle, "\(one.name)")
            #expect(note.isEmpty == one.isEmpty, "\(one.name)")
            #expect(note.linkMarkdown == one.linkMarkdown, "\(one.name)")
        }
    }
}
