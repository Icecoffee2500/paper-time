import SwiftUI

/// A short explainer for getting the exported file into Overleaf.
///
/// Collapsed by default: the export sheet is about the file itself, not a
/// tutorial, so this stays out of the way until someone asks for it.
struct ExportInstructionsView: View {
    var body: some View {
        DisclosureGroup("Using this file in Overleaf") {
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Save the exported .bib file somewhere you can find it.")
                step(2, "Open your project on Overleaf.")
                step(3, "Drag the file into the file list on the left, or use the project's Upload button.")
                step(
                    4,
                    "Reference it from your document with \\bibliography{refs} for plain BibTeX, or \\addbibresource{refs.bib} for biblatex — matching whatever you named the file."
                )
                Text("Uploading a file with the same name replaces the one already in the project.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.top, 4)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(text)
        }
        .font(.callout)
    }
}
