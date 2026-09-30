#if os(macOS)
import AppKit
import Foundation
import Observation
import SwiftUI

/// A version number, compared part by part: 0.9.10 is newer than 0.9.9.
///
/// Anything after a hyphen is ignored, the way the page sorts its list — a
/// pre-release is never offered as an update, so there is nothing to order.
struct UpdateVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    let description: String

    init?(_ text: String) {
        let core = text.split(separator: "-").first.map(String.init) ?? text
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
        self.description = text
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The page's `releases.json`, as far as an update needs it.
///
/// The same file the download page draws its list from, so publishing a
/// version is announcing it: `publish-release.sh` writes both at once, and
/// the notes it carries are the version's own entry in `ReleaseNotes`.
struct UpdateFeed: Decodable {
    struct Pair: Decodable, Equatable {
        let ko: String
        let en: String
        var value: String { L(ko, en) }
    }

    struct Item: Decodable, Equatable, Identifiable {
        let title: Pair
        let detail: Pair?
        var id: String { title.en }
    }

    struct Notes: Decodable, Equatable {
        let note: Pair?
        let added: [Item]?
        let fixed: [Item]?
    }

    struct Build: Decodable {
        let url: String
    }

    struct Release: Decodable {
        let version: String
        let builds: [String: [Build]]?
        let notes: Notes?
    }

    let releases: [Release]
}

/// What there is to update to, and what changed on the way there.
struct UpdateOffer: Equatable {
    struct Step: Equatable, Identifiable {
        let version: String
        let notes: UpdateFeed.Notes?
        var id: String { version }
    }

    /// The newest version.
    let version: String
    /// Every version newer than this one, newest first — somebody three
    /// versions behind is told about all three, not only the last.
    let steps: [Step]
    /// The disk image, for when the update cannot install itself.
    let download: URL?

    /// The offer in a feed for a copy running `current`, if there is one.
    static func from(_ feed: UpdateFeed, current: String) -> UpdateOffer? {
        guard let running = UpdateVersion(current) else { return nil }
        let newer = feed.releases
            .compactMap { release in UpdateVersion(release.version).map { ($0, release) } }
            .filter { $0.0 > running }
            .sorted { $0.0 > $1.0 }
        guard let newest = newer.first else { return nil }
        return UpdateOffer(
            version: newest.1.version,
            steps: newer.prefix(6).map { Step(version: $0.1.version, notes: $0.1.notes) },
            download: newest.1.builds?["mac"]?.first.flatMap { URL(string: $0.url) }
        )
    }
}

/// What installs an update once one has been found: Sparkle on this Mac.
@MainActor
protocol UpdateInstaller: AnyObject {
    /// Start fetching `version` in the background, so installing is quick.
    func prepare(version: String)
    /// Install what was prepared and relaunch.
    func install()
    /// Ask again for the quit the install is waiting on.
    func retry()
    /// Forget what was prepared; do not install it when the app quits.
    func cancel()
}

/// Whether there is a newer Paper Time, and the notice that says so.
///
/// Looks once shortly after launch and then once a day, at the page's list
/// rather than at GitHub's API (which counts every look against an hourly
/// allowance, and which the page itself already uses). What it finds at
/// launch is a sheet — nobody is reading yet, so nothing is interrupted.
/// What it finds later, with a paper open, is a line at the bottom of the
/// window that opens the same sheet when asked.
@MainActor
@Observable
final class UpdateCenter {
    static let shared = UpdateCenter()

    /// Where an update has got to. Every step that takes time says how far
    /// along it is: a spinner that says «Installing» and nothing more cannot
    /// be told apart from one that has stopped.
    enum Stage: Equatable {
        /// Found, and handed to the installer.
        case preparing
        /// Coming down: the bytes so far, and the whole once the server has
        /// said it.
        case downloading(received: Int64, total: Int64?)
        /// Downloaded: Sparkle opens the disk image, copies the app out and
        /// checks its signature. Its own measure, 0–1.
        case unpacking(Double)
        /// Downloaded and checked; installing is one click.
        case ready
        /// Installing: the app is closing, and opens again as the new version.
        case installing
        /// Asked to close for the install, the app did not: something held it
        /// open.
        case blocked
        /// The installer cannot do it: download the disk image instead.
        case manual

        /// How far along, 0–1, when there is a number to show.
        var fraction: Double? {
            switch self {
            case let .downloading(received, total?) where total > 0:
                min(1, Double(received) / Double(total))
            case let .unpacking(value):
                min(1, max(0, value))
            default:
                nil
            }
        }
    }

    private(set) var offer: UpdateOffer?
    private(set) var stage: Stage = .preparing
    /// The sheet with what changed.
    var showsSheet = false
    /// The quiet line, for an update found while the app was in use.
    private(set) var showsBar = false
    /// Asked to install before the download had finished: it installs the
    /// moment it is ready.
    private(set) var wantsInstall = false
    private(set) var isChecking = false
    private(set) var lastCheck: Date?
    private(set) var lastCheckFailed = false

    @ObservationIgnored private var installer: UpdateInstaller?
    /// Made the first time there is something to install, so a copy that
    /// never finds an update never starts Sparkle.
    @ObservationIgnored private var makeInstaller: (() -> UpdateInstaller?)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    /// How many times the quit has been asked for, so a late watch knows it
    /// has been overtaken.
    @ObservationIgnored private var installAsked = 0
    /// A probe's skip is remembered for the run only: the defaults belong to
    /// the copy people use.
    @ObservationIgnored private var skippedInMemory: String?

    static let enabledKey = "checkForUpdates"
    static let skippedKey = "skippedUpdateVersion"
    static let defaultFeed = URL(string: "https://icecoffee2500.github.io/paper-time/releases.json")!

    private var isProbe: Bool { Boot.setting("PAPERTIME_LIBRARY") != nil }

    /// Where to look. A probe looks nowhere unless it is given a feed of its
    /// own — it must never announce a real release on a test run, and never
    /// ask the network on the way.
    private var feedURL: URL? {
        if let given = Boot.setting("PAPERTIME_UPDATE_FEED"), !given.isEmpty {
            return given.contains("://") ? URL(string: given) : URL(fileURLWithPath: given)
        }
        return isProbe ? nil : Self.defaultFeed
    }

    /// The version this copy is. A probe can pretend to be an older one.
    var current: String {
        Boot.setting("PAPERTIME_UPDATE_AS").flatMap { $0.isEmpty ? nil : $0 } ?? ReleaseNotes.version
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private var skipped: String? {
        isProbe ? skippedInMemory : UserDefaults.standard.string(forKey: Self.skippedKey)
    }

    /// Called once the library is up. Checks a few seconds later — after the
    /// window has settled, and after the welcome for a new version.
    func start(installer: @escaping () -> UpdateInstaller?) {
        guard !started else { return }
        started = true
        makeInstaller = installer
        Task {
            try? await Task.sleep(for: .seconds(isProbe ? 0.5 : 4))
            // A probe can have the first look count as one made mid-session,
            // to see the line rather than the sheet.
            await check(atLaunch: !Boot.isSet("PAPERTIME_UPDATE_BAR"))
        }
        // Once an hour it asks whether a day has gone by. A day-long timer
        // would drift across sleep; this does not.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in
                let center = UpdateCenter.shared
                guard let last = center.lastCheck, Date().timeIntervalSince(last) > 86_000 else { return }
                await center.check(atLaunch: false)
            }
        }
    }

    /// Looks at the feed. `userInitiated` is the button in Settings: it runs
    /// even when checking is off, and shows the sheet even for a version
    /// that was skipped.
    func check(atLaunch: Bool, userInitiated: Bool = false) async {
        guard userInitiated || isEnabled, let url = feedURL, !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            note("check")
        }
        let found: UpdateOffer?
        do {
            found = try await Self.fetch(url, current: current)
            lastCheckFailed = false
        } catch {
            lastCheckFailed = true
            return
        }
        lastCheck = Date()
        guard let found else {
            if offer != nil { withdraw() }
            return
        }
        if !userInitiated, found.version == skipped { return }
        let isNew = found.version != offer?.version
        offer = found
        var pretend: String?
        if isNew {
            stage = .preparing
            wantsInstall = false
            if isProbe, let stageText = Boot.setting("PAPERTIME_UPDATE_STAGE") {
                if Boot.setting("PAPERTIME_UPDATE_QUIT") == "1" {
                    installer = QuitProbe()
                    QuitProbe.whenSheetIsUp { UpdateCenter.shared.installNow() }
                }
                if Boot.setting("PAPERTIME_UPDATE_QUIT") == "sheet" {
                    QuitProbe.whenSheetIsUp { QuitProbe.quit(when: "sheet up") }
                }
                pretend = stageText
            } else {
                if installer == nil, let make = makeInstaller {
                    installer = make()
                    makeInstaller = nil
                }
                if let installer { installer.prepare(version: found.version) } else { stage = .manual }
            }
        }
        // A probe that tries the whole install, as if Install Now were pressed
        // the moment the sheet appeared.
        if Boot.isSet("PAPERTIME_UPDATE_INSTALL") { wantsInstall = true }
        // Never the sheet again once the install has begun: it would stand in
        // the way of the very quit the install is waiting for.
        if (userInitiated || atLaunch), stage != .installing {
            showsBar = false
            showsSheet = true
        } else if isNew {
            showsBar = true
        }
        // Last, as Sparkle's reports come after the check that asked for them.
        if let pretend { pretendStage(pretend) }
    }

    private static func fetch(_ url: URL, current: String) async throws -> UpdateOffer? {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("Paper Time/\(ReleaseNotes.version) (Mac)", forHTTPHeaderField: "User-Agent")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            let (body, response) = try await URLSession(configuration: configuration).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            data = body
        }
        let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
        return UpdateOffer.from(feed, current: current)
    }

    /// The version went away from the feed (a release taken back).
    private func withdraw() {
        installer?.cancel()
        offer = nil
        showsBar = false
        showsSheet = false
    }

    // MARK: - What the notice's buttons do

    func showChanges() {
        showsSheet = true
    }

    func installNow() {
        switch stage {
        case .ready, .blocked:
            beginInstall()
        case .manual:
            if let url = offer?.download { NSWorkspace.shared.open(url) }
            showsSheet = false
            showsBar = false
        case .installing:
            break
        case .preparing, .downloading, .unpacking:
            wantsInstall = true
        }
    }

    /// Installs, and the new version opens. Sparkle asks for the quit with an
    /// Apple event the app may turn down, and a sheet on any window turns it
    /// down: macOS logs «App termination blocked by modal sheet» and Sparkle
    /// waits for a quit that never comes. The notice's own sheet was such a
    /// sheet — from 0.9.12 to 0.9.15 Install Now in it stood at «Installing»
    /// until the person quit by hand. So the sheet goes first, and the quit
    /// is asked for once no sheet is left.
    private func beginInstall() {
        let retrying = stage == .blocked
        stage = .installing
        wantsInstall = false
        showsSheet = false
        // The line says what happens next while the window is still here.
        showsBar = true
        note("install")
        Task { @MainActor in
            await Self.sheetsClosed()
            if retrying { installer?.retry() } else { installer?.install() }
            watchForQuit()
        }
    }

    /// Once no window has a sheet and nothing runs modally — two seconds at
    /// most, for a sheet that is not ours to close.
    private static func sheetsClosed() async {
        for _ in 0..<40 {
            if NSApp.modalWindow == nil, !NSApp.windows.contains(where: { $0.attachedSheet != nil }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The app should be gone a moment after the quit is asked for. Still
    /// here, something kept it open, and the line says so and offers to ask
    /// again — rather than «Installing» for ever.
    private func watchForQuit() {
        installAsked += 1
        let asked = installAsked
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.installAsked == asked, self.stage == .installing else { return }
            self.stage = .blocked
            if !self.showsSheet { self.showsBar = true }
            self.note("blocked")
        }
    }

    /// Not now. What was downloaded still goes in when the app quits.
    func later() {
        showsSheet = false
        showsBar = false
        wantsInstall = false
    }

    func skip() {
        guard let version = offer?.version else { return }
        if isProbe { skippedInMemory = version } else { UserDefaults.standard.set(version, forKey: Self.skippedKey) }
        installer?.cancel()
        offer = nil
        showsSheet = false
        showsBar = false
    }

    func hideBar() {
        showsBar = false
    }

    // MARK: - What the installer reports

    func installerDownloading(received: Int64, total: Int64?) {
        guard stage != .manual else { return }
        stage = .downloading(received: received, total: total)
    }

    func installerUnpacking(_ fraction: Double) {
        guard stage != .manual else { return }
        stage = .unpacking(fraction)
    }

    func installerReady() {
        defer { note("ready") }
        stage = .ready
        if wantsInstall { beginInstall() }
    }

    /// Sparkle has sent the quit. Nothing more to show when the app has gone;
    /// `watchForQuit` is there for when it has not.
    func installerInstalling() {
        defer { note("installing") }
        if stage != .blocked { stage = .installing }
    }

    /// The installer gave up (no network, a bad signature, a version the
    /// appcast does not have yet). The notice stays, and offers the disk
    /// image instead.
    func installerFailed() {
        defer { note("failed") }
        stage = .manual
        wantsInstall = false
    }

    /// For a probe (`--papertime-update-stage=`): the notice held at one
    /// stage, with no installer behind it, to photograph what each looks like
    /// — `downloading:<bytes>/<total>`, `unpacking:<0–1>`, `ready`, `blocked`
    /// or `manual`. From `ready`, Install Now runs the real path with nobody
    /// to quit the app, so the line ends at «blocked».
    private func pretendStage(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "downloading":
            let numbers = value.split(separator: "/").compactMap { Int64($0) }
            installerDownloading(received: numbers.first ?? 0, total: numbers.count > 1 ? numbers[1] : nil)
        case "unpacking":
            installerUnpacking(Double(value) ?? 0)
        case "ready":
            installerReady()
        case "blocked":
            stage = .blocked
        default:
            stage = .manual
        }
    }

    /// For a probe (`--papertime-update-log=1`): what the notice is doing.
    private func note(_ event: String) {
        guard Boot.isSet("PAPERTIME_UPDATE_LOG") else { return }
        FileHandle.standardError.write(Data("\(report) after \(event)\n".utf8))
    }

    /// For a probe: what the notice is doing, on one line.
    var report: String {
        let steps = offer?.steps.map(\.version).joined(separator: ",") ?? "-"
        return "update: offer \(offer?.version ?? "none") steps \(steps) stage \(stage) sheet \(showsSheet) bar \(showsBar) failed \(lastCheckFailed)"
    }
}

