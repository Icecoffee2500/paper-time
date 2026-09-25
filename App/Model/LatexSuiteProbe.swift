import Foundation
import PaperCore
#if os(macOS)
import AppKit
import SwiftUI
#endif

/// Proves the Latex Suite engine works inside the app — that its snippet file
/// made it into PaperCore's resource bundle in this build, not only in
/// `swift test` — and quits: `--papertime-latex-suite=1`.
///
/// It types a few keystrokes into a note held in memory and prints what came
/// out; nothing is opened or written. `LatexSuiteTypingProbe` is the one that
/// goes through the editors.
enum LatexSuiteProbe {
    static func run() {
        print("latex suite \(LatexSuite.version): \(LatexSuite.snippetCount) snippets")
        let engine = LatexSuite.Engine()
        for (marked, keys) in [("$|$", "@a"), ("$x|$", "/"), ("$|$", "//"), ("$x|$", "sr"), ("text |", "dm")] {
            var text = marked.replacingOccurrences(of: "|", with: "")
            var selection = [NSRange(location: (marked as NSString).range(of: "|").location, length: 0)]
            var tabstops = LatexSuite.Tabstops.none
            for key in keys.map(String.init) {
                if let edit = engine.handle(.text(key), text: text, selection: selection, tabstops: tabstops) {
                    let storage = NSMutableString(string: text)
                    for change in edit.changes.reversed() { storage.replaceCharacters(in: change.range, with: change.text) }
                    text = storage as String
                    selection = edit.selection
                    tabstops = edit.tabstops
                } else {
                    let change = LatexSuite.Change(range: selection[0], text: key)
                    text = (text as NSString).replacingCharacters(in: change.range, with: key)
                    selection = [NSRange(location: selection[0].location + (key as NSString).length, length: 0)]
                    tabstops = tabstops.afterEdit([change], selection: selection)
                }
            }
            let shown = (text as NSString).replacingCharacters(in: NSRange(location: selection[0].location, length: 0), with: "|")
            print("  \(marked.debugDescription) + \(keys.debugDescription) → \(shown.debugDescription)"
                + (tabstops.isActive ? " (\(tabstops.groups.count) tabstops)" : ""))
        }
        exit(0)
    }
}

#if os(macOS)
/// Types into the real editors, from inside the app, and says what came out:
/// `--papertime-latex-typing=<cases.json in the container>`.
///
/// The cases are Latex Suite's own fixtures (`latex-suite-cases.json`, what
/// the plugin itself did) plus any written in the same form. Each one is set
/// into a note — a real `NoteEditor`, the SwiftUI view the notes use, in a
/// window of the probe's own that no display reaches — and into a text card's
/// editor, and typed the way a keyboard types: a character through
/// `insertText`, which is where it arrives once any input method is done with
/// it, and Tab, Return and Delete as key events handed to the text view's own
/// `keyDown`, so they go through the key bindings to the command they are
/// bound to. Nothing is posted to the system and nothing reaches another
/// application; the note is never saved, and no setting is written.
///
/// Keys beyond the fixtures' own: `Mark:<text>` sets text as an input
/// method's composition, `Commit:<text>` hands it over while it is still
/// marked — the two halves of typing a Korean syllable.
///
/// `--papertime-latex-typing-shot=<png in the container>` also photographs
/// the note with its placeholders drawn; `--papertime-latex-typing-debug=1`
/// says before every key how deep the undo manager's grouping is, which is
/// what showed that a key typed here stayed in one group with the next until
/// an event went by (see `endOfEvent`); `--papertime-latex-typing-timing-first=1`
/// times a long note before the cases as well as after them.
@MainActor
enum LatexSuiteTypingProbe {
    struct Case: Decodable {
        var id: String
        var name: String?
        var before: String
        var input: Input
        var after: String
        var afterTabstops: String?
        var tabstopIndex: Int?
        var passThrough: String?
        /// What the note does with a key Latex Suite leaves alone, for the
        /// cases written for this probe.
        var noteAfter: String?

