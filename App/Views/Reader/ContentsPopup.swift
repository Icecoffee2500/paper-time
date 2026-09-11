import PDFKit
import SwiftUI

/// The paper's own table of contents, summoned over the page.
///
/// A paper is read in sections, and the way back to one is its heading, not
/// its page number. This reads the outline the PDF carries — most papers set
/// from LaTeX have one — and lists it as a narrow column floating over the
/// paper, tall rather than wide so that in a book spread it sits in the
/// gutter between the two pages and covers no words. It has no button; it is
/// a key, and Escape or a choice puts it away.
struct ContentsPopup: View {
    let link: ReaderLink
    let dismiss: () -> Void

    private struct Item: Identifiable {
        let id: Int
        let title: String
        let level: Int
        let destination: PDFDestination?
        let pageNumber: Int?
        /// The heading in pieces: the words, and — where the heading has
        /// mathematics in it — a rendering of that mathematics from the page.
        let pieces: [Piece]
    }

    enum Piece {
        case words(String)
        case picture(NSImage)
    }

    @State private var items: [Item] = []

    /// Where the contents come from, by preference: the outline the PDF
    /// carries, and failing that the headings found on the pages themselves.
    private func build() -> [Item] {
        guard let document = link.session?.document else { return [] }
        let found = fromOutline(document)
        return found.isEmpty ? fromHeadings(document) : found
    }

