import AppKit
import SwiftUI

/// Menu bar commands. On the Mac these are the primary way to reach most
/// actions, and every one of them carries the shortcut a Mac user expects.
struct PaperTimeCommands: Commands {
    let model: AppModel

    /// A command, carrying whichever key the reader has given it.
    ///
    /// The shortcut is optional rather than chosen between two kinds of
    /// button: branching produced two view types in one place and SwiftUI
    /// handed the keys to the wrong items.
    private func command(
        _ title: String, _ action: ShortcutAction, run: @escaping () -> Void
    ) -> some View {
        Button(title, action: run)
            .keyboardShortcut(model.keyboardShortcut(for: action))
    }

    /// The same, for a command that only posts a notification.
    private func command(
        _ title: String, _ action: ShortcutAction, post name: Notification.Name
    ) -> some View {
        command(title, action) { NotificationCenter.default.post(name: name, object: nil) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            command("Add Papers…", .addPapers, post: .paperTimeAddPapers)
                .disabled(model.library == nil)
        }

        CommandGroup(after: .newItem) {
            Divider()
            command("Export BibTeX…", .exportBibTeX, post: .paperTimeExportBibTeX)
                .disabled(model.library == nil)
            command("Copy Citation Key", .copyCitationKey, post: .paperTimeCopyCitationKey)
        }

        CommandMenu("Library") {
            command("Resolve Missing Metadata", .resolveMetadata) {
                guard let library = model.library else { return }
                Task { await library.resolveAllPending() }
            }
            command("Refresh from Folder", .refreshFolder) {
                guard let library = model.library else { return }
                Task { await library.refresh() }
            }

            Divider()

            Button("Change Library Folder…") {
                model.forgetLibrary()
            }
        }

        CommandGroup(after: .textEditing) {
            command("Search Everything…", .searchEverything) {
                model.showsSearchPalette = true
            }
            .disabled(model.library == nil)

            command("Find in Document…", .findInDocument, post: .paperTimeFindInDocument)
                .disabled(model.library?.selectedPaperID == nil)

            command("Ultracopy", .ultracopy, post: .paperTimeUltraCopy)
                .disabled(model.library?.selectedPaperID == nil)
                .help("Copy the selection, with formulas as LaTeX")

            command("Link Selection to Note", .linkToNote, post: .paperTimeLinkToNote)
                .disabled(model.library?.selectedPaperID == nil)

            Divider()

            command("Highlight Selection", .highlight, post: .paperTimeHighlight)
                .disabled(model.library?.selectedPaperID == nil)
            command("Underline Selection", .underline, post: .paperTimeUnderline)
                .disabled(model.library?.selectedPaperID == nil)
            command("New Note", .newNote, post: .paperTimeNewNote)
                .disabled(model.library == nil)
        }

        // The paper list answers to Command-P, so the system's own Print item
        // does not get to keep it.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .toolbar) {
            command(
                model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", .sidebar
            ) { model.toggleSidebar() }
                .disabled(model.library == nil)

            command(
                model.showsPaperList ? "Hide Paper List" : "Show Paper List", .paperList
            ) { model.togglePaperList() }
                .disabled(model.library == nil)

            command(
                model.showsReader && !model.isFocusMode ? "Hide Paper" : "Show Paper", .reader
            ) { model.toggleReader() }
                .disabled(model.library == nil)

            command(
                model.showsInspector ? "Hide Inspector" : "Show Inspector", .inspector
            ) { model.toggleInspector() }

            command(
                model.isFocusMode ? "Leave Focus" : "Focus on the Paper", .focus
            ) { model.toggleFocusMode() }
                .disabled(model.library == nil)

            command("Table of Contents", .floatingList) { model.toggleFloatingList() }
                .disabled(model.library?.selectedPaperID == nil)

            Divider()

            command("Continuous", .layoutContinuous, post: .paperTimeLayoutContinuous)
                .disabled(model.library?.selectedPaperID == nil)
            command("Single Page", .layoutSinglePage, post: .paperTimeLayoutSinglePage)
                .disabled(model.library?.selectedPaperID == nil)
            command("Book", .layoutBook, post: .paperTimeLayoutBook)
                .disabled(model.library?.selectedPaperID == nil)

            Divider()

            command("Zoom In", .zoomIn, post: .paperTimeZoomIn)
            command("Zoom Out", .zoomOut, post: .paperTimeZoomOut)
            command("Actual Size", .actualSize, post: .paperTimeActualSize)

            Divider()

            command("Next Page", .nextPage, post: .paperTimeNextPage)
            command("Previous Page", .previousPage, post: .paperTimePreviousPage)
            command("Next Paper", .nextPaper, post: .paperTimeNextPaper)
                .disabled(model.library == nil)
            command("Previous Paper", .previousPaper, post: .paperTimePreviousPaper)
                .disabled(model.library == nil)
            command("Back", .back, post: .paperTimeGoBack)
            command("Forward", .forward, post: .paperTimeGoForward)
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
    static let paperTimeLayoutContinuous = Notification.Name("PaperTime.layoutContinuous")
    static let paperTimeLayoutSinglePage = Notification.Name("PaperTime.layoutSinglePage")
    static let paperTimeLayoutBook = Notification.Name("PaperTime.layoutBook")
    static let paperTimeZoomIn = Notification.Name("PaperTime.zoomIn")
    static let paperTimeZoomOut = Notification.Name("PaperTime.zoomOut")
    static let paperTimeActualSize = Notification.Name("PaperTime.actualSize")
    static let paperTimeHighlight = Notification.Name("PaperTime.highlight")
    static let paperTimeUnderline = Notification.Name("PaperTime.underline")
    static let paperTimeNewNote = Notification.Name("PaperTime.newNote")
    static let paperTimeNextPaper = Notification.Name("PaperTime.nextPaper")
    static let paperTimePreviousPaper = Notification.Name("PaperTime.previousPaper")
}
