import Foundation
import InkEngine
import Observation
import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore
#endif

/// What somebody wants to tell us, and everything the app can say about the
/// moment they wanted to tell us.
///
/// The app never talks to a server on its own. It talks when somebody presses
/// 보내기, and it sends only what they were shown before they pressed it — the
/// window has a list of exactly what goes, and every part of it can be taken
/// out. That is not politeness. An app whose whole promise is "no account, no
/// server" cannot have a quiet back channel and still mean it.
public enum Feedback {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case bug, wish
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .bug: L("문제가 있어요", "Something's wrong")
            case .wish: L("이랬으면 좋겠어요", "I wish it did this")
            }
        }
    }

    /// Where the report goes. One route, one purpose; overridable so it can be
    /// pointed at a test worker without a new build.
    public static var endpoint: URL {
        let raw = Boot.setting("PAPERTIME_FEEDBACK_URL")
            ?? "https://paper-time-feedback.icecoffee2500.workers.dev/report"
        return URL(string: raw) ?? URL(string: "https://example.invalid")!
    }

    // MARK: - The last few things that happened

    /// A short ring of what the reader just did, so "가끔 느려져요" can become a
    /// report somebody can act on. Names of actions only — never a paper's
    /// title, never a path. Those are the reader's, not ours.
    @MainActor
    public enum Trail {
        private static var entries: [String] = []
        private static let limit = 6

        public static func note(_ what: String) {
            entries.append(what)
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
        }

        public static var recent: [String] { entries }
    }

    // MARK: - Did it come back from a crash?

    /// The app writes a flag on launch and clears it on a clean quit. Finding
    /// the flag still set means the last run ended badly — the one moment
    /// somebody is most willing to say what happened, and the one moment an
    /// app usually says nothing.
    @MainActor
    public enum Crash {
        private static let key = "feedback.running"

        public static func markLaunched() -> Bool {
            let crashed = UserDefaults.standard.bool(forKey: key)
            UserDefaults.standard.set(true, forKey: key)
            return crashed
        }

        public static func markCleanExit() {
            UserDefaults.standard.set(false, forKey: key)
        }

        /// The newest crash report the system wrote for this app, if there is
        /// one from the last hour. Read from the user's own log folder; it is
        /// attached only if they leave it attached.
        public static func latestReport() -> String? {
            let folder = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            else { return nil }
            let mine = names.filter { $0.hasPrefix("Paper Time") }
            var newest: (URL, Date)?
            for name in mine {
                let url = folder.appending(path: name)
                guard let when = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                else { continue }
                if when.timeIntervalSinceNow > -3600, newest == nil || when > newest!.1 {
                    newest = (url, when)
                }
            }
            guard let found = newest?.0, let text = try? String(contentsOf: found, encoding: .utf8) else { return nil }
            return String(text.prefix(6000))
        }
    }
}

// MARK: - What the app knows about this moment

/// Everything sent alongside the message, in the order the window lists it.
///
/// The rule for what may be here: it describes the app, never the papers. A
/// version, a window size, the shape of the layout. Not a title, not a path,
/// not a word anybody wrote. The one thing that could carry those is the
/// screenshot, which is why it can be drawn over and thrown away.
public struct FeedbackDiagnostics: Sendable {
    public var version: String
    public var build: String
    public var platform: String
    public var arch: String
    public var lang: String
    public var window: String?
    public var layout: String?
    public var panes: String?
    public var libraryCloud: Bool?
    public var paperCount: Int?
    public var recent: [String]

    /// The same lines the window shows under "함께 보내는 것", so the list and
    /// the payload cannot drift apart.
    public var rows: [(String, String)] {
        var out: [(String, String)] = [
            (L("버전", "Version"), build.isEmpty ? version : "\(version) (\(build))"),
            (L("운영체제", "System"), "\(platform) · \(arch)"),
            (L("앱 언어", "Language"), lang),
        ]
        if let window { out.append((L("창 크기", "Window"), window)) }
        if let layout { out.append((L("쪽 배치", "Page layout"), layout)) }
        if let panes { out.append((L("열어 둔 칸", "Panes open"), panes)) }
        if let paperCount { out.append((L("논문 수", "Papers"), "\(paperCount)")) }
        if let libraryCloud {
            out.append((
                L("클라우드 폴더", "Cloud folder"),
                libraryCloud ? L("예", "yes") : L("아니오", "no")
            ))
        }
        if !recent.isEmpty {
            out.append((L("최근에 한 일", "Last few actions"), recent.joined(separator: " → ")))
        }
        return out
    }

