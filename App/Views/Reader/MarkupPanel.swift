#if os(macOS)
import AppKit
import InkEngine

/// The markup controls, in a window of their own, built out of AppKit.
///
/// Three earlier attempts are worth recording. A SwiftUI overlay painted over
/// the PDF view looked right and was dead: the pixels were SwiftUI's, but the
/// mouse still belonged to the AppKit view underneath. A SwiftUI popover was
/// dead the same way. A panel hosting SwiftUI was dead too. Ordinary AppKit
/// controls in an ordinary window are not: a button is a button.
@MainActor
final class MarkupPanelController {
    private var panel: NSPanel?
    private var bar: MarkupBarView?
    private var composer: NoteComposerView?
    /// Whether the controls are on screen. The PDF view reports its selection
    /// cleared the moment the panel takes focus; that is the panel opening,
    /// not the reader letting go, and must not close what just opened.
    private(set) var isShowing = false

    private var onMark: ((MarkupDescriptor.Kind, MarkupColor) -> Void)?
    private var onRecolor: ((MarkupColor) -> Void)?
    private var onDelete: (() -> Void)?
    private var onNote: ((String) -> Void)?
    private var onCopy: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var quotedText = ""
    private var anchor = NSRect.zero

    func show(
        anchor: NSRect,
        over host: NSWindow,
        quotedText: String,
        onMark: @escaping (MarkupDescriptor.Kind, MarkupColor) -> Void,
        onNote: @escaping (String) -> Void,
        onCopy: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        composing: Bool = false
    ) {
        self.onMark = onMark
        self.onNote = onNote
        self.onCopy = onCopy
        self.onDismiss = onDismiss
        self.quotedText = quotedText
        self.anchor = anchor

        let panel = panel ?? makePanel()
        self.panel = panel
        if panel.parent == nil { host.addChildWindow(panel, ordered: .above) }
        if composing { presentComposer() } else { presentBar() }
        panel.orderFront(nil)
        isShowing = true
    }

    /// The controls for a mark that is already on the page: change its colour,
    /// or take it off. Reached by clicking the mark itself, because that is
    /// where a reader looks for it.
    func showEditor(
        anchor: NSRect,
        over host: NSWindow,
        onRecolor: @escaping (MarkupColor) -> Void,
        onDelete: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onRecolor = onRecolor
        self.onDelete = onDelete
        self.onDismiss = onDismiss
        self.anchor = anchor

        let panel = panel ?? makePanel()
        self.panel = panel
        if panel.parent == nil { host.addChildWindow(panel, ordered: .above) }
        let editor = MarkEditorView(
            onRecolor: { [weak self] color in self?.onRecolor?(color) },
            onDelete: { [weak self] in self?.onDelete?() }
        )
        bar = nil
        composer = nil
        install(editor, makeKey: false)
        panel.orderFront(nil)
        isShowing = true
    }

    func hide() {
        isShowing = false
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = MarkupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = true
        return panel
    }

    private func presentBar() {
        let bar = MarkupBarView(
            onMark: { [weak self] kind, color in self?.onMark?(kind, color) },
            onNote: { [weak self] in self?.presentComposer() },
            onCopy: { [weak self] in self?.onCopy?() }
        )
        self.bar = bar
        composer = nil
        install(bar, makeKey: false)
    }

    private func presentComposer() {
        let composer = NoteComposerView(
            quotedText: quotedText,
            onCancel: { [weak self] in self?.onDismiss?() },
            onSave: { [weak self] text in self?.onNote?(text) }
        )
        self.composer = composer
        bar = nil
        install(composer, makeKey: true)
        composer.focusField()
    }

