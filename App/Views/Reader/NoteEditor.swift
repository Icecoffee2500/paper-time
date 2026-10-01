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

        if let words = pendingReveal {
            DispatchQueue.main.async {
                Self.reveal(words, in: textView)
                pendingReveal = nil
            }
        }
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
            lastKnownMarkdown = source
            markdown = source
            updateCompletions(in: textView)
            updateMathPreview(in: textView)
            scheduleRestyle(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView,
                  !textView.hasMarkedText(), !isRestyling
            else { return }
            updateMathPreview(in: textView)
            // Never rebuild the text under a selection: that is what made a
            // drag let go of what it had just selected.
            guard textView.selectedRange().length == 0, !textView.isSelectingByHand else {
                lastCaretLine = (textView.string as NSString)
                    .lineRange(for: textView.selectedRange())
                return
            }
            textView.typingAttributes = NoteMarkdown.bodyAttributes
            // A caret set down inside a drawn marker — on the bullet, by a
            // click — goes to the words after it: nothing is typed into a
            // bullet.
            if let storage = textView.textStorage, storage.length > 0 {
                let caret = textView.selectedRange().location
                let lineStart = (textView.string as NSString).lineRange(for: NSRange(location: caret, length: 0)).location
                var run = NSRange()
                if caret > lineStart, caret < storage.length,
                   let standing = storage.attribute(.paperTimeSource, at: lineStart, longestEffectiveRange: &run,
                                                    in: NSRange(location: lineStart, length: storage.length - lineStart)) as? String,
                   caret < NSMaxRange(run), NoteMarkdown.Block(line: standing).marker == standing {
                    textView.setSelectedRange(NSRange(location: NSMaxRange(run), length: 0))
                    return
                }
            }
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
                // And a marker arriving or going on that line — "- " typed
                // at its start is a bullet at once, as it is in Notion.
                let marker = Self.marker(ofLineAt: caret, in: source)
                if lines == self.setLineCount, line == self.setCaretLine, marker == self.setCaretMarker {
                    return
                }
                self.setLineCount = lines
                self.setCaretLine = line
                self.setCaretMarker = marker
                self.restyle(textView, source: source, caretSource: caret)
            }
        }

        /// Which line the caret was on, and how many lines there were, when
        /// the note was last set — see `scheduleRestyle`. (`lastCaretLine`
        /// above is a different thing: the *range* of the line, kept so a
        /// click that stays on one line does not set the note again.)
        private var setCaretLine = -1
        private var setLineCount = -1
        private var setCaretMarker = ""

        /// The marker of the line a source offset is on, as written.
        static func marker(ofLineAt caret: Int, in source: String) -> String {
            let text = source as NSString
            let bounded = min(max(caret, 0), text.length)
            let line = text.lineRange(for: NSRange(location: bounded, length: 0))
            return NoteMarkdown.Block(line: text.substring(with: line).trimmingCharacters(in: .newlines)).marker
        }

        func restyle(_ textView: NoteTextView, source: String, caretSource: Int?) {
            guard !isRestyling else { return }
            if caretSource == nil { setCaretLine = -1; setLineCount = -1; setCaretMarker = "" }
            isRestyling = true
            defer { isRestyling = false }

            let rendered = Trace.time("note: set the whole note again") {
                NoteMarkdown.render(
                    source, caret: caretSource, raw: showsRawText, width: room(in: textView),
                    appearance: textView.effectiveAppearance
                )
            }
            lastKnownWidth = room(in: textView)
            let caret = caretSource.map { rendered.displayIndex(forSource: $0) }
            // Whether the caret was in sight before: typing keeps it there,
            // and a note scrolled away from the caret by hand stays put.
            let caretWasShown = caretIsShown(in: textView)
            setContents(rendered.text, in: textView)
            if let caret {
                let range = NSRange(location: min(max(caret, 0), textView.string.utf16.count), length: 0)
                textView.setSelectedRange(range)
                if caretWasShown { textView.scrollRangeToVisible(range) }
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

            lastKnownMarkdown = updated
            markdown = updated
            restyle(textView, source: updated,
                    caretSource: (head + block + after).utf16.count)
            textView.window?.makeFirstResponder(textView)
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
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.mathPreview.hide() }
        return resigned
    }

    /// A note put away does not always resign: the view is simply taken
    /// out of the window. The card must not stay behind.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { coordinator?.mathPreview.hide() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        coordinator?.mathPreview.hide()
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
        isSelectingByHand = true
        // NSTextView tracks the drag itself and returns when the mouse is let
        // go, so this brackets the whole gesture.
        super.mouseDown(with: event)
        isSelectingByHand = false
        if let coordinator, selectedRange().length == 0 {
            coordinator.scheduleRestyle(in: self)
        }
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
        guard let storage = textStorage else { return nil }
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

    /// Puts another marker where this line's is — "- " for "  - " to
    /// outdent, nothing to make the line plain. Written as Markdown; the
    /// note is set again from it.
    private func replaceMarker(of line: CaretLine, with marker: String) {
        replaceDisplay(line.markerDisplay, with: marker)
    }

    /// Puts Markdown over a range of what is shown — with the note's own
    /// attributes and none of a drawn stand-in's: text typed over a stand-in
    /// inherits its `.paperTimeSource`, and would still read as the old
    /// marker. Through `shouldChangeText`, so it can be undone, and
    /// `didChangeText`, so the note is read and set again.
    private func replaceDisplay(_ range: NSRange, with markdown: String) {
        guard shouldChangeText(in: range, replacementString: markdown), let storage = textStorage else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: markdown, attributes: NoteMarkdown.bodyAttributes))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (markdown as NSString).length, length: 0))
    }

    // MARK: Keys

    /// Return continues what the line was doing: another bullet, the next
    /// number, another empty checkbox — and an empty item ends the list, which
    /// is how every outliner behaves and how nobody has to think about it. An
    /// empty item nested in another steps out a level first, as Notion's
    /// does.
    override func insertNewline(_ sender: Any?) {
        guard coordinator?.showsRawText != true, selectedRange().length == 0,
              let line = caretLine(), line.block.kind != .plain, !line.block.marker.isEmpty
        else { return super.insertNewline(sender) }
        let block = line.block
        if block.content.trimmingCharacters(in: .whitespaces).isEmpty {
            if block.indent > 0 {
                replaceMarker(of: line, with: String(block.marker.dropFirst(2)))
                return
            }
            // An empty item: take the marker away rather than making another.
            replaceMarker(of: line, with: "")
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

    /// Backspace at the start of an item's words steps the item out a level,
    /// and at the left edge makes it a plain line — the way to turn a bullet
    /// back into text when the "- " is drawn as a bullet.
    override func deleteBackward(_ sender: Any?) {
        guard coordinator?.showsRawText != true, selectedRange().length == 0,
              let line = caretLine(), line.block.kind != .plain, !line.block.marker.isEmpty,
              selectedRange().location == line.contentStart
        else { return super.deleteBackward(sender) }
        if line.block.indent > 0 {
            replaceMarker(of: line, with: String(line.block.marker.dropFirst(2)))
        } else {
            replaceMarker(of: line, with: "")
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
        guard coordinator?.showsRawText != true, let line = caretLine(), line.block.isListItem else { return false }
        if step > 0 {
            replaceMarker(of: line, with: "  " + line.block.marker)
            return true
        }
        guard line.block.marker.hasPrefix("  ") else { return true }
        replaceMarker(of: line, with: String(line.block.marker.dropFirst(2)))
        return true
    }

    /// ⌘B, ⌘I and ⌘E set the selection bold, italic and as code — as
    /// Markdown, round the words — and take it off again when it is.
    override func keyDown(with event: NSEvent) {
        if coordinator?.showsRawText != true,
           event.modifierFlags.intersection([.command, .control, .option]) == [.command],
           let mark = ["b": "**", "i": "*", "e": "`"][event.charactersIgnoringModifiers?.lowercased() ?? ""] {
            toggleEmphasis(mark)
            return
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

    private func toggleEmphasis(_ mark: String) {
        let text = string as NSString
        let range = selectedRange()
        let width = (mark as NSString).length
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
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

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let range = selectedRange()
        if coordinator?.showsRawText != true, range.length > 0,
           replacementRange.location == NSNotFound || replacementRange == range,
           let closing = Self.wrapping[typed] {
            undoManager?.beginUndoGrouping()
            super.insertText(closing, replacementRange: NSRange(location: NSMaxRange(range), length: 0))
            super.insertText(typed, replacementRange: NSRange(location: range.location, length: 0))
            undoManager?.endUndoGrouping()
            setSelectedRange(NSRange(location: range.location + (typed as NSString).length, length: range.length))
            return
        }
        // "[] " at the start of a line, or of a bullet's words, is a task
        // — Notion's shortcut for one.
        if typed == " ", range.length == 0, coordinator?.showsRawText != true,
           let line = caretLine(), line.block.kind == .plain || line.block.kind == .bullet,
           range.location >= line.contentStart {
            let text = self.string as NSString
            let sofar = text.substring(with: NSRange(location: line.contentStart, length: range.location - line.contentStart))
            if sofar.trimmingCharacters(in: .whitespaces) == "[]" {
                let lead = String(repeating: "  ", count: line.block.indent)
                    + (line.block.kind == .plain ? sofar.prefix { $0 == " " } : "")
                replaceDisplay(NSRange(location: line.markerDisplay.location, length: range.location - line.markerDisplay.location),
                               with: lead + "- [ ] ")
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }
}
#endif
