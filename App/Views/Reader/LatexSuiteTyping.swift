#if os(macOS)
import AppKit
import PaperCore

/// A text view that answers to Latex Suite: `@a` becomes `\alpha`, `/` makes a
/// fraction, Tab walks the placeholders and out of the equation.
///
/// The two places anybody writes LaTeX on the Mac — the note beside the paper
/// and the text card on the page — are both this, so the keys behave the same
/// in both and there is one place to get them right. Everything here is a
/// forward to `LatexSuiteTyping`; what a subclass adds on top (lists that
/// continue, a card that finishes on ⌘Return) runs when Latex Suite leaves
/// the key alone, exactly as it did before.
class LatexSuiteTextView: NSTextView {
    let latexSuite = LatexSuiteTyping()

    /// True while the view's owner replaces the text wholesale without
    /// changing what it says — the note editor setting a line as mathematics
    /// again. The selection jumps about while that happens, and none of those
    /// jumps is the typist leaving a placeholder.
    var isSettingText: Bool { false }

    override func keyDown(with event: NSEvent) {
        latexSuite.handling(event) { super.keyDown(with: event) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if latexSuite.insert(string, replacementRange: replacementRange, in: self) { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func doCommand(by selector: Selector) {
        if latexSuite.perform(selector, in: self) { return }
        super.doCommand(by: selector)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else { return false }
        latexSuite.willChange(affectedRanges, to: replacementStrings, in: self)
        return true
    }

    override func didChangeText() {
        super.didChangeText()
        latexSuite.didChange(in: self)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { latexSuite.selectionChanged(in: self) }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        latexSuite.drawPlaceholders(in: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // What was registered to undo an expansion goes with the view: left on
        // the window's stack it would be a ⌘Z that does nothing, spent.
        if newWindow == nil, window != nil { undoManager?.removeAllActions(withTarget: self) }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// Latex Suite's keys, for one text view.
///
/// The engine (`LatexSuite`, in PaperCore) is pure: text and selection in, an
/// edit out. This is everything around it that belongs to an editor — which
/// keys reach it, when it must stay out of the way, how its edit lands, how
/// it is undone, and what the placeholders look like on screen.
///
/// **The text it reads is the Markdown, not the screen.** The note editor
/// shows every line but the caret's set as it reads — a formula as a picture,
/// a heading without its `#` — so the characters on screen are not the note.
/// Latex Suite has to see `$…$` to know it is in math, so it is given the
/// source (`LatexSuiteDisplay`), and its answer is carried back to the screen
/// through the same map. The card on the page has no such runs, and there the
/// map is the identity.
///
/// **Undo is kept in the source too.** The note sets its lines again after an
/// edit that adds or removes one, and a range on screen from before that is a
/// range into a different string after it. Latex Suite's own undo is
/// "one ⌘Z gives back what you typed" — `@a`, not `\alpha` — and that promise
/// has to survive the note setting itself again in between.
@MainActor
final class LatexSuiteTyping {
    /// Whether the setting is on: the one switch in Settings, on unless it
    /// was turned off. A probe of the typing turns it on for itself without
    /// writing anything down.
    static var isEnabled: Bool {
        if isSwitchedOffForProbe { return false }
        return Boot.isSet("PAPERTIME_LATEX_TYPING")
            || (UserDefaults.standard.object(forKey: AppSettings.latexShortcutsKey) as? Bool ?? true)
    }

    /// The switch turned off for a moment by the typing probe, which times a
    /// keypress both ways — without writing the setting.
    static var isSwitchedOffForProbe = false

    /// The name ⌘Z carries in the Edit menu after an expansion.
    static var undoName: String { L("LaTeX 단축 입력", "LaTeX Shortcut") }

    private let engine = LatexSuite.Engine()
    /// The placeholders of the snippet being filled in, in source offsets.
    private(set) var tabstops = LatexSuite.Tabstops.none
    /// The key being handled, so a character that arrives by way of
    /// `insertText` can tell whether Command or Control was down, and Return
    /// whether Shift was.
    private var event: NSEvent?
    /// Set while an edit of ours is landing: the text view reports it as an
    /// edit and a selection change like any other, and those reports are
    /// about what this is already doing.
    private var isApplying = false
    /// Edits the text view made itself since the placeholders last moved,
    /// in source offsets, each against the text before it.
    private var pending: [[LatexSuite.Change]] = []
    /// How long the source should be if every edit since the placeholders
    /// were set went through the text view. Anything else changed the note
    /// behind its back — a passage dropped in, the note changed on another
    /// device — and the placeholders no longer point at anything.
    private var expectedLength = 0
    /// The whole selection, in source offsets, when Latex Suite made one of
    /// several ranges — one placeholder in two places, `\begin{…}` and
    /// `\end{…}`, or `f` four times over in `tayl`. A text view has one caret
    /// and types into one range, so it is given the first of them, and the
    /// rest are held here, drawn here, and typed into from here. Empty unless
    /// there are at least two.
    private var mirrors: [NSRange] = []
    /// The last reading of the view's text as its source, kept for as long
    /// as the text is the same. One keypress reads the note several times —
    /// before the edit, for the caret after it, for the placeholders drawn
    /// behind it — and a long note read run by run is the dearest thing this
    /// does: 9 ms a reading for 20,000 characters in a Debug build, where a
    /// keypress that expanded read it six times over.
    private var reading: (text: NSString, display: LatexSuiteDisplay)?

    /// The view's text as Latex Suite reads it. The same characters on
    /// screen are the same source: every piece shows something other than
    /// what it stands for.
    func display(of view: NSTextView) -> LatexSuiteDisplay? {
        guard let storage = view.textStorage else { return nil }
        if let reading, reading.text.isEqual(to: storage.string) { return reading.display }
        let display = LatexSuiteDisplay(storage)
        reading = (NSString(string: storage.string), display)
        return display
    }

    func handling(_ event: NSEvent, _ body: () -> Void) {
        let previous = self.event
        self.event = event
        defer { self.event = previous }
        body()
    }

    // MARK: Keys

    /// A typed character, before the text view puts it in. True when Latex
    /// Suite took it.
    func insert(_ string: Any, replacementRange: NSRange, in view: LatexSuiteTextView) -> Bool {
        // An input method is putting a syllable together, or handing one
        // over: the characters are its, not the typist's keys. Latex Suite
        // stays out of a composition in Obsidian for the same reason, and for
        // Korean it is every syllable.
        guard Self.isEnabled, !view.hasMarkedText() else { return false }
        let typed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard (typed as NSString).length == 1 else { return false }
        if let event, !event.modifierFlags.intersection([.command, .control]).isEmpty { return false }
        // A range of its own is somebody replacing text elsewhere — an input
        // method converting a word again, dictation — not a keypress.
        if replacementRange.location != NSNotFound, replacementRange != view.selectedRange() { return false }
        return run(.text(typed), in: view)
    }

    /// A command a key was bound to — Tab, Shift-Tab, Return, Delete. True
    /// when Latex Suite took it; otherwise the view does what it always did.
    func perform(_ selector: Selector, in view: LatexSuiteTextView) -> Bool {
        guard Self.isEnabled, !view.hasMarkedText() else { return false }
        let shift = event?.modifierFlags.contains(.shift) ?? false
        let input: LatexSuite.Input
        switch selector {
        case #selector(NSResponder.insertTab(_:)): input = .tab
        case #selector(NSResponder.insertBacktab(_:)): input = .shiftTab
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            input = shift ? .shiftEnter : .enter
        case #selector(NSResponder.deleteBackward(_:)): input = .backspace
        default: return false
        }
        return run(input, in: view)
    }

    private func run(_ input: LatexSuite.Input, in view: LatexSuiteTextView) -> Bool {
        guard let display = display(of: view) else { return false }
        if tabstops.isActive, display.source.length != expectedLength { tabstops = .none }
        let selection = self.selection(in: view, display: display)
        let source = display.source as String
        if let edit = engine.handle(input, text: source, selection: selection, tabstops: tabstops) {
            apply(edit, selection: selection, in: view)
            return true
        }
        guard selection.count > 1 else { return false }
        // Latex Suite left the key alone, and there are several carets: the
        // key does what it would have done at one, at every one of them.
        switch input {
        case .text(let typed):
            typeEverywhere(selection.map { LatexSuite.Change(range: $0, text: typed) }, selection: selection, in: view)
            return true
        case .backspace:
            var changes: [LatexSuite.Change] = []
            for range in selection {
                let gone = range.length > 0 ? range
                    : range.location > 0 ? display.source.rangeOfComposedCharacterSequence(at: range.location - 1)
                    : range
                if let last = changes.last, gone.location < last.range.location + last.range.length { continue }
                changes.append(LatexSuite.Change(range: gone, text: ""))
            }
            typeEverywhere(changes, selection: selection, in: view)
            return true
        default:
            // Tab or Return that is not Latex Suite's is the view's own, and
            // the view has one caret: the others let go.
            mirrors = []
            view.needsDisplay = true
            return false
        }
    }

    /// The selection Latex Suite is to see: the one the view has, or the
    /// several Latex Suite made, as long as the view's own is still the
    /// first of them — a click or an arrow key since then means the others
    /// have been let go.
    func selection(in view: LatexSuiteTextView, display: LatexSuiteDisplay) -> [NSRange] {
        let own = view.selectedRanges.map { display.sourceRange(for: $0.rangeValue) }
        if mirrors.count > 1, own.count == 1, own[0] == mirrors[0] { return mirrors }
        return own
    }

    /// A key at several carets, as one edit and one step to undo.
    private func typeEverywhere(_ changes: [LatexSuite.Change], selection: [NSRange], in view: LatexSuiteTextView) {
        guard !changes.isEmpty else { return }
        var shift = 0
        let after = changes.map { change -> NSRange in
            let length = (change.text as NSString).length
            defer { shift += length - change.range.length }
            return NSRange(location: change.range.location + shift + length, length: 0)
        }
        var step = Step(
            forward: changes, backward: [], selectionBefore: selection, selectionAfter: after,
            tabstopsAfter: tabstops.afterEdit(changes, selection: after)
        )
        view.breakUndoCoalescing()
        step.backward = land(changes, in: view)
        select(after, in: view)
        register(step, in: view)
        view.breakUndoCoalescing()
        tabstops = step.tabstopsAfter
        expectedLength = display(of: view)?.source.length ?? 0
        view.needsDisplay = true
    }

    // MARK: Landing an edit

    /// One step of Latex Suite's history: what it changed, how to take it
    /// back, and where the selection and placeholders stand on either side.
    private struct Step: Sendable {
        var forward: [LatexSuite.Change]
        var backward: [LatexSuite.Change]
        var selectionBefore: [NSRange]
        var selectionAfter: [NSRange]
        var tabstopsAfter: LatexSuite.Tabstops
    }

    private func apply(_ edit: LatexSuite.Edit, selection: [NSRange], in view: LatexSuiteTextView) {
        // Only the caret moved: past a bracket, to the next placeholder, out
        // of the equation. Nothing to undo — Latex Suite records nothing
        // either.
        if edit.changes.isEmpty {
            tabstops = edit.tabstops
            select(edit.selection, in: view)
            view.needsDisplay = true
            return
        }
        let history = edit.undoSteps.isEmpty ? [edit.changes] : edit.undoSteps.filter { !$0.isEmpty }
        var before = selection
        var steps: [Step] = []
        for (index, changes) in history.enumerated() {
            let last = index == history.count - 1
            let after = last ? edit.selection : before.map { LatexSuiteDisplay.map($0, through: changes) }
            steps.append(Step(
                forward: changes, backward: [], selectionBefore: before, selectionAfter: after,
                tabstopsAfter: last ? edit.tabstops : .none
            ))
            before = after
        }

        // Each step its own group on the undo stack, so one ⌘Z takes back the
        // expansion and leaves the key that set it off — `@a`, as typed. With
        // the manager grouping by event, the two would fall into the one
        // group this keypress opened; so grouping by event is set aside for
        // the length of this, which is only possible while no group is open
        // (the event's own group is opened by the first registration in it,
        // and nothing has registered yet: the key was taken before the text
        // view saw it). The typing before the key stops coalescing here, so
        // that it stays a step of its own and the text view does not go on
        // extending it at offsets this edit has moved.
        let manager = view.undoManager
        view.breakUndoCoalescing()
        let separate = history.count > 1 && manager?.groupingLevel == 0
        let groupsByEvent = manager?.groupsByEvent ?? true
        if separate { manager?.groupsByEvent = false }
        for (index, var step) in steps.enumerated() {
            if separate { manager?.beginUndoGrouping() }
            step.backward = land(step.forward, in: view)
            select(step.selectionAfter, in: view)
            register(step, in: view)
            if index == steps.count - 1 { manager?.setActionName(Self.undoName) }
            if separate { manager?.endUndoGrouping() }
        }
        if separate { manager?.groupsByEvent = groupsByEvent }
        view.breakUndoCoalescing()
        tabstops = edit.tabstops
        expectedLength = display(of: view)?.source.length ?? 0
        view.needsDisplay = true
    }

    /// Puts changes (source offsets, against the source as it is now) on
    /// screen as one edit of the text view, and gives back the changes that
    /// would undo them.
    @discardableResult
    private func land(_ changes: [LatexSuite.Change], in view: LatexSuiteTextView) -> [LatexSuite.Change] {
        guard let storage = view.textStorage, let display = display(of: view) else { return [] }
        let pieces = display.displayEdits(for: changes)
        guard !pieces.isEmpty else { return [] }
        let backward = LatexSuiteDisplay.inverse(of: changes, in: display.source)

        isApplying = true
        defer { isApplying = false }
        let manager = view.undoManager
        // The text view would record the edit in screen offsets; this records
        // it in source offsets instead (see the type's comment).
        manager?.disableUndoRegistration()
        defer { manager?.enableUndoRegistration() }
        guard view.shouldChangeText(
            inRanges: pieces.map { NSValue(range: $0.range) }, replacementStrings: pieces.map(\.text)
        ) else { return [] }
        let attributes = view.typingAttributes
        let edit = {
            // Right to left, so each range is still where it was said to be.
            for piece in pieces.reversed() {
                storage.replaceCharacters(in: piece.range, with: NSAttributedString(string: piece.text, attributes: attributes))
            }
        }
        // Through the content storage's own transaction: under TextKit 2 an
        // edit made to the storage behind its back is laid out by nobody.
        if let content = view.textLayoutManager?.textContentManager as? NSTextContentStorage {
            content.performEditingTransaction(edit)
        } else {
            storage.beginEditing()
            edit()
            storage.endEditing()
        }
        view.didChangeText()
        return backward
    }

    /// Puts a selection (source offsets) on screen: the first range as the
    /// view's own, the rest as `mirrors`.
    func select(_ selection: [NSRange], in view: LatexSuiteTextView) {
        guard let first = selection.first, let display = display(of: view) else { return }
        let shown = display.displayRange(for: first)
        mirrors = selection.count > 1 ? selection : []
        isApplying = true
        view.setSelectedRanges([NSValue(range: shown)], affinity: .downstream, stillSelecting: false)
        isApplying = false
        view.scrollRangeToVisible(shown)
        view.needsDisplay = true
    }

    private func register(_ step: Step, in view: LatexSuiteTextView) {
        view.undoManager?.registerUndo(withTarget: view) { view in
            MainActor.assumeIsolated { view.latexSuite.revert(step, in: view) }
        }
    }

    /// Undo of one step: the text as it was, the selection as it was, and —
    /// as in Latex Suite — no placeholders at all.
    private func revert(_ step: Step, in view: LatexSuiteTextView) {
        land(step.backward, in: view)
        select(step.selectionBefore, in: view)
        tabstops = .none
        view.breakUndoCoalescing()
        view.needsDisplay = true
        view.undoManager?.registerUndo(withTarget: view) { view in
            MainActor.assumeIsolated { view.latexSuite.reapply(step, in: view) }
        }
    }

    /// Redo: the step again, with the placeholders it made.
    private func reapply(_ step: Step, in view: LatexSuiteTextView) {
        land(step.forward, in: view)
        select(step.selectionAfter, in: view)
        tabstops = step.tabstopsAfter
        expectedLength = display(of: view)?.source.length ?? 0
        view.breakUndoCoalescing()
        view.needsDisplay = true
        register(step, in: view)
    }

    // MARK: Following the text view's own edits

    /// The text view is about to change the text itself — typing into a
    /// placeholder, pasting, deleting. Placeholders grow and shrink with it,
    /// so the change is noted in source offsets while the old text is still
    /// there to read them from.
    func willChange(_ ranges: [NSValue], to strings: [String]?, in view: LatexSuiteTextView) {
        guard !isApplying, !view.isSettingText else { return }
        // The view types at its one caret; the others would be left behind.
        if !mirrors.isEmpty {
            mirrors = []
            view.needsDisplay = true
        }
        guard tabstops.isActive, let strings else { return }
        // Latex Suite drops every placeholder on undo.
        if let manager = view.undoManager, manager.isUndoing || manager.isRedoing {
            tabstops = .none
            view.needsDisplay = true
            return
        }
        guard let display = display(of: view) else { return }
        let changes = zip(ranges, strings).map { range, text in
            LatexSuite.Change(range: display.sourceRange(for: range.rangeValue), text: text)
        }.sorted { $0.range.location < $1.range.location }
        pending.append(changes)
    }

    func didChange(in view: LatexSuiteTextView) {
        guard !isApplying else { return }
        flushPending()
        view.needsDisplay = true
    }

    func selectionChanged(in view: LatexSuiteTextView) {
        guard !isApplying, !view.isSettingText else { return }
        // A selection the typist made: a click, an arrow key.
        if !mirrors.isEmpty {
            mirrors = []
            view.needsDisplay = true
        }
        guard tabstops.isActive else { return }
        flushPending()
        guard let display = display(of: view) else { return }
        guard display.source.length == expectedLength else {
            tabstops = .none
            view.needsDisplay = true
            return
        }
        let before = tabstops
        tabstops = tabstops.selecting(view.selectedRanges.map { display.sourceRange(for: $0.rangeValue) })
        if tabstops != before { view.needsDisplay = true }
    }

    private func flushPending() {
        for changes in pending {
            tabstops = tabstops.mapped(through: changes)
            expectedLength += changes.reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
        }
        pending.removeAll()
    }

    /// Forgets the placeholders — for a probe that starts every case afresh.
    func reset() {
        tabstops = .none
        pending.removeAll()
        mirrors = []
        reading = nil
    }

    // MARK: Drawing the placeholders

    /// Latex Suite's three colours, one per expansion in turn, as the system's
    /// own: a faint wash with a line round it, under the letters.
    private static let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen]
    /// How round a placeholder's corner is. It sits round a letter or two of
    /// LaTeX, where a capsule would read as a pill rather than a field.
    private static let radius: CGFloat = 3
    /// How far the wash reaches past the letters.
    private static let padding = NSSize(width: 1.5, height: 0.5)

    /// The placeholders still to come, drawn behind the text. The one being
    /// typed in is not drawn: it is the selection, and Latex Suite hides it
    /// too. An empty one is a dotted upright where it waits.
    func drawPlaceholders(in view: LatexSuiteTextView) {
        guard tabstops.isActive || !mirrors.isEmpty, let display = display(of: view) else { return }
        drawMirrors(in: view, display: display)
        guard tabstops.isActive else { return }
        guard display.source.length == expectedLength || !pending.isEmpty else { return }
        for (index, group) in tabstops.groups.enumerated() where index > tabstops.index {
            let colour = Self.palette[group.color % Self.palette.count]
            for range in group.ranges {
                let shown = display.displayRange(for: range)
                if shown.length == 0 {
                    guard let caret = Self.rects(for: shown, in: view).first else { continue }
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: caret.minX, y: caret.minY + 1))
                    path.line(to: NSPoint(x: caret.minX, y: caret.maxY - 1))
                    path.lineWidth = 1.4
                    path.setLineDash([1.4, 1.6], count: 2, phase: 0)
                    NSColor.secondaryLabelColor.setStroke()
                    path.stroke()
                } else {
                    for rect in Self.rects(for: shown, in: view) {
                        let box = rect.insetBy(dx: -Self.padding.width, dy: -Self.padding.height)
                        let path = NSBezierPath(roundedRect: box, xRadius: Self.radius, yRadius: Self.radius)
                        colour.withAlphaComponent(0.16).setFill()
                        path.fill()
                        colour.withAlphaComponent(0.42).setStroke()
                        path.lineWidth = 1
                        path.stroke()
                    }
                }
            }
        }
    }

    /// The carets and selections past the view's own, drawn the way the view
    /// draws its own: a caret where the range is empty, the selection's
    /// colour where it is not.
    private func drawMirrors(in view: LatexSuiteTextView, display: LatexSuiteDisplay) {
        let own = view.selectedRanges.map { display.sourceRange(for: $0.rangeValue) }
        guard mirrors.count > 1, own.count == 1, own[0] == mirrors[0] else { return }
        let focused = view.window?.firstResponder === view
        for range in mirrors.dropFirst() {
            let shown = display.displayRange(for: range)
            if shown.length == 0 {
                guard let caret = Self.rects(for: shown, in: view).first else { continue }
                (view.insertionPointColor).setFill()
                NSRect(x: caret.minX, y: caret.minY, width: 1, height: caret.height).fill()
            } else {
                (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
                for rect in Self.rects(for: shown, in: view) { rect.fill() }
            }
        }
    }

    /// The boxes a range of the screen occupies, one per line, in the view's
    /// coordinates. An empty range gives the caret's box.
    static func rects(for range: NSRange, in view: NSTextView) -> [CGRect] {
        let length = view.textStorage?.length ?? 0
        guard range.location <= length, range.location + range.length <= length else { return [] }
        let origin = view.textContainerOrigin
        if let layout = view.textLayoutManager, let content = layout.textContentManager {
            guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let span = NSTextRange(location: start, end: end)
            else { return [] }
            layout.ensureLayout(for: span)
            var rects: [CGRect] = []
            layout.enumerateTextSegments(
                in: span, type: range.length == 0 ? .selection : .standard,
                options: range.length == 0 ? [.rangeNotRequired] : []
            ) { _, frame, _, _ in
                rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                return true
            }
            return rects
        }
        guard let manager = view.layoutManager, let container = view.textContainer else { return [] }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        if range.length == 0 {
            let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 0), in: container)
            return [rect.offsetBy(dx: origin.x, dy: origin.y)]
        }
        var rects: [CGRect] = []
        manager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in rects.append(rect.offsetBy(dx: origin.x, dy: origin.y)) }
        return rects
    }
}

/// The characters on screen and the Markdown they stand for, run by run.
///
/// A run that carries `.paperTimeSource` — a formula set as a picture, a link
/// shown as its label, a heading's hidden `#` — is one piece: it stands for
/// its source as a whole and cannot be cut. Every other run is its own source,
/// character for character. Read the same way `NoteMarkdown.markdown(from:)`
/// reads the note, so that the source here is the source the note will save.
struct LatexSuiteDisplay {
    struct Run {
        var display: NSRange
        var source: NSRange
        /// Stands for its source as a whole.
        var isPiece: Bool
    }