    @MainActor
    public static func collect(app: AppModel?) -> FeedbackDiagnostics {
        let info = Bundle.main.infoDictionary
        var platform = "macOS"
        #if os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        platform = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #elseif os(iOS)
        platform = "iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        #endif

        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif

        var window: String?
        #if os(macOS)
        if let frame = NSApp.keyWindow?.frame ?? NSApp.windows.first(where: \.isVisible)?.frame {
            window = "\(Int(frame.width))×\(Int(frame.height))"
        }
        #endif

        var panes: [String] = []
        if let app {
            if app.showsInspector { panes.append(L("정보", "inspector")) }
        }

        return FeedbackDiagnostics(
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "",
            platform: platform,
            arch: arch,
            lang: Language.prefersKorean ? "ko" : "en",
            window: window,
            layout: nil,
            panes: panes.isEmpty ? nil : panes.joined(separator: ", "),
            libraryCloud: app?.library?.location.provider != nil,
            paperCount: app?.library?.papers.count,
            recent: Feedback.Trail.recent
        )
    }
}

// MARK: - The draft

/// One report while it is being written.
@MainActor
@Observable
public final class FeedbackDraft {
    public enum State: Equatable {
        case writing
        case sending
        case sent(String)
        /// Kept on the machine instead, because the send did not go through.
        case kept(URL)
        case failed(String)
    }

    public var kind: Feedback.Kind = .bug
    public var message = ""
    public var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "feedback.name") }
    }
    public var reply: String {
        didSet { UserDefaults.standard.set(reply, forKey: "feedback.reply") }
    }
    public var includesShot = true
    public var showsDetails = false
    public var state: State = .writing

    /// The window as it was the instant the key was pressed. Taken first,
    /// before this sheet exists, so the sheet is not in its own picture.
    public var shot: CGImage?
    /// Drawn over the shot with the app's own pen.
    public var marks: [SketchElement] = []
    public var crash: String?

    public var diagnostics = FeedbackDiagnostics(
        version: "?", build: "", platform: "", arch: "", lang: "ko", recent: []
    )

    public init() {
        name = UserDefaults.standard.string(forKey: "feedback.name") ?? ""
        reply = UserDefaults.standard.string(forKey: "feedback.reply") ?? ""
    }

    public var canSend: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && state != .sending
    }

    /// The row this will become on the page, shown before the send rather than
    /// after it. People do not write to a void; showing the void has an exit
    /// is most of the work.
    public var previewTitle: String {
        let first = message
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if first.isEmpty { return L("여기 쓴 첫 줄이 제목이 돼요", "Your first line becomes the title") }
        return first.count > 60 ? String(first.prefix(59)) + "…" : first
    }

    public var creditName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? L("익명", "anonymous") : trimmed
    }
}

// MARK: - Sending

public enum FeedbackSender {
    struct Payload: Encodable {
        var kind: String
        var body: String
        var name: String
        var reply: String?
        var app: App
        var context: Context
        var shot: String?
        var crash: String?

        struct App: Encodable {
            var version: String
            var build: String
            var platform: String
            var arch: String
            var lang: String
        }

        struct Context: Encodable {
            var window: String?
            var layout: String?
            var panes: String?
            var libraryCloud: Bool?
            var paperCount: Int?
            var recent: [String]
        }
    }

    struct Answer: Decodable {
        var ok: Bool?
        var url: String?
        var error: String?
    }

