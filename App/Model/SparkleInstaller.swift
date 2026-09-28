#if os(macOS) && canImport(Sparkle)
import AppKit
import Foundation
import Sparkle

/// Sparkle, driven by Paper Time's own notice instead of its windows.
///
/// Sparkle does the parts that are hard to get right — the download, the
/// EdDSA check against `SUPublicEDKey`, swapping the bundle in place from a
/// sandboxed app, the relaunch — and asks a *user driver* what to show at
/// each step. This driver shows nothing: it reports to `UpdateCenter`, which
/// draws the sheet and the line, and answers for it.
///
/// The one choice with consequences is holding the last reply. When the
/// update is downloaded and ready, Sparkle asks whether to install and
/// relaunch now; the reply is kept until somebody presses Install Now. If the
/// app quits first, Sparkle installs it on the way out — that is what Later
/// means.
@MainActor
final class SparkleInstaller: NSObject, UpdateInstaller, SPUUserDriver, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var expected: String?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var expectedLength: UInt64 = 0
    private var received: UInt64 = 0
    private let log = Boot.isSet("PAPERTIME_UPDATE_LOG")

    private var center: UpdateCenter { .shared }

    /// Nil when Sparkle cannot run here — the notice then offers the disk
    /// image.
    static func make() -> SparkleInstaller? {
        // A probe goes to no appcast but the one it names.
        if Boot.setting("PAPERTIME_LIBRARY") != nil, Boot.setting("PAPERTIME_UPDATE_APPCAST") == nil { return nil }
        let installer = SparkleInstaller()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: installer, delegate: installer)
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        do {
            try updater.start()
        } catch {
            installer.say("cannot start: \(error.localizedDescription)")
            return nil
        }
        installer.updater = updater
        return installer
    }

    private func say(_ message: String) {
        if log { FileHandle.standardError.write(Data("sparkle: \(message)\n".utf8)) }
    }

    // MARK: UpdateInstaller

    func prepare(version: String) {
        expected = version
        readyReply = nil
        guard let updater else { center.installerFailed(); return }
        say("checking the appcast for \(version)")
        updater.checkForUpdatesInBackground()
    }

    func install() {
        guard let reply = readyReply else { return }
        readyReply = nil
        say("installing and relaunching")
        reply(.install)
    }

    func cancel() {
        expected = nil
        if let reply = readyReply {
            readyReply = nil
            reply(.skip)
        }
    }

    // MARK: SPUUpdaterDelegate

    /// A probe can point Sparkle at an appcast of its own.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        guard let given = Boot.setting("PAPERTIME_UPDATE_APPCAST"), !given.isEmpty else { return nil }
        return given.contains("://") ? given : URL(fileURLWithPath: given).absoluteString
    }

    /// A probe never relaunches: the relaunched copy would come to the front.
    nonisolated func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        Boot.setting("PAPERTIME_LIBRARY") == nil
    }

    /// A check that goes wrong in the background never reaches the user
    /// driver — Sparkle only tells a person about errors they asked for. So
    /// the end of every cycle is where a failure is heard.
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard let error else { return }
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            say("cycle ended: \(message)")
            if readyReply == nil { center.installerFailed() }
        }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Checking is Paper Time's switch, not Sparkle's.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        say("appcast offers \(version) (\(appcastItem.versionString)), stage \(state.stage.rawValue)")
        guard let expected, UpdateVersion(version) == UpdateVersion(expected), !appcastItem.isInformationOnlyUpdate else {
            // The appcast and the page disagree — one of them is ahead of the
            // other for a minute after a release. The disk image still works.
            reply(.dismiss)
            center.installerFailed()
            return
        }
        center.installerProgress(nil)
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        say("no update in the appcast: \(error.localizedDescription)")
        center.installerFailed()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        say("error: \(error.localizedDescription)")
        center.installerFailed()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        received = 0
        expectedLength = 0
        center.installerProgress(nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        center.installerProgress(expectedLength > 0 ? min(1, Double(received) / Double(expectedLength)) : nil)
    }

    func showDownloadDidStartExtractingUpdate() {
        say("downloaded \(received) bytes; extracting")
        center.installerProgress(1)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        say("ready")
        readyReply = reply
        center.installerReady()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        say("installing (terminated: \(applicationTerminated))")
        center.installerInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        center.showChanges()
    }

    func dismissUpdateInstallation() {}
}
#endif
