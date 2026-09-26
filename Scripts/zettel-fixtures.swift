// The slip-box's file format as the Mac writes and reads it, for the other
// build to be checked against.
//
// A note is a Markdown file that both builds read and write in the same
// folder, so "the same" has to mean the same bytes: a header written one way
// here and another way there is a whole-file change to every sync client, and
// a note that reads back differently on the other desktop is a different note.
// These cases are run through the Mac's own `ZettelFile` and `Zettel`, and the
// answers go where both test suites read them:
//
//     swiftc -O -parse-as-library \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/Zettel.swift \
//       Packages/PaperTimeKit/Sources/PaperCore/Model/ZettelFile.swift \
//       Scripts/zettel-fixtures.swift -o /tmp/zettel-fixtures
//     /tmp/zettel-fixtures > Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/zettel-files.json
//
// `ZettelFixtureTests` (Swift) says the file still is what this code writes;
// `src/test/zettel.ts` (Portable) says the port writes and reads the same.

import Foundation

@main
enum ZettelFixtures {
    struct NoteFields: Codable {
        var id: String
        var kind: String
        var title: String
        var body: String
        var paperID: String?
        /// Seconds since 1970, as the Mac holds it.
        var created: Double
    }

    struct WriteCase: Codable {
        var name: String
        var note: NoteFields
        var text: String
    }

    struct ReadCase: Codable {
        var name: String
        var text: String
        var fallbackID: String
        var modified: Double
        var note: NoteFields
    }

    struct DerivedCase: Codable {
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

    struct Fixture: Codable {
        var write: [WriteCase]
        var read: [ReadCase]
        var derived: [DerivedCase]
    }

    static func fields(_ note: Zettel) -> NoteFields {
        NoteFields(
            id: note.id,
            kind: note.kind.rawValue,
            title: note.title,
            body: note.body,
            paperID: note.paperID?.uuidString,
            created: note.created.timeIntervalSince1970
        )
    }

    static let paper = UUID(uuidString: "4F3A1C08-0000-4000-8000-000000000001")!

