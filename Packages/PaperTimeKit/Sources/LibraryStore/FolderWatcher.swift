import Foundation

/// Notices when the library folder's contents change.
///
/// The library *is* a folder, so sooner or later a paper arrives in it without
/// going through the app: dropped in from Finder, saved there by a browser, or
/// synced down by iCloud Drive or Google Drive. A folder-shaped library that
/// only notices new files when it is relaunched would be a folder-shaped lie.
///
/// A kqueue on the directory is the cheapest way to hear about that on both
/// platforms, and it costs one file descriptor. Changes arrive in bursts — a
/// cloud client writes a temporary file, renames it, then updates attributes —
/// so they are coalesced into one callback after a quiet period.
public final class FolderWatcher: @unchecked Sendable {
    private let url: URL
    private let quietPeriod: DispatchTimeInterval
    private let onChange: @Sendable () -> Void

    /// Everything below is read and written only on `queue`, which is what
    /// makes the unchecked `Sendable` above true.
    private let queue = DispatchQueue(label: "com.imtaeheon.PaperTime.FolderWatcher")
    private var source: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?

    public init(
        url: URL,
        quietPeriod: DispatchTimeInterval = .milliseconds(600),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.quietPeriod = quietPeriod
        self.onChange = onChange
    }

    /// The owner is expected to call `stop()`, but a watcher that is simply
    /// let go must not leave a live kqueue behind either.
    deinit {
        pending?.cancel()
        source?.cancel()
    }

    public func start() {
        queue.async { [self] in
            guard source == nil else { return }
            let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
                queue: queue
            )
            // The handler holds only a weak reference, so the source is kept
            // alive by this object and dies with it.
            source.setEventHandler { [weak self] in
                guard let self, let events = self.source?.data else { return }
                if events.contains(.delete) || events.contains(.rename)
                    || events.contains(.revoke) {
                    // The folder itself moved out from under us. Report it once
                    // so the app can rescan, then let go: the descriptor now
                    // points at something the user can no longer see.
                    stopOnQueue()
                    scheduleCallback()
                    return
                }
                scheduleCallback()
            }
            source.setCancelHandler { close(descriptor) }
            self.source = source
            source.resume()
        }
    }

    public func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func scheduleCallback() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }
}
