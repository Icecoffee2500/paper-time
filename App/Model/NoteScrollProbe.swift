#if os(macOS)
import AppKit
import SwiftUI

/// Whether the note stays still while it is typed in.
///
/// `--papertime-note-scroll=<markdown file>` opens that note in an editor in
/// a window of the probe's own, off every display, puts the caret at the end,
/// and presses keys the way a keyboard does (`--papertime-note-scroll-keys=`,
/// comma separated; the default is a sentence, Return, a line, deletes). After
/// each key it prints where the view is scrolled to, how tall the note is,
/// and where the caret is — a line that moves when nothing asked it to is the
/// jump a reader saw. Then it scrolls up by hand and watches whether the view
/// is pulled back. Nothing is saved: the note lives in memory.
enum NoteScrollProbe {
    static func runIfAsked() {
        guard let path = Boot.setting("PAPERTIME_NOTE_SCROLL"), !path.isEmpty else { return }
        Task { @MainActor in await run(path) }
    }

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    @MainActor
    private static func run(_ path: String) async {
        guard let data = FileManager.default.contents(atPath: path) else { return say("note scroll: cannot read \(path)") }
        let source = String(decoding: data, as: UTF8.self)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Watching the note scroll")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try? await Task.sleep(for: .seconds(1))

        let size = NSRect(x: 0, y: 0, width: 540, height: 560)
        let window = WindowProbe.ownWindow(contentRect: size, styleMask: [.titled, .resizable])
        let note = LatexSuiteTypingProbe.Note()
        note.markdown = source
        let hosting = NSHostingView(rootView: LatexSuiteTypingProbe.NoteHost(note: note))
        hosting.frame = size
        window.contentView = hosting
        window.orderFront(nil)
        if WindowProbe.isOnAScreen(window) {
            window.orderOut(nil)
            say("note scroll: the window landed on a screen — put away, nothing typed")
            return NSApp.terminate(nil)
        }
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        guard let text = LatexSuiteTypingProbe.noteTextView(in: hosting),
              let scroll = text.enclosingScrollView else { return say("note scroll: no note text view") }
        window.makeFirstResponder(text)
        let end = text.string.utf16.count
        text.setSelectedRange(NSRange(location: end, length: 0))
        text.scrollRangeToVisible(NSRange(location: end, length: 0))
        try? await Task.sleep(for: .milliseconds(400))

        var last = scroll.contentView.bounds.origin.y
        func report(_ label: String) {
            let visible = scroll.contentView.bounds
            let caret = text.selectedRange()
            // The caret's own segment, from TextKit 2: `firstRect` answers
            // nonsense for an empty last line.
            var rect = NSRect.zero
            if let layout = text.textLayoutManager, let content = layout.textContentManager,
               let location = content.location(content.documentRange.location, offsetBy: caret.location) {
                layout.ensureLayout(for: NSTextRange(location: location))
                layout.enumerateTextSegments(in: NSTextRange(location: location), type: .selection, options: []) { _, frame, _, _ in
                    rect = frame
                    return false
                }
                rect = rect.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
                if rect.height < 1 { rect.size.height = 18 }
            }
            let shown = rect.minY >= visible.minY - 1 && rect.maxY <= visible.maxY + 1
            let moved = visible.origin.y - last
            last = visible.origin.y
            // Across too: a caret set past the right edge is as out of sight
            // as one scrolled away — where the words after a too-wide list
            // number went.
            let across = rect.minX >= visible.minX - 1 && rect.maxX <= visible.maxX + 1
            say(String(format: "note scroll: %-14@ top %7.1f (%+6.1f)  height %7.1f  caret %7.1f…%7.1f at x %7.1f %@",
                       label as NSString, visible.origin.y, moved, text.frame.height, rect.minY, rect.maxY, rect.minX,
                       shown && across ? "shown" : "HIDDEN"))
        }
        report("start")

        let keys = (Boot.setting("PAPERTIME_NOTE_SCROLL_KEYS").flatMap { $0.isEmpty ? nil : $0 }
            ?? "a,b,c,Enter,Enter,d,e,f,Enter,g,Backspace,Backspace,Backspace,Backspace,Backspace,Enter,Enter,Enter,h")
            .split(separator: ",").map(String.init)
        for key in keys {
            // `Paste:<file>`: that file's HTML (or, for a .txt, its text) on a
            // pasteboard of the probe's own, pasted where the caret is.
            if let file = key.stripPrefix("Paste:") {
                let board = NSPasteboard(name: NSPasteboard.Name("PaperTimeProbe-\(ProcessInfo.processInfo.processIdentifier)"))
                board.clearContents()
                let contents = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
                board.setString(contents, forType: file.hasSuffix(".txt") ? .string : .html)
                let pasted = text.pasteTable(from: board)
                board.releaseGlobally()
                try? await Task.sleep(for: .milliseconds(300))
                say("note scroll: pasted table \(pasted); the note now reads:\n\(note.markdown.suffix(600))")
                report(key)
                continue
            }
            // `Shot:<png>`: the note as it stands, caret and all, drawn by the
            // view itself (`cacheDisplay`) — no screen is looked at.
            if let file = key.stripPrefix("Shot:") {
                if let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
                    scroll.cacheDisplay(in: scroll.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                }
                say("note scroll: shot \(file)")
                continue
            }
            // `Dark` / `Light`: the window's appearance, and the note set
            // again in it.
            if key == "Dark" || key == "Light" {
                window.appearance = NSAppearance(named: key == "Dark" ? .darkAqua : .aqua)
                try? await Task.sleep(for: .milliseconds(400))
                report(key)
                continue
            }
            // `PressCopy`: a press on the first block's copy pill where it is
            // drawn, and one just left of it — through the same hit test a
            // click takes — onto a pasteboard of the probe's own.
            if key == "PressCopy" {
                let board = NSPasteboard(name: NSPasteboard.Name("PaperTimeProbe-\(ProcessInfo.processInfo.processIdentifier)"))
                board.clearContents()
                var header: Int?
                if let storage = text.textStorage {
                    storage.enumerateAttribute(NoteCodeStyle.Block.attribute, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                        if NoteCodeStyle.Block.Row(value)?.role == .header { header = range.location; stop.pointee = true }
                    }
                }
                guard let header, let pill = text.copyButtonFrame(ofBlockAt: header) else {
                    say("note scroll: no copy pill")
                    continue
                }
                let beside = text.copyCode(at: NSPoint(x: pill.minX - 4, y: pill.midY), to: board)
                let inside = text.copyCode(at: NSPoint(x: pill.midX, y: pill.midY), to: board)
                say("note scroll: copy pill \(NSStringFromRect(pill)) beside \(beside) inside \(inside): \((board.string(forType: .string) ?? "").debugDescription)")
                board.releaseGlobally()
                report(key)
                continue
            }
            // `CopyCode`: the first block's copy button, onto a pasteboard of
            // the probe's own — never the one people copy to.
            if key == "CopyCode" {
                let board = NSPasteboard(name: NSPasteboard.Name("PaperTimeProbe-\(ProcessInfo.processInfo.processIdentifier)"))
                var header: Int?
                if let storage = text.textStorage {
                    storage.enumerateAttribute(NoteCodeStyle.Block.attribute, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                        if NoteCodeStyle.Block.Row(value)?.role == .header { header = range.location; stop.pointee = true }
                    }
                }
                let copied = header.map { text.copyCode(ofBlockAt: $0, to: board) } ?? false
                say("note scroll: copied code \(copied): \((board.string(forType: .string) ?? "").debugDescription)")
                board.releaseGlobally()
                report(key)
                continue
            }
            _ = await LatexSuiteTypingProbe.press(key, in: text, window: window)
            if key.hasPrefix("Caret:") { text.scrollRangeToVisible(text.selectedRange()) }
            await LatexSuiteTypingProbe.endOfEvent(window)
            try? await Task.sleep(for: .milliseconds(150))
            report(key)
            // What the note says now, for a probe of the keys themselves.
            if Boot.isSet("PAPERTIME_NOTE_SCROLL_TEXT") {
                say("note text: \(note.markdown.debugDescription) selection \(text.selectedRange()) shown \(text.string.debugDescription)")
                say("note toolbar: \(text.probeToolbar) syntax \(text.probeSyntax)")
                say("note emphasis: \(text.probeEmphasis)")
            }
        }

        // Scrolled up by hand, the caret left at the end: does anything pull
        // the view back down?
        let up = max(0, scroll.contentView.bounds.origin.y - 300)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: up))
        scroll.reflectScrolledClipView(scroll.contentView)
        report("scrolled up")
        for wait in [100, 300, 1000] {
            try? await Task.sleep(for: .milliseconds(wait))
            report("after \(wait)ms")
        }
        NSApp.terminate(nil)
    }
}
#endif
