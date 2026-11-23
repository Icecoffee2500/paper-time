#if os(macOS)
import Foundation

/// The answers Portable's `shared/noteFormat.ts` is held to.
///
/// `--papertime-format-fixture=<cases.json> --papertime-format-fixture-out=<file>`
/// (both inside the container) runs every case through `NoteFormat` as it
/// is and writes the cases back with what it answered
/// (`Scripts/note-format-fixture.sh`). The format's functions read a note
/// through `NoteMarkdown`, which is the app's, so they are asked here and
/// not in a script of their own.
enum NoteFormatFixture {
    struct Case: Codable {
        var source: String
        var from: Int
        var to: Int
        /// color, size, family, highlight, bold, italic, underline, strike,
        /// para, list, align, picture, tidy or state.
        var op: String
        var value: String?
        var edit: Answer?
        var tidied: String?
        var state: State?
    }

    struct Answer: Codable {
        var from: Int
        var to: Int
        var insert: String
        var selectFrom: Int
        var selectTo: Int
    }

    struct State: Codable {
        var css: String
        var paragraph: String
        var list: String
        var alignment: String
        var size: Double
        var ownSize: Double
    }

    static func write(from path: String, to out: String) {
        guard let data = FileManager.default.contents(atPath: path),
              var cases = try? JSONDecoder().decode([Case].self, from: data) else {
            print("format fixture: cannot read \(path)")
            return
        }
        for index in cases.indices {
            let one = cases[index]
            let selection = NSRange(location: one.from, length: one.to - one.from)
            let value = one.value ?? ""
            let on = value == "1"
            var edit: NoteFormat.Edit?
            switch one.op {
            case "color": edit = NoteFormat.set(.color(value.isEmpty ? nil : value), in: one.source, selection: selection)
            case "size": edit = NoteFormat.set(.size(Double(value)), in: one.source, selection: selection)
            case "family": edit = NoteFormat.set(.family(value.isEmpty ? nil : value), in: one.source, selection: selection)
            case "highlight": edit = NoteFormat.set(.highlight(value.isEmpty ? nil : value), in: one.source, selection: selection)
            case "bold": edit = NoteFormat.set(.bold(on), in: one.source, selection: selection)
            case "italic": edit = NoteFormat.set(.italic(on), in: one.source, selection: selection)
            case "underline": edit = NoteFormat.set(.underline(on), in: one.source, selection: selection)
            case "strike": edit = NoteFormat.set(.strike(on), in: one.source, selection: selection)
            case "para": edit = NoteFormat.Paragraph(rawValue: value).flatMap { NoteFormat.set($0, in: one.source, selection: selection) }
            case "list": edit = NoteFormat.List(rawValue: value).flatMap { NoteFormat.set($0, in: one.source, selection: selection) }
            case "align": edit = NoteAlignment(rawValue: value).flatMap { NoteFormat.set($0, in: one.source, selection: selection) }
            case "picture": edit = NoteFormat.insertPicture(value, in: one.source, selection: selection)
            case "tidy": cases[index].tidied = NoteFormat.tidy(line: one.source)
            case "state":
                let state = NoteFormat.state(in: one.source, selection: selection)
                cases[index].state = State(css: state.style.css, paragraph: state.paragraph.rawValue, list: state.list.rawValue,
                                           alignment: state.alignment.rawValue, size: state.size, ownSize: state.ownSize)
            default: break
            }
            if let edit {
                cases[index].edit = Answer(from: edit.range.location, to: NSMaxRange(edit.range), insert: edit.replacement,
                                           selectFrom: edit.selection.location, selectTo: NSMaxRange(edit.selection))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(cases).write(to: URL(fileURLWithPath: out))
            print("format fixture: \(cases.count) cases → \(out)")
        } catch {
            print("format fixture: \(error)")
        }
    }
}
#endif