    private func install(_ view: NSView, makeKey: Bool) {
        guard let panel, let host = panel.parent ?? panel.parent else { return }
        panel.contentView = view
        let size = view.fittingSize
        panel.setContentSize(size)
        position(panel, size: size, in: host)
        // The bar must never take focus — the selection it acts on belongs to
        // the PDF view. The note editor must, or there is nowhere to type.
        panel.becomesKeyOnlyIfNeeded = !makeKey
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    /// Keeps the panel over the text and inside the window.
    private func position(_ panel: NSPanel, size: NSSize, in host: NSWindow) {
        let frame = host.frame
        var x = anchor.midX - size.width / 2
        x = min(max(x, frame.minX + 12), max(frame.minX + 12, frame.maxX - size.width - 12))
        // Above the text where it fits, below it when the selection sits at the
        // top of the window: the controls must never cover what they are about.
        var y = anchor.maxY + 10
        if y + size.height > frame.maxY - 12 { y = anchor.minY - size.height - 10 }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// A panel that may take keyboard focus when the note editor needs it.
private final class MarkupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The row of markup actions.
final class MarkupBarView: NSVisualEffectView {
    private let onMark: (MarkupDescriptor.Kind, MarkupColor) -> Void
    private let onNote: () -> Void
    private let onCopy: () -> Void

    init(
        onMark: @escaping (MarkupDescriptor.Kind, MarkupColor) -> Void,
        onNote: @escaping () -> Void,
        onCopy: @escaping () -> Void
    ) {
        self.onMark = onMark
        self.onNote = onNote
        self.onCopy = onCopy
        super.init(frame: .zero)

        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        var views: [NSView] = MarkupColor.allCases.map { color in
            let button = NSButton(image: Self.swatch(for: color), target: self, action: #selector(highlight(_:)))
            button.isBordered = false
            button.tag = MarkupColor.allCases.firstIndex(of: color) ?? 0
            button.toolTip = "Highlight \(color.displayName)"
            button.setAccessibilityLabel("Highlight \(color.displayName)")
            return button
        }
        views.append(Self.divider())
        views.append(symbolButton("underline", "Underline", #selector(underline)))
        views.append(symbolButton("strikethrough", "Strikethrough", #selector(strikethrough)))
        views.append(Self.divider())
        views.append(symbolButton("note.text.badge.plus", "Add Note", #selector(note)))
        views.append(symbolButton("doc.on.doc", "Copy", #selector(copyText)))

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The panel is deliberately never key, so every click into it is a "first"
    /// click; without this AppKit swallows them all.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func symbolButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    static func swatch(for color: MarkupColor) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        return NSImage(size: size, flipped: false) { rect in
            color.platformColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.labelColor.withAlphaComponent(0.12).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
    }

    @objc private func highlight(_ sender: NSButton) {
        let color = MarkupColor.allCases[min(sender.tag, MarkupColor.allCases.count - 1)]
        onMark(.highlight, color)
    }

    @objc private func underline() { onMark(.underline, .yellow) }
    @objc private func strikethrough() { onMark(.strikethrough, .yellow) }
    @objc private func note() { onNote() }
    @objc private func copyText() { onCopy() }
}

/// The controls for a mark already on the page.
private final class MarkEditorView: NSVisualEffectView {
    private let onRecolor: (MarkupColor) -> Void
    private let onDelete: () -> Void

    init(onRecolor: @escaping (MarkupColor) -> Void, onDelete: @escaping () -> Void) {
        self.onRecolor = onRecolor
        self.onDelete = onDelete
        super.init(frame: .zero)

        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        var views: [NSView] = MarkupColor.allCases.enumerated().map { index, color in
            let button = NSButton(
                image: MarkupBarView.swatch(for: color),
                target: self,
                action: #selector(recolor(_:))
            )
            button.isBordered = false
            button.tag = index
            button.toolTip = color.displayName
            button.setAccessibilityLabel("Change to \(color.displayName)")
            return button
        }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
        views.append(separator)

        let trash = NSButton(
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove Mark")
                ?? NSImage(),
            target: self,
            action: #selector(delete)
        )
        trash.isBordered = false
        trash.contentTintColor = .systemRed
        trash.toolTip = "Remove Mark"
        trash.setAccessibilityLabel("Remove Mark")
        views.append(trash)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func recolor(_ sender: NSButton) {
        onRecolor(MarkupColor.allCases[min(sender.tag, MarkupColor.allCases.count - 1)])
    }

    @objc private func delete() { onDelete() }
}

/// Writing a note about the selected passage.
private final class NoteComposerView: NSVisualEffectView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let onCancel: () -> Void
    private let onSave: (String) -> Void

    init(quotedText: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.onCancel = onCancel
        self.onSave = onSave
        super.init(frame: .zero)

        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let quote = NSTextField(labelWithString: quotedText)
        quote.font = .preferredFont(forTextStyle: .footnote)
        quote.textColor = .secondaryLabelColor
        quote.lineBreakMode = .byTruncatingTail
        quote.maximumNumberOfLines = 2

        field.placeholderString = "Note"
        field.font = .preferredFont(forTextStyle: .body)
        field.delegate = self
        field.target = self
        field.action = #selector(save)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(self.save))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded

        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [quote, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 320),
            field.widthAnchor.constraint(equalToConstant: 292),
            buttons.widthAnchor.constraint(equalToConstant: 292),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func focusField() { window?.makeFirstResponder(field) }

    @objc private func cancel() { onCancel() }

    @objc private func save() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { onCancel() } else { onSave(text) }
    }
}
#endif
