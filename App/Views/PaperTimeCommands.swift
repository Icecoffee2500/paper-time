#if canImport(AppKit)
import AppKit
#endif
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
            command(L("논문 더하기…", "Add Papers…"), .addPapers, post: .paperTimeAddPapers)
                .disabled(model.library == nil)
        }

        CommandGroup(after: .newItem) {
            Divider()
            command(L("BibTeX 내보내기…", "Export BibTeX…"), .exportBibTeX, post: .paperTimeExportBibTeX)
                .disabled(model.library == nil)
            command(L("인용 키 복사", "Copy Citation Key"), .copyCitationKey, post: .paperTimeCopyCitationKey)
        }

        CommandMenu(L("라이브러리", "Library")) {
            command(L("빠진 서지 채우기", "Resolve Missing Metadata"), .resolveMetadata) {
                guard let library = model.library else { return }
                Task { await library.resolveAllPending() }
            }
            // The same errand as the toolbar's button: ask the cloud for what
            // it has not brought, read the folder again, and tell the open
            // paper to look at its own files. Posted rather than done here,
            // because the reader's session is the window's, not the menu's.
            command(L("지금 맞추기", "Sync Now"), .refreshFolder, post: .paperTimeSyncNow)

            Divider()

            Button(L("라이브러리 폴더 바꾸기…", "Change Library Folder…")) {
                model.isChoosingLibraryFolder = true
            }
        }

        CommandGroup(after: .textEditing) {
            command(L("전부 찾기…", "Search Everything…"), .searchEverything) {
                model.showsSearchPalette = true
            }
            .disabled(model.library == nil)

            command(L("이 논문에서 찾기…", "Find in Document…"), .findInDocument, post: .paperTimeFindInDocument)
                .disabled(model.library?.selectedPaperID == nil)

            command("Ultracopy", .ultracopy, post: .paperTimeUltraCopy)
                .disabled(model.library?.selectedPaperID == nil)
                .help(L("고른 곳 복사, 수식은 LaTeX로", "Copy the selection, with formulas as LaTeX"))

            command(L("고른 곳을 노트로", "Link Selection to Note"), .linkToNote, post: .paperTimeLinkToNote)
                .disabled(model.library?.selectedPaperID == nil)

            Divider()

            command(L("고른 곳에 형광펜", "Highlight Selection"), .highlight, post: .paperTimeHighlight)
                .disabled(model.library?.selectedPaperID == nil)
            command(L("고른 곳에 밑줄", "Underline Selection"), .underline, post: .paperTimeUnderline)
                .disabled(model.library?.selectedPaperID == nil)
            command(L("새 노트", "New Note"), .newNote, post: .paperTimeNewNote)
                .disabled(model.library == nil)
            // The pencil, the shapes and the arrows: the Mac's own drawing
            // mode, which the iPad reaches with the pencil itself.
            command(L("쪽에 그리기", "Draw on the Page"), .draw, post: .paperTimeToggleDraw)
                .disabled(model.library?.selectedPaperID == nil)
        }

        // The paper list answers to Command-P, so the system's own Print item
        // does not get to keep it.
        CommandGroup(replacing: .printItem) {}

        // In Help, where a Mac user looks for it, and on ⌥⌘/ from anywhere.
        // One keystroke is the whole design: the screenshot is already taken
        // by the time the sheet is on screen.
        CommandGroup(replacing: .help) {
            command(L("한마디 보내기…", "Send Feedback…"), .feedback) {
                model.askForFeedback()
            }
            Divider()
            Link(L("함께 만드는 중", "Built together"),
                 destination: URL(string: "https://icecoffee2500.github.io/paper-time/#together")!)
        }

        CommandGroup(after: .toolbar) {
            command(
                model.isSidebarVisible ? L("옆 목록 숨기기", "Hide Sidebar") : L("옆 목록 보이기", "Show Sidebar"), .sidebar
            ) { model.toggleSidebar() }
                .disabled(model.library == nil)

            command(
                model.showsPaperList ? L("논문 목록 숨기기", "Hide Paper List") : L("논문 목록 보이기", "Show Paper List"), .paperList
            ) { model.togglePaperList() }
                .disabled(model.library == nil)

            command(
                model.showsReader && !model.isFocusMode ? L("논문 숨기기", "Hide Paper") : L("논문 보이기", "Show Paper"), .reader
            ) { model.toggleReader() }
                .disabled(model.library == nil)

            command(
                model.showsInspector ? L("정보 패널 숨기기", "Hide Inspector") : L("정보 패널 보이기", "Show Inspector"), .inspector
            ) { model.toggleInspector() }

            command(
                model.isFocusMode ? L("집중에서 나오기", "Leave Focus") : L("논문에 집중", "Focus on the Paper"), .focus
            ) { model.toggleFocusMode() }
                .disabled(model.library == nil)

            command(L("차례", "Table of Contents"), .floatingList) { model.toggleFloatingList() }
                .disabled(model.library?.selectedPaperID == nil)

            Divider()

            command(L("이어서 보기", "Continuous"), .layoutContinuous, post: .paperTimeLayoutContinuous)
                .disabled(model.library?.selectedPaperID == nil)
            command(L("한 쪽씩 보기", "Single Page"), .layoutSinglePage, post: .paperTimeLayoutSinglePage)
                .disabled(model.library?.selectedPaperID == nil)
            command(L("책처럼 보기", "Book"), .layoutBook, post: .paperTimeLayoutBook)
                .disabled(model.library?.selectedPaperID == nil)

            Divider()

            command(L("크게", "Zoom In"), .zoomIn, post: .paperTimeZoomIn)
            command(L("작게", "Zoom Out"), .zoomOut, post: .paperTimeZoomOut)
            command(L("실제 크기", "Actual Size"), .actualSize, post: .paperTimeActualSize)

            Divider()

            command(L("다음 쪽", "Next Page"), .nextPage, post: .paperTimeNextPage)
            command(L("이전 쪽", "Previous Page"), .previousPage, post: .paperTimePreviousPage)
            command(L("다음 논문", "Next Paper"), .nextPaper, post: .paperTimeNextPaper)
                .disabled(model.library == nil)
            command(L("이전 논문", "Previous Paper"), .previousPaper, post: .paperTimePreviousPaper)
                .disabled(model.library == nil)
            command(L("뒤로", "Back"), .back, post: .paperTimeGoBack)
            command(L("앞으로", "Forward"), .forward, post: .paperTimeGoForward)
        }
    }
}

/// Menu commands reach the focused reader through notifications because the
/// command builder is outside the view hierarchy that owns the PDF view.
extension Notification.Name {
    static let paperTimeAddPapers = Notification.Name("PaperTime.addPapers")
    static let paperTimeExportBibTeX = Notification.Name("PaperTime.exportBibTeX")
    static let paperTimeCopyCitationKey = Notification.Name("PaperTime.copyCitationKey")
    static let paperTimeSyncNow = Notification.Name("PaperTime.syncNow")
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
    static let paperTimeToggleDraw = Notification.Name("PaperTime.toggleDraw")
    static let paperTimeBackToPreviousPaper = Notification.Name("PaperTime.backToPreviousPaper")
    static let paperTimeForwardToNextPaper = Notification.Name("PaperTime.forwardToNextPaper")
    static let paperTimePreviousPaper = Notification.Name("PaperTime.previousPaper")
}
