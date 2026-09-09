import SwiftUI

/// Menu bar commands. On the Mac these are the primary way to reach most
/// actions, and every one of them carries the shortcut a Mac user expects.
struct PaperTimeCommands: Commands {
    let model: AppModel

    /// A pane toggle, carrying whichever key the reader has given it.
    ///
    /// A pane whose key was taken by another still gets its menu item; it just
    /// has no shortcut on it.
    @ViewBuilder
    private func paneButton(
        _ title: String, _ pane: PaneShortcut, action: @escaping () -> Void
    ) -> some View {
        let shortcut = model.shortcut(for: pane)
        if model.hasShortcut(pane) {
            Button(title, action: action)
                .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
        } else {
            Button(title, action: action)
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Papers…") {
                NotificationCenter.default.post(name: .paperTimeAddPapers, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(model.library == nil)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Export BibTeX…") {
                NotificationCenter.default.post(name: .paperTimeExportBibTeX, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.library == nil)

            Button("Copy Citation Key") {
                NotificationCenter.default.post(name: .paperTimeCopyCitationKey, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }

        CommandMenu("Library") {
            Button("Resolve Missing Metadata") {
                guard let library = model.library else { return }
                Task { await library.resolveAllPending() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Refresh from Folder") {
                guard let library = model.library else { return }
                Task { await library.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Change Library Folder…") {
                model.forgetLibrary()
            }
        }

        CommandGroup(after: .textEditing) {
            Button("Search Everything…") {
                model.showsSearchPalette = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model.library == nil)

            Button("Ultracopy") {
                NotificationCenter.default.post(name: .paperTimeUltraCopy, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.library?.selectedPaperID == nil)
            .help("Copy the selection, with formulas as LaTeX")

            Button("Link Selection to Note") {
                NotificationCenter.default.post(name: .paperTimeLinkToNote, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.library?.selectedPaperID == nil)

            Button("Find in Document…") {
                NotificationCenter.default.post(name: .paperTimeFindInDocument, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.library?.selectedPaperID == nil)
        }

        // The paper list answers to Command-P, so the system's own Print item
        // does not get to keep it.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .toolbar) {
            paneButton(
                model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", .sidebar
            ) { model.toggleSidebar() }
                .disabled(model.library == nil)

            paneButton(
                model.showsPaperList ? "Hide Paper List" : "Show Paper List", .paperList
            ) { model.togglePaperList() }
                .disabled(model.library == nil)

            paneButton(
                model.showsReader && !model.isFocusMode ? "Hide Paper" : "Show Paper", .reader
            ) { model.toggleReader() }
                .disabled(model.library == nil)

            paneButton(
                model.showsInspector ? "Hide Inspector" : "Show Inspector", .inspector
            ) { model.toggleInspector() }

            paneButton(
                model.isFocusMode ? "Leave Focus" : "Focus on the Paper", .focus
            ) { model.toggleFocusMode() }
                .disabled(model.library == nil)

            Button("Show Papers") {
                model.toggleFloatingList()
            }
            // Command-L belongs to linking a passage into the note; the
            // floating list takes the variant.
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!model.isFocusMode)

            Divider()

            Button("Zoom In") {
                NotificationCenter.default.post(name: .paperTimeZoomIn, object: nil)
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Zoom Out") {
                NotificationCenter.default.post(name: .paperTimeZoomOut, object: nil)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Actual Size") {
                NotificationCenter.default.post(name: .paperTimeActualSize, object: nil)
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button("Next Page") {
                NotificationCenter.default.post(name: .paperTimeNextPage, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Button("Previous Page") {
                NotificationCenter.default.post(name: .paperTimePreviousPage, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            // Back and forward through followed links. Command-bracket belongs
            // to the sidebars here, so these take the option variant.
            Button("Back") {
                NotificationCenter.default.post(name: .paperTimeGoBack, object: nil)
            }
            .keyboardShortcut("[", modifiers: [.command, .option])

            Button("Forward") {
                NotificationCenter.default.post(name: .paperTimeGoForward, object: nil)
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
        }
    }
}

/// Menu commands reach the focused reader through notifications because the
/// command builder is outside the view hierarchy that owns the PDF view.
extension Notification.Name {
    static let paperTimeAddPapers = Notification.Name("PaperTime.addPapers")
    static let paperTimeExportBibTeX = Notification.Name("PaperTime.exportBibTeX")
    static let paperTimeCopyCitationKey = Notification.Name("PaperTime.copyCitationKey")
    static let paperTimeNextPage = Notification.Name("PaperTime.nextPage")
    static let paperTimePreviousPage = Notification.Name("PaperTime.previousPage")
    static let paperTimeGoBack = Notification.Name("PaperTime.goBack")
    static let paperTimeGoForward = Notification.Name("PaperTime.goForward")
    static let paperTimeFindInDocument = Notification.Name("PaperTime.findInDocument")
    static let paperTimeLinkToNote = Notification.Name("PaperTime.linkToNote")
    static let paperTimeUltraCopy = Notification.Name("PaperTime.ultraCopy")
    static let paperTimeToggleFocus = Notification.Name("PaperTime.toggleFocus")
    static let paperTimeZoomIn = Notification.Name("PaperTime.zoomIn")
    static let paperTimeZoomOut = Notification.Name("PaperTime.zoomOut")
    static let paperTimeActualSize = Notification.Name("PaperTime.actualSize")
}
