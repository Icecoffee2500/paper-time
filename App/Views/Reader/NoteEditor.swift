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
        textView.allowsUndo = true
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
            NoteMarkdown.render(markdown, raw: showsRawText).text, in: textView
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
            // rewriting it on every pass would fight the typist.
            context.coordinator.lastKnownMarkdown = markdown
            context.coordinator.restyle(textView, source: markdown, caretSource: nil)
        }

        if let anchor = pendingAnchor {
            DispatchQueue.main.async {
                context.coordinator.insert(anchor, into: textView)
                pendingAnchor = nil
            }
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
            lastKnownMarkdown = source
            markdown = source
            updateCompletions(in: textView)
            scheduleRestyle(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView,
                  !textView.hasMarkedText(), !isRestyling
            else { return }
            // Never rebuild the text under a selection: that is what made a
            // drag let go of what it had just selected.
            guard textView.selectedRange().length == 0, !textView.isSelectingByHand else {
                lastCaretLine = (textView.string as NSString)
                    .lineRange(for: textView.selectedRange())
                return
            }
            textView.typingAttributes = NoteMarkdown.bodyAttributes
            let line = (textView.string as NSString).lineRange(for: textView.selectedRange())
            guard line != lastCaretLine else { return }
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
                let lines = source.reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                let line = source.prefix(caret).reduce(into: 0) { count, character in
                    if character == "\n" { count += 1 }
                }
                if lines == self.setLineCount, line == self.setCaretLine {
                    return
                }
                self.setLineCount = lines
                self.setCaretLine = line
                self.restyle(textView, source: source, caretSource: caret)
            }
        }

        /// Which line the caret was on, and how many lines there were, when
        /// the note was last set — see `scheduleRestyle`. (`lastCaretLine`
        /// above is a different thing: the *range* of the line, kept so a
        /// click that stays on one line does not set the note again.)
        private var setCaretLine = -1
        private var setLineCount = -1

        func restyle(_ textView: NoteTextView, source: String, caretSource: Int?) {
            guard !isRestyling else { return }
            if caretSource == nil { setCaretLine = -1; setLineCount = -1 }
            isRestyling = true
            defer { isRestyling = false }

            let rendered = Trace.time("note: set the whole note again") {
                NoteMarkdown.render(
                    source, caret: caretSource, raw: showsRawText, width: room(in: textView)
                )
            }
            lastKnownWidth = room(in: textView)
            let caret = caretSource.map { rendered.displayIndex(forSource: $0) }
            setContents(rendered.text, in: textView)
            if let caret {
                textView.setSelectedRange(
                    NSRange(location: min(max(caret, 0), textView.string.utf16.count), length: 0)
                )
            }
            textView.typingAttributes = showsRawText
                ? NoteMarkdown.rawAttributes : NoteMarkdown.bodyAttributes
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
            guard !isRestyling, !showsRawText else { return }
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
        func setContents(_ attributed: NSAttributedString, in textView: NSTextView) {
            if let content = textView.textLayoutManager?.textContentManager as? NSTextContentStorage {
                content.performEditingTransaction {
                    content.textStorage?.setAttributedString(attributed)
                }
            } else {
                textView.textStorage?.setAttributedString(attributed)
            }
            textView.needsDisplay = true
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

            lastKnownMarkdown = updated
            markdown = updated
            restyle(textView, source: updated,
                    caretSource: (head + block + after).utf16.count)
            textView.window?.makeFirstResponder(textView)
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
            guard let open = openWikiLink(in: textView) else { return completions.hide() }
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

    @objc func scrolled() { setHoveredChip(nil) }

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
        isSelectingByHand = true
        // NSTextView tracks the drag itself and returns when the mouse is let
        // go, so this brackets the whole gesture.
        super.mouseDown(with: event)
        isSelectingByHand = false
        if let coordinator, selectedRange().length == 0 {
            coordinator.scheduleRestyle(in: self)
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
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

    /// Return continues what the line was doing: another bullet, the next
    /// number, another empty checkbox — and an empty item ends the list, which
    /// is how every outliner behaves and how nobody has to think about it.
    override func insertNewline(_ sender: Any?) {
        guard coordinator?.showsRawText != true else { return super.insertNewline(sender) }
        let text = string as NSString
        let line = text.lineRange(for: selectedRange())
        let content = text.substring(with: line).trimmingCharacters(in: .newlines)
        let block = NoteMarkdown.Block(line: content)

        guard block.kind != .plain, !block.marker.isEmpty else {
            return super.insertNewline(sender)
        }
        if block.content.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item: take the marker away rather than making another.
            let markerRange = NSRange(location: line.location,
                                      length: (block.marker as NSString).length)
            insertText("", replacementRange: markerRange)
            super.insertNewline(sender)
            return
        }
        super.insertNewline(sender)
        insertText(continuation(of: block), replacementRange: selectedRange())
    }

    private func continuation(of block: NoteMarkdown.Block) -> String {
        let indent = String(repeating: "  ", count: block.indent)
        switch block.kind {
        case .bullet: return indent + "- "
        case .ordered(let number): return indent + "\(number + 1). "
        case .task: return indent + "- [ ] "
        case .quote: return indent + "> "
        case .heading, .plain: return ""
        }
    }

    /// Tab indents the item the caret is in rather than dropping a tab into
    /// the middle of a sentence.
    override func insertTab(_ sender: Any?) {
        guard shiftListItem(by: 1) else { return super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        guard shiftListItem(by: -1) else { return super.insertBacktab(sender) }
    }

    private func shiftListItem(by step: Int) -> Bool {
        guard coordinator?.showsRawText != true else { return false }
        let text = string as NSString
        let line = text.lineRange(for: selectedRange())
        let content = text.substring(with: line).trimmingCharacters(in: .newlines)
        let block = NoteMarkdown.Block(line: content)
        switch block.kind {
        case .bullet, .ordered, .task:
            break
        default:
            return false
        }
        if step > 0 {
            insertText("  ", replacementRange: NSRange(location: line.location, length: 0))
            return true
        }
        guard text.substring(with: NSRange(location: line.location,
                                           length: min(2, line.length))) == "  " else { return true }
        insertText("", replacementRange: NSRange(location: line.location, length: 2))
        return true
    }
}
#endif
