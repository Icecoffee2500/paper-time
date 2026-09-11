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
    }

    private var items: [Item] {
        guard let document = link.session?.document, let root = document.outlineRoot else { return [] }
        var found: [Item] = []
        func walk(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                var title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let destination = child.destination {
                    title = Self.heading(matching: title, at: destination) ?? title
                }
                if !title.isEmpty {
                    let page = child.destination?.page.map { document.index(for: $0) + 1 }
                    found.append(Item(id: found.count, title: title, level: level,
                                      destination: child.destination, pageNumber: page))
                }
                // Two levels is what a paper has — sections and subsections.
                // Deeper than that is a thesis, and a thesis can scroll.
                if level < 1 { walk(child, level: level + 1) }
            }
        }
        walk(root, level: 0)
        return found
    }

    /// The heading as it is printed, for an outline label that lost something
    /// on the way into the file.
    ///
    /// LaTeX writes bookmarks from the heading with the mathematics taken out
    /// — "The π₀ Model" becomes "The 0 Model" — because a PDF outline is plain
    /// text and hyperref would rather drop a symbol than guess at it. The
    /// heading is still on the page, in its real glyphs, at the place the
    /// bookmark points to; this reads the lines around that point and takes
    /// the one whose letters and digits match the label's. All-capitals
    /// headings are given back their case, word by word, leaving alone any
    /// word with something in it that is not a plain letter.
    private static func heading(matching label: String, at destination: PDFDestination) -> String? {
        guard let page = destination.page else { return nil }
        let key = compact(label)
        guard key.count >= 3 else { return nil }
        let box = page.bounds(for: .cropBox)
        // A band below the destination point, which hyperref places just
        // above the heading; a little above too, for outlines set by hand.
        let band = CGRect(x: box.minX, y: destination.point.y - 48, width: box.width, height: 64)
        guard let lines = page.selection(for: band)?.selectionsByLine() else { return nil }
        var best: (score: Int, text: String)?
        for line in lines {
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let candidate = compact(text)
            // The label's letters have to be in the line, in order; the line
            // may have more (the symbol, a section number).
            guard contains(candidate, inOrder: key) else { continue }
            let extra = candidate.count - key.count
            if best == nil || extra < best!.score { best = (extra, text) }
        }
        guard let best, best.score > 0 else { return nil }
        return recase(best.text, like: label)
    }

    private static func compact(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func contains(_ haystack: [Character], inOrder needle: [Character]) -> Bool {
        var index = 0
        for character in haystack where index < needle.count && character == needle[index] { index += 1 }
        return index == needle.count
    }

    /// The label's own words in the label's own case, with the line's extra
    /// glyphs spliced in where they fall; a heading set in capitals stays
    /// readable rather than shouting.
    private static func recase(_ line: String, like label: String) -> String {
        var text = line
        // A leading section number or roman numeral the label did without.
        if let range = text.range(of: #"^\s*(\d+(\.\d+)*\.?|[IVXLC]+\.)\s+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        let letters = text.filter(\.isLetter)
        let isShouting = !letters.isEmpty && letters.allSatisfy { $0.isUppercase }
        guard isShouting else { return text }
        return text.split(separator: " ").map { word -> String in
            let plain = word.allSatisfy { $0.isLetter && $0.isASCII }
            return plain ? word.prefix(1).uppercased() + word.dropFirst().lowercased() : String(word)
        }.joined(separator: " ")
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
                Text("This PDF carries no table of contents.")
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
                                    Text(item.title)
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
