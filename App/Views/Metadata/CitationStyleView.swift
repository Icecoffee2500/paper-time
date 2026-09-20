import Bibliography
import PaperCore
import SwiftUI

/// Shows the selected paper written out in the common citation styles, with a
/// short note on the rule that usually trips people up in each one.
///
/// Formatting happens on the device from the stored CSL-JSON record, so it
/// works offline and reflects any correction the user just made.
struct CitationStyleView: View {
    let item: CSLItem
    @State private var style: CitationStyle = .apa7
    @State private var copiedStyle: CitationStyle?

    var body: some View {
        Form {
            Section {
                Picker(L("양식", "Style"), selection: $style) {
                    ForEach(CitationStyle.allCases) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(L("참고문헌", "Reference List")) {
                Text(CitationFormatter.format(item, style: style))
                    .textSelection(.enabled)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    copy(CitationFormatter.format(item, style: style))
                } label: {
                    Label(
                        copiedStyle == style ? L("복사했어요", "Copied") : L("참고문헌 복사", "Copy Reference"),
                        systemImage: copiedStyle == style ? "checkmark" : "doc.on.doc"
                    )
                }
            }

            Section(L("본문 인용", "In Text")) {
                Text(style.inTextExample(for: item, number: 1))
                    .textSelection(.enabled)
                    .font(.callout.monospaced())
            }

            Section(L("언제 쓰나요", "When to Use It")) {
                Text(style.guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(
                    L(
                        """
                        마지막 모양은 LaTeX 템플릿이 정해요. \
                        여기 있는 건 눈으로 한번 훑어보거나, \
                        메일이나 슬라이드에 하나 붙일 때 쓰면 돼요.
                        """,
                        """
                        The LaTeX template decides the final formatting. \
                        Use these to check a reference, or to paste one into an \
                        email or a slide.
                        """
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("인용 양식", "Citation Styles"))
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copiedStyle = style
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedStyle == style { copiedStyle = nil }
        }
    }
}

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
