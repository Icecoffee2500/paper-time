#if os(macOS)
import AppKit
import PaperCore
import SwiftUI

/// The place to write while reading.
///
/// A text view rather than SwiftUI's `TextEditor`, because a note here has to
/// do four things `TextEditor` cannot: carry links you can click, set a formula
/// as mathematics, continue a list when you press Return, and give back plain
/// Markdown when you copy any of it.
extension NoteEditor {
    /// Where the words start. Written down because two surfaces have to agree
    /// on it — the text view, and the placeholder drawn over it while the note
    /// is empty. They drifted apart, and the caret sat in the middle of the
    /// first line of the placeholder rather than at its beginning.
    static let inset: CGFloat = 22
    /// What TextKit leaves at the edge of a line fragment, on top of the
    /// inset. Set rather than assumed: its default has changed between
    /// TextKit 1 and 2.
    static let gutter: CGFloat = 5
    /// The first line's baseline box, for putting something over it.
    static var textOrigin: CGSize { CGSize(width: inset + gutter, height: inset) }
}

struct NoteEditor: NSViewRepresentable {
    @Binding var markdown: String
    /// Set to drop a link at the cursor; cleared once it has been dropped.
    @Binding var pendingAnchor: NoteAnchor?
    /// Words to scroll to and flash; cleared once they have been shown. A
    /// passage found by meaning is a run of the note's words with the
    /// Markdown taken out, so the first few of them are looked for in
    /// what is on screen, and the whole run is not asked for — a formula
    /// or a link in the middle of it is spelled differently here.
    @Binding var pendingReveal: String?
    /// A quotation to scroll to and flash, by its page link's address — its
    /// passage was clicked on the page. Cleared once shown.
    @Binding var pendingPassage: String?
    /// Shows the Markdown as written, for when a link or a formula needs
    /// changing by hand.
    var showsRawText = false
    var onFollow: (NoteAnchor) -> Void
    /// Opening another note in the box, from a `[[link]]`.
    var onOpenNote: (String) -> Void = { _ in }
    /// The notes that could finish what is being typed after `[[`.
    var suggestions: (String) -> [(id: String, title: String, subtitle: String)] = { _ in [] }

