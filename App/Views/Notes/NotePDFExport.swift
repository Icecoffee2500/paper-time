#if os(macOS)
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A note as a PDF: the title over the note set the way the editor sets it —
/// headings, bullets, quotations with their rule, formulas, tables — on A4
/// pages, a page number at the foot of each.
///
/// The note is laid out once, with TextKit 2, at the width of a page's text
/// block, and the pages are cut between its layout fragments: a paragraph
/// that would run past the foot of a page starts the next one, and no line
/// is cut in two. Each page is then drawn into the PDF's own graphics
/// context — vector type, not a picture of it — by the same fragments that
/// draw the note on screen (`NoteLayoutFragment`), so the quotation's rule
/// and the passage chips come with it.
@MainActor
enum NotePDFExport {
    /// A4, and the margins round the text block, in points.
    static let paper = CGSize(width: 595.28, height: 841.89)
    static let margins = NSEdgeInsets(top: 64, left: 60, bottom: 64, right: 60)

    /// Asks where to save, then writes the note there. `window` takes the
    /// save sheet; without one the panel stands on its own.
    static func export(title: String, markdown: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName(for: title) + ".pdf"
        panel.title = L("PDF로 내보내기", "Export as PDF")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(title: title, markdown: markdown, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = L("PDF를 저장하지 못했어요", "Couldn't Save the PDF")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// A file name out of a title: the separators a file system refuses are
    /// taken out, and an empty title is «노트» / «Note».
    static func fileName(for title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortened = String(cleaned.prefix(80))
        return shortened.isEmpty ? L("노트", "Note") : shortened
    }

    /// Writes the PDF. Pure of any panel, so a probe can call it.
    static func write(title: String, markdown: String, to url: URL) throws {
        let data = try pdfData(title: title, markdown: markdown)
        try data.write(to: url, options: .atomic)
    }

    private final class Fragments: NSObject, NSTextLayoutManagerDelegate {
        func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager,
            textLayoutFragmentFor location: any NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            NoteLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { L("PDF를 만들지 못했어요.", "The PDF could not be made.") }
    }

    /// The PDF's bytes.
    static func pdfData(title: String, markdown: String) throws -> Data {
        let width = paper.width - margins.left - margins.right
        let height = paper.height - margins.top - margins.bottom
        // The title is the note's first heading; a note with no title is
        // just the note.
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = heading.isEmpty ? markdown : "# \(heading)\n\n" + markdown

        // Laid out in the light appearance whatever the screen shows: paper
        // is white, and a formula drawn for a dark note is white ink.
        let light = NSAppearance(named: .aqua)
        var rendered: NSAttributedString?
        light?.performAsCurrentDrawingAppearance {
            rendered = NoteMarkdown.render(source, width: width, appearance: light).text
        }
        guard let rendered else { throw Failure() }

        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.drawsBackground = false
        let fragments = Fragments()
        view.textLayoutManager?.delegate = fragments
        view.textStorage?.setAttributedString(rendered)
        guard let layout = view.textLayoutManager else { throw Failure() }
        layout.ensureLayout(for: layout.documentRange)
        view.layoutSubtreeIfNeeded()

        // The pages: fragments gathered until the next would run past the
        // foot. A fragment taller than a page — a very long table — has a
        // page of its own and is cut at its foot.
        var pages: [[NSTextLayoutFragment]] = [[]]
        var top: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if !pages[pages.count - 1].isEmpty, frame.maxY - top > height {
                pages.append([])
                top = frame.minY
            }
            pages[pages.count - 1].append(fragment)
            return true
        }
        if pages.last?.isEmpty == true { pages.removeLast() }
        if pages.isEmpty { pages = [[]] }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw Failure() }
        var box = CGRect(origin: .zero, size: paper)
        let footer = NoteTypography.body().withSize(9)
        for (number, page) in pages.enumerated() {
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            light?.performAsCurrentDrawingAppearance {
                // The text block is flipped (TextKit's y grows downward);
                // the PDF's does not. Each fragment is drawn where it stands
                // on its page.
                let pageTop = page.first?.layoutFragmentFrame.minY ?? 0
                context.saveGState()
                context.translateBy(x: margins.left, y: paper.height - margins.top)
                context.scaleBy(x: 1, y: -1)
                // Each fragment with the context moved to its own origin, as
                // the text view draws them: what a fragment draws of its own
                // — the quotation's rule — is drawn at the context's origin.
                for fragment in page {
                    let frame = fragment.layoutFragmentFrame
                    context.saveGState()
                    context.translateBy(x: frame.minX, y: frame.minY - pageTop)
                    fragment.draw(at: .zero, in: context)
                    context.restoreGState()
                }
                context.restoreGState()
                // The page number, at the foot, in the margin's quiet grey.
                let label = NSAttributedString(
                    string: "\(number + 1) / \(pages.count)",
                    attributes: [.font: footer, .foregroundColor: NSColor.secondaryLabelColor]
                )
                let size = label.size()
                label.draw(at: CGPoint(x: (paper.width - size.width) / 2, y: margins.bottom / 2 - size.height / 2))
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
#endif