    private func fromOutline(_ document: PDFDocument) -> [Item] {
        guard let root = document.outlineRoot else { return [] }
        var found: [Item] = []
        func walk(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !label.isEmpty {
                    let page = child.destination?.page
                    let line = child.destination.flatMap { Self.headingLine(matching: label, at: $0) }
                    found.append(Item(
                        id: found.count, title: label, level: level,
                        destination: child.destination,
                        pageNumber: page.map { document.index(for: $0) + 1 },
                        pieces: line.map { Self.pieces(label: label, line: $0.selection, on: $0.page) } ?? [.words(label)]
                    ))
                }
                // Two levels is what a paper has — sections and subsections.
                // Deeper than that is a thesis, and a thesis can scroll.
                if level < 1 { walk(child, level: level + 1) }
            }
        }
        walk(root, level: 0)
        return found
    }

    /// Headings read off the pages, for a PDF with no outline.
    ///
    /// A heading is a short line on its own, set a step larger than the body
    /// or set bold, and often numbered. The body's size is the size most of
    /// the page's characters are set in. Lines much larger than that are the
    /// title; lines much smaller are the axes of a figure; author lists are
    /// long and full of commas; captions begin "Fig." — none of them is a
    /// heading, and a list with them in it was not a table of contents.
    private func fromHeadings(_ document: PDFDocument) -> [Item] {
        struct Line { let page: PDFPage; let index: Int; let selection: PDFSelection; let text: String; let size: CGFloat; let bold: Bool }
        var weight: [CGFloat: Int] = [:]
        var lines: [Line] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let all = page.selection(for: page.bounds(for: .mediaBox))
            else { continue }
            for line in all.selectionsByLine() {
                guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                let font = line.attributedString?.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont
                let size = (font?.pointSize ?? 0).rounded()
                let bold = (font?.fontName ?? "").lowercased().contains("bold")
                weight[size, default: 0] += text.count
                lines.append(Line(page: page, index: index, selection: line, text: text, size: size, bold: bold))
            }
        }
        guard let body = weight.max(by: { $0.value < $1.value })?.key, body > 0,
              let numbered = try? NSRegularExpression(pattern: #"^(\d+(\.\d+)*\.?|[IVX]+\.|[A-Z]\.)\s+\S"#)
        else { return [] }
        var found: [Item] = []
        for line in lines {
            let text = line.text
            let letters = text.filter(\.isLetter).count
            let words = text.split(separator: " ")
            // "A B C" under a figure is bold and short and not a heading.
            guard letters >= 4, words.contains(where: { $0.count > 1 }),
                  text.contains(where: \.isLowercase) || letters >= 6,
                  text.count >= 4, text.count <= 80,
                  text.filter({ $0 == "," }).count < 3,
                  !text.lowercased().hasPrefix("fig"), !text.lowercased().hasPrefix("table")
            else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let hasNumber = numbered.firstMatch(in: text, range: range) != nil
            let step = line.size - body
            // A step up, but not the title's leap; or bold at body size, on a
            // line short enough to be a heading rather than a paragraph.
            let larger = step >= 1 && step <= body * 0.7
            let boldHeading = line.bold && line.size >= body - 0.5 && line.size <= body + 0.5 && text.count <= 60
            guard larger || boldHeading else { continue }
            guard !text.hasSuffix(",") else { continue }
            let head = text.prefix { !$0.isWhitespace }
            let subsection = hasNumber && (
                (head.first?.isNumber == true && head.filter { $0 == "." }.count >= 1 && !head.hasSuffix("."))
                || (head.first?.isLetter == true && head.count == 2)
            )
            let bounds = line.selection.bounds(for: line.page)
            let destination = PDFDestination(page: line.page, at: CGPoint(x: bounds.minX, y: bounds.maxY + 12))
            found.append(Item(
                id: found.count, title: text, level: subsection ? 1 : 0, destination: destination,
                pageNumber: line.index + 1,
                pieces: Self.pieces(label: text, line: line.selection, on: line.page)
            ))
            if found.count >= 80 { break }
        }
        // Fewer than two is not a table of contents; say so rather than
        // show a stray line dressed up as one.
        return found.count >= 2 ? found : []
    }

    /// The printed heading an outline label stands for.
    ///
    /// LaTeX writes bookmarks from the heading with the mathematics taken out
    /// — "The π₀ Model" becomes "The 0 Model" — and reading the text back
    /// off the page is no better: the maths font hands PDFKit a "w" for π.
    /// So the line is not read, it is *drawn*: this finds the line at the
    /// place the bookmark points to whose letters and digits contain the
    /// label's, and the row shows a rendering of that line, in the paper's
    /// own type, symbol and all.
    private static func headingLine(matching label: String, at destination: PDFDestination) -> (selection: PDFSelection, page: PDFPage)? {
        guard let page = destination.page else { return nil }
        let key = compact(label)
        guard key.count >= 3 else { return nil }
        let box = page.bounds(for: .cropBox)
        let band = CGRect(x: box.minX, y: destination.point.y - 48, width: box.width, height: 64)
        guard let lines = page.selection(for: band)?.selectionsByLine() else { return nil }
        var best: (extra: Int, line: PDFSelection)?
        for line in lines {
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let candidate = compact(text)
            // Letters the maths font mangles are skipped on both sides: the
            // label has none of them and the line has the wrong ones.
            guard contains(candidate, inOrder: key, slack: 3) else { continue }
            let extra = abs(candidate.count - key.count)
            if best == nil || extra < best!.extra { best = (extra, line) }
        }
        guard let best else { return nil }
        return (best.line, page)
    }

    /// The heading as words with its mathematics spliced in as pictures.
    ///
    /// PDFKit reports every run of a line as "Helvetica", whatever the PDF
    /// set it in, so a formula cannot be told by its font. It can be told by
    /// its letters: the outline's label was written with the mathematics
    /// left out, so whatever the printed line has that the label does not —
    /// read in order, letter by letter — is the formula. "IV. THE ω0 MODEL"
    /// against "The 0 Model" leaves the ω (PDFKit's reading of π), and the
    /// small "0" beside it is taken along as its subscript. That stretch is
    /// cut from the page as a picture; the words either side come from the
    /// label, in the label's own case. A heading with no label of its own is
    /// read the same way, with any letter outside ASCII standing as the
    /// formula.
    private static func pieces(label: String, line: PDFSelection, on page: PDFPage) -> [Piece] {
        guard let attributed = line.attributedString, attributed.length > 0,
              let pageString = page.string
        else { return [.words(label)] }
        let printed = attributed.string
        let characters = Array(printed)
        guard characters.count == attributed.length else { return [.words(label)] }

        // Each character's size, and the size most of them have.
        var sizes = [CGFloat](repeating: 0, count: characters.count)
        var weight: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let size = ((value as? NSFont)?.pointSize ?? 0).rounded()
            for index in range.location..<(range.location + range.length) where index < sizes.count { sizes[index] = size }
            weight[size, default: 0] += range.length
        }
        let dominant = weight.max { $0.value < $1.value }?.key ?? 0

        // Where the formula is: the printed letters the label has no match
        // for, in order, after the section number the label never carries.
        let lead = printed.count - stripNumbering(printed).count
        var candidates: [Int] = []
        if compact(label) == compact(printed) {
            for (index, character) in characters.enumerated() where index >= lead {
                if !character.isASCII, !character.isWhitespace, character.isLetter || character.isSymbol {
                    candidates.append(index)
                }
            }
        } else {
            let key = compact(label)
            var next = 0
            for (index, character) in characters.enumerated() where index >= lead {
                let lowered = Character(character.lowercased())
                if character.isLetter || character.isNumber {
                    if next < key.count, lowered == key[next] {
                        next += 1
                    } else {
                        candidates.append(index)
                    }
                } else if !character.isASCII, !character.isWhitespace {
                    candidates.append(index)
                }
            }
        }
        guard let first = candidates.first, let last = candidates.last else { return [.words(label)] }

        // The formula's own sub- and superscripts sit beside it, smaller.
        var from = first, to = last
        while from - 1 >= lead, !characters[from - 1].isWhitespace, sizes[from - 1] < dominant - 0.5 { from -= 1 }
        while to + 1 < characters.count, !characters[to + 1].isWhitespace, sizes[to + 1] < dominant - 0.5 { to += 1 }
        guard to - from + 1 < characters.count * 3 / 5 else { return [.words(label)] }

        // Where the stretch sits on the page, so it can be cut out: a
        // selection over those characters, asked for its bounds. Not
        // `characterBounds(at:)`, which on this very heading answered with
        // rectangles a hundred points from the line and a third its height —
        // a selection's bounds are the ones PDFKit itself draws with.
        let lineRange = (pageString as NSString).range(of: printed)
        guard lineRange.location != NSNotFound else { return [.words(label)] }
        let lineBounds = line.bounds(for: page)
        let stretch = NSRange(location: lineRange.location + from, length: to - from + 1)
        guard let glyphs = page.selection(for: stretch) else { return [.words(label)] }
        let box = glyphs.bounds(for: page)
        guard box.width > 1, box.height > 2, lineBounds.insetBy(dx: -8, dy: -8).contains(box),
              let picture = snippet(of: box.insetBy(dx: -1.5, dy: -1), on: page)
        else { return [.words(label)] }

        // The words either side, from the label: as many of its letters as
        // were matched before the formula, and after it.
        let (head, tail): (String, String)
        if compact(label) == compact(printed) {
            head = String(characters[lead..<from]).trimmingCharacters(in: .whitespaces)
            tail = String(characters[(to + 1)...]).trimmingCharacters(in: .whitespaces)
        } else {
            // Label letters matched inside the stretch (a digit under the
            // symbol) belong to the picture; count only what lies outside.
            let key = compact(label)
            var before = 0, after = 0, next = 0
            for (index, character) in characters.enumerated() where index >= lead && (character.isLetter || character.isNumber) {
                let lowered = Character(character.lowercased())
                guard next < key.count, lowered == key[next] else { continue }
                next += 1
                if index < from { before += 1 } else if index > to { after += 1 }
            }
            (head, tail) = split(label, keepingFirst: before, last: after)
        }
        var result: [Piece] = []
        if !head.isEmpty { result.append(.words(head)) }
        result.append(.picture(picture))
        if !tail.isEmpty { result.append(.words(tail)) }
        return result
    }

    private static func stripNumbering(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\s*(\d+(\.\d+)*\.?|[IVXLC]+\.|[A-Z]\.)\s+"#, with: "", options: .regularExpression)
    }

    /// The label's opening and closing words, by how many of its letters and
    /// digits belong to each; what lies between was the formula.
    private static func split(_ label: String, keepingFirst prefix: Int, last suffix: Int) -> (String, String) {
        let characters = Array(label)
        let alnum = characters.indices.filter { characters[$0].isLetter || characters[$0].isNumber }
        let headEnd = prefix > 0 && prefix <= alnum.count ? alnum[prefix - 1] + 1 : 0
        let tailStart = suffix > 0 && suffix <= alnum.count ? alnum[alnum.count - suffix] : characters.count
        let head = String(characters[0..<headEnd]).trimmingCharacters(in: .whitespaces)
        let tail = tailStart < characters.count ? String(characters[tailStart...]).trimmingCharacters(in: .whitespaces) : ""
        return (head, tail)
    }

    private static func compact(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Whether the needle's characters appear in the haystack in order,
    /// allowing a few of them to be missing — the ones a symbol displaced.
    private static func contains(_ haystack: [Character], inOrder needle: [Character], slack: Int) -> Bool {
        var index = 0, missed = 0
        var position = 0
        while index < needle.count {
            if let found = haystack[position...].firstIndex(of: needle[index]) {
                position = found + 1
            } else {
                missed += 1
                if missed > slack { return false }
            }
            index += 1
        }
        return true
    }

    /// The line as the page prints it, drawn at four times its size so it
    /// stays crisp at the size it is shown.
    private static func snippet(of rect: CGRect, on page: PDFPage) -> NSImage? {
        guard rect.width > 2, rect.height > 3, rect.width < 400 else { return nil }
        let pixels: CGFloat = 4
        let image = NSImage(size: NSSize(width: rect.width * pixels, height: rect.height * pixels))
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            context.scaleBy(x: pixels, y: pixels)
            // `draw(with:to:)` puts the box's corner at the origin.
            let box = page.bounds(for: .mediaBox)
            context.translateBy(x: -(rect.minX - box.minX), y: -(rect.minY - box.minY))
            page.draw(with: .mediaBox, to: context)
        }
        image.unlockFocus()
        // Shown at the height of a line of the list's type — the formula was
        // set at the paper's heading size, which is not the list's.
        let shown: CGFloat = 15
        image.size = NSSize(width: rect.width * shown / rect.height, height: shown)
        return image
    }

    /// The row's heading, words and pictures run together as one `Text`.
    private func heading(_ item: Item) -> Text {
        item.pieces.reduce(Text("")) { text, piece in
            switch piece {
            case .words(let words):
                return text + Text(words)
            case .picture(let image):
                // Multiplied onto the list so the paper's white around the
                // formula vanishes; inverted first in the dark.
                return text + Text(" ") + Text(Image(nsImage: image)) + Text(" ")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Contents")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if items.isEmpty {
                Text("No headings could be found in this PDF.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(items) { item in
                            Button {
                                // Goes there and stays open: reading by
                                // sections means going to several in a row,
                                // and Escape or a click on the page is what
                                // puts the list away.
                                if let destination = item.destination {
                                    link.destinationRequest = destination
                                }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    // Words in the list's own type, mathematics as
                                    // a picture of itself — the way the paper sets
                                    // its heading, and readable at this size, which
                                    // a picture of the whole line was not.
                                    heading(item)
                                        .font(item.level == 0 ? .callout.weight(.medium) : .callout)
                                        .foregroundStyle(item.level == 0 ? .primary : .secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 4)
                                    if let page = item.pageNumber {
                                        Text("\(page)")
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.leading, CGFloat(item.level) * 12)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .pressable()
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }
        }
        // As wide as the gutter allows and no wider: in a book the list sits
        // between the pages, and it should sit there with room to spare.
        .frame(width: link.bookGutter > 0 ? max(180, min(300, link.bookGutter - 40)) : 220)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { items = build() }
        .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .background {
            // Escape puts it away, from anywhere in the window — and so
            // does a click on anything that is not the list.
            Button("", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
            ClickOutside(onClick: dismiss)
        }
    }
}

#if os(macOS)
/// Notices a click that lands outside the view this sits in.
///
/// The click itself goes on to whatever it landed on: the list is put away,
/// and the page still gets the click that put it away — the way a popover
/// behaves, rather than the way a modal does.
private struct ClickOutside: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> Watcher {
        let watcher = Watcher()
        watcher.onClick = onClick
        return watcher
    }

    func updateNSView(_ view: Watcher, context: Context) { view.onClick = onClick }

    final class Watcher: NSView {
        var onClick: (() -> Void)?
        // Removed in deinit, which is nonisolated; the monitor token is an
        // opaque object AppKit hands back and nothing else touches it.
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                // This view fills the popup's frame (it is its background),
                // so "outside the popup" is "outside this view".
                let inView = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(inView) { self.onClick?() }
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#else
private struct ClickOutside: View {
    let onClick: () -> Void
    var body: some View { EmptyView() }
}
#endif