    func makeCoordinator() -> Coordinator {
        Coordinator(markdown: $markdown, onFollow: onFollow)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = NoteTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = true
        // Undo is the coordinator's, in the Markdown (`Coordinator.willEdit`):
        // the text view's own undo is in screen offsets, which the note
        // invalidates every time it sets a line again, and under TextKit 2
        // it changes the screen without telling the delegate — so ⌘Z after
        // ⌘B took the stars off the screen and left them in the note.
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        // Room to breathe. A note is prose in a narrow column, and prose
        // pressed against the edge of its column is the thing that made this
        // read like a text field rather than a page.
        textView.textContainerInset = NSSize(width: Self.inset, height: Self.inset)
        textView.textContainer?.lineFragmentPadding = Self.gutter
        // The chips are painted by the fragment this hands back.
        textView.textLayoutManager?.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = NoteMarkdown.bodyAttributes
        // Only the cursor. Colour and underline are decided per run, because a
        // passage from the paper and a link to a note are not the same thing
        // and should not look the same.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        scrollView.documentView = textView

        // Over the whole scroll view, above the text, so the glow it draws
        // for a hovered chip is not something the text has to redraw.
        let hover = ChipHoverView(frame: scrollView.bounds)
        hover.autoresizingMask = [.width, .height]
        scrollView.addSubview(hover, positioned: .above, relativeTo: nil)
        textView.chipHoverView = hover
        // Scrolling moves the chip out from under its glow; the glow goes
        // until the pointer finds the chip again.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            textView, selector: #selector(NoteTextView.scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        context.coordinator.textView = textView
        context.coordinator.showsRawText = showsRawText
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.textViewFrameChanged(_:)),
            name: NSView.frameDidChangeNotification, object: textView
        )
        context.coordinator.setContents(
            NoteMarkdown.render(markdown, raw: showsRawText, appearance: textView.effectiveAppearance).text, in: textView
        )
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onFollow = onFollow
        context.coordinator.onOpenNote = onOpenNote
        context.coordinator.suggestions = suggestions
        guard let textView = scrollView.documentView as? NoteTextView else { return }

        if context.coordinator.showsRawText != showsRawText {
            context.coordinator.showsRawText = showsRawText
            context.coordinator.restyle(textView, source: markdown, caretSource: nil)
        } else if context.coordinator.lastKnownMarkdown != markdown {
            // Only replace what is on screen when the note changed elsewhere —
            // rewriting it on every pass would fight the typist. What could be
            // undone was about the note as it was: undone now, it would put
            // that note back over this one.
            context.coordinator.forgetUndo(in: textView)
            context.coordinator.lastKnownMarkdown = markdown
            context.coordinator.restyle(textView, source: markdown, caretSource: nil)
        }

        if let anchor = pendingAnchor {
            DispatchQueue.main.async {
                context.coordinator.insert(anchor, into: textView)
                pendingAnchor = nil
            }
        }

        if let words = pendingReveal {
            DispatchQueue.main.async {
                Self.reveal(words, in: textView)
                pendingReveal = nil
            }
        }

        if let address = pendingPassage {
            DispatchQueue.main.async {
                Self.revealQuotation(address, in: textView)
                pendingPassage = nil
            }
        }
    }

    /// Scrolls to the quotation whose page link is this address and flashes
    /// it the way Find does: the block quote the link closes, or the link's
    /// own line for a passage in a sentence. The caret stays where it was —
    /// put on the quotation, the line would turn back into its Markdown.
    static func revealQuotation(_ address: String, in textView: NSTextView) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let shown = storage.string as NSString
        var chip: NSRange?
        storage.enumerateAttribute(NoteChip.attribute, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            let url = (value as? URL)?.absoluteString ?? (value as? String)
            if url == address {
                chip = range
                stop.pointee = true
            }
        }
        // A line shown as written spells the address out.
        let found = chip ?? {
            let raw = shown.range(of: address)
            return raw.location == NSNotFound ? nil : raw
        }()
        guard let found else {
            if Boot.isSet("PAPERTIME_NOTE_REVEAL") {
                FileHandle.standardError.write(Data("note reveal: quotation \(address.prefix(60)) not in the note\n".utf8))
            }
            return
        }
        let range = quotation(endingWith: found, in: storage)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
        if Boot.isSet("PAPERTIME_NOTE_REVEAL") {
            let words = shown.substring(with: range).replacingOccurrences(of: "\n", with: "⏎")
            FileHandle.standardError.write(Data("note reveal: quotation at \(range.location)+\(range.length): “\(words)”\n".utf8))
        }
    }

    /// The quotation a page link closes, as the note shows it: back up the
    /// lines of its block quote — the ones under the quotation's rule — to
    /// where the quote opens, or to the line before that closes another
    /// quotation. A link outside a quote is its own line.
    static func quotation(endingWith link: NSRange, in storage: NSTextStorage) -> NSRange {
        let shown = storage.string as NSString
        let last = shown.paragraphRange(for: link)
        func quoteEdge(_ paragraph: NSRange) -> NoteMarkdown.QuoteEdge? {
            guard paragraph.length > 0 else { return nil }
            return (storage.attribute(NoteQuoteBar.attribute, at: paragraph.location, effectiveRange: nil) as? Int)
                .map(NoteMarkdown.QuoteEdge.init(rawValue:))
        }
        func hasLink(_ paragraph: NSRange) -> Bool {
            var found = false
            storage.enumerateAttribute(NoteChip.attribute, in: paragraph) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return found
        }
        var start = last.location
        if let edge = quoteEdge(last), !edge.contains(.opens) {
            while start > 0 {
                let above = shown.paragraphRange(for: NSRange(location: start - 1, length: 0))
                guard let edge = quoteEdge(above), !hasLink(above) else { break }
                start = above.location
                if edge.contains(.opens) { break }
            }
        }
        var end = NSMaxRange(last)
        while end > start, [10, 13].contains(shown.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// Scrolls to the first place the first few of these words stand, and
    /// flashes it the way Find does. Nothing when they are not on screen
    /// — the note is open, which is most of the way there.
    static func reveal(_ words: String, in textView: NSTextView) {
        let shown = textView.string as NSString
        let pieces = words.split(whereSeparator: \.isWhitespace)
        // The longest run of leading words that is found, down to three;
        // a shorter run than that lands on the wrong line too often.
        for count in stride(from: min(pieces.count, 8), through: min(pieces.count, 3), by: -1) where count > 0 {
            let phrase = pieces.prefix(count).joined(separator: " ")
            // Any white space between the words: the index joined them
            // with spaces, and on screen a title's line break stands there.
            let pattern = pieces.prefix(count).map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"\s+"#)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: shown as String, range: NSRange(location: 0, length: shown.length))
            else { continue }
            let range = match.range
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
            if Boot.isSet("PAPERTIME_NOTE_REVEAL") {
                FileHandle.standardError.write(Data("note reveal: “\(phrase)” at \(range.location)+\(range.length) of \(shown.length)\n".utf8))
            }
            return
        }
        if Boot.isSet("PAPERTIME_NOTE_REVEAL") {
            FileHandle.standardError.write(Data("note reveal: “\(words.prefix(40))” not on screen\n".utf8))
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextLayoutManagerDelegate {
        /// Hands back the fragment that paints the passage chips. Everything
        /// else about it is the stock one.
        func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager,
            textLayoutFragmentFor location: any NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            NoteLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }

        @Binding var markdown: String
        var onFollow: (NoteAnchor) -> Void
        var onOpenNote: (String) -> Void = { _ in }
        var suggestions: (String) -> [(id: String, title: String, subtitle: String)] = { _ in [] }
        var lastKnownMarkdown: String
        var showsRawText = false
        weak var textView: NoteTextView?

        let completions = WikiLinkPopover()
        /// The formula under the caret, set — see `MathPreviewCard`.
        let mathPreview = MathPreviewCard()
        /// Bold, italic, code and math over a selection (`SelectionToolbar`).
        let selectionToolbar = SelectionToolbar()
        /// The toggles whose children are folded away, by `Block.toggleKey`.
        /// Kept for the editor's life, not written anywhere: a fold is how
        /// the note is being read, not what it says.
        var collapsedToggles = Set<String>()
        private var mathPreviewWork: DispatchWorkItem?

        /// The line the caret was on when the text was last set: syntax is
        /// shown on that line and nowhere else, so leaving a line sets it.
        private var lastCaretLine = NSRange(location: 0, length: 0)
        private var restyleIsScheduled = false
        /// The width the formulas on screen were laid out for.
        var lastKnownWidth: CGFloat?
        private(set) var isRestyling = false

        init(markdown: Binding<String>, onFollow: @escaping (NoteAnchor) -> Void) {
            _markdown = markdown
            self.onFollow = onFollow
            self.lastKnownMarkdown = markdown.wrappedValue
        }

        // MARK: Editing

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView,
                  let storage = textView.textStorage,
                  !textView.hasMarkedText()
            else { return }

            let source = NoteMarkdown.markdown(from: storage)
            // A change to a drawn stand-in that leaves the note as it was —
            // the tab after a bullet deleted on its own — is undone on screen
            // at once: nothing else would set that line again until the
            // caret left it.
            if source == lastKnownMarkdown { setCaretLine = -1 }
            lastKnownMarkdown = source
            markdown = source
            didEdit(in: textView)
            carryFoldKey(in: textView)
            updateCompletions(in: textView)
            updateMathPreview(in: textView)
            scheduleRestyle(in: textView)
            recolorCaretLine(in: textView)
        }

        /// The key of the folded toggle the caret was last on, if any — so
        /// that typing in its title keeps it folded (`carryFoldKey`).
        private var caretFoldKey: String?

        /// A folded toggle is named by its line as written; typing in that
        /// line renames it, and the name in `collapsedToggles` goes along.
        func carryFoldKey(in textView: NoteTextView) {
            guard let storage = textView.textStorage, textView.selectedRange().length == 0 else { return }
            let line = (textView.string as NSString).lineRange(for: textView.selectedRange())
            let source = NoteMarkdown.markdown(from: storage.attributedSubstring(from: line))
            let block = NoteMarkdown.Block(line: String(source.prefix { $0 != "\n" }))
            guard block.kind == .toggle else { caretFoldKey = nil; return }
            let key = block.toggleKey
            if let was = caretFoldKey, was != key, collapsedToggles.contains(was) {
                collapsedToggles.remove(was)
                collapsedToggles.insert(key)
            }
            caretFoldKey = key
        }

        /// Colours the syntax on the line being edited as it is typed, and
        /// sets its emphasis: the note is not set again for a keystroke that
        /// stays on one line (`scheduleRestyle`), so a "$" typed there would
        /// stay the colour of a word, and a word closed in `**` stay plain,
        /// until the caret left the line.
        ///
        /// With a selection too, on one line: ⌘B over a selected word puts its
        /// stars in and leaves the word selected, and the word stayed plain
        /// — under the stars, looking like nothing had happened — until the
        /// selection was let go.
        func recolorCaretLine(in textView: NoteTextView) {
            guard !showsRawText, Self.isOnOneLine(textView), !textView.hasMarkedText() else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, !self.isRestyling, let textView, let storage = textView.textStorage,
                      Self.isOnOneLine(textView) else { return }
                let text = textView.string as NSString
                let line = text.lineRange(for: textView.selectedRange())
                guard line.length > 0 else { return }
                // A block of code is coloured as a whole: a quote opened on one
                // line colours the lines after it.
                if storage.attribute(NoteCodeStyle.Block.attribute, at: min(line.location, storage.length - 1),
                                     effectiveRange: nil) != nil {
                    storage.beginEditing()
                    NoteMarkdown.recolourCode(storage, around: textView.selectedRange().location)
                    storage.endEditing()
                    return
                }
                let shown = storage.attributedSubstring(from: line)
                let source = NoteMarkdown.markdown(from: shown).trimmingCharacters(in: .newlines)
                let block = NoteMarkdown.Block(line: source)
                var contentStart = line.location
                storage.beginEditing()
                if !block.marker.isEmpty {
                    var run = NSRange()
                    if let standing = storage.attribute(.paperTimeSource, at: line.location, longestEffectiveRange: &run, in: line) as? String,
                       standing == block.marker {
                        contentStart = NSMaxRange(run)
                    } else {
                        contentStart = min(line.location + (block.marker as NSString).length, NSMaxRange(line))
                        storage.addAttribute(.foregroundColor, value: NoteMarkdown.syntaxColor,
                                             range: NSRange(location: line.location, length: contentStart - line.location))
                    }
                }
                var end = NSMaxRange(line)
                if end > contentStart, text.substring(with: NSRange(location: end - 1, length: 1)) == "\n" { end -= 1 }
                if end > contentStart {
                    // The emphasis too, not only the colours: a word made
                    // bold is bold while its line is being written.
                    NoteMarkdown.styleAsWritten(storage, range: NSRange(location: contentStart, length: end - contentStart),
                                                block: block)
                }
                storage.endEditing()
            }
        }

        /// Whether the caret, or the whole of the selection, is on one line.
        static func isOnOneLine(_ textView: NSTextView) -> Bool {
            let range = textView.selectedRange()
            guard range.length > 0 else { return true }
            let text = textView.string as NSString
            guard NSMaxRange(range) <= text.length else { return false }
            return text.lineRange(for: NSRange(location: range.location, length: 0)) == text.lineRange(for: range)
                && !text.substring(with: range).contains("\n")
        }

        /// Shows the bar over a selection made with the keyboard or just let
        /// go of with the mouse, and takes it away with the selection.
        func updateSelectionToolbar(in textView: NoteTextView) {
            let range = textView.selectedRange()
            // Code is not made bold: no bar over a selection in a block of code.
            guard range.length > 0, !textView.isSelectingByHand, !showsRawText,
                  let window = textView.window, window.firstResponder === textView,
                  textView.codeRowAtCaret() == nil
            else { return selectionToolbar.hide() }
            let rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            guard rect.width.isFinite, rect.height.isFinite else { return selectionToolbar.hide() }
            selectionToolbar.show(over: rect, in: textView) { [weak textView] mark in
                textView?.toggleEmphasis(mark)
            }
        }

        /// Folds a toggle's children away, or brings them back, and sets the
        /// note again so the lines go and come.
        func setFolded(_ key: String, _ folded: Bool, in textView: NoteTextView) {
            guard let storage = textView.textStorage else { return }
            if folded { collapsedToggles.insert(key) } else { collapsedToggles.remove(key) }
            endTyping()
            let source = NoteMarkdown.markdown(from: storage)
            let caret = NoteMarkdown.sourceIndex(in: storage, displayIndex: textView.selectedRange().location)
            restyle(textView, source: source, caretSource: caret)
        }

        /// The selection before the last change of it — which way a caret
        /// stepped (`NoteTextView.settledCaret`).
        private var lastSelection = NSRange(location: 0, length: 0)

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView else { return }
            let previous = lastSelection
            lastSelection = textView.selectedRange()
            guard !textView.hasMarkedText(), !isRestyling else { return }
            updateMathPreview(in: textView)
            updateSelectionToolbar(in: textView)
            // Never rebuild the text under a selection: that is what made a
            // drag let go of what it had just selected.
            guard textView.selectedRange().length == 0, !textView.isSelectingByHand else {
                lastCaretLine = (textView.string as NSString)
                    .lineRange(for: textView.selectedRange())
                return
            }
            textView.typingAttributes = textView.codeTypingAttributes() ?? NoteMarkdown.bodyAttributes
            // A caret at the start of a list's line or inside its drawn
            // marker goes to the words after it — or, stepping left from
            // them, on to the line above: nothing is typed into a bullet.
            if let storage = textView.textStorage, storage.length > 0 {
                let caret = textView.selectedRange().location
                var run = NSRange()
                if let settled = textView.settledCaret(caret, previous: previous.length == 0 ? previous.location : nil) {
                    textView.setSelectedRange(NSRange(location: settled, length: 0))
                    return
                }
                // A caret set down after the folded children of a toggle
                // goes before them: typed there, the words would land after
                // the last line nobody can see.
                if caret > 0, caret <= storage.length,
                   storage.attribute(.paperTimeFolded, at: caret - 1, longestEffectiveRange: &run,
                                     in: NSRange(location: 0, length: storage.length)) != nil {
                    textView.setSelectedRange(NSRange(location: run.location, length: 0))
                    return
                }
            }
            let line = (textView.string as NSString).lineRange(for: textView.selectedRange())
            guard line != lastCaretLine else { return }
            caretFoldKey = nil
            carryFoldKey(in: textView)
            scheduleRestyle(in: textView)
        }

        /// Sets the text on the next turn of the run loop, once, however many
        /// times it was asked for in this one. Doing it inside a text view
        /// callback would mean replacing the storage while the layout is being
        /// worked out, which walks over TextKit's own state.
        func scheduleRestyle(in textView: NoteTextView) {
            guard !restyleIsScheduled, !isRestyling else { return }
            restyleIsScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, let storage = textView.textStorage else { return }
                self.restyleIsScheduled = false
                guard !textView.hasMarkedText(),
                      textView.selectedRange().length == 0,
                      !textView.isSelectingByHand
                else { return }
                let source = NoteMarkdown.markdown(from: storage)
                let caret = NoteMarkdown.sourceIndex(
                    in: storage, displayIndex: textView.selectedRange().location
                )
                // The line under the caret is shown exactly as it is written —
                // that is what makes a rendered note editable — so while the
                // typing stays on one line there is nothing to set again. It
                // used to set the whole note on every keystroke: a note of
                // thirty thousand characters was sixty milliseconds a letter,
                // and the words arrived behind the fingers. Anything that
                // changes the shape of the note — a line more, a line fewer,
                // the caret moving to another line — still sets it.
                // And a marker arriving or going on that line — "- " typed
                // at its start is a bullet at once, as it is in Notion.
                let shape = Self.shape(of: source, caret: caret)
                if shape.lines == self.setLineCount, shape.line == self.setCaretLine, shape.marker == self.setCaretMarker {
                    return
                }
                self.remember(shape)
                self.restyle(textView, source: source, caretSource: caret)
                // The caret is where it was in the note, at another place on
                // screen: the words being typed go on being one step.
                if self.typing != nil { self.typing?.caret = textView.selectedRange().location }
            }
        }

        /// Which line the caret was on, and how many lines there were, when
        /// the note was last set — see `scheduleRestyle`. (`lastCaretLine`
        /// above is a different thing: the *range* of the line, kept so a
        /// click that stays on one line does not set the note again.)
        private var setCaretLine = -1
        private var setLineCount = -1
        private var setCaretMarker = ""

        /// How many lines the note has, which one the caret is on, and that
        /// line's marker — what decides whether it has to be set again.
        static func shape(of source: String, caret: Int) -> (lines: Int, line: Int, marker: String) {
            let lines = source.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
            let line = source.utf16.prefix(caret).reduce(into: 0) { count, unit in
                if unit == 10 { count += 1 }
            }
            // Where the fences are is part of the shape: a third backtick
            // typed on a line makes every line under it code.
            let fences = NoteCode.blocks(in: source).map { "\($0.open.location),\($0.close?.location ?? -1)" }
                .joined(separator: ";")
            return (lines, line, marker(ofLineAt: caret, in: source) + "|" + fences)
        }

        private func remember(_ shape: (lines: Int, line: Int, marker: String)) {
            setLineCount = shape.lines
            setCaretLine = shape.line
            setCaretMarker = shape.marker
        }

        /// The marker of the line a source offset is on, as written.
        static func marker(ofLineAt caret: Int, in source: String) -> String {
            let text = source as NSString
            let bounded = min(max(caret, 0), text.length)
            let line = text.lineRange(for: NSRange(location: bounded, length: 0))
            return NoteMarkdown.Block(line: text.substring(with: line).trimmingCharacters(in: .newlines)).marker
        }

        func restyle(_ textView: NoteTextView, source: String, caretSource: Int?, selection: NSRange? = nil) {
            guard !isRestyling else { return }
            if caretSource == nil { setCaretLine = -1; setLineCount = -1; setCaretMarker = "" }
            isRestyling = true
            defer { isRestyling = false }

            let rendered = Trace.time("note: set the whole note again") {
                NoteMarkdown.render(
                    source, caret: caretSource, raw: showsRawText, width: room(in: textView),
                    appearance: textView.effectiveAppearance, collapsed: collapsedToggles
                )
            }
            lastKnownWidth = room(in: textView)
            let caret = caretSource.map { rendered.displayIndex(forSource: $0) }
            // Whether the caret was in sight before: typing keeps it there,
            // and a note scrolled away from the caret by hand stays put.
            let caretWasShown = caretIsShown(in: textView)
            setContents(rendered.text, in: textView)
            if let caret {
                var range = NSRange(location: min(max(caret, 0), textView.string.utf16.count), length: 0)
                // A selection put back by ⌘Z: on the caret's line, which is
                // shown as written, so its two ends are the same characters.
                if let selection, selection.length > 0 {
                    let end = min(rendered.displayIndex(forSource: NSMaxRange(selection)), textView.string.utf16.count)
                    range.length = max(0, end - range.location)
                } else if let settled = textView.settledCaret(range.location) {
                    // A caret at a list line's start, which the source
                    // allows, rests at its words on screen.
                    range.location = settled
                }
                textView.setSelectedRange(range)
                if caretWasShown { textView.scrollRangeToVisible(range) }
            }
            // In a block of code, what is typed is code: set as the line it
            // goes into, or the next Return would not know it is in one.
            textView.typingAttributes = showsRawText
                ? NoteMarkdown.rawAttributes : (textView.codeTypingAttributes() ?? NoteMarkdown.bodyAttributes)
            lastCaretLine = (textView.string as NSString).lineRange(for: textView.selectedRange())
        }

        @objc func textViewFrameChanged(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView else { return }
            // After the resize settles, not during it.
            NSObject.cancelPreviousPerformRequests(
                withTarget: self, selector: #selector(applyWidthChange(_:)), object: textView
            )
            perform(#selector(applyWidthChange(_:)), with: textView, afterDelay: 0.12)
        }

        @objc private func applyWidthChange(_ textView: NoteTextView) {
            widthChanged(textView)
        }

        /// The room a line of the note has: the pane, less the margins the
        /// text is set inside. A formula is laid out to fit it.
        func room(in textView: NSTextView) -> CGFloat? {
            guard let container = textView.textContainer else { return nil }
            let width = textView.bounds.width
                - textView.textContainerInset.width * 2
                - container.lineFragmentPadding * 2
            return width > 80 ? width : nil
        }

        /// The pane has been resized: formulas laid out for the old width are
        /// either running off the edge or leaving room unused, so they are set
        /// again. Only a real change counts — dragging a divider sends this
        /// many times a second.
        func widthChanged(_ textView: NoteTextView) {
            guard !isRestyling else { return }
            // A new width throws away every measured line, and TextKit 2 then
            // guesses the height of all but the ones on screen — a note of
            // 29,000 pt opened as 16,981, and the first Return in its middle
            // moved the view 280 pt. So the note is measured whole once the
            // width has settled, with the line at the top kept at the top.
            if let width = room(in: textView), width != lastMeasuredWidth {
                lastMeasuredWidth = width
                measureWhole(textView)
            }
            guard !showsRawText else { return }
            let now = room(in: textView)
            guard let now, let before = lastKnownWidth else {
                lastKnownWidth = now
                return
            }
            guard abs(now - before) >= 8 else { return }
            lastKnownWidth = now
            guard let storage = textView.textLayoutManager?.textContentManager
                as? NSTextContentStorage, let text = storage.textStorage else { return }
            // Nothing to redraw if the note has no formulas in it.
            var hasMath = false
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) {
                value, _, stop in
                if value != nil { hasMath = true; stop.pointee = true }
            }
            guard hasMath else { return }
            let source = NoteMarkdown.markdown(from: text)
            let caret = NoteMarkdown.sourceIndex(
                in: text, displayIndex: textView.selectedRange().location
            )
            restyle(textView, source: source, caretSource: caret)
        }

        /// Replaces what is on screen, through the content storage's own
        /// transaction: the text view is backed by TextKit 2, which lays out
        /// nothing when its storage is changed behind its back.
        ///
        /// Only the lines that came out differently are replaced. TextKit 2
        /// lays out only what is on screen and *guesses* the height of the
        /// rest; replacing the whole storage threw every measured line away,
        /// so each Return, each line joined, set the note on guesses — its
        /// height went 2298 → 2010 → 1826 → 1940 pt over five keys, and the
        /// view jumped by as much (705 pt on one Return), putting the caret
        /// out of sight while somebody typed. Laying the whole note out again
        /// instead cured it but cost 55 ms a Return on a note of 30,000
        /// characters. Replacing the changed lines keeps every other line's
        /// measured height, and the replaced ones are measured at once.
        /// The first time (an empty view) is the whole note, measured whole
        /// once the view has its width.
        func setContents(_ attributed: NSAttributedString, in textView: NSTextView) {
            guard let content = textView.textLayoutManager?.textContentManager as? NSTextContentStorage,
                  let storage = content.textStorage, let layout = textView.textLayoutManager
            else {
                textView.textStorage?.setAttributedString(attributed)
                textView.needsDisplay = true
                return
            }
            let clip = textView.enclosingScrollView?.contentView
            let change = Self.changedLines(from: storage, to: attributed)
            guard let change else { return }
            // What stood above the top of the view before, so a line that
            // changed height up there does not move what is being read.
            let top = clip?.bounds.origin.y ?? 0
            let oldFrame = frame(of: change.old, in: layout, content: content)
            let heightBefore = textView.frame.height
            let wasFirst = storage.length == 0
            content.performEditingTransaction {
                storage.replaceCharacters(in: change.old, with: attributed.attributedSubstring(from: change.new))
            }
            Trace.time("note: lay out the lines that changed") {
                if wasFirst {
                    // Measured whole once it has a width (`widthChanged`);
                    // laid out now, at no width, it would be measured twice.
                    if room(in: textView) != nil { layout.ensureLayout(for: layout.documentRange) }
                } else if let range = textRange(change.new, content: content) {
                    layout.ensureLayout(for: range)
                }
                layout.textViewportLayoutController.layoutViewport()
            }
            if let clip, let oldFrame, oldFrame.maxY <= top, !wasFirst {
                let moved = textView.frame.height - heightBefore
                if moved != 0 {
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, top + moved)))
                    textView.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
            textView.needsDisplay = true
        }

        /// The lines to replace, in the note on screen and in the new one:
        /// everything between the first line that differs and the last.
        /// Nil when nothing differs.
        static func changedLines(from old: NSAttributedString, to new: NSAttributedString) -> (old: NSRange, new: NSRange)? {
            let oldText = old.string as NSString, newText = new.string as NSString
            // From the front, line by line, while the lines are the same —
            // their words and how they are set.
            var head = 0
            while head < oldText.length, head < newText.length {
                let a = oldText.paragraphRange(for: NSRange(location: head, length: 0))
                let b = newText.paragraphRange(for: NSRange(location: head, length: 0))
                guard a == b, old.attributedSubstring(from: a).isEqual(to: new.attributedSubstring(from: b)) else { break }
                head = NSMaxRange(a)
            }
            // From the back, the same, never past the front.
            var oldEnd = oldText.length, newEnd = newText.length
            while oldEnd > head, newEnd > head {
                let a = oldText.paragraphRange(for: NSRange(location: oldEnd - 1, length: 0))
                let b = newText.paragraphRange(for: NSRange(location: newEnd - 1, length: 0))
                guard a.length == b.length, a.location >= head, b.location >= head,
                      old.attributedSubstring(from: a).isEqual(to: new.attributedSubstring(from: b)) else { break }
                oldEnd = a.location
                newEnd = b.location
            }
            let oldRange = NSRange(location: head, length: oldEnd - head)
            let newRange = NSRange(location: head, length: newEnd - head)
            if oldRange.length == 0, newRange.length == 0 { return nil }
            return (oldRange, newRange)
        }

        private func textRange(_ range: NSRange, content: NSTextContentStorage) -> NSTextRange? {
            guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }

        /// Where these lines are drawn now, if they are laid out.
        private func frame(of range: NSRange, in layout: NSTextLayoutManager, content: NSTextContentStorage) -> CGRect? {
            guard let text = textRange(range, content: content) else { return nil }
            var frame: CGRect?
            layout.enumerateTextLayoutFragments(from: text.location, options: [.ensuresLayout]) { fragment in
                frame = frame.map { $0.union(fragment.layoutFragmentFrame) } ?? fragment.layoutFragmentFrame
                return fragment.rangeInElement.endLocation.compare(text.endLocation) == .orderedAscending
            }
            return frame
        }

        /// The width the note was last measured whole at.
        private var lastMeasuredWidth: CGFloat?

        /// Lays out every line, keeping the line at the top of the view where
        /// it is on screen.
        func measureWhole(_ textView: NSTextView) {
            guard let layout = textView.textLayoutManager,
                  let clip = textView.enclosingScrollView?.contentView else { return }
            let top = clip.bounds.origin.y - textView.textContainerOrigin.y
            var anchor: (location: NSTextLocation, offset: CGFloat)?
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
                let frame = fragment.layoutFragmentFrame
                if frame.maxY > top {
                    anchor = (fragment.rangeInElement.location, top - frame.minY)
                    return false
                }
                return true
            }
            Trace.time("note: measure the whole note") {
                layout.ensureLayout(for: layout.documentRange)
                layout.textViewportLayoutController.layoutViewport()
            }
            guard let anchor, let fragment = layout.textLayoutFragment(for: anchor.location) else { return }
            let y = fragment.layoutFragmentFrame.minY + anchor.offset + textView.textContainerOrigin.y
            let highest = max(0, textView.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, y), highest)))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        /// Whether the caret's line is inside the part of the note on screen.
        func caretIsShown(in textView: NSTextView) -> Bool {
            guard let clip = textView.enclosingScrollView?.contentView,
                  let layout = textView.textLayoutManager, let content = layout.textContentManager,
                  let location = content.location(content.documentRange.location, offsetBy: textView.selectedRange().location)
            else { return true }
            var frame: CGRect?
            layout.enumerateTextSegments(in: NSTextRange(location: location), type: .selection, options: []) { _, rect, _, _ in
                frame = rect
                return false
            }
            guard let frame else { return true }
            let line = frame.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let visible = clip.bounds
            return line.maxY >= visible.minY && line.minY <= visible.maxY
        }

        // MARK: Links

        func textView(_ view: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if let id = NoteMarkdown.noteID(from: url) {
                onOpenNote(id)
                return true
            }
            guard var anchor = NoteAnchor(url: url) else { return false }
            anchor.quotedText = view.attributedString()
                .attributedSubstring(from: rangeOfLink(at: index, in: view)).string
            onFollow(anchor)
            return true
        }

        private func rangeOfLink(at index: Int, in view: NSTextView) -> NSRange {
            var effective = NSRange(location: index, length: 0)
            _ = view.attributedString().attribute(
                .link, at: index, longestEffectiveRange: &effective,
                in: NSRange(location: 0, length: view.attributedString().length)
            )
            return effective
        }

        /// Drops a link where the cursor is, the way an editor inserts a
        /// citation: the writing carries on from there.
        /// Drops the passage in as a quotation of its own.
        ///
        /// Written into the Markdown rather than typed into the display: a
        /// quotation is two lines and a blank one, and insertions into the
        /// rendered text have to be mapped back through markers that are not
        /// there — a mapping that is exactly right for a word and exactly
        /// wrong for a block. Editing the source and re-rendering it is one
        /// step, and what lands is what the file will hold.
        func insert(_ anchor: NoteAnchor, into textView: NoteTextView) {
            guard let storage = textView.textStorage else { return }
            let source = NoteMarkdown.markdown(from: storage) as NSString
            let caret = min(
                NoteMarkdown.sourceIndex(
                    in: storage, displayIndex: textView.selectedRange().location
                ),
                source.length
            )
            var head = source.substring(to: caret)
            let tail = source.substring(from: caret)
            // A quotation starts its own line, and leaves one behind it to go
            // on writing in.
            if !head.isEmpty, !head.hasSuffix("\n") { head += "\n" }
            let block = NoteMarkdown.quotationSource(for: anchor)
            let after = tail.hasPrefix("\n") ? "" : "\n"
            let updated = head + block + after + tail

            registerStep(named: L("인용 넣기", "Insert Quotation"), in: textView)
            lastKnownMarkdown = updated
            markdown = updated
            restyle(textView, source: updated,
                    caretSource: (head + block + after).utf16.count)
            textView.window?.makeFirstResponder(textView)
        }

        // MARK: Undo, in the Markdown

        /// The note as it was, for ⌘Z: its Markdown, and the selection in it.
        struct Snapshot {
            var source: String
            var selection: NSRange
        }

        /// The step being typed. Characters typed one after another at the
        /// caret — or taken back beside it — are one ⌘Z, as in any Mac text
        /// view; `caret` is where the next keystroke has to land to join it.
        struct Typing { var caret: Int }
        var typing: Typing?
        /// A syllable is being composed (`willEdit`).
        private var composing = false
        /// While ⌘Z or ⇧⌘Z puts a note back.
        private var isRestoring = false
        /// What the Edit menu calls the next step, when it is not typing —
        /// set by a command for the edits it makes.
        var nextStepName: String?

        /// A change is about to land on screen. If it starts a step, the note
        /// as it is now goes on the undo stack — as Markdown, so it means the
        /// same thing after the note has set its lines again. The text view's
        /// own undo was in screen offsets: ⌘B on the line being written, the
        /// caret moved off it (the stars go out of sight, the line is
        /// shorter), and ⌘Z took two characters from the wrong place.
        func willEdit(_ ranges: [NSRange], strings: [String]?, in textView: NoteTextView) {
            if Self.tracesUndo {
                FileHandle.standardError.write(Data("undo: will edit \(ranges) \((strings ?? []).map(\.debugDescription)) marked \(textView.hasMarkedText()) typing \(typing.map { "\($0.caret)" } ?? "-") registration \(textView.stepUndoManager?.isUndoRegistrationEnabled ?? false)\n".utf8))
            }
            guard !isRestyling, !isRestoring,
                  let manager = textView.stepUndoManager, !manager.isUndoing, !manager.isRedoing
            else { return }
            // Latex Suite lands its own steps, already in the Markdown, with
            // registration switched off while it does.
            guard manager.isUndoRegistrationEnabled else { typing = nil; composing = false; return }
            if textView.hasMarkedText() {
                // Hangul being put together: the text view marks it before it
                // asks, so the first jamo of a syllable already reads as
                // marked. That first change starts the step or joins the one
                // being typed; the rest of the syllable belongs to it.
                guard !composing else { return }
                composing = true
                if let typing, Self.continues(typing, ranges) { return }
                registerStep(named: nextStepName ?? L("입력", "Typing"), in: textView)
                typing = Typing(caret: -1)
                return
            }
            if composing {
                // The syllable put in for good — the marked text replaced by
                // what it spelled, which reads as a replacement, not a
                // keystroke. Still the same step: one ⌘Z took one syllable.
                composing = false
                if typing == nil { typing = Typing(caret: -1) }
                return
            }
            let keystroke = Self.isKeystroke(ranges, strings: strings)
            if keystroke, let typing, Self.continues(typing, ranges) { return }
            registerStep(named: nextStepName ?? (keystroke ? L("입력", "Typing") : L("편집", "Edit")), in: textView)
            typing = keystroke ? Typing(caret: -1) : nil
        }

        /// The text has changed: the step being typed goes on from the caret.
        func didEdit(in textView: NoteTextView) {
            guard typing != nil else { return }
            typing?.caret = textView.selectedRange().location
        }

        /// The next change starts a step of its own.
        func endTyping() { typing = nil }

        /// `PAPERTIME_UNDO_TRACE=1`: every edit the note sees, and every step
        /// it puts on the stack, on stderr.
        static let tracesUndo = Boot.isSet("PAPERTIME_UNDO_TRACE")

        /// Puts the note as it is now on the undo stack, as one step.
        func registerStep(named name: String, in textView: NoteTextView) {
            guard let manager = textView.stepUndoManager, manager.isUndoRegistrationEnabled else { return }
            let before = Snapshot(source: lastKnownMarkdown, selection: sourceSelection(in: textView))
            if Self.tracesUndo {
                FileHandle.standardError.write(Data("undo: step “\(name)” back to \(before.source.debugDescription) at \(before.selection)\n".utf8))
            }
            manager.registerUndo(withTarget: self) { [weak textView] coordinator in
                MainActor.assumeIsolated {
                    guard let textView else { return }
                    coordinator.restore(before, in: textView)
                }
            }
            manager.setActionName(name)
            typing = nil
        }

        /// ⌘Z, and ⇧⌘Z: the note as it was, set again, with the selection it
        /// had — and the note as it is now goes on the other stack. Through
        /// the binding as well as the screen: under TextKit 2 the text view's
        /// undo changed the screen without a word to the delegate, so the
        /// note kept what had been undone and put it back at the next save.
        func restore(_ snapshot: Snapshot, in textView: NoteTextView) {
            guard let manager = textView.stepUndoManager else { return }
            let now = Snapshot(source: lastKnownMarkdown, selection: sourceSelection(in: textView))
            manager.registerUndo(withTarget: self) { [weak textView] coordinator in
                MainActor.assumeIsolated {
                    guard let textView else { return }
                    coordinator.restore(now, in: textView)
                }
            }
            isRestoring = true
            defer { isRestoring = false }
            typing = nil
            composing = false
            let source = snapshot.source as NSString
            let start = min(snapshot.selection.location, source.length)
            let selection = NSRange(location: start,
                                    length: max(0, min(NSMaxRange(snapshot.selection), source.length) - start))
            lastKnownMarkdown = snapshot.source
            markdown = snapshot.source
            remember(Self.shape(of: snapshot.source, caret: start))
            restyle(textView, source: snapshot.source, caretSource: start, selection: selection)
            lastCaretLine = (textView.string as NSString)
                .lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
            textView.latexSuite.dropPlaceholders(in: textView)
            updateMathPreview(in: textView)
            updateSelectionToolbar(in: textView)
        }

        /// The note was replaced from elsewhere: nothing on the undo stack is
        /// about it any more, and undone it would put the old one back.
        func forgetUndo(in textView: NoteTextView) {
            typing = nil
            composing = false
            textView.stepUndoManager?.removeAllActions(withTarget: self)
            textView.stepUndoManager?.removeAllActions(withTarget: textView)
        }

        /// The selection, in the Markdown.
        private func sourceSelection(in textView: NSTextView) -> NSRange {
            guard let storage = textView.textStorage else { return NSRange(location: 0, length: 0) }
            let shown = textView.selectedRange()
            let start = NoteMarkdown.sourceIndex(in: storage, displayIndex: shown.location)
            guard shown.length > 0 else { return NSRange(location: start, length: 0) }
            let end = NoteMarkdown.sourceIndex(in: storage, displayIndex: NSMaxRange(shown))
            return NSRange(location: start, length: max(0, end - start))
        }

        /// One character typed with nothing selected, or one taken away.
        static func isKeystroke(_ ranges: [NSRange], strings: [String]?) -> Bool {
            guard ranges.count == 1, let range = ranges.first, let strings, strings.count == 1 else { return false }
            let length = (strings[0] as NSString).length
            if range.length == 0 { return length > 0 && length <= 2 }
            return length == 0 && range.length <= 2
        }

        /// Whether a keystroke lands where the step being typed left off:
        /// typed at the caret, taken back from before it, deleted after it.
        static func continues(_ typing: Typing, _ ranges: [NSRange]) -> Bool {
            guard let range = ranges.first, typing.caret >= 0 else { return false }
            return range.location == typing.caret || NSMaxRange(range) == typing.caret
        }

        // MARK: The formula being typed

        /// Shows the set formula under the caret's line, a moment after the
        /// keystroke — 80 ms, so a word typed at speed sets once, not once a
        /// letter — and takes it away when the caret leaves the formula or
        /// the note loses the keyboard.
        func updateMathPreview(in textView: NoteTextView, now: Bool = false) {
            mathPreviewWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.placeMathPreview(in: textView)
            }
            mathPreviewWork = work
            if now {
                work.perform()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
        }

        private func placeMathPreview(in textView: NoteTextView) {
            // In code a `$` is a dollar.
            guard textView.codeRowAtCaret() == nil else { return mathPreview.hide() }
            guard let storage = textView.textStorage, let window = textView.window,
                  window.firstResponder === textView,
                  textView.selectedRange().length == 0, !textView.hasMarkedText(),
                  !showsRawText
            else { return mathPreview.hide() }
            let source = NoteMarkdown.markdown(from: storage)
            let caret = NoteMarkdown.sourceIndex(in: storage, displayIndex: textView.selectedRange().location)
            guard let span = NoteMath.span(at: caret, in: source) else { return mathPreview.hide() }

            // The line is the caret's, shown as written, so its source and
            // its display are the same characters — but the rest of the
            // note is not, and the offsets are mapped rather than assumed.
            let display = LatexSuiteDisplay(storage)
            let start = display.displayOffset(forSource: span.range.location)
            let end = display.displayOffset(forSource: span.range.location + span.range.length)
            guard end > start else { return mathPreview.hide() }
            let first = textView.firstRect(forCharacterRange: NSRange(location: start, length: 1), actualRange: nil)
            let last = textView.firstRect(forCharacterRange: NSRange(location: end - 1, length: 1), actualRange: nil)
            guard first.isFinite, last.isFinite, first.width + first.height > 0 else { return mathPreview.hide() }

            let visible = textView.enclosingScrollView?.documentVisibleRect ?? textView.bounds
            let bounds = window.convertToScreen(textView.convert(visible, to: nil))
            mathPreview.show(span, startX: first.minX, line: last, bounds: bounds, in: textView)
        }

        // MARK: Completions

        /// The text between the `[[` that is open on this line and the caret.
        func openWikiLink(in textView: NoteTextView) -> (range: NSRange, query: String)? {
            let text = textView.string as NSString
            let caret = textView.selectedRange()
            guard caret.length == 0, caret.location <= text.length else { return nil }
            let line = text.lineRange(for: caret)
            let before = text.substring(with: NSRange(location: line.location,
                                                      length: caret.location - line.location))
            guard let opened = before.range(of: "[[", options: .backwards) else { return nil }
            let query = String(before[opened.upperBound...])
            guard !query.contains("]]"), !query.contains("\n") else { return nil }
            let start = line.location + before.distance(from: before.startIndex,
                                                        to: opened.lowerBound)
            return (NSRange(location: start, length: caret.location - start), query)
        }

        func updateCompletions(in textView: NoteTextView) {
            guard textView.codeRowAtCaret() == nil, let open = openWikiLink(in: textView) else { return completions.hide() }
            let matches = suggestions(open.query).map {
                WikiLinkPopover.Match(id: $0.id, title: $0.title, subtitle: $0.subtitle)
            }
            guard !matches.isEmpty else { return completions.hide() }
            let caretRect = textView.firstRect(
                forCharacterRange: textView.selectedRange(), actualRange: nil
            )
            let local = textView.window?.convertFromScreen(caretRect) ?? .zero
            completions.show(
                matches: matches,
                below: textView.convert(local, from: nil),
                in: textView
            ) { [weak self, weak textView] match in
                guard let self, let textView else { return }
                self.accept(match, in: textView)
            }
        }

        /// Puts the chosen note in as a link, identifier and all: the file
        /// keeps the identifier, which does not change when a title does.
        func accept(_ match: WikiLinkPopover.Match, in textView: NoteTextView) {
            guard let open = openWikiLink(in: textView) else { return }
            let text = textView.string as NSString
            var range = open.range
            // Swallow a closing "]]" that was typed or auto-inserted.
            let after = range.location + range.length
            if after + 2 <= text.length,
               text.substring(with: NSRange(location: after, length: 2)) == "]]" {
                range.length += 2
            }
            textView.insertText("[[\(match.id)|\(match.title)]]", replacementRange: range)
            completions.hide()
            if let storage = textView.textStorage {
                let source = NoteMarkdown.markdown(from: storage)
                lastKnownMarkdown = source
                markdown = source
                let caret = NoteMarkdown.sourceIndex(
                    in: storage, displayIndex: textView.selectedRange().location
                )
                restyle(textView, source: source, caretSource: caret)
            }
        }
    }
}

