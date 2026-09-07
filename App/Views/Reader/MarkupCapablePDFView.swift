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

#else
import AppKit

/// A `PDFView` that offers the markup actions on a Control-click.
///
/// The floating panel is the way this is meant to be reached, but a menu on
/// the selection is what a Mac user tries when a control does not respond, and
/// it goes through AppKit's own menu machinery rather than anything of ours.
final class MarkupCapablePDFView: PDFView {
    var onMarkup: ((MarkupDescriptor.Kind, MarkupColor) -> Void)?
    var onNote: (() -> Void)?
    /// Called when a mark already on the page is clicked.
    var onMarkTapped: ((PDFAnnotation, NSPoint) -> Void)?
    /// A click on an existing mark selects the mark rather than the text, so it
    /// can be recoloured or taken off the page where it actually is.
    override func mouseDown(with event: NSEvent) {
        let inView = convert(event.locationInWindow, from: nil)
        if let page = page(for: inView, nearest: false) {
            let onPage = convert(inView, to: page)
            let hit = page.annotations.first {
                ["Highlight", "Underline", "StrikeOut", "Text"].contains($0.type ?? "")
                    && $0.bounds.insetBy(dx: -2, dy: -2).contains(onPage)
            }
            if let hit {
                clearSelection()
                onMarkTapped?(hit, event.locationInWindow)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard currentSelection?.string?.isEmpty == false else { return menu }

        let markup = NSMenu()
        let highlights = NSMenu()
        for color in MarkupColor.allCases {
            let item = NSMenuItem(
                title: color.displayName,
                action: #selector(highlightFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = color.rawValue
            highlights.addItem(item)
        }
        let highlightItem = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
        highlightItem.submenu = highlights
        markup.addItem(highlightItem)

        for (title, selector) in [
            ("Underline", #selector(underlineFromMenu)),
            ("Strikethrough", #selector(strikethroughFromMenu)),
            ("Add Note…", #selector(noteFromMenu)),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            markup.addItem(item)
        }

        menu.insertItem(NSMenuItem.separator(), at: 0)
        for item in markup.items.reversed() {
            markup.removeItem(item)
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func highlightFromMenu(_ sender: NSMenuItem) {
        let color = (sender.representedObject as? String).flatMap(MarkupColor.init(rawValue:))
        onMarkup?(.highlight, color ?? .yellow)
        clearSelection()
    }

    @objc private func underlineFromMenu() {
        onMarkup?(.underline, .yellow)
        clearSelection()
    }

    @objc private func strikethroughFromMenu() {
        onMarkup?(.strikethrough, .yellow)
        clearSelection()
    }

    @objc private func noteFromMenu() {
        onNote?()
    }
}
#endif
