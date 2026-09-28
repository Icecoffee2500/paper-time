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

    enum Stage: Equatable {
        /// Found, and handed to the installer.
        case preparing
        /// Coming down: a fraction when the size is known.
        case downloading(Double?)
        /// Downloaded and checked; installing is one click.
        case ready
        /// Installing: the app is about to quit.
        case installing
        /// The installer cannot do it: download the disk image instead.
        case manual
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
    private var current: String {
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
        if isNew {
            stage = .preparing
            wantsInstall = false
            if installer == nil, let make = makeInstaller {
                installer = make()
                makeInstaller = nil
            }
            if let installer { installer.prepare(version: found.version) } else { stage = .manual }
        }
        // A probe that tries the whole install, as if Install Now were pressed
        // the moment the sheet appeared.
        if Boot.isSet("PAPERTIME_UPDATE_INSTALL") { wantsInstall = true }
        if userInitiated || atLaunch {
            showsBar = false
            showsSheet = true
        } else if isNew {
            showsBar = true
        }
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
        case .ready:
            stage = .installing
            installer?.install()
        case .manual:
            if let url = offer?.download { NSWorkspace.shared.open(url) }
            showsSheet = false
            showsBar = false
        case .installing:
            break
        case .preparing, .downloading:
            wantsInstall = true
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

    func installerProgress(_ fraction: Double?) {
        guard stage != .manual else { return }
        stage = .downloading(fraction)
    }

    func installerReady() {
        defer { note("ready") }
        stage = .ready
        if wantsInstall {
            stage = .installing
            installer?.install()
        }
    }

    func installerInstalling() {
        defer { note("installing") }
        stage = .installing
    }

    /// The installer gave up (no network, a bad signature, a version the
    /// appcast does not have yet). The notice stays, and offers the disk
    /// image instead.
    func installerFailed() {
        defer { note("failed") }
        stage = .manual
        wantsInstall = false
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
#endif