    static func main() throws {
        let written: [(String, Zettel)] = [
            ("the least a note can be",
             Zettel(id: "202609081530", body: "just a thought",
                    created: Date(timeIntervalSince1970: 1_757_000_000))),
            ("a literature note with a tag and a link",
             Zettel(id: "202609081530", title: "OpenVLA turns a VLM into a policy",
                    body: "The action head is detokenised text. #vla\nSee [[202609061204|Discretising actions]].",
                    paperID: paper, created: Date(timeIntervalSince1970: 1_757_000_000))),
            ("a map",
             Zettel(id: "202609081531", kind: .map, title: "VLA",
                    body: "# Models\n- [[202609081530|OpenVLA]]\n",
                    created: Date(timeIntervalSince1970: 1_757_000_060))),
            ("an empty draft with a title",
             Zettel(id: "202609081532", kind: .draft, title: "Related work", body: "",
                    created: Date(timeIntervalSince1970: 1_757_000_120))),
            ("tags, and the things that are not tags",
             Zettel(id: "202609081533",
                    body: "#vla #robot-learning #vla\n#강화학습 and a#b, #a/b, (#paren) #_x #-x ##double # heading #123 #cafe\u{0301}",
                    created: Date(timeIntervalSince1970: 1_757_000_000.999))),
            ("a title with a colon and spaces, a body opening on blank lines",
             Zettel(id: "x-1", title: "  spaced : title  ", body: "\n\nleading blank lines",
                    created: Date(timeIntervalSince1970: 1_757_000_000.5))),
            ("mathematics, a rule and an emoji, at the epoch",
             Zettel(id: "202609081534", title: "수식",
                    body: "$$\n\\frac{a}{b}\n$$\n\n---\n\nafter a rule 😀",
                    paperID: paper, created: Date(timeIntervalSince1970: 0))),
            ("tags after unusual spaces",
             Zettel(id: "202609081535",
                    body: "word\u{00A0}#nbsp\tword\t#tab\u{2028}#ls\u{3000}#ideographic\u{000B}#vt\u{FEFF}#bom",
                    created: Date(timeIntervalSince1970: 1_757_000_180))),
        ]

        var write: [WriteCase] = []
        var read: [ReadCase] = []
        for (name, note) in written {
            let text = ZettelFile.text(of: note)
            write.append(WriteCase(name: name, note: fields(note), text: text))
            let back = ZettelFile.note(from: text, id: "fallback", modified: Date(timeIntervalSince1970: 1_757_100_000))
            read.append(ReadCase(name: "written: " + name, text: text, fallbackID: "fallback",
                                 modified: 1_757_100_000, note: fields(back)))
        }

        let texts: [(String, String, String, Double)] = [
            ("no header at all", "just a thought", "202609081530", 1_757_000_123.25),
            ("a header with no id", "---\ntitle: No id\n---\n\nbody", "fallback-id", 1_757_000_000),
            ("a kind this build does not know", "---\nid: 1\nkind: board\n---\n\nx", "f", 1_757_000_000),
            ("a paper in lower case", "---\nid: 2\npaper: 4f3a1c08-0000-4000-8000-000000000001\n---\n\nlower", "f", 1_757_000_000),
            ("a paper that is not an identifier", "---\nid: 3\npaper: not-a-uuid\n---\n\nbad paper", "f", 1_757_000_000),
            ("a creation time with a fraction", "---\nid: 4\ncreated: 2026-09-08T15:30:00.123Z\n---\n\nfraction", "f", 1_757_000_000),
            ("a creation time with an offset", "---\nid: 5\ncreated: 2026-09-08T15:30:00+09:00\n---\n\noffset", "f", 1_757_000_000),
            ("a creation time nobody can read", "---\nid: 6\ncreated: yesterday\n---\n\nunparseable", "f", 1_757_000_000.75),
            ("keys in capitals, and a line with no colon", "---\nID: 7\nTitle:  Upper Keys  \nnocolon line\n---\n\nkeys", "f", 1_757_000_000),
            ("the fence closes the file", "---\nid: 8\n---", "f", 1_757_000_000),
            ("an empty header", "---\n---\nbody", "f", 1_757_000_000),
            ("a byte order mark first", "\u{FEFF}---\nid: 9\n---\n\nbom", "f", 1_757_000_000),
            ("nothing at all", "", "empty", 1_757_000_000),
            ("Windows line ends", "---\r\nid: 10\r\ntitle: CRLF\r\n---\r\n\r\ncrlf body\r\n", "f", 1_757_000_000),
            ("colons in the value", "---\nid: 11\ntitle: a: b: c\n---\n\ncolons", "f", 1_757_000_000),
            ("no blank line after the fence", "---\nid: 12\n---\nno blank line after fence", "f", 1_757_000_000),
            ("four dashes are not the fence", "---\nid: 13\n----\nmore\n---\n\nafter", "f", 1_757_000_000),
            ("spaces after the fence", "---\nid: 14\ntitle: x\n---   \n\ntrailing spaces after fence", "f", 1_757_000_000),
            ("an indented first line", "---\nid: 15\ncreated: 2026-09-08T15:30:00Z\n---\n\n\n\n  indented first line", "f", 1_757_000_000),
            ("a header that never closes", "---\nid: 16\ntitle: open\n\nbody without a fence", "f", 1_757_000_000),
        ]
        for (name, text, fallback, modified) in texts {
            let note = ZettelFile.note(from: text, id: fallback, modified: Date(timeIntervalSince1970: modified))
            read.append(ReadCase(name: name, text: text, fallbackID: fallback, modified: modified, note: fields(note)))
        }

        let bodies: [(String, String, String)] = [
            ("nothing", "", ""),
            ("a formula and nothing else", "", "$$x^2$$"),
            ("spaces only", "", "   "),
            ("Markdown of every kind", "", "# Heading\n\nSome **bold** text with `code` and a [link](http://x.y) and ![img](a.png)."),
            ("quotes and lists", "", "> quoted line\n- item one\n2. item two\n* star item"),
            ("punctuation left holding hands", "", "a formula, $x$, should read , well ; ok"),
            ("links to notes", "", "See [[202609061204|Discretising actions]] and [[202609071010]]."),
            ("a title of its own", "Title", "Body #tag"),
            ("a long first line", "", "A very long first line that goes on and on beyond sixty characters to test the prefix cut here"),
            ("a long Korean first line", "", "한국어 노트의 첫 줄이 꽤 길어서 육십 글자를 넘어가면 어디서 잘리는지 확인하는 문장입니다 정말로요 그렇죠"),
            ("fenced code", "", "```\ncode block\n```\nafter code"),
            ("emoji as one letter each", "", String(repeating: "family 👩‍👩‍👧‍👦 ", count: 9)),
            ("a title of spaces", "  ", "x"),
            ("runs of spaces and tabs", "", "multiple   spaces\tand\ttabs"),
            ("numbered lists", "", "1. first\n10. tenth\n\u{0661}. arabic-indic digit"),
            ("a formula between words", "", "The loss $\\mathcal{L}$ falls; then $$\\sum_i x_i$$ rises."),
            ("a heading that is only marks", "", "###\n>>>\nreal words"),
        ]
        var derived: [DerivedCase] = []
        for (name, title, body) in bodies {
            let note = Zettel(id: "202609081530", title: title, body: body,
                              created: Date(timeIntervalSince1970: 1_757_000_000))
            derived.append(DerivedCase(
                name: name, title: title, body: body,
                tags: note.tags, links: note.links, preview: note.preview,
                previewBody: note.previewBody, displayTitle: note.displayTitle,
                isEmpty: note.isEmpty, linkMarkdown: note.linkMarkdown
            ))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Fixture(write: write, read: read, derived: derived))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}
