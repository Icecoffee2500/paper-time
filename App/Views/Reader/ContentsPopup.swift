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
                let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        .frame(width: 200)
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