    @MainActor
    public static func send(_ draft: FeedbackDraft) async {
        draft.state = .sending
        let d = draft.diagnostics
        let payload = Payload(
            kind: draft.kind.rawValue,
            body: draft.message.trimmingCharacters(in: .whitespacesAndNewlines),
            name: draft.creditName,
            reply: draft.reply.trimmingCharacters(in: .whitespaces).isEmpty ? nil : draft.reply,
            app: .init(version: d.version, build: d.build, platform: d.platform, arch: d.arch, lang: d.lang),
            context: .init(
                window: d.window, layout: d.layout, panes: d.panes,
                libraryCloud: d.libraryCloud, paperCount: d.paperCount, recent: d.recent
            ),
            shot: draft.includesShot ? FeedbackImage.dataURL(of: draft) : nil,
            crash: draft.crash
        )

        var request = URLRequest(url: Feedback.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONEncoder().encode(payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let answer = try? JSONDecoder().decode(Answer.self, from: data)
            if code == 200, answer?.ok == true {
                draft.state = .sent(answer?.url ?? "")
                return
            }
            if code == 429 {
                draft.state = .failed(L(
                    "잠깐 사이에 너무 많이 보냈어요. 조금 뒤에 다시 보내주세요.",
                    "That's a lot of reports in a short time. Try again in a bit."
                ))
                return
            }
            keep(draft)
        } catch {
            keep(draft)
        }
    }

    /// Nothing anybody wrote is ever lost because a network was down. It goes
    /// to the desktop as a folder they can attach to an email themselves.
    @MainActor
    private static func keep(_ draft: FeedbackDraft) {
        if let url = FeedbackImage.writeBundle(draft) {
            draft.state = .kept(url)
        } else {
            draft.state = .failed(L(
                "보내지 못했어요. 인터넷 연결을 확인해 주세요.",
                "Couldn't send. Check the network connection."
            ))
        }
    }
}

#if os(macOS)
/// Looking at the report sheet without a hand on the keyboard.
///
/// `--papertime-feedback-shot=<path in the container>` opens it, fills it the
/// way somebody would, draws a mark or two with the app's own pen, writes the
/// window to a PNG and quits. No event is posted to the system: the sheet is
/// opened by setting the flag the menu item sets, which is the same door.
@MainActor
public enum FeedbackProbe {
    public static func runIfAsked(app: AppModel) {
        guard let path = Boot.setting("PAPERTIME_FEEDBACK_SHOT") else { return }
        guard Boot.isSet("PAPERTIME_LIBRARY") else {
            FileHandle.standardError.write(Data("feedback probe: refused — not the test library\n".utf8))
            return
        }
        Task { @MainActor in
            func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
            try? await Task.sleep(for: .seconds(2))
            app.askForFeedback()
            // Long enough for the sheet's own task to have taken the picture.
            try? await Task.sleep(for: .seconds(1.2))

            let draft = app.feedbackDraft
            if Boot.isSet("PAPERTIME_FEEDBACK_FILL") {
                draft.message = Language.prefersKorean
                    ? "표가 있는 쪽에서 스크롤하면 가끔 멈춰요."
                    : "Scrolling stalls on pages that have a table."
                draft.name = Language.prefersKorean ? "김연구" : "Sam"
                draft.reply = "someone@example.com"
                draft.showsDetails = true
                if let shot = draft.shot {
                    let width = CGFloat(shot.width)
                    let height = CGFloat(shot.height)
                    let line = FeedbackImage.strokeWidth(for: shot)
                    draft.marks = [
                        MarkTool.box.element(
                            from: CGPoint(x: width * 0.08, y: height * 0.30),
                            to: CGPoint(x: width * 0.46, y: height * 0.52),
                            width: line
                        ),
                        MarkTool.arrow.element(
                            from: CGPoint(x: width * 0.72, y: height * 0.20),
                            to: CGPoint(x: width * 0.48, y: height * 0.40),
                            width: line
                        ),
                        MarkTool.hide.element(
                            from: CGPoint(x: width * 0.06, y: height * 0.78),
                            to: CGPoint(x: width * 0.38, y: height * 0.86),
                            width: line
                        ),
                    ]
                }
            }

            try? await Task.sleep(for: .seconds(1.2))
            // The sheet is its own window; the picture wanted is that one.
            let windows = NSApp.windows.filter(\.isVisible)
            let sheet = windows.first(where: { $0.isSheet }) ?? windows.last
            guard let content = sheet?.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else { return say("feedback probe: no window") }
            content.cacheDisplay(in: content.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                say("feedback probe: wrote \(path); \(draft.marks.count) marks, \(draft.diagnostics.rows.count) diagnostic rows")
            }
            if Boot.isSet("PAPERTIME_FEEDBACK_QUIT") { NSApp.terminate(nil) }
        }
    }
}
#endif

#if os(macOS)
/// Photographs the window without a hand on it, for looking at a screen that
/// only appears in a state the app is not usually in — the first-run setup,
/// an error page, a field being edited.
///
/// `--papertime-window-shot=<path in the container>`, with
/// `--papertime-window-shot-after=<seconds>` (2 by default) and
/// `--papertime-window-shot-quit=1`. Read-only: it posts nothing and touches
/// no file of the reader's.
@MainActor
public enum WindowProbe {
    public static func runIfAsked(app: AppModel) {
        guard let path = Boot.setting("PAPERTIME_WINDOW_SHOT") else { return }
        let after = Double(Boot.setting("PAPERTIME_WINDOW_SHOT_AFTER") ?? "") ?? 2
        Task { @MainActor in
            func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
            // Before anything waits on the window: a run started hidden has no
            // visible window at all, and a sheet has nothing to attach itself
            // to — the probe watched for one and counted none, which reads as
            // "it never opened" when the truth is "there was no window". Put it
            // outside every display first and the run behaves like any other.
            if NSApp.keyWindow == nil, !NSApp.windows.contains(where: \.isVisible) {
                _ = offscreen(say: say)
            }
            try? await Task.sleep(for: .seconds(after))
            // Whichever text field was asked for, made first responder first,
            // so a shot of "while editing" is a shot of editing.
            if let marker = Boot.setting("PAPERTIME_WINDOW_SHOT_EDIT"),
               let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
                if let field = firstTextField(in: window.contentView, marker: marker) {
                    window.makeFirstResponder(field)
                    say("window probe: editing \(type(of: field))")
                    try? await Task.sleep(for: .seconds(1.2))
                } else {
                    say("window probe: no text field matching \(marker)")
                }
            }
            // The welcome sheet, on demand: it shows itself once per version
            // and then never again, so the only way to look at it on a machine
            // that has already seen it is to ask. Nothing is marked as seen.
            if Boot.isSet("PAPERTIME_WHATS_NEW") {
                app.showsReleaseNotes = true
                try? await Task.sleep(for: .seconds(1.2))
            }
            // Does the folder chooser actually come up? It is the one thing
            // on the first-run screen, and a SwiftUI `fileImporter` there
            // opened nothing at all.
            if Boot.isSet("PAPERTIME_CHOOSE_FOLDER") {
                let before = NSApp.windows.count
                app.chooseLibraryFolder()
                try? await Task.sleep(for: .seconds(1.5))
                let panels = NSApp.windows.filter { $0 is NSOpenPanel }
                say("window probe: windows \(before) → \(NSApp.windows.count); open panels: \(panels.count)")
                for panel in panels.compactMap({ $0 as? NSOpenPanel }) {
                    say("window probe: panel prompt \"\(panel.prompt ?? "")\" directories=\(panel.canChooseDirectories) files=\(panel.canChooseFiles)")
                    panel.cancel(nil)
                }
            }
            // `--papertime-settings=1` photographs Settings. Its own scene is
            // opened by an action that brings the app forward, so the page is
            // put in a window of the probe's own instead, outside every
            // display like the main one, and that is the window photographed.
            var settings: NSWindow?
            if Boot.isSet("PAPERTIME_SETTINGS") {
                settings = settingsWindow(app: app, say: say)
                try? await Task.sleep(for: .seconds(1.5))
                if let window = settings,
                   NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                    // It must never be where somebody can see it. Put away
                    // rather than photographed.
                    window.orderOut(nil)
                    return say("settings probe: the window landed on a screen at \(window.frame) — put away")
                }
                if let notes = app.library?.notes {
                    var said = "settings probe: notes row — \(notes.looseBox.path(percentEncoded: false))"
                    said += " chosen=\(notes.looseBoxIsChosen) place=\(app.notesFolder)"
                    if let move = app.lastNotesMove {
                        said += " — \"\(SettingsView.describe(move, appFolder: notes.appFolderURL, box: notes.looseBox))\""
                    }
                    if let notice = app.notesNotice { said += " — notice \"\(notice)\"" }
                    say(said)
                }
            }
            // A sheet is a window of its own, hung off the one it covers, and
            // photographing the parent gets the page behind it. Whatever is in
            // front is what was asked for.
            guard let base = settings ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: \.isVisible)
                ?? offscreen(say: say)
            else { return say("window probe: no window") }
            let window = base.attachedSheet ?? base
            guard let content = window.contentView
            else { return say("window probe: no window") }
            // What a scroll actually costs, without a hand on the trackpad and
            // without sending the desktop a single event: the list's own
            // scroll view is moved from inside the process and the window is
            // told to draw, and the drawing is what is timed. A row that is
            // expensive to build shows up here as milliseconds per step.
            // `--papertime-click-row=<n>`이 목록의 n번째 줄을 누른다.
            //
            // 이벤트는 **창 안에서 만들어 그 창에만** 보낸다(`sendEvent`) —
            // 시스템 큐로 나가지 않으므로 앞에 있는 다른 앱에는 갈 수가 없다.
            // 포터블이 `--papertime-probe`에서 페이지 안에 이벤트를 만드는 것과
            // 같은 이유다. 줄이 SwiftUI 뷰라서 클릭이 표까지 안 내려가는 일이
            // 있었고, 그건 손 없이는 이 길로만 보인다.
            if let script = Boot.setting("PAPERTIME_CLICK_ROW"),
               let table = tallestTable(in: content) {
                // `3` · `3;6,shift;4,command` — one click, or several in order,
                // which is the only way to see what ⇧ and ⌘ do to a selection.
                for step in script.split(separator: ";") {
                    let parts = step.split(separator: ",").map(String.init)
                    // `down` · `up` — the arrow keys, which is how a Mac list
                    // is walked without the mouse. They go to whatever is first
                    // responder, so a click has to come first.
                    if parts.first == "down" || parts.first == "up" {
                        await pressArrow(down: parts.first == "down", window: window, app: app, table: table, say: say)
                        continue
                    }
                    guard let wanted = Int(parts.first ?? "") else { continue }
                    var modifiers: NSEvent.ModifierFlags = []
                    if parts.dropFirst().contains("shift") { modifiers.insert(.shift) }
                    if parts.dropFirst().contains("command") { modifiers.insert(.command) }
                    await clickRow(wanted, modifiers: modifiers, in: table, window: window, app: app, say: say)
                }
            }
            if let steps = Int(Boot.setting("PAPERTIME_SCROLL_TEST") ?? "") {
                scrollTest(in: content, steps: steps, say: say)
                try? await Task.sleep(for: .milliseconds(400))
                say("scroll test: pulled past the top — search palette \(app.showsSearchPalette ? "opened" : "did NOT open")")
            }
            if Boot.isSet("PAPERTIME_WINDOW_DUMP") {
                var lines: [String] = []
                dump(window, depth: 0, into: &lines)
                say("window probe: what the window says it shows —")
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    say(line)
                }
            }
            if let png = pixels(of: content) {
                try? png.write(to: URL(fileURLWithPath: path))
                say("window probe: wrote \(path); opaque=\(window.isOpaque) background=\(window.backgroundColor)")
                // What is actually in the window, for the times a picture of
                // it cannot be trusted: `cacheDisplay` misses a ScrollView's
                // contents, so an empty-looking shot proves nothing and this
                // does.
                if Boot.isSet("PAPERTIME_WINDOW_DUMP") {
                    var tree: [String] = []
                    func walk(_ view: NSView, _ depth: Int) {
                        guard depth < 7 else { return }
                        tree.append(String(repeating: "  ", count: depth)
                            + "\(type(of: view))(\(Int(view.frame.width))×\(Int(view.frame.height)))")
                        for child in view.subviews { walk(child, depth + 1) }
                    }
                    if let content = window.contentView { walk(content, 0) }
                    say("window probe: view tree —")
                    for line in tree.prefix(40) { say(line) }
                }
            }
            if Boot.isSet("PAPERTIME_WINDOW_SHOT_QUIT") { NSApp.terminate(nil) }
        }
    }

    /// A window put where no display reaches, for a run started hidden.
    ///
    /// Probes are launched with `open -g -j` so that nothing of theirs ever
    /// appears in front of the person using the machine — see `Scripts/probe.sh`.
    /// A hidden app has no visible window, and `cacheDisplay` on a window that
    /// was never ordered on gives back nothing, so the shot came out empty.
    ///
    /// This moves the window far outside every screen **before** ordering it
    /// on. It then has a backing store and draws, so it photographs exactly as
    /// a window on screen does, and it is on no display: the origin is checked
    /// against the union of every screen's frame rather than assumed, because
    /// a second monitor to the left puts real pixels at negative coordinates.
    private static func offscreen(say: (String) -> Void) -> NSWindow? {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else { return nil }
        let displays = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let origin = NSPoint(x: displays.minX - 60_000, y: displays.minY - 60_000)
        window.setFrameOrigin(origin)
        window.orderFront(nil)
        window.displayIfNeeded()
        say("window probe: drawing off every screen at \(Int(origin.x)),\(Int(origin.y))")
        return window
    }

    /// The app's model, for a probe run that has no window to hold it.
    static weak var model: AppModel?
    /// The window made for such a run. AppKit does not keep a window alive
    /// for us.
    private static var launchWindow: NSWindow?

    /// A window for a probe whose launch opened none.
    ///
    /// A probe starts hidden (`open -g -j`, see `Scripts/probe.sh`), and a
    /// hidden launch cannot be counted on to open a window. Probes used to
    /// get one from AppKit bringing back the last session's — and the probe
    /// and the copy somebody reads with are one sandbox, so that was
    /// whatever their copy had left. Once it left none, no view existed,
    /// `RootView`'s task never ran, nothing opened the library, and every
    /// probe printed "app starting" and nothing after it. With nothing to
    /// bring back, SwiftUI opened its own window in five runs of ten and none
    /// in the other five. So a probe run that nothing has started a moment
    /// in gets a window of its own: outside every display before it is
    /// ordered on, in an app that is hidden, and never made key.
    static func openIfNoneWasRestored() {
        guard Boot.setting("PAPERTIME_LIBRARY") != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let model, !model.launchBegan, launchWindow == nil else { return }
            let window = Unconstrained(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            let displays = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            window.setFrameOrigin(NSPoint(x: displays.minX - 60_000, y: displays.minY - 60_000))
            func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
            // Checked before it is ordered on, not after: a window that
            // landed on a screen has been seen by then.
            guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
                return say("probe: the launch opened no window, and one made for it would have been on a screen at \(window.frame) — none made")
            }
            window.contentView = NSHostingView(rootView: RootView().environment(model))
            window.orderFront(nil)
            // And after, in case AppKit moved it anyway: put away at once.
            if NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                window.orderOut(nil)
                return say("probe: the window made for a launch that opened none landed on a screen at \(window.frame) — put away")
            }
            launchWindow = window
            say("probe: the launch opened no window — made one off every screen at \(window.frame)")
            // The watch on the main thread starts from the window group's
            // own window, which this run never got: without this a probe
            // that made its own window reported no stalls at all — not
            // because there were none, but because nobody was counting.
            Hitches.watch()
        }
    }

    /// A titled window that stays where it is put. AppKit pulls a titled
    /// window back onto a screen when it is ordered on — the first one made
    /// for a probe was put 60 000 points away and came up at (218, 0).
    private final class Unconstrained: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// Settings, in a window that is on no display.
    ///
    /// Borderless, so AppKit has no title bar to keep on a screen and leaves
    /// the frame where it is put; placed before it has any content, so
    /// nothing is ever drawn anywhere else; ordered on without being made key,
    /// so the app stays where it was — hidden, and behind everything.
    private static var settingsWindows: [NSWindow] = []

    private static func settingsWindow(app: AppModel, say: (String) -> Void) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let displays = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        window.setFrameOrigin(NSPoint(x: displays.minX - 60_000, y: displays.minY - 60_000))
        window.contentView = NSHostingView(rootView: SettingsView().environment(app))
        window.orderFront(nil)
        window.displayIfNeeded()
        settingsWindows.append(window)
        say("settings probe: drawing Settings off every screen at \(window.frame)")
        return window
    }

    /// What the window says it contains.
    ///
    /// Neither `cacheDisplay` nor `layer.render(in:)` catches a SwiftUI tree
    /// reliably, so "is the first-run screen actually there" cannot be settled
    /// with a picture taken from inside the process. The accessibility tree
    /// can settle it: it is what VoiceOver reads, which is a fair definition
    /// of what is on screen.
    private static func dump(_ element: Any?, depth: Int, into lines: inout [String]) {
        guard depth < 12, let element = element as? NSObject else { return }
        let role = (element.value(forKey: "accessibilityRole") as? String) ?? ""
        let label = (element.value(forKey: "accessibilityLabel") as? String) ?? ""
        let value = (element.value(forKey: "accessibilityValue") as? String) ?? ""
        let title = (element.value(forKey: "accessibilityTitle") as? String) ?? ""
        let said = [title, label, value].filter { !$0.isEmpty }.joined(separator: " / ")
        if !said.isEmpty || !role.isEmpty {
            lines.append(String(repeating: "  ", count: depth) + "\(role) \(said)")
        }
        let children = (element.value(forKey: "accessibilityChildren") as? [Any]) ?? []
        for child in children { dump(child, depth: depth + 1, into: &lines) }
    }

    /// The window as it is actually drawn.
    ///
    /// `cacheDisplay` walks `draw(_:)` and therefore misses everything that
    /// renders through Core Animation — which in a SwiftUI window is most of
    /// it. It is why an inspector full of text came out as a black rectangle
    /// and a first-run screen came out empty: not bugs in the app, bugs in the
    /// camera. Rendering the layer tree instead catches what the screen shows,
    /// and needs no screen-recording permission.
    private static func pixels(of view: NSView) -> Data? {
        // `cacheDisplay` on the content view itself, which is what the report
        // sheet's own screenshot uses and what actually comes out right. The
        // theme frame (`contentView.superview`) does not: asking it for a
        // bitmap skips the layer-backed subviews and hands back black where
        // the panels are.
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Scrolls the tallest scroll view in the window and times each step.
    ///
    /// The tallest one is the list: the source list and the inspector are a
    /// screenful, and a library of hundreds is thousands of points. Each step
    /// moves it by one screen's worth and then forces the draw, so what is
    /// measured is the work of bringing new rows into being rather than the
    /// time until some later frame happens to land.
    /// Presses a row, from inside the application.
    ///
    /// The event is made here and put in **this app's own queue**; it cannot
    /// reach another application, which is the whole reason the rule against
    /// synthetic events exists. It is the Mac's counterpart to the Portable
    /// build's `--papertime-probe`, which makes its events inside the page.
    ///
    /// A hidden application's windows are not visible windows, and AppKit does
    /// not hand mouse events to a window that is not visible — so the app is
    /// unhidden **without being activated** first. Its window is already
    /// outside every display, so nothing appears in front of anybody.
    private static func clickRow(
        _ wanted: Int,
        modifiers: NSEvent.ModifierFlags,
        in table: NSTableView,
        window: NSWindow,
        app: AppModel,
        say: (String) -> Void
    ) async {
        guard wanted >= 0, wanted < table.numberOfRows else {
            return say("click: no row \(wanted) — the table has \(table.numberOfRows)")
        }
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
            try? await Task.sleep(for: .milliseconds(300))
            _ = offscreen(say: { _ in })
        }
        table.scrollRowToVisible(wanted)
        window.displayIfNeeded()

        let rect = table.rect(ofRow: wanted)
        let inWindow = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        for (kind, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
            guard let event = NSEvent.mouseEvent(
                with: kind, location: inWindow, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: pressure
            ) else { continue }
            window.sendEvent(event)
        }
        try? await Task.sleep(for: .milliseconds(500))

        let picked = app.library?.selection ?? []
        let named = modifiers.isEmpty ? "" : (modifiers.contains(.shift) ? " with shift" : " with command")
        say("click: row \(wanted)\(named) → \(picked.count) selected"
            + ", showing \(app.library?.selectedPaper?.meta.displayTitle ?? "—")"
            + ", the table says \(table.selectedRowIndexes.count)")
    }

    /// An arrow key, made and delivered inside the application as a click is.
    private static func pressArrow(
        down: Bool,
        window: NSWindow,
        app: AppModel,
        table: NSTableView,
        say: (String) -> Void
    ) async {
        let code: UInt16 = down ? 125 : 126
        let character = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: kind, location: .zero, modifierFlags: .function,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code
            ) else { continue }
            window.sendEvent(event)
        }
        try? await Task.sleep(for: .milliseconds(400))
        say("click: arrow \(down ? "down" : "up") → \(app.library?.selection.count ?? 0) selected"
            + ", showing \(app.library?.selectedPaper?.meta.displayTitle ?? "—")"
            + ", the table says row \(table.selectedRow)")
    }

    /// The table the list is drawn on, found the same way the scroll test finds
    /// its scroll view: the tallest one in the window.
    private static func tallestTable(in content: NSView) -> NSTableView? {
        var tallest: NSTableView?
        func walk(_ view: NSView) {
            if let table = view as? NSTableView,
               table.frame.height > (tallest?.frame.height ?? 0) {
                tallest = table
            }
            for child in view.subviews { walk(child) }
        }
        walk(content)
        return tallest
    }

    private static func scrollTest(in content: NSView, steps: Int, say: (String) -> Void) {
        var tallest: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               let document = scroll.documentView,
               document.frame.height > (tallest?.documentView?.frame.height ?? 0) {
                tallest = scroll
            }
            for child in view.subviews { walk(child) }
        }
        walk(content)
        guard let scroll = tallest, let document = scroll.documentView else {
            return say("scroll test: no scroll view")
        }
        let visible = scroll.contentView.bounds.height
        let travel = max(document.frame.height - visible, 0)
        guard travel > 0 else { return say("scroll test: nothing to scroll") }
        // How many row views actually exist. A list that draws what you can
        // see keeps a dozen; one that draws the library keeps the library,
        // and that is the difference between a scroll that costs the same
        // however much you have and one that does not.
        func descendants(of view: NSView) -> Int {
            view.subviews.reduce(view.subviews.count) { $0 + descendants(of: $1) }
        }
        say(String(format: "scroll test: %.0f points of list, %.0f visible, %d steps · %d views under the list",
                   document.frame.height, visible, steps, descendants(of: document)))

        var times: [Double] = []
        let rowsBefore = Trace.ticks("row body")
        let initsBefore = Trace.ticks("row init")
        for step in 0..<steps {
            let fraction = Double(step % 40) / 39
            let y = travel * fraction
            let started = DispatchTime.now().uptimeNanoseconds
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            content.window?.displayIfNeeded()
            CATransaction.flush()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        }
        // And a pull past the top, which is how the search palette opens. The
        // list reported that through `onScrollGeometryChange`; the table has to
        // report it from its own scroll view, and a gesture nobody can send
        // from here would otherwise go unchecked until somebody noticed it had
        // stopped working.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -120))
        scroll.reflectScrolledClipView(scroll.contentView)
        content.window?.displayIfNeeded()

        // Pass by pass. The list sweeps its whole length every forty steps, so
        // if the cost were NSTableView measuring rows it had not measured yet,
        // the second sweep over the same forty positions would be cheap. If it
        // is the same all the way down, the work is being done again every
        // time and no amount of scrolling settles it.
        var passes: [String] = []
        for start in stride(from: 0, to: times.count, by: 40) {
            let pass = Array(times[start..<min(start + 40, times.count)]).sorted()
            guard !pass.isEmpty else { continue }
            passes.append(String(format: "%.1f", pass[pass.count / 2]))
        }
        say("scroll test: median per sweep of the list — \(passes.joined(separator: ", "))ms")

        let sorted = times.sorted()
        let sum = times.reduce(0, +)
        let rows = Trace.ticks("row body") - rowsBefore
        let inits = Trace.ticks("row init") - initsBefore
        say(String(format: "scroll test: %d row bodies · %d row structs · %.1f and %.1f per step",
                   rows, inits, Double(rows) / Double(max(steps, 1)), Double(inits) / Double(max(steps, 1))))
        say(String(format: "scroll test: %d steps · median %.1fms · p95 %.1fms · worst %.1fms · %.2fs total",
                   times.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)],
                   sorted.last ?? 0, sum / 1000))
    }

    private static func firstTextField(in view: NSView?, marker: String) -> NSView? {
        guard let view else { return nil }
        if view is NSTextField || view is NSTextView {
            if marker == "any" { return view }
            if let field = view as? NSTextField, field.stringValue.contains(marker) { return view }
        }
        for child in view.subviews {
            if let found = firstTextField(in: child, marker: marker) { return found }
        }
        return nil
    }
}
#endif