    let source: NSString
    let runs: [Run]
    private let displayLength: Int

    init(_ text: NSAttributedString) {
        // Asked for the one attribute rather than for every run's whole set:
        // handing each run's attributes over as a dictionary was nine tenths
        // of the cost — 5.8 ms of 7.6 for a 9,600-character note of 565
        // formulas, against 0.7 ms this way (measured, -O).
        let whole = NSRange(location: 0, length: text.length)
        let string = text.string as NSString
        var units = [unichar](repeating: 0, count: whole.length)
        string.getCharacters(&units, range: whole)
        var built: [unichar] = []
        built.reserveCapacity(whole.length + whole.length / 4)
        var runs: [Run] = []
        text.enumerateAttribute(.paperTimeSource, in: whole) { value, range, _ in
            guard let piece = value as? String else {
                runs.append(Run(display: range, source: NSRange(location: built.count, length: range.length), isPiece: false))
                built.append(contentsOf: units[range.location ..< range.location + range.length])
                return
            }
            // Two formulas side by side with the same source are one span of
            // that attribute, and two pieces: `markdown(from:)` reads them
            // run by run, and each picture is its own run.
            var parts: [NSRange] = []
            text.enumerateAttribute(.attachment, in: range) { _, part, _ in parts.append(part) }
            if parts.count < 2 { parts = [range] }
            let pieceUnits = Array(piece.utf16)
            for part in parts {
                runs.append(Run(display: part, source: NSRange(location: built.count, length: pieceUnits.count), isPiece: true))
                built.append(contentsOf: pieceUnits)
            }
        }
        self.runs = runs
        displayLength = text.length
        source = NSString(characters: built, length: built.count)
    }

