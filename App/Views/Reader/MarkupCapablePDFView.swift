import InkEngine
import PDFKit
import SwiftUI

#if canImport(UIKit)
import UIKit

/// A `PDFView` that adds markup actions to the selection menu.
///
/// On iPhone and iPad the natural way to highlight a sentence is to press and
/// hold it, so the app's most-used action belongs in the system edit menu
/// rather than behind a mode switch in the toolbar.
final class MarkupCapablePDFView: PDFView {
    /// Called with the chosen markup for the current selection.
    var onMarkup: ((MarkupDescriptor.Kind, MarkupColor) -> Void)?
    /// Called when the user wants to write a note about the selection.
    var onNote: (() -> Void)?
    /// Called when the user asks to look up a reference or a term.
    var onLookUp: ((String) -> Void)?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard currentSelection?.string?.isEmpty == false else { return }

        let highlights = MarkupColor.allCases.map { color in
            UIAction(
                title: color.displayName,
                image: UIImage(systemName: "highlighter"),
                handler: { [weak self] _ in
                    self?.perform(.highlight, color)
                }
            )
        }
        let highlightMenu = UIMenu(
            title: String(localized: "Highlight"),
            image: UIImage(systemName: "highlighter"),
            children: highlights
        )

        let underline = UIAction(
            title: String(localized: "Underline"),
            image: UIImage(systemName: "underline")
        ) { [weak self] _ in
            self?.perform(.underline, .yellow)
        }
        let strikethrough = UIAction(
            title: String(localized: "Strikethrough"),
            image: UIImage(systemName: "strikethrough")
        ) { [weak self] _ in
            self?.perform(.strikethrough, .yellow)
        }

        let note = UIAction(
            title: String(localized: "Add Note"),
            image: UIImage(systemName: "note.text.badge.plus")
        ) { [weak self] _ in
            self?.onNote?()
        }

        let markup = UIMenu(
            title: "",
            options: .displayInline,
            children: [highlightMenu, underline, strikethrough, note]
        )
        builder.insertChild(markup, atStartOfMenu: .standardEdit)
    }

    private func perform(_ kind: MarkupDescriptor.Kind, _ color: MarkupColor) {
        onMarkup?(kind, color)
        // Clearing the selection dismisses the menu and shows the new mark,
        // which is what happens in Books and Preview.
        clearSelection()
    }
}
#endif
