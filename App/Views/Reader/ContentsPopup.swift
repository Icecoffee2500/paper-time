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
    @Environment(\.colorScheme) private var scheme

    private struct Item: Identifiable {
        let id: Int
        let title: String
        let level: Int
        let destination: PDFDestination?
        let pageNumber: Int?
        /// The heading as the page prints it, when the line could be found.
        let snippet: NSImage?
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
                        snippet: line.flatMap { Self.snippet(of: $0.bounds, on: $0.page) }
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
    /// A heading is a short line set larger or bolder than the body, and
    /// usually numbered. The body's size is what most lines are; anything a
    /// step above it on its own line is a heading, and the numbering says
    /// how deep — "5" a section, "5.2" or "A." a subsection.
    private func fromHeadings(_ document: PDFDocument) -> [Item] {
        var sizes: [CGFloat] = []
        var lines: [(page: PDFPage, index: Int, selection: PDFSelection, text: String, size: CGFloat, bold: Bool)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let all = page.selection(for: page.bounds(for: .mediaBox))
            else { continue }
            for line in all.selectionsByLine() {
                guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                let attributes = line.attributedString?.attributes(at: 0, effectiveRange: nil)
                let font = attributes?[.font] as? NSFont
                let size = font?.pointSize ?? 0
                let bold = (font?.fontName ?? "").lowercased().contains("bold")
                sizes.append(size)
                lines.append((page, index, line, text, size, bold))
            }
        }
        guard !sizes.isEmpty else { return [] }
        let body = sizes.sorted()[sizes.count / 2]
        guard let numbered = try? NSRegularExpression(pattern: #"^(\d+(\.\d+)*\.?|[IVX]+\.|[A-Z]\.)\s+\S"#)
        else { return [] }
        var found: [Item] = []
        for line in lines where line.text.count >= 3 && line.text.count <= 90 {
            let range = NSRange(line.text.startIndex..., in: line.text)
            let hasNumber = numbered.firstMatch(in: line.text, range: range) != nil
            let larger = line.size >= body + 0.8
            guard (larger || (line.bold && hasNumber)), !line.text.hasSuffix(".") || hasNumber else { continue }
            // Depth from the numbering; an unnumbered larger line is a section.
            let head = line.text.prefix { !$0.isWhitespace }
            let level = hasNumber && (head.contains(".") && head.first?.isNumber == true && head.filter({ $0 == "." }).count > 1
                                      || head.first?.isLetter == true && head.count == 2) ? 1 : 0
            let bounds = line.selection.bounds(for: line.page)
            let destination = PDFDestination(page: line.page, at: CGPoint(x: bounds.minX, y: bounds.maxY + 12))
            found.append(Item(
                id: found.count, title: line.text, level: level, destination: destination,
                pageNumber: line.index + 1,
                snippet: Self.snippet(of: bounds, on: line.page)
            ))
            if found.count >= 80 { break }
        }
        // The title page's own lines are all "larger"; a run of them at the
        // top of page one is the title and the authors, not the contents.
        // Keep the last few on that page — the abstract and introduction
        // headings — and drop the rest.
        let onFirstPage = found.filter { $0.pageNumber == 1 }
        if onFirstPage.count > 3 {
            let dropped = Set(onFirstPage.dropLast(2).map(\.id))
            found.removeAll { dropped.contains($0.id) }
        }
        return found.enumerated().map { offset, item in
            Item(id: offset, title: item.title, level: item.level, destination: item.destination,
                 pageNumber: item.pageNumber, snippet: item.snippet)
        }
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
    private static func headingLine(matching label: String, at destination: PDFDestination) -> (bounds: CGRect, page: PDFPage)? {
        guard let page = destination.page else { return nil }
        let key = compact(label)
        guard key.count >= 3 else { return nil }
        let box = page.bounds(for: .cropBox)
        let band = CGRect(x: box.minX, y: destination.point.y - 48, width: box.width, height: 64)
        guard let lines = page.selection(for: band)?.selectionsByLine() else { return nil }
        var best: (extra: Int, bounds: CGRect)?
        for line in lines {
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let candidate = compact(text)
            // Letters the maths font mangles are skipped on both sides: the
            // label has none of them and the line has the wrong ones.
            guard contains(candidate, inOrder: key, slack: 3) else { continue }
            let extra = abs(candidate.count - key.count)
            if best == nil || extra < best!.extra { best = (extra, line.bounds(for: page)) }
        }
        guard let best else { return nil }
        return (best.bounds, page)
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
    private static func snippet(of bounds: CGRect, on page: PDFPage) -> NSImage? {
        let rect = bounds.insetBy(dx: -2, dy: -1.5)
        guard rect.width > 4, rect.height > 4, rect.width < 700 else { return nil }
        let scale: CGFloat = 4
        let image = NSImage(size: NSSize(width: rect.width * scale, height: rect.height * scale))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: image.size))
        context.scaleBy(x: scale, y: scale)
        // `draw(with:to:)` puts the box's corner at the origin.
        let box = page.bounds(for: .mediaBox)
        context.translateBy(x: -(rect.minX - box.minX), y: -(rect.minY - box.minY))
        page.draw(with: .mediaBox, to: context)
        return image
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
                                HStack(alignment: .center, spacing: 6) {
                                    if let snippet = item.snippet {
                                        // The heading as printed — the paper's
                                        // type, its symbols — multiplied onto
                                        // the list so its white paper vanishes.
                                        // At the size of a line of the list, and cut
                                        // at the right edge if it runs long — a heading
                                        // shrunk to fit its whole length was legible to
                                        // nobody, and the first words are the ones that
                                        // name a section.
                                        Image(nsImage: snippet)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(height: item.level == 0 ? 15 : 13)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .clipped()
                                            .mask(
                                                LinearGradient(
                                                    stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                                    startPoint: .leading, endPoint: .trailing
                                                )
                                            )
                                            .blendMode(scheme == .dark ? .screen : .multiply)
                                            .colorInvertedIfDark(scheme)
                                            .opacity(item.level == 0 ? 1 : 0.75)
                                            .accessibilityLabel(item.title)
                                    } else {
                                        Text(item.title)
                                            .font(item.level == 0 ? .callout.weight(.medium) : .callout)
                                            .foregroundStyle(item.level == 0 ? .primary : .secondary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
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


private extension View {
    /// Black type on white becomes white type on nothing in the dark.
    @ViewBuilder
    func colorInvertedIfDark(_ scheme: ColorScheme) -> some View {
        if scheme == .dark { colorInvert() } else { self }
    }
}
