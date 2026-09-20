import SwiftUI

/// A short explainer for getting the exported file into Overleaf.
///
/// Collapsed by default: the export sheet is about the file itself, not a
/// tutorial, so this stays out of the way until someone asks for it.
struct ExportInstructionsView: View {
    var body: some View {
        DisclosureGroup(L("이 파일을 Overleaf에서 쓰기", "Using this file in Overleaf")) {
            VStack(alignment: .leading, spacing: 10) {
                step(1, L("내보낸 .bib 파일을 찾을 수 있는 곳에 저장한다.", "Save the exported .bib file somewhere you can find it."))
                step(2, L("Overleaf에서 프로젝트를 연다.", "Open your project on Overleaf."))
                step(3, L("파일을 왼쪽 파일 목록에 끌어다 놓거나, 프로젝트의 Upload 단추를 쓴다.", "Drag the file into the file list on the left, or use the project's Upload button."))
                step(
                    4,
                    L(
                        "문서에서는 보통 BibTeX이면 \\bibliography{refs}로, biblatex이면 \\addbibresource{refs.bib}로 부른다 — refs 자리에는 파일에 붙인 이름을 쓴다.",
                        "Reference it from your document with \\bibliography{refs} for plain BibTeX, or \\addbibresource{refs.bib} for biblatex — matching whatever you named the file."
                    )
                )
                Text(L(
                    "같은 이름으로 올리면 프로젝트에 이미 있던 파일을 대신한다.",
                    "Uploading a file with the same name replaces the one already in the project."
                ))
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