    /// The source offset for a place on screen. A place inside a piece is
    /// after it — the caret cannot be inside a formula that is a picture.
    func sourceOffset(forDisplay offset: Int) -> Int {
        for run in runs where offset <= run.display.location + run.display.length {
            if offset <= run.display.location { return run.source.location }
            return run.isPiece
                ? run.source.location + run.source.length
                : run.source.location + (offset - run.display.location)
        }
        return source.length
    }

    /// The place on screen for a source offset. Inside a piece is after it.
    func displayOffset(forSource offset: Int) -> Int {
        for run in runs where offset <= run.source.location + run.source.length {
            if offset <= run.source.location { return run.display.location }
            return run.isPiece
                ? run.display.location + run.display.length
                : run.display.location + (offset - run.source.location)
        }
        return displayLength
    }

    func sourceRange(for display: NSRange) -> NSRange {
        let start = sourceOffset(forDisplay: display.location)
        let end = max(start, sourceOffset(forDisplay: display.location + display.length))
        return NSRange(location: start, length: end - start)
    }

    func displayRange(for source: NSRange) -> NSRange {
        let start = displayOffset(forSource: min(max(source.location, 0), self.source.length))
        let end = max(start, displayOffset(forSource: min(max(source.location + source.length, 0), self.source.length)))
        return NSRange(location: start, length: end - start)
    }