/// For a probe (`--papertime-update-stage=` with `--papertime-update-quit=`):
/// the quit Sparkle asks for, sent by the app to itself. A probe cannot let
/// Sparkle do it — Sparkle only sends the quit when it may relaunch, and a
/// relaunched copy would come to the front — so this asks the same question
/// AppKit is asked, `terminate`, and says whether the app went.
/// `1`: Install Now pressed in the sheet, and this as the installer.
/// `sheet`: the quit sent with the sheet still up, the way 0.9.15 sent it.
@MainActor
private final class QuitProbe: UpdateInstaller {
    func prepare(version: String) {}
    func install() { Self.quit(when: "install") }
    func retry() { Self.quit(when: "retry") }
    func cancel() {}

    /// Once the sheet is on its window (ten seconds at most), and a moment
    /// more — where a person's click would come.
    static func whenSheetIsUp(_ then: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            var waited = 0
            while waited < 100, !NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            let up = NSApp.windows.contains(where: { $0.attachedSheet != nil })
            let windows = NSApp.windows.map { "\(type(of: $0))\($0.isVisible ? "" : " hidden") \(Int($0.frame.minX)),\(Int($0.frame.minY))" }
            FileHandle.standardError.write(Data("update: sheet \(up ? "up" : "never up") after \(waited * 100) ms; windows \(windows)\n".utf8))
            try? await Task.sleep(for: .seconds(1))
            then()
        }
    }

    static func quit(when: String) {
        let say = { (text: String) in FileHandle.standardError.write(Data("update: \(text)\n".utf8)) }
        say("quit asked (\(when)) with \(NSApp.windows.filter { $0.attachedSheet != nil }.count) sheet(s) up")
        NSApp.terminate(nil)
        // `terminate` returns only when the quit was turned down.
        say("still running after the quit")
    }
}
#endif