/// The text view itself: everything that has to happen at the moment a key is
/// pressed rather than after the text has already changed.
final class NoteTextView: LatexSuiteTextView {
    weak var coordinator: NoteEditor.Coordinator?
    /// True while the mouse is down and dragging out a selection.
    private(set) var isSelectingByHand = false

    /// Setting the note again replaces every character and then puts the
    /// caret back. In between, the selection is wherever TextKit left it, and
    /// Latex Suite is not to read that as a step out of its placeholders.
    override var isSettingText: Bool { coordinator?.isRestyling ?? false }

    // MARK: Undo

    /// The window's stack. The text view's own undo is off (`allowsUndo`),
    /// which also makes `undoManager` answer nil — and lending it the
    /// window's turns the text view's registration back on (measured).
    override var stepUndoManager: UndoManager? { window?.undoManager }

    /// Every change goes past the coordinator first, which keeps the undo
    /// stack in the Markdown (`Coordinator.willEdit`).
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else { return false }
        coordinator?.willEdit(affectedRanges.map(\.rangeValue), strings: replacementStrings, in: self)
        return true
    }

    /// What breaks the text view's typing into steps breaks the
    /// coordinator's too — Latex Suite's snippets ask for it.
    override func breakUndoCoalescing() {
        super.breakUndoCoalescing()
        coordinator?.endTyping()
    }

    // MARK: Copying

    /// Copying gives back Markdown — `$x^2$` rather than a picture of x², and
    /// `[[id|title]]` rather than the title on its own — so what is copied can
    /// be pasted anywhere and still say what it said here.
    override func copy(_ sender: Any?) {
        guard writeMarkdownToPasteboard() else { return super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        guard writeMarkdownToPasteboard() else { return super.cut(sender) }
        insertText("", replacementRange: selectedRange())
    }

    // MARK: Pasting

    /// A table pasted from ChatGPT or Obsidian arrives as HTML, and as its
    /// words one cell to a line — pasted as it was, that is what the note
    /// got. Here it becomes the Markdown table it stands for (`NoteTable`),
    /// on lines of its own, and the note draws it as a grid. Rows of
    /// tab-separated cells — a spreadsheet's — do the same. Anything else
    /// pastes as before.
    override func paste(_ sender: Any?) {
        guard pasteTable(from: .general) else { return super.paste(sender) }
    }

    /// Pastes the table on this pasteboard; false when there is none. A probe
    /// hands it a pasteboard of its own, never the one people copy to.
    @discardableResult
    func pasteTable(from pasteboard: NSPasteboard) -> Bool {
        guard let table = Self.pastedTable(from: pasteboard) else { return false }
        let text = string as NSString
        let range = selectedRange()
        // A blank line on either side: a table is read until the first line
        // without a bar, so one pasted under another would join it.
        let newline: unichar = 10
        let before = range.location > 0 ? text.character(at: range.location - 1) : newline
        let beforeThat = range.location > 1 ? text.character(at: range.location - 2) : newline
        let atEnd = NSMaxRange(range) >= text.length
        let after = atEnd ? newline : text.character(at: NSMaxRange(range))
        let lead = range.location == 0 ? "" : before != newline ? "\n\n" : beforeThat != newline ? "\n" : ""
        let tail = atEnd ? "\n" : after != newline ? "\n\n" : "\n"
        let block = lead + table + tail
        breakUndoCoalescing()
        insertText(block, replacementRange: range)
        breakUndoCoalescing()
        return true
    }

    /// What a paste would put in the note as a table, if it is one.
    static func pastedTable(from pasteboard: NSPasteboard) -> String? {
        if let html = pasteboard.string(forType: .html), let markdown = NoteTable.fromHTML(html) {
            return markdown
        }
        if let plain = pasteboard.string(forType: .string), let markdown = NoteTable.fromTabSeparated(plain) {
            return markdown
        }
        return nil
    }

    private func writeMarkdownToPasteboard() -> Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        let piece = attributedString().attributedSubstring(from: range)
        let markdown = NoteMarkdown.markdown(from: piece)
        guard !markdown.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        return true
    }

    // MARK: Hovering

    /// Draws the glow over the chip under the pointer. Owned by the scroll
    /// view; this only tells it where.
    weak var chipHoverView: ChipHoverView?
    private var hoveredChip: NSRange?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredChip(chipRange(at: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredChip(nil)
    }

    @objc func scrolled() {
        setHoveredChip(nil)
        // The card is placed under a line; when the line moves, it follows.
        if let coordinator, coordinator.mathPreview.isShowing {
            coordinator.updateMathPreview(in: self, now: true)
        }
        coordinator?.updateSelectionToolbar(in: self)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.mathPreview.hide(); coordinator?.selectionToolbar.hide() }
        return resigned
    }

    /// A note put away does not always resign: the view is simply taken
    /// out of the window. The card must not stay behind.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // The note's steps go with the editor, as Latex Suite's do: left on
        // the window's stack they would be ⌘Zs that do nothing.
        if newWindow == nil, window != nil, let coordinator { stepUndoManager?.removeAllActions(withTarget: coordinator) }
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { coordinator?.mathPreview.hide(); coordinator?.selectionToolbar.hide() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        coordinator?.mathPreview.hide()
        coordinator?.selectionToolbar.hide()
    }

    /// The whole chip under the pointer, in document offsets — and only when
    /// the pointer is on its letters. `characterIndexForInsertion` snaps to
    /// the nearest gap, so a pointer in the margin beside a chip would
    /// otherwise count as on it.
    private func chipRange(at event: NSEvent) -> NSRange? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = attributedString()
        guard index >= 0, index < text.length else { return nil }
        var range = NSRange()
        guard text.attribute(NoteChip.attribute, at: index, longestEffectiveRange: &range,
                             in: NSRange(location: 0, length: text.length)) != nil
        else { return nil }
        return chipRects(range).contains { $0.contains(point) } ? range : nil
    }

    /// The boxes a chip occupies, one per line, in this view's coordinates.
    private func chipRects(_ range: NSRange) -> [CGRect] {
        guard let layout = textLayoutManager,
              let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let span = NSTextRange(location: start, end: end)
        else { return [] }
        var rects: [CGRect] = []
        layout.enumerateTextSegments(in: span, type: .standard, options: []) { _, frame, _, _ in
            rects.append(
                frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                    .insetBy(dx: -NoteChip.padding.width, dy: -NoteChip.padding.height)
            )
            return true
        }
        return rects
    }

    private func setHoveredChip(_ range: NSRange?) {
        guard hoveredChip != range else { return }
        hoveredChip = range
        guard let chipHoverView else { return }
        guard let range else {
            chipHoverView.rects = []
            return
        }
        chipHoverView.rects = chipRects(range).map { convert($0, to: chipHoverView) }
    }

    // MARK: Selecting

    /// Follows the passage under the pointer, if there is one.
    private func followChip(at event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index >= 0, index < attributedString().length,
              let url = attributedString().attribute(
                  NoteChip.attribute, at: index, effectiveRange: nil
              ) as? URL
        else { return false }
        _ = coordinator?.textView(self, clickedOnLink: url, at: index)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // A chip is not a `.link`, so the click that follows it is ours to
        // notice. Anything else falls through to the ordinary text handling.
        if followChip(at: event) { return }
        if foldToggle(at: event) { return }
        if copyCode(at: convert(event.locationInWindow, from: nil), to: .general) { return }
        isSelectingByHand = true
        // NSTextView tracks the drag itself and returns when the mouse is let
        // go, so this brackets the whole gesture.
        super.mouseDown(with: event)
        isSelectingByHand = false
        if selectedRange().length == 0 {
            // The selection changed while the hand had it, and nothing
            // looked: a press on a marker leaves the caret beside it, and
            // what is typed next is the note's own, not the marker's.
            if let settled = settledCaret(selectedRange().location) {
                setSelectedRange(NSRange(location: settled, length: 0))
            }
            typingAttributes = codeTypingAttributes() ?? NoteMarkdown.bodyAttributes
        }
        if let coordinator, selectedRange().length == 0 {
            coordinator.scheduleRestyle(in: self)
        }
        coordinator?.updateSelectionToolbar(in: self)
    }

    /// What the probe sees of the bar over a selection.
    var probeToolbar: String {
        guard let coordinator else { return "no coordinator" }
        return coordinator.selectionToolbar.isShowing
            ? "showing \(coordinator.selectionToolbar.buttons)" : "hidden"
    }

    /// The stretches of the caret's line drawn in the syntax colour.
    /// Every run of the note set in bold, in italics or as code, with what
    /// it says: `굵게:b`, `기울여:i`, `x:c` — and the face the Hangul in it
    /// is drawn with, where a cascade would have drawn it.
    var probeEmphasis: [String] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        var found: [(text: String, marks: String)] = []
        var lastEnd = -1
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            guard let font = attributes[.font] as? NSFont else { return }
            var marks = ""
            let name = font.fontName
            let cascade = (font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])?.first?.postscriptName ?? ""
            if name.contains("Bold") || (font.textTransform.m21 != 0 && name.contains("Bold")) || cascade.contains("Bold") { marks += "b" }
            if NoteTypography.isItalic(font) { marks += "i" }
            if attributes[NoteCodeStyle.attribute] != nil { marks += "c" }
            guard !marks.isEmpty else { return }
            let text = (string as NSString).substring(with: range)
            // Runs that touch, joined: a Korean word in italics is several.
            if let last = found.last, last.marks == marks, lastEnd == range.location {
                found[found.count - 1].text += text
            } else {
                found.append((text, marks))
            }
            lastEnd = NSMaxRange(range)
        }
        return found.map { "\($0.text):\($0.marks)" }
    }

    var probeSyntax: [String] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let line = (string as NSString).lineRange(for: selectedRange())
        var found: [String] = []
        storage.enumerateAttribute(.foregroundColor, in: line) { value, range, _ in
            guard let colour = value as? NSColor, colour == NoteMarkdown.syntaxColor else { return }
            found.append((string as NSString).substring(with: range))
        }
        return found
    }

    /// Folds the toggle named `key` away, or back — the probe's click.
    func probeFold(_ key: String) {
        guard let coordinator else { return }
        coordinator.setFolded(key, !coordinator.collapsedToggles.contains(key), in: self)
    }

    /// A click on a toggle's marker folds its children away, or brings them
    /// back. The marker is the first glyph of the line, and a click lands
    /// on the gap before or after it.
    private func foldToggle(at event: NSEvent) -> Bool {
        guard let coordinator, !coordinator.showsRawText, event.clickCount == 1, let storage = textStorage,
              storage.length > 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        let lineStart = (string as NSString).lineRange(for: NSRange(location: index, length: 0)).location
        guard index <= lineStart + 1, lineStart < storage.length,
              let marker = storage.attribute(.paperTimeSource, at: lineStart, effectiveRange: nil) as? String
        else { return false }
        let block = NoteMarkdown.Block(line: marker)
        guard block.kind == .toggle, block.marker == marker else { return false }
        let line = (string as NSString).lineRange(for: NSRange(location: lineStart, length: 0))
        let source = NoteMarkdown.markdown(from: storage.attributedSubstring(from: line))
            .trimmingCharacters(in: .newlines)
        let key = NoteMarkdown.Block(line: String(source.prefix { $0 != "\n" })).toggleKey
        coordinator.setFolded(key, !coordinator.collapsedToggles.contains(key), in: self)
        return true
    }

    // MARK: The line under the caret, as it is written

    /// The line the caret is on: its range on screen, what it says in the
    /// Markdown (a list's marker is drawn as a bullet on screen and stands
    /// for "- " underneath), its block, and where its marker is on screen.
    private struct CaretLine {
        var display: NSRange
        var source: String
        var block: NoteMarkdown.Block
        /// The marker on screen — a drawn stand-in's run, or the marker as
        /// written — and where the words begin.
        var markerDisplay: NSRange
        var contentStart: Int { NSMaxRange(markerDisplay) }
    }

    private func caretLine() -> CaretLine? {
        // A line of fenced code has no marker, whatever it starts with:
        // `- x` in code is not a bullet to continue or take away.
        guard let storage = textStorage, codeRowAtCaret() == nil else { return nil }
        let text = string as NSString
        let display = text.lineRange(for: selectedRange())
        let shown = storage.attributedSubstring(from: display)
        let source = NoteMarkdown.markdown(from: shown).trimmingCharacters(in: .newlines)
        let block = NoteMarkdown.Block(line: source)
        var marker = NSRange(location: display.location, length: 0)
        if !block.marker.isEmpty {
            var effective = NSRange()
            if display.length > 0,
               let standing = storage.attribute(.paperTimeSource, at: display.location,
                                                 longestEffectiveRange: &effective, in: display) as? String,
               standing == block.marker {
                marker = effective
            } else {
                marker = NSRange(location: display.location, length: (block.marker as NSString).length)
            }
        }
        return CaretLine(display: display, source: source, block: block, markerDisplay: marker)
    }

    // MARK: Keys

    /// Return continues what the line was doing: another bullet, the next
    /// number, another empty checkbox — and an empty item ends the list, which
    /// is how every outliner behaves and how nobody has to think about it. An
    /// empty item nested in another steps out a level first, as Notion's
    /// does. What it does is `NoteList.newLine`, made in the Markdown as one
    /// step to undo (`applyListEdit`): it had been the text view's newline
    /// and then the next marker typed in, which the note's undo took for a
    /// keystroke and an edit — ⌘Z left a bare line, and «- » was short enough
    /// to count as typing, so a list of bullets went in one ⌘Z.
    override func insertNewline(_ sender: Any?) {
        if coordinator?.showsRawText != true, selectedRange().length == 0, let code = codeRowAtCaret() {
            return insertCodeNewline(code, sender: sender)
        }
        // A line at the left with no marker is a line break and nothing more,
        // found without reading the whole note back as Markdown — that is
        // most Returns.
        guard selectedRange().length == 0, let line = caretLine(),
              !line.block.marker.isEmpty || line.source.first == " " || line.source.first == "\t",
              let (source, selection) = sourceAndSelection(),
              let edit = NoteList.newLine(in: source, caret: selection.location, folded: caretIsOnFoldedToggle())
        else { return super.insertNewline(sender) }
        applyListEdit(edit, to: source, named: L("줄 바꿈", "New Line"))
    }

    /// Whether the caret's line is a toggle with its children folded away.
    private func caretIsOnFoldedToggle() -> Bool {
        guard let line = caretLine(), line.block.kind == .toggle else { return false }
        return foldedRun(in: line) != nil
    }

    /// The zero-width run at the end of a folded toggle's line that carries
    /// its children.
    private func foldedRun(in line: CaretLine) -> NSRange? {
        guard let storage = textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.paperTimeFolded, in: line.display) { value, range, stop in
            if value != nil { found = range; stop.pointee = true }
        }
        return found
    }

    /// Backspace at the start of an item's words steps the item out a level,
    /// and at the left edge makes it a plain line — the way to turn a bullet
    /// back into text when the "- " is drawn as a bullet (`NoteList.backspace`,
    /// one step to undo).
    override func deleteBackward(_ sender: Any?) {
        guard coordinator?.showsRawText != true, selectedRange().length == 0 else { return super.deleteBackward(sender) }
        let caret = selectedRange().location
        let text = string as NSString
        // Folded children just behind the caret — at the end of the toggle's
        // words, or at the start of the line after it — come back rather
        // than go: nothing is deleted unseen.
        if let storage = textStorage, caret > 0 {
            let behind = storage.attribute(.paperTimeFolded, at: caret - 1, effectiveRange: nil) != nil
                || (caret > 1 && text.substring(with: NSRange(location: caret - 1, length: 1)) == "\n"
                    && storage.attribute(.paperTimeFolded, at: caret - 2, effectiveRange: nil) != nil)
            if behind, let header = toggleHeader(before: caret), let coordinator {
                coordinator.setFolded(header, false, in: self)
                return
            }
        }
        // Between the two of an empty pair, both go.
        if caret > 0, caret < text.length {
            let before = text.substring(with: NSRange(location: caret - 1, length: 1))
            if Self.pairs[before] == text.substring(with: NSRange(location: caret, length: 1)) {
                insertText("", replacementRange: NSRange(location: caret - 1, length: 2))
                return
            }
        }
        // Only at the edge of a marker: every other Backspace is a
        // character's, and is not worth reading the note back for.
        guard let line = caretLine(), !line.block.marker.isEmpty, caret <= line.contentStart,
              let (source, selection) = sourceAndSelection(),
              let edit = NoteList.backspace(in: source, caret: selection.location)
        else { return super.deleteBackward(sender) }
        applyListEdit(edit, to: source, named: L("지우기", "Delete"))
    }

    /// Delete at the end of a line before a marked one takes the next line's
    /// words, not its marker (`NoteList.deleteForward`): «1. a» and «2. b»
    /// had become «1. a2. b».
    override func deleteForward(_ sender: Any?) {
        if coordinator?.showsRawText != true, selectedRange().length == 0, let storage = textStorage,
           selectedRange().location < storage.length,
           storage.attribute(.paperTimeFolded, at: selectedRange().location, effectiveRange: nil) != nil,
           let header = toggleHeader(before: selectedRange().location + 1), let coordinator {
            coordinator.setFolded(header, false, in: self)
            return
        }
        // Only at the end of a line.
        if selectedRange().length == 0, selectedRange().location < (string as NSString).length,
           (string as NSString).character(at: selectedRange().location) == 10,
           let (source, selection) = sourceAndSelection(),
           let edit = NoteList.deleteForward(in: source, caret: selection.location) {
            return applyListEdit(edit, to: source, named: L("지우기", "Delete"))
        }
        super.deleteForward(sender)
    }

    /// The key of the toggle whose line holds the display offset just
    /// before `index`.
    private func toggleHeader(before index: Int) -> String? {
        guard let storage = textStorage, index > 0 else { return nil }
        let line = (string as NSString).lineRange(for: NSRange(location: index - 1, length: 0))
        let source = NoteMarkdown.markdown(from: storage.attributedSubstring(from: line))
        let block = NoteMarkdown.Block(line: String(source.prefix { $0 != "\n" }))
        return block.kind == .toggle ? block.toggleKey : nil
    }

    // MARK: Home

    /// Where ⌘← (and Home) go on a line with a marker: to the start of the
    /// words first, and to the start of the line from there — past the
    /// marker only when asked twice, as Notion and Obsidian do. A caret on a
    /// list's line has only the first: its marker is drawn, and a caret
    /// before it was typed into as the line's words — «x- a», the item gone
    /// (`settledCaret`). A selection still reaches the line's start.
    private func homeTarget(extending: Bool) -> Int? {
        guard coordinator?.showsRawText != true, let line = caretLine(), !line.block.marker.isEmpty else { return nil }
        if line.block.isListItem, !extending { return line.contentStart }
        let head = selectedRange().location
        return head > line.contentStart ? line.contentStart : line.display.location
    }

    override func moveToLeftEndOfLine(_ sender: Any?) {
        guard let target = homeTarget(extending: false) else { return super.moveToLeftEndOfLine(sender) }
        setSelectedRange(NSRange(location: target, length: 0))
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        guard let target = homeTarget(extending: false) else { return super.moveToBeginningOfLine(sender) }
        setSelectedRange(NSRange(location: target, length: 0))
    }

    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        guard let target = homeTarget(extending: true) else { return super.moveToLeftEndOfLineAndModifySelection(sender) }
        let range = selectedRange()
        setSelectedRange(NSRange(location: target, length: NSMaxRange(range) - target))
    }

    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        guard let target = homeTarget(extending: true) else { return super.moveToBeginningOfLineAndModifySelection(sender) }
        let range = selectedRange()
        setSelectedRange(NSRange(location: target, length: NSMaxRange(range) - target))
    }

    /// Where a caret that has come to rest at the start of a list's line,
    /// or inside its drawn marker, goes: to the marker's words — or, when it
    /// got there stepping left from those words (`previous`, where it was),
    /// on to the end of the line above. Nil when it is anywhere else. There
    /// is nothing before or inside a drawn marker to type into: a press on
    /// the bullet's left half left the caret before it and what was typed
    /// went in front of the marker, «x- a»; on its right half the caret was
    /// between the bullet and its tab, and the marker was read twice,
    /// «- x- a». And ← at an item's words went into its marker and was put
    /// back where it started: it could not leave the line.
    func settledCaret(_ caret: Int, previous: Int? = nil) -> Int? {
        guard coordinator?.showsRawText != true, let storage = textStorage, caret < storage.length else { return nil }
        let lineStart = (string as NSString).lineRange(for: NSRange(location: caret, length: 0)).location
        var run = NSRange()
        guard let standing = storage.attribute(.paperTimeSource, at: lineStart, longestEffectiveRange: &run,
                                               in: NSRange(location: lineStart, length: storage.length - lineStart)) as? String
        else { return nil }
        let block = NoteMarkdown.Block(line: standing)
        guard block.isListItem, block.marker == standing, caret < NSMaxRange(run) else { return nil }
        let words = NSMaxRange(run)
        return previous == words && lineStart > 0 ? lineStart - 1 : words
    }

    /// Tab indents the item the caret is in rather than dropping a tab into
    /// the middle of a sentence.
    override func insertTab(_ sender: Any?) {
        if indentCode(by: 1) { return }
        guard shiftListItems(by: 1) else { return super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if indentCode(by: -1) { return }
        guard shiftListItems(by: -1) else { return super.insertBacktab(sender) }
    }

    // MARK: Fenced code

    /// What a code block's indent is: four spaces, as most code is written.
    static let codeIndent = "    "

    /// The row of a fenced block the caret's line is, read off the screen —
    /// every row carries what it is (`NoteCodeStyle.Block.attribute`).
    func codeRowAtCaret() -> (row: NoteCodeStyle.Block.Row, line: NSRange)? {
        guard coordinator?.showsRawText != true, let storage = textStorage, storage.length > 0 else { return nil }
        let line = (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let probe = min(line.location, storage.length - 1)
        guard let row = NoteCodeStyle.Block.Row(storage.attribute(NoteCodeStyle.Block.attribute, at: probe, effectiveRange: nil))
        else { return nil }
        return (row, line)
    }

    /// What a character typed into a block is set in: its line's own look —
    /// the code face, the block's paragraph — in the plain colour, which the
    /// block's colours are laid over as it is typed (`NoteMarkdown.recolourCode`).
    func codeTypingAttributes() -> [NSAttributedString.Key: Any]? {
        guard let code = codeRowAtCaret(), let storage = textStorage else { return nil }
        var attributes = storage.attributes(at: min(code.line.location, storage.length - 1), effectiveRange: nil)
        for key in [NSAttributedString.Key.paperTimeSource, .paperTimePiece, .paperTimeSourceLead, .link,
                    NoteCodeStyle.Block.copied, .baselineOffset] {
            attributes.removeValue(forKey: key)
        }
        if code.row.role == .line {
            attributes[.foregroundColor] = NSColor.labelColor
        } else {
            // The fence as written: the language after its marks — on the
            // header, lifted to its middle as the rest of the line is.
            attributes[.font] = NoteTypography.code()
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            if code.row.role == .header {
                attributes[.baselineOffset] = NoteCodeStyle.Block.headerLift(for: NoteTypography.code())
            }
        }
        return attributes
    }

    /// Return in a block, as a code editor has it: the next line starts
    /// where this one did, and one indent further after a `:` or an opening
    /// bracket. Return on a fence just typed closes the block below it, and
    /// leaves the caret on the empty line between.
    private func insertCodeNewline(_ code: (row: NoteCodeStyle.Block.Row, line: NSRange), sender: Any?) {
        let text = string as NSString
        let caret = selectedRange().location
        var lineEnd = NSMaxRange(code.line)
        if lineEnd > code.line.location, text.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        let written = text.substring(with: NSRange(location: code.line.location, length: lineEnd - code.line.location))
        switch code.row.role {
        case .header:
            // Into the Markdown, not the screen: once the caret leaves the
            // fence it is shown by its language's name, and offsets on the
            // screen move under it.
            guard caret == lineEnd, let coordinator, let storage = textStorage,
                  let fence = NoteCode.opening(written)
            else { return super.insertNewline(sender) }
            let source = NoteMarkdown.markdown(from: storage) as NSString
            let at = NoteMarkdown.sourceIndex(in: storage, displayIndex: code.line.location)
            guard let block = NoteCode.blocks(in: source as String).first(where: { $0.open.location == at }),
                  Self.wantsClosing(block, in: source)
            else { return super.insertNewline(sender) }
            let end = NSMaxRange(block.open)
            let lead = String(written.prefix { $0 == " " })
            let marks = String(repeating: fence.character, count: fence.length)
            let updated = source.replacingCharacters(in: NSRange(location: end, length: 0), with: "\n\n" + lead + marks)
            coordinator.registerStep(named: L("코드 블록", "Code Block"), in: self)
            coordinator.lastKnownMarkdown = updated
            coordinator.markdown = updated
            coordinator.restyle(self, source: updated, caretSource: end + 1)
        case .line:
            let before = text.substring(with: NSRange(location: code.line.location, length: caret - code.line.location))
            let indent = String(before.prefix { $0 == " " || $0 == "\t" })
            let opens = before.trimmingCharacters(in: .whitespaces).last.map { ":{([".contains($0) } ?? false
            insertText("\n" + indent + (opens ? Self.codeIndent : ""), replacementRange: selectedRange())
        case .close:
            super.insertNewline(sender)
        }
    }

    /// Whether Return on a block's opening fence should close the block:
    /// when nothing closes it — or what closes it is another block's closing
    /// fence, which a fence typed above that block takes for its own, and
    /// the other block's opening fence (`py`, a language after the marks)
    /// is read as a line of code.
    static func wantsClosing(_ block: NoteCode.Block, in source: NSString) -> Bool {
        if block.close == nil { return true }
        return block.lines.contains { NoteCode.opening(source.substring(with: $0))?.language.isEmpty == false }
    }

    /// Tab and ⇧Tab in a block: four spaces in at the caret, or every line
    /// of a selection in or out by four.
    private func indentCode(by step: Int) -> Bool {
        guard let code = codeRowAtCaret(), code.row.role == .line else { return false }
        let range = selectedRange()
        let text = string as NSString
        if step > 0, range.length == 0 {
            insertText(Self.codeIndent, replacementRange: range)
            return true
        }
        let lines = text.lineRange(for: range)
        let written = text.substring(with: lines)
        var changed: [String] = []
        var removedBeforeCaret = 0
        for (index, line) in written.components(separatedBy: "\n").enumerated() {
            if step > 0 {
                changed.append(line.isEmpty ? line : Self.codeIndent + line)
            } else {
                let spaces = line.prefix(4).prefix { $0 == " " }.count
                if index == 0 { removedBeforeCaret = spaces }
                changed.append(String(line.dropFirst(spaces)))
            }
        }
        let replacement = changed.joined(separator: "\n")
        guard replacement != written else { return true }
        insertText(replacement, replacementRange: lines)
        if range.length == 0 {
            setSelectedRange(NSRange(location: max(lines.location, range.location - removedBeforeCaret), length: 0))
        } else {
            setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length))
        }
        return true
    }

    /// A click on a block's copy button copies its code — the lines between
    /// the fences, as written — and says so on the button for a moment. The
    /// point is in the view's coordinates; the pasteboard is a parameter so a
    /// probe can press the button onto one of its own.
    func copyCode(at point: NSPoint, to pasteboard: NSPasteboard) -> Bool {
        guard coordinator?.showsRawText != true, let layout = textLayoutManager else { return false }
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        guard let fragment = layout.textLayoutFragment(for: inContainer) as? NoteLayoutFragment,
              let button = fragment.codeCopyButton?.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                              dy: fragment.layoutFragmentFrame.minY),
              button.contains(inContainer),
              let content = layout.textContentManager,
              let start = fragment.textElement?.elementRange?.location
        else { return false }
        let index = content.offset(from: content.documentRange.location, to: start)
        return copyCode(ofBlockAt: index, to: pasteboard)
    }

    /// Where the copy pill of the block whose header is at this display
    /// offset stands, in the view's coordinates — what a probe presses.
    func copyButtonFrame(ofBlockAt index: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: index),
              let fragment = layout.textLayoutFragment(for: location) as? NoteLayoutFragment,
              let button = fragment.codeCopyButton
        else { return nil }
        return button.offsetBy(dx: fragment.layoutFragmentFrame.minX + textContainerOrigin.x,
                               dy: fragment.layoutFragmentFrame.minY + textContainerOrigin.y)
    }

    /// Copies the code of the block whose header is at this display offset.
    /// The pasteboard is a parameter so a probe can hand in one of its own.
    @discardableResult
    func copyCode(ofBlockAt index: Int, to pasteboard: NSPasteboard) -> Bool {
        guard let coordinator, let storage = textStorage, index < storage.length else { return false }
        let source = coordinator.lastKnownMarkdown
        let at = NoteMarkdown.sourceIndex(in: storage, displayIndex: index)
        guard let block = NoteCode.blocks(in: source).first(where: { NSLocationInRange(at, $0.range) || at == $0.range.location })
        else { return false }
        pasteboard.clearContents()
        pasteboard.setString(NoteCode.code(of: block, in: source as NSString), forType: .string)
        // "Copied" on the button for a moment: an attribute on the header,
        // which its fragment reads when it draws.
        let header = (string as NSString).lineRange(for: NSRange(location: index, length: 0))
        storage.addAttribute(NoteCodeStyle.Block.copied, value: true, range: header)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let storage = self?.textStorage else { return }
            storage.removeAttribute(NoteCodeStyle.Block.copied, range: NSRange(location: 0, length: storage.length))
        }
        return true
    }

    /// Tab and ⇧Tab on a list: the item the caret is in — or every item
    /// selected — a level in or out with what is under it, its list
    /// numbered as it is shown (`NoteList.shift`), as one step to undo.
    /// With a selection it had been the caret's item alone, and the
    /// selection was let go.
    private func shiftListItems(by step: Int) -> Bool {
        guard let line = caretLine(), line.block.isListItem, let (source, selection) = sourceAndSelection(),
              let edit = NoteList.shift(in: source, selection: selection, by: step) else { return false }
        applyListEdit(edit, to: source, named: step > 0 ? L("들여쓰기", "Indent") : L("내어쓰기", "Outdent"))
        return true
    }

    /// The note's Markdown and the selection in it, for a list's edit. Nil
    /// while an input method is composing — the syllable is not in the note
    /// yet, and the note set again under it would put it in twice — and in
    /// the Markdown view, where every key is the text view's.
    private func sourceAndSelection() -> (source: String, selection: NSRange)? {
        guard coordinator?.showsRawText != true, !hasMarkedText(), let storage = textStorage else { return nil }
        let shown = selectedRange()
        let start = NoteMarkdown.sourceIndex(in: storage, displayIndex: shown.location)
        let end = shown.length > 0 ? NoteMarkdown.sourceIndex(in: storage, displayIndex: NSMaxRange(shown)) : start
        return (NoteMarkdown.markdown(from: storage), NSRange(location: start, length: max(0, end - start)))
    }

    /// A list's edit (`NoteList`), made in the Markdown — the note set again
    /// from it, the caret or the selection where the edit leaves it — as one
    /// step of the note's undo, never part of the typing either side of it.
    /// An edit that changes nothing (⇧Tab at the left) takes the key and
    /// leaves the note alone.
    private func applyListEdit(_ edit: NoteList.Edit, to source: String, named name: String) {
        guard let coordinator, !edit.changesNothing else { return }
        let updated = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        coordinator.registerStep(named: name, in: self)
        coordinator.lastKnownMarkdown = updated
        coordinator.markdown = updated
        coordinator.restyle(self, source: updated, caretSource: edit.caret,
                            selection: edit.length > 0 ? NSRange(location: edit.caret, length: edit.length) : nil)
    }

    /// ⌘B, ⌘I and ⌘E set the selection bold, italic and as code — as
    /// Markdown, round the words — and take it off again when it is.
    override func keyDown(with event: NSEvent) {
        // By key code, not by the character: with a Korean keyboard the B
        // key's character is "ㅠ", and ⌘B did nothing for anyone typing in
        // Korean. ⌘⇧M is a formula (⌘M is the window's).
        if coordinator?.showsRawText != true,
           event.modifierFlags.intersection([.command, .control, .option]) == [.command] {
            let shift = event.modifierFlags.contains(.shift)
            // Code is not made bold: in a block of code the keys do nothing.
            let inCode = codeRowAtCaret() != nil
            switch (event.keyCode, shift) {
            case (11, false): if !inCode { toggleEmphasis("**") }; return
            case (34, false): if !inCode { toggleEmphasis("*") }; return
            case (14, false): if !inCode { toggleEmphasis("`") }; return
            case (46, true): if !inCode { toggleEmphasis("$") }; return
            default: break
            }
        }
        guard let coordinator, coordinator.completions.isShowing else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 125: if coordinator.completions.move(by: 1) { return }      // down
        case 126: if coordinator.completions.move(by: -1) { return }     // up
        case 36, 48: if coordinator.completions.chooseSelected() { return }  // return, tab
        case 53: coordinator.completions.hide(); return                  // escape
        default: break
        }
        super.keyDown(with: event)
    }

    func toggleEmphasis(_ mark: String) {
        let text = string as NSString
        let range = selectedRange()
        let width = (mark as NSString).length
        // One step, named for what it did, and never part of the typing
        // around it.
        coordinator?.endTyping()
        let name: String? = switch mark {
        case "**": L("굵게", "Bold")
        case "*": L("기울임", "Italic")
        case "`": L("코드", "Code")
        case "$": L("수식", "Math")
        default: nil
        }
        coordinator?.nextStepName = name
        stepUndoManager?.beginUndoGrouping()
        defer {
            stepUndoManager?.endUndoGrouping()
            coordinator?.nextStepName = nil
            coordinator?.endTyping()
        }
        if range.length == 0 {
            // Between an empty pair already: it comes off. Otherwise the pair
            // goes in, and the caret between.
            if range.location >= width, range.location + width <= text.length,
               text.substring(with: NSRange(location: range.location - width, length: width)) == mark,
               text.substring(with: NSRange(location: range.location, length: width)) == mark {
                insertText("", replacementRange: NSRange(location: range.location - width, length: width * 2))
                return
            }
            insertText(mark + mark, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + width, length: 0))
            return
        }
        let selected = text.substring(with: range)
        let before = range.location >= width
            ? text.substring(with: NSRange(location: range.location - width, length: width)) : ""
        let after = NSMaxRange(range) + width <= text.length
            ? text.substring(with: NSRange(location: NSMaxRange(range), length: width)) : ""
        if selected.hasPrefix(mark), selected.hasSuffix(mark), (selected as NSString).length >= width * 2 {
            let inner = (selected as NSString).substring(
                with: NSRange(location: width, length: (selected as NSString).length - width * 2))
            insertText(inner, replacementRange: range)
            setSelectedRange(NSRange(location: range.location, length: (inner as NSString).length))
        } else if before == mark, after == mark {
            insertText("", replacementRange: NSRange(location: NSMaxRange(range), length: width))
            insertText("", replacementRange: NSRange(location: range.location - width, length: width))
            setSelectedRange(NSRange(location: range.location - width, length: range.length))
        } else {
            insertText(mark, replacementRange: NSRange(location: NSMaxRange(range), length: 0))
            insertText(mark, replacementRange: NSRange(location: range.location, length: 0))
            setSelectedRange(NSRange(location: range.location + width, length: range.length))
        }
    }

    /// A bracket, a quote or a mark typed over a selection wraps it — the
    /// way every editor does — and "[] " at the start of a line is a task.
    private static let wrapping: [String: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
        "*": "*", "_": "_", "$": "$", "~": "~",
    ]
    /// What is typed as a pair with nothing selected (Obsidian): brackets
    /// always; a quote, a dollar, a backtick, a star, an underscore or a
    /// tilde only between things that are not words — the apostrophe in
    /// "don't" is never one, and is left out altogether.
    static let pairs: [String: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`",
        "*": "*", "_": "_", "$": "$", "~": "~",
    ]
    private static let openers: Set<String> = ["(", "[", "{"]
    /// What wraps a selection in code: brackets and quotes — never a star,
    /// an underscore, a dollar or a tilde.
    private static let codeWrapping: Set<String> = ["(", "[", "{", "\"", "'", "`"]
    /// What closes itself in code.
    private static let codeQuotes: Set<String> = ["\"", "'", "`"]

    /// The third backtick (or tilde) of a fence: where it goes. A line of
    /// nothing but two of them before the caret, and nothing but more of
    /// them after it, takes the third as typed — and the marks after the
    /// caret, which the pairs put there, go. Typed a key at a time ``` was
    /// otherwise ```` with the caret before the last: the first brings its
    /// closer, the second steps over it, and the third brought another, so
    /// «```python» was never a fence. The Portable build's `fenceTypingEdit`.
    private func typedFenceMarks(_ typed: String, at caret: Int) -> NSRange? {
        guard typed == "`" || typed == "~" else { return nil }
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        var end = NSMaxRange(line)
        while end > caret, [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
        let before = text.substring(with: NSRange(location: line.location, length: caret - line.location))
        let after = text.substring(with: NSRange(location: caret, length: end - caret))
        let spaces = before.prefix { $0 == " " }.count
        let marks = before.dropFirst(spaces)
        guard spaces <= 3, marks.count >= 2,
              marks.allSatisfy({ String($0) == typed }), after.allSatisfy({ String($0) == typed })
        else { return nil }
        return NSRange(location: caret, length: end - caret)
    }
    private static let closers: Set<String> = [")", "]", "}", "\"", "`", "*", "_", "$", "~"]
    /// The marks Markdown doubles: `**`, `__`, `$$`, `~~`.
    private static let doubled: Set<String> = ["*", "_", "$", "~"]

    private static func isWordy(_ character: String) -> Bool {
        character.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let range = selectedRange()
        if coordinator?.showsRawText != true, range.length > 0,
           replacementRange.location == NSNotFound || replacementRange == range,
           let closing = Self.wrapping[typed],
           // In code a star is a star: only brackets and quotes wrap there.
           Self.codeWrapping.contains(typed) || codeRowAtCaret() == nil {
            coordinator?.endTyping()
            stepUndoManager?.beginUndoGrouping()
            super.insertText(closing, replacementRange: NSRange(location: NSMaxRange(range), length: 0))
            super.insertText(typed, replacementRange: NSRange(location: range.location, length: 0))
            stepUndoManager?.endUndoGrouping()
            coordinator?.endTyping()
            setSelectedRange(NSRange(location: range.location + (typed as NSString).length, length: range.length))
            return
        }
        // The third backtick of a fence takes the pairs' marks after it away.
        if range.length == 0, coordinator?.showsRawText != true, (typed as NSString).length == 1, !hasMarkedText(),
           replacementRange.location == NSNotFound || replacementRange == range,
           let marks = typedFenceMarks(typed, at: range.location) {
            insertTextBypassingLatexSuite(typed, replacementRange: marks)
            return
        }
        // Latex Suite first: a snippet that fires takes the character.
        if latexSuite.insert(string, replacementRange: replacementRange, in: self) { return }
        // "[] " at the start of a line, or of a bullet's words, is a task —
        // Notion's shortcut for one — and "-- " there is a toggle (Notion
        // makes one with ">", which Markdown has for quotations): `NoteList.shortcut`,
        // one step to undo.
        if typed == " ", range.length == 0, replacementRange.location == NSNotFound || replacementRange == range,
           range.location >= 2,
           ["[]", "--"].contains((self.string as NSString).substring(with: NSRange(location: range.location - 2, length: 2))),
           let (source, selection) = sourceAndSelection(),
           let edit = NoteList.shortcut(in: source, caret: selection.location) {
            applyListEdit(edit, to: source, named: edit.replacement.hasPrefix("+") ? L("토글", "Toggle") : L("할 일", "To-Do"))
            return
        }
        // Pairs: a closer typed before the same closer steps over it, and an
        // opener with nothing selected brings its closer along.
        if range.length == 0, (typed as NSString).length == 1, !hasMarkedText(),
           replacementRange.location == NSNotFound || replacementRange == range {
            let text = self.string as NSString
            let next = range.location < text.length ? text.substring(with: NSRange(location: range.location, length: 1)) : ""
            let previous = range.location > 0 ? text.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
            // In a line of code, a code editor's pairs: a bracket brings its
            // closer, a quote does between non-words, a closer already next
            // is stepped over — and Markdown's marks are only characters.
            if codeRowAtCaret()?.row.role == .line {
                if Self.codeQuotes.contains(typed) || [")", "]", "}"].contains(typed), next == typed {
                    setSelectedRange(NSRange(location: range.location + 1, length: 0))
                    return
                }
                let closing = Self.openers.contains(typed) ? Self.pairs[typed]
                    : Self.codeQuotes.contains(typed) && !Self.isWordy(previous) && !Self.isWordy(next)
                        && !Self.codeQuotes.contains(previous) ? typed : nil
                if let closing {
                    insertTextBypassingLatexSuite(typed + closing, replacementRange: range)
                    setSelectedRange(NSRange(location: range.location + 1, length: 0))
                    return
                }
                return insertTextBypassingLatexSuite(string, replacementRange: replacementRange)
            }
            // (Not when a Markdown mark is being doubled — "*|*" with another
            // "*" typed is the start of "**bold**", and the pair doubles to
            // "**|**"; at "**b*|*" the "*" before the caret follows a word,
            // so it is the closing mark and the caret steps over.)
            let beforePrevious = range.location > 1 ? text.substring(with: NSRange(location: range.location - 2, length: 1)) : ""
            let doubling = Self.doubled.contains(typed) && previous == typed && !Self.isWordy(beforePrevious)
            if Self.closers.contains(typed), next == typed, !doubling {
                setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return
            }
            if let closing = Self.pairs[typed],
               Self.openers.contains(typed) || (!Self.isWordy(previous) && !Self.isWordy(next)) {
                insertTextBypassingLatexSuite(typed + closing, replacementRange: range)
                setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return
            }
        }
        insertTextBypassingLatexSuite(string, replacementRange: replacementRange)
    }
}
#endif