    /// Where a source offset falls inside a piece, the piece's source range.
    private func piece(around offset: Int) -> NSRange? {
        runs.first { $0.isPiece && $0.source.location < offset && offset < $0.source.location + $0.source.length }?.source
    }

    /// The edits on screen that make `changes` (source offsets) happen.
    ///
    /// A change that begins or ends inside a piece takes the whole piece with
    /// it and writes the piece back as its source — so the note says exactly
    /// what the changes say, and the next setting of the note sets it as
    /// mathematics again. Latex Suite nearly always edits the caret's line,
    /// which is shown as written, so this is nearly always one to one.
    func displayEdits(for changes: [LatexSuite.Change]) -> [(range: NSRange, text: String)] {
        var groups: [(span: NSRange, changes: [LatexSuite.Change])] = []
        for change in changes.sorted(by: { $0.range.location < $1.range.location }) {
            let start = piece(around: change.range.location)?.location ?? change.range.location
            let endOffset = change.range.location + change.range.length
            let end = piece(around: endOffset).map { $0.location + $0.length }
                ?? piece(around: change.range.location).map { max($0.location + $0.length, endOffset) }
                ?? endOffset
            let span = NSRange(location: start, length: max(end, endOffset) - start)
            if let last = groups.last, span.location < last.span.location + last.span.length {
                groups[groups.count - 1].span = NSUnionRange(last.span, span)
                groups[groups.count - 1].changes.append(change)
            } else {
                groups.append((span, [change]))
            }
        }
        return groups.map { group in
            var text = ""
            var cursor = group.span.location
            for change in group.changes {
                text += source.substring(with: NSRange(location: cursor, length: change.range.location - cursor))
                text += change.text
                cursor = change.range.location + change.range.length
            }
            text += source.substring(with: NSRange(location: cursor, length: group.span.location + group.span.length - cursor))
            return (displayRange(for: group.span), text)
        }
    }

    /// The changes that take `changes` back, against the text they leave.
    static func inverse(of changes: [LatexSuite.Change], in text: NSString) -> [LatexSuite.Change] {
        var shift = 0
        return changes.sorted { $0.range.location < $1.range.location }.map { change in
            let length = (change.text as NSString).length
            let undone = LatexSuite.Change(
                range: NSRange(location: change.range.location + shift, length: length),
                text: text.substring(with: change.range)
            )
            shift += length - change.range.length
            return undone
        }
    }

    /// A selection carried through changes: past what was put in where it
    /// stood, moved along by what was put in before it.
    static func map(_ range: NSRange, through changes: [LatexSuite.Change]) -> NSRange {
        func offset(_ position: Int) -> Int {
            var shift = 0
            for change in changes.sorted(by: { $0.range.location < $1.range.location }) {
                let end = change.range.location + change.range.length
                if end <= position && !(change.range.length == 0 && change.range.location == position) {
                    shift += (change.text as NSString).length - change.range.length
                } else if change.range.location <= position {
                    return change.range.location + shift + (change.text as NSString).length
                }
            }
            return position + shift
        }
        let start = offset(range.location)
        let end = max(start, offset(range.location + range.length))
        return NSRange(location: start, length: end - start)
    }
}
#endif
