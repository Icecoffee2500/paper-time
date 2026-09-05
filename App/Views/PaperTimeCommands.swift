import SwiftUI

/// Menu bar commands. On the Mac these are the primary way to reach most
/// actions, and every one of them carries the shortcut a Mac user expects.
struct PaperTimeCommands: Commands {
    let model: AppModel

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

        CommandGroup(after: .toolbar) {
            Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                model.toggleSidebar()
            }
            .keyboardShortcut("[", modifiers: .command)

            Button(model.showsInspector ? "Hide Inspector" : "Show Inspector") {
                model.showsInspector.toggle()
            }
            .keyboardShortcut("]", modifiers: .command)

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
}
