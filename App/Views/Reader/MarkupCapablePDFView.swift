import InkEngine
import PDFKit
import PDFReader
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
    /// Called to take a mark off the page, and to recolour one.
    var onRemoveMark: ((PDFAnnotation) -> Void)?
    var onRecolorMark: ((PDFAnnotation, MarkupColor) -> Void)?
    private var hitMark: PDFAnnotation?

    // MARK: Hovering

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    /// The hand over a mark, and the mark a shade deeper under it.
    ///
    /// A highlight on the page is something you can click — it opens the
    /// mark in the inspector — and nothing about it said so. PDFKit sets its
    /// own cursor on every move, so this only speaks up while the pointer is
    /// actually on a mark and lets PDFKit have it back the moment it is not.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredMark(mark(at: event.locationInWindow))
        if MarkHover.hovered != nil { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredMark(nil)
    }

    private func setHoveredMark(_ mark: PDFAnnotation?) {
        let previous = MarkHover.hovered
        guard previous !== mark else { return }
        MarkHover.hovered = mark
        for changed in [previous, mark].compactMap({ $0?.page }) {
            MarkOverlayView.refresh(changed)
        }
    }

    /// The mark under a click, if there is one.
    func mark(at locationInWindow: NSPoint) -> PDFAnnotation? {
        let inView = convert(locationInWindow, from: nil)
        guard let page = page(for: inView, nearest: true) else { return nil }
        let onPage = convert(inView, to: page)
        return page.annotations.first {
            ["Highlight", "Underline", "StrikeOut", "Text"].contains($0.type ?? "")
                && $0.bounds.insetBy(dx: -3, dy: -3).contains(onPage)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()

        // Control-clicking a mark offers to change or remove it, which is the
        // one place a reader looks when a highlight was a mistake.
        if let mark = mark(at: event.locationInWindow) {
            hitMark = mark
            let colors = NSMenu()
            for (index, color) in MarkupColor.allCases.enumerated() {
                let item = NSMenuItem(
                    title: color.displayName,
                    action: #selector(recolorMarkFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                colors.addItem(item)
            }
            let colorItem = NSMenuItem(title: "Mark Colour", action: nil, keyEquivalent: "")
            colorItem.submenu = colors

            let remove = NSMenuItem(
                title: "Remove Mark",
                action: #selector(removeMarkFromMenu),
                keyEquivalent: ""
            )
            remove.target = self

            menu.insertItem(NSMenuItem.separator(), at: 0)
            menu.insertItem(remove, at: 0)
            menu.insertItem(colorItem, at: 0)
            return menu
        }

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

    @objc private func removeMarkFromMenu() {
        guard let hitMark else { return }
        onRemoveMark?(hitMark)
        self.hitMark = nil
    }

    @objc private func recolorMarkFromMenu(_ sender: NSMenuItem) {
        guard let hitMark else { return }
        onRecolorMark?(hitMark, MarkupColor.allCases[min(sender.tag, MarkupColor.allCases.count - 1)])
        self.hitMark = nil
    }
}
#endif
