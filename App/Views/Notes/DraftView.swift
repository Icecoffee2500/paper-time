import Bibliography
import PaperCore
import SwiftUI

/// A draft: the note that is leaving the box.
///
/// Written like any note — prose, links to notes, passages with addresses —
/// and rendered for the manuscript on the way out: every passage becomes
/// the citation of its paper, every linked note unfolds into its words, and
/// a `.bib` of exactly the papers cited goes with it. What leaves arrives
/// in Overleaf with its references intact.
struct DraftView: View {
    let model: LibraryModel
    let draftID: String
    let link: ReaderLink

    @State private var exporting = false

    var body: some View {
        ZettelEditorView(notes: model.notes, noteID: draftID, link: link)
            .overlay(alignment: .topTrailing) {
                Button {
                    exporting = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .help("Render the draft for the manuscript (Shift-Command-E)")
                .padding(.trailing, 60)
                .padding(.top, 14)
            }
            .sheet(isPresented: $exporting) {
                if let draft = model.notes.note(draftID) {
                    DraftExportSheet(model: model, draft: draft)
                }
            }
    }
}

/// The rendered draft and its bibliography, ready to copy.
struct DraftExportSheet: View {
    let model: LibraryModel
    let draft: Zettel
    @Environment(\.dismiss) private var dismiss
    @State private var format: DraftRenderer.Format = .latex

    private var rendered: (text: String, bib: String, count: Int) {
        let keys = model.citationKeys()
        let made = DraftRenderer.render(draft, as: format, key: { keys[$0] }, note: { model.notes.note($0) })
        let entries = made.cited.compactMap { id -> BibTeXEntry? in
            guard let paper = model.paper(id) else { return nil }
            return BibTeXWriter.entry(for: paper.meta.csl, key: keys[id] ?? paper.meta.bibKey, identifiers: paper.meta.identifiers)
        }
        return (made.text, BibTeXWriter.write(entries), made.cited.count)
    }

    var body: some View {
        let made = rendered
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.displayTitle).font(.headline)
                Spacer()
                Picker("Format", selection: $format) {
                    Text("LaTeX").tag(DraftRenderer.Format.latex)
                    Text("Markdown").tag(DraftRenderer.Format.markdown)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            Text(made.count == 1 ? "1 paper cited" : "\(made.count) papers cited")
                .font(.caption)
                .foregroundStyle(.secondary)
            pane("Text", made.text)
            pane("references.bib", made.bib)
            HStack {
                Spacer()
                Button("Copy .bib") { copy(made.bib) }
                Button("Copy Text") { copy(made.text) }
                Button("Copy Both") { copy(made.text + "\n\n" + made.bib) }
                    .buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
    }

    private func pane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: Corner.row, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