        enum Input: Decodable {
            case one(String)
            case many([String])
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let one = try? container.decode(String.self) { self = .one(one) } else { self = .many(try container.decode([String].self)) }
            }
            var items: [String] {
                switch self {
                case .one(let one): [one]
                case .many(let many): many
                }
            }
        }

        /// The keys, one per press.
        var keys: [String] {
            input.items.flatMap { item -> [String] in
                if LatexSuiteTypingProbe.named.contains(item) || item.hasPrefix("Caret:")
                    || item.hasPrefix("Mark:") || item.hasPrefix("Commit:") {
                    return [item]
                }
                return item.map(String.init)
            }
        }
    }

    nonisolated static let named: Set<String> = ["Tab", "Shift+Tab", "Enter", "Shift+Enter", "Backspace", "Undo", "Redo"]

    @Observable
    final class Note {
        var markdown = ""
    }

    struct NoteHost: View {
        @Bindable var note: Note
        var body: some View {
            NoteEditor(markdown: $note.markdown, pendingAnchor: .constant(nil), onFollow: { _ in })
        }
    }

    static func runIfAsked() {
        guard let path = Boot.setting("PAPERTIME_LATEX_TYPING"), !path.isEmpty else { return }
        say("latex typing: starting with \(path)")
        Task { @MainActor in await run(path) }
    }

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func run(_ path: String) async {
        guard let data = FileManager.default.contents(atPath: path) else { return say("latex typing: cannot read \(path)") }
        struct File: Decodable { var cases: [Case] }
        let cases: [Case]
        do { cases = try JSONDecoder().decode(File.self, from: data).cases } catch { return say("latex typing: \(error)") }
        // A probe runs hidden, and a hidden app with no window on any screen
        // is put to sleep by App Nap a minute or two in: the same arithmetic
        // ran five times slower at the end of a run than at its start, and so
        // did every keypress. Holding an activity for the run keeps the
        // timings about the app rather than about macOS saving power.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "Timing Latex Suite in the editors"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try? await Task.sleep(for: .seconds(1))

        // A window of the probe's own, far outside every display.
        let displays = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: displays.minX - 60_000, y: displays.minY - 60_000))
        let note = Note()
        let hosting = NSHostingView(rootView: NoteHost(note: note))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        hosting.frame = NSRect(x: 0, y: 140, width: 640, height: 280)
        hosting.autoresizingMask = [.width, .minYMargin]
        container.addSubview(hosting)
        let card = SketchTextEditor(frame: NSRect(x: 20, y: 20, width: 600, height: 100))
        card.font = NSFont.systemFont(ofSize: 14)
        card.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        container.addSubview(card)
        window.contentView = container
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        guard let text = noteTextView(in: hosting), let coordinator = text.coordinator else {
            return say("latex typing: no note text view in the window")
        }
        say("latex typing: \(cases.count) cases, Latex Suite \(LatexSuite.version); note \(type(of: text)), card \(type(of: card))")

        if Boot.isSet("PAPERTIME_LATEX_TYPING_TIMING_FIRST") { await timing(text, coordinator: coordinator, note: note) }
        var tally: [String: Int] = [:]
        for probe in cases {
            for editor in ["note", "card"] {
                let view: LatexSuiteTextView = editor == "note" ? text : card
                let started = Date()
                guard let (source, selection) = parse(probe.before) else { say("\(probe.id) \(editor): cannot read before"); continue }
                if editor == "note" {
                    coordinator.lastKnownMarkdown = source
                    note.markdown = source
                    coordinator.restyle(text, source: source, caretSource: selection.first?.location ?? 0)
                } else {
                    card.string = source
                }
                view.latexSuite.reset()
                // A fresh start: the typing the text view is still coalescing
                // belongs to the case before, in a text that is gone.
                view.breakUndoCoalescing()
                view.undoManager?.removeAllActions()
                view.latexSuite.select(selection, in: view)
                window.makeFirstResponder(view)
                try? await Task.sleep(for: .milliseconds(40))
                var handled: [String] = []
                for key in probe.keys {
                    if Boot.isSet("PAPERTIME_LATEX_TYPING_DEBUG") {
                        say("  key \(key.debugDescription): level \(view.undoManager?.groupingLevel ?? -1) canUndo \(view.undoManager?.canUndo ?? false)")
                    }
                    handled.append(await press(key, in: view, window: window))
                    await endOfEvent(window)
                }
                try? await Task.sleep(for: .milliseconds(40))
                // Latex Suite's reading of the note has to be the note's own,
                // character for character, or its offsets land elsewhere.
                if editor == "note", let storage = text.textStorage,
                   LatexSuiteDisplay(storage).source as String != NoteMarkdown.markdown(from: storage) {
                    tally["note readings that differ", default: 0] += 1
                    say("READING \(probe.id): \((LatexSuiteDisplay(storage).source as String).debugDescription) ≠ \(NoteMarkdown.markdown(from: storage).debugDescription)")
                }
                let got = marked(view)
                let tabs = tabstopString(view)
                let index = view.latexSuite.tabstops.isActive ? view.latexSuite.tabstops.index : nil
                let hostAfter = editor == "note" ? probe.noteAfter : nil
                let verdict: String
                if probe.passThrough != nil, hostAfter == nil {
                    verdict = "HOST"
                } else if got == (hostAfter ?? probe.after),
                          hostAfter != nil || (tabs == probe.afterTabstops && index == probe.tabstopIndex) {
                    verdict = "PASS"
                } else {
                    verdict = "FAIL"
                }
                tally["\(editor) \(verdict)", default: 0] += 1
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                var line = "\(verdict) \(probe.id) \(editor) \(probe.before.debugDescription) \(probe.keys) → \(got.debugDescription)"
                if let tabs { line += " tabstops \(tabs.debugDescription) @\(index.map(String.init) ?? "-")" }
                if verdict == "FAIL" {
                    line += " — expected \((hostAfter ?? probe.after).debugDescription)"
                    if hostAfter == nil { line += " tabstops \(probe.afterTabstops?.debugDescription ?? "nil") @\(probe.tabstopIndex.map(String.init) ?? "-")" }
                }
                if verdict == "HOST" { line += " (passes \(probe.passThrough ?? "") to the \(editor))" }
                say(line + " [\(handled.joined(separator: ","))] \(ms)ms")
            }
        }
        say("latex typing: " + tally.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        await timing(text, coordinator: coordinator, note: note)
        if let shot = Boot.setting("PAPERTIME_LATEX_TYPING_SHOT") {
            await photograph(text, coordinator: coordinator, note: note, to: shot)
        }
        NSApp.terminate(nil)
    }

    /// What the end of a keypress is to the rest of the app. A key typed on
    /// a keyboard arrives as an event, and when the app has handled the event
    /// the undo manager closes the group the keypress opened — that is what
    /// makes two keys two steps to undo. A key typed here is a call, not an
    /// event, so the group stayed open from one key to the next and the probe
    /// saw every key of a case as one step. An event of the app's own kind,
    /// put at the end of its own queue (never the system's), is handled the
    /// same way and closes the group the same way.
    static func endOfEvent(_ window: NSWindow) async {
        if let marker = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0
        ) {
            NSApp.postEvent(marker, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(25))
    }

    /// One keypress, the way it arrives from a keyboard.
    static func press(_ key: String, in view: LatexSuiteTextView, window: NSWindow) async -> String {
        func event(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )
        }
        let before = marked(view)
        switch key {
        case "Tab": if let key = event("\t", 48) { view.keyDown(with: key) }
        case "Shift+Tab": if let key = event("\u{19}", 48, .shift) { view.keyDown(with: key) }
        case "Enter": if let key = event("\r", 36) { view.keyDown(with: key) }
        case "Shift+Enter": if let key = event("\r", 36, .shift) { view.keyDown(with: key) }
        case "Backspace": if let key = event("\u{7F}", 51) { view.keyDown(with: key) }
        // The Edit menu's own route: `undo:` to the first thing up the
        // responder chain from the text view that answers it — the card's
        // editor, or the window.
        case "Undo":
            guard view.undoManager?.canUndo == true else { return "nothing to undo" }
            sendUp(Selector(("undo:")), from: view)
        case "Redo":
            guard view.undoManager?.canRedo == true else { return "nothing to redo" }
            sendUp(Selector(("redo:")), from: view)
        default:
            if let offset = key.stripPrefix("Caret:").flatMap(Int.init) {
                set([NSRange(location: offset, length: 0)], in: view)
            } else if let composing = key.stripPrefix("Mark:") {
                // With nothing marked, `markedRange()` is not NSNotFound here,
                // so it is asked only while there is a composition.
                let open = view.hasMarkedText() ? view.markedRange() : NSRange(location: NSNotFound, length: 0)
                view.setMarkedText(
                    composing, selectedRange: NSRange(location: (composing as NSString).length, length: 0),
                    replacementRange: open
                )
                return "marked \(view.markedRange()) of \(marked(view).debugDescription)"
            } else if let committed = key.stripPrefix("Commit:") {
                view.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
                return "committed"
            } else {
                view.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        return marked(view) == before ? "·" : "✓"
    }

    /// One op of the sketch script on the card being typed into:
    /// `cardtext=<marked>` sets its words and caret, `keys=<keys>` types
    /// (a space between keys; a named key — Tab, Enter, Undo… — is one key,
    /// anything else is typed a character at a time), `cardreport` says what
    /// the card holds.
    static func card(_ op: String, in view: LatexSuiteTextView) async -> String {
        guard let window = view.window else { return "card: not in a window" }
        if let marked = op.stripPrefix("cardtext=") {
            guard let (text, selection) = parse(marked) else { return "card: cannot read \(marked)" }
            view.string = text
            view.latexSuite.reset()
            view.breakUndoCoalescing()
            view.undoManager?.removeAllActions()
            view.latexSuite.select(selection, in: view)
            return "card: set to \(self.marked(view).debugDescription)"
        }
        if let script = op.stripPrefix("keys=") {
            var keys: [String] = []
            for token in script.split(separator: " ").map(String.init) {
                if named.contains(token) { keys.append(token) } else { keys += token.map(String.init) }
            }
            var said: [String] = []
            for key in keys {
                said.append(await press(key, in: view, window: window))
                await endOfEvent(window)
            }
            return "card: typed \(keys) [\(said.joined(separator: ","))] → \(marked(view).debugDescription)"
                + (tabstopString(view).map { " tabstops \($0.debugDescription)" } ?? "")
        }
        return "card: \(marked(view).debugDescription)" + (tabstopString(view).map { " tabstops \($0.debugDescription)" } ?? "")
    }

    private static func sendUp(_ action: Selector, from view: NSView) {
        var responder: NSResponder? = view
        while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
        guard let target = responder else { return say("latex typing: nothing answers \(action)") }
        NSApp.sendAction(action, to: target, from: nil)
    }

    /// Where Latex Suite's own time goes on a long note: the note set to
    /// 20,000 characters with a formula at the end, and `/` typed into it.
    private static func timing(_ text: NoteTextView, coordinator: NoteEditor.Coordinator, note: Note) async {
        var paragraph = "모델은 학습률 $\\eta$와 정규화 항 $\\lambda \\lVert w \\rVert^{2}$를 함께 조절해요. "
        while (paragraph as NSString).length < 400 { paragraph += paragraph }
        var body = ""
        while (body as NSString).length < 20_000 { body += paragraph + "\n\n" }
        let source = body + "끝에서 $a+b$"
        coordinator.lastKnownMarkdown = source
        note.markdown = source
        let caret = (source as NSString).length - 1
        coordinator.restyle(text, source: source, caretSource: caret)
        text.latexSuite.reset()
        try? await Task.sleep(for: .milliseconds(200))
        func ms(_ since: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(since) * 1000) }
        guard let storage = text.textStorage, let window = text.window else { return }
        // The pieces, one at a time, before the whole: reading the note back
        // as Markdown (what the adapter does, and what the note does after
        // every edit), and Latex Suite's own answer.
        var started = Date()
        let display = LatexSuiteDisplay(storage)
        let reading = ms(started)
        started = Date()
        _ = LatexSuite.Engine().handle(.text("/"), text: display.source as String, selection: [NSRange(location: caret, length: 0)])
        let engine = ms(started)
        started = Date()
        _ = NoteMarkdown.markdown(from: storage)
        let noteReading = ms(started)
        say("latex typing: a \(storage.length)-character screen, \(display.runs.count) runs — reading it as the source \(reading) ms (the same text as the note's own: \(display.source as String == NoteMarkdown.markdown(from: storage))), Latex Suite's answer \(engine) ms, the note's own reading \(noteReading) ms; \(residentMegabytes()) MB resident; the yardstick \(yardstick()) ms")
        var times: [String] = []
        for _ in 0..<5 {
            started = Date()
            text.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
            times.append(ms(started))
            await endOfEvent(window)
            sendUp(Selector(("undo:")), from: text)
            await endOfEvent(window)
            sendUp(Selector(("undo:")), from: text)
            await endOfEvent(window)
        }
        say("latex typing: / at the end of a \((source as NSString).length)-character note — \(times.joined(separator: ", ")) ms (the keypress, expansion and all); now \(String(marked(text).suffix(24)).debugDescription)")
        // A key Latex Suite leaves alone, in the words after the formula — the
        // cost every keypress now pays — with the switch on and then off.
        let words = source + " 그리고"
        coordinator.lastKnownMarkdown = words
        note.markdown = words
        coordinator.restyle(text, source: words, caretSource: (words as NSString).length)
        text.latexSuite.reset()
        try? await Task.sleep(for: .milliseconds(200))
        var plain: [String] = []
        for _ in 0..<5 {
            started = Date()
            text.insertText("k", replacementRange: NSRange(location: NSNotFound, length: 0))
            plain.append(ms(started))
            await endOfEvent(window)
            sendUp(Selector(("undo:")), from: text)
            await endOfEvent(window)
        }
        LatexSuiteTyping.isSwitchedOffForProbe = true
        var off: [String] = []
        for _ in 0..<5 {
            started = Date()
            text.insertText("k", replacementRange: NSRange(location: NSNotFound, length: 0))
            off.append(ms(started))
            await endOfEvent(window)
            sendUp(Selector(("undo:")), from: text)
            await endOfEvent(window)
        }
        LatexSuiteTyping.isSwitchedOffForProbe = false
        say("latex typing: a plain key at the end of that note — \(plain.joined(separator: ", ")) ms with Latex Suite, \(off.joined(separator: ", ")) ms with it switched off")
    }

    /// The same fixed piece of arithmetic every time, which has nothing to do
    /// with notes: when it slows down as much as the typing does, the machine
    /// is busy, not the app.
    private static func yardstick() -> String {
        var generator = SystemRandomNumberGenerator()
        var values = (0..<300_000).map { _ in Double.random(in: 0..<1, using: &generator) }
        let started = Date()
        values.sort()
        return String(format: "%.1f", Date().timeIntervalSince(started) * 1000 + values[0] * 0)
    }

    /// How much memory the app holds, for telling a slowdown that comes with
    /// the app's history from one that comes with the machine being busy.
    private static func residentMegabytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    /// The note with its placeholders on, as a picture.
    private static func photograph(_ text: NoteTextView, coordinator: NoteEditor.Coordinator, note: Note, to path: String) async {
        let source = "평균 $|$ 이에요"
        guard let (plain, selection) = parse(source) else { return }
        coordinator.lastKnownMarkdown = plain
        note.markdown = plain
        coordinator.restyle(text, source: plain, caretSource: selection[0].location)
        text.latexSuite.reset()
        set(selection, in: text)
        for key in ["\\", "s", "u", "m", "Tab"] {
            _ = await press(key, in: text, window: text.window ?? NSWindow())
            try? await Task.sleep(for: .milliseconds(40))
        }
        say("latex typing: for the picture \(marked(text).debugDescription), tabstops \(tabstopString(text)?.debugDescription ?? "none")")
        let display = LatexSuiteDisplay(text.textStorage ?? NSAttributedString())
        for (index, group) in text.latexSuite.tabstops.groups.enumerated() {
            let rects = group.ranges.flatMap { LatexSuiteTyping.rects(for: display.displayRange(for: $0), in: text) }
            say("latex typing: group \(index) \(index > text.latexSuite.tabstops.index ? "drawn" : "not drawn") at \(rects.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" })")
        }
        text.display()
        guard let bitmap = text.bitmapImageRepForCachingDisplay(in: text.bounds) else { return }
        text.cacheDisplay(in: text.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        say("latex typing: wrote \(path)")
    }

    // MARK: Reading and writing the marked-up strings

    /// `$a|b$` → the text and its selection. `«…»` is a selection (anchor at
    /// «), several `|` are several carets, `¦` is a real bar.
    static func parse(_ marked: String) -> (String, [NSRange])? {
        var text = ""
        var ranges: [NSRange] = []
        var open: Int?
        var length = 0
        for character in marked {
            switch character {
            case "|": ranges.append(NSRange(location: length, length: 0))
            case "«": open = length
            case "»":
                guard let start = open else { return nil }
                ranges.append(NSRange(location: start, length: length - start))
                open = nil
            case "¦":
                text.append("|")
                length += 1
            default:
                text.append(character)
                length += (String(character) as NSString).length
            }
        }
        return (text, ranges.isEmpty ? [NSRange(location: length, length: 0)] : ranges)
    }

    /// The editor's text as the source, with its selection marked the same way.
    static func marked(_ view: LatexSuiteTextView) -> String {
        guard let storage = view.textStorage else { return "" }
        let display = LatexSuiteDisplay(storage)
        let source = (display.source as String).replacingOccurrences(of: "|", with: "¦") as NSString
        var inserts: [(Int, String)] = []
        for range in view.latexSuite.selection(in: view, display: display) {
            if range.length == 0 { inserts.append((range.location, "|")) }
            else { inserts.append((range.location, "«")); inserts.append((range.location + range.length, "»")) }
        }
        let result = NSMutableString(string: source as String)
        for (offset, mark) in inserts.sorted(by: { $0.0 > $1.0 }) { result.insert(mark, at: offset) }
        return result as String
    }

    /// The active placeholders the fixtures' way: `⟨k⟩` for an empty one of
    /// group k, `⟨k:text⟩` for one round text. Nil when there are none.
    static func tabstopString(_ view: LatexSuiteTextView) -> String? {
        let tabstops = view.latexSuite.tabstops
        guard tabstops.isActive, let storage = view.textStorage else { return nil }
        let source = LatexSuiteDisplay(storage).source
        // Offset, then what goes first where several meet: a closing, an
        // empty one, an opening — lower groups first.
        var marks: [(offset: Int, order: Int, group: Int, text: String)] = []
        for (index, group) in tabstops.groups.enumerated() {
            for range in group.ranges {
                if range.length == 0 {
                    marks.append((range.location, 1, index, "⟨\(index)⟩"))
                } else {
                    marks.append((range.location, 2, index, "⟨\(index):"))
                    marks.append((range.location + range.length, 0, index, "⟩"))
                }
            }
        }
        let result = NSMutableString(string: (source as String).replacingOccurrences(of: "|", with: "¦"))
        for mark in marks.sorted(by: { ($0.offset, $0.order, $0.group) > ($1.offset, $1.order, $1.group) }) {
            result.insert(mark.text, at: mark.offset)
        }
        return result as String
    }

    static func set(_ selection: [NSRange], in view: LatexSuiteTextView) {
        guard let storage = view.textStorage else { return }
        let display = LatexSuiteDisplay(storage)
        view.setSelectedRanges(selection.map { NSValue(range: display.displayRange(for: $0)) }, affinity: .downstream, stillSelecting: false)
    }

    static func noteTextView(in view: NSView) -> NoteTextView? {
        if let text = view as? NoteTextView { return text }
        for child in view.subviews { if let found = noteTextView(in: child) { return found } }
        return nil
    }
}
#endif
