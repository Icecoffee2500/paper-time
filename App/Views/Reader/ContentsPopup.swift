import PDFKit
import SwiftUI

/// The paper's own table of contents, summoned over the page.
///
/// A paper is read in sections, and the way back to one is its heading, not
/// its page number. This lists what `PaperContents` reads — the outline the
/// PDF carries, or the headings on its pages — as a narrow column floating
/// over the paper, tall rather than wide so that in a book spread it sits in
/// the gutter between the two pages and covers no words. It has no button;
/// it is a key, and Escape or a choice puts it away.
struct ContentsPopup: View {
    /// Where the list is put, which decides its shape.
    ///
    /// On the Mac it is a narrow column standing in the gutter of a spread.
    /// A touch screen has no gutter to spare and the page is read at arm's
    /// length, so there it is a wide, shallow panel along the foot of the
    /// paper — the headings get the width, the paper keeps its top.
    enum Placement { case gutter, footer }

    let link: ReaderLink
    var placement: Placement = .gutter
    let dismiss: () -> Void

    @State private var items: [PaperContents.Item] = []
    /// Whether the pages are still being read for their headings.
    @State private var reading = true
    /// How tall the headings are, so a panel along the foot of the page is as
    /// short as its contents allow. A scroll view takes whatever height it is
    /// offered, which in a footer is the rest of the screen.
    @State private var listHeight: CGFloat = 0

    /// The most of the page a footer list may cover.
    private static let footerLimit: CGFloat = 300

    /// The size the list sets its words in; the pictures of formulas are
    /// scaled to match it.
    private static var listSize: CGFloat { PlatformFont.preferredFont(forTextStyle: .callout).pointSize }

    /// Contents already read, by the document they were read from — a paper
    /// asked for its contents twice is not read twice.
    @MainActor private static var known: [URL: [PaperContents.Item]] = [:]
    private static let reader = DispatchQueue(label: "PaperTime.Contents", qos: .userInitiated)

    /// Reads the contents off a copy of the document on another thread.
    ///
    /// Finding headings means reading every page's text and walking its
    /// content stream, half a second for a long paper — too long to hold the
    /// key press for. PDFKit's document is not to be read from two threads at
    /// once, so the copy is opened from the same file, and the headings come
    /// back as page indices and points that the view's own document can go to.
    private func load() {
        guard let document = link.session?.document else { reading = false; return }
        let size = Self.listSize
        if let url = document.documentURL, let cached = Self.known[url] {
            items = cached
            reading = false
            return
        }
        let url = document.documentURL
        let data = url == nil ? document.dataRepresentation() : nil
        let identity = ObjectIdentifier(document)
        Self.reader.async {
            let copy = url.flatMap { PDFDocument(url: $0) } ?? data.flatMap { PDFDocument(data: $0) }
            let found = copy.map { PaperContents.items(in: $0, listSize: size) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let url { Self.known[url] = found }
                    // Still the same paper: the reader may have moved on.
                    guard link.session.map({ ObjectIdentifier($0.document) }) == identity else { return }
                    items = found
                    reading = false
                }
            }
        }
    }

    private func go(to item: PaperContents.Item) {
        guard let document = link.session?.document, let index = item.pageIndex,
              let page = document.page(at: index)
        else { return }
        let top = CGPoint(x: kPDFDestinationUnspecifiedValue, y: page.bounds(for: .cropBox).maxY)
        link.destinationRequest = PDFDestination(page: page, at: item.point ?? top)
    }

    /// The row's heading, words and pictures run together as one `Text`.
    private func heading(_ item: PaperContents.Item) -> Text {
        item.pieces.reduce(Text("")) { text, piece in
            switch piece {
            case .words(let words):
                return text + Text(words)
            case .picture(let image, let scale):
                return text + Text(" ") + Text(Image(decorative: image, scale: scale)) + Text(" ")
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
                Text(reading ? "Reading the paper for its headings…" : "No headings could be found in this PDF.")
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
                                go(to: item)
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollIndicators(.never)
                .frame(height: placement == .footer
                    ? min(max(listHeight, 44), Self.footerLimit)
                    : nil)
            }
        }
        // As wide as the gutter allows and no wider: in a book the list sits
        // between the pages, and it should sit there with room to spare.
        // Along the foot of the page it takes the width instead, which is
        // what lets a heading be read without wrapping.
        .frame(width: placement == .gutter
            ? (link.bookGutter > 0 ? max(180, min(300, link.bookGutter - 40)) : 220)
            : nil)
        .frame(maxWidth: placement == .gutter ? nil : .infinity)
        .frame(maxHeight: placement == .gutter ? 520 : nil)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
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

