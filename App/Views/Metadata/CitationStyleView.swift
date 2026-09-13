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
                Picker("Style", selection: $style) {
                    ForEach(CitationStyle.allCases) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Reference List") {
                Text(CitationFormatter.format(item, style: style))
                    .textSelection(.enabled)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    copy(CitationFormatter.format(item, style: style))
                } label: {
                    Label(
                        copiedStyle == style ? "Copied" : "Copy Reference",
                        systemImage: copiedStyle == style ? "checkmark" : "doc.on.doc"
                    )
                }
            }

            Section("In Text") {
                Text(style.inTextExample(for: item, number: 1))
                    .textSelection(.enabled)
                    .font(.callout.monospaced())
            }

            Section("When to Use It") {
                Text(style.guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(
                    """
                    Your LaTeX template decides the final formatting. \
                    These are here to check a reference by eye and to paste one \
                    into an email or a slide.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Citation Styles")
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
