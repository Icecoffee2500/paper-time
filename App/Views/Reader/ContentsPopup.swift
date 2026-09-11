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
                                if let destination = item.destination {
                                    link.destinationRequest = destination
                                }
                                dismiss()
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
        .frame(width: 230)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
        .liquidGlass(.floating, in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .background {
            // Escape puts it away, from anywhere in the window.
            Button("", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
    }
}
