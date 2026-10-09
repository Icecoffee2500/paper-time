import Foundation
#if os(macOS)
import CoreServices
#endif

/// Notices when the library folder's contents change — anywhere under it.
///
/// The library *is* a folder, so sooner or later a paper arrives in it without
/// going through the app: dropped in from Finder, saved there by a browser, or
/// synced down by iCloud Drive or Google Drive. A folder-shaped library that
/// only notices new files when it is relaunched would be a folder-shaped lie.
///
/// On the Mac this is an FSEvents stream over the whole tree. It used to be a
/// kqueue on the root directory alone, and a kqueue on a directory hears only
/// about that directory's own entries: a PDF put into `2026/Week 3/` was never
/// heard of, a folder made inside a folder was never heard of, and a record
/// arriving from another machine under `.papertime/papers/<id>/` was never
/// heard of either — so the library showed the one subfolder it had read at
/// launch and nothing that came after. iOS has no FSEvents, so there the
/// kqueue stays. Either way changes arrive in bursts — a cloud client writes
/// a temporary file, renames it, then updates attributes — and are coalesced
/// into one callback after a quiet period, carrying every path the burst
/// named.
public final class FolderWatcher: @unchecked Sendable {
    private let url: URL
    private let quietPeriod: DispatchTimeInterval
    private let onChange: @Sendable ([String]) -> Void

    /// Everything below is read and written only on `queue`, which is what
    /// makes the unchecked `Sendable` above true.
    private let queue = DispatchQueue(label: "com.imtaeheon.PaperTime.FolderWatcher")
    private var pending: DispatchWorkItem?
    /// The paths a burst named so far. Empty with a burst in flight means the
    /// platform gave no names, and the caller has to look at everything.
    private var burst: [String] = []
    private var unnamed = false
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #else
    private var source: (any DispatchSourceFileSystemObject)?
    #endif

    /// `onChange` is handed the absolute paths the burst named, standardised
    /// (`LibraryStore.normalizedPath`); an empty list is "something, somewhere
    /// under the folder".
    public init(
        url: URL,
        quietPeriod: DispatchTimeInterval = .milliseconds(600),
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.url = url
        self.quietPeriod = quietPeriod
        self.onChange = onChange
    }

    /// The callback without the paths, for a caller that rescans anyway.
    public convenience init(
        url: URL,
        quietPeriod: DispatchTimeInterval = .milliseconds(600),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.init(url: url, quietPeriod: quietPeriod) { (_: [String]) in onChange() }
    }

    /// The owner is expected to call `stop()`, but a watcher that is simply
    /// let go must not leave a live stream behind either.
    deinit {
        pending?.cancel()
        #if os(macOS)
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        #else
        source?.cancel()
        #endif
    }

    public func start() {
        queue.async { [self] in startOnQueue() }
    }

    public func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    #if os(macOS)
    private func startOnQueue() {
        guard stream == nil else { return }
        // The path as the file system has it: FSEvents reports real paths,
        // and a library reached through a symlink would otherwise report
        // paths nobody could match against it.
        let path = LibraryStore.normalizedPath(url)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let names = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            for index in 0..<count {
                let flag = flags[index]
                // A dropped history, or a tree too big to say: look at all of it.
                if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                    watcher.unnamed = true
                } else {
                    watcher.burst.append(LibraryStore.normalizedPath(URL(filePath: names[index])))
                }
            }
            watcher.scheduleCallback()
        }
        guard let made = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
            )
        ) else { return }
        FSEventStreamSetDispatchQueue(made, queue)
        guard FSEventStreamStart(made) else {
            FSEventStreamInvalidate(made)
            FSEventStreamRelease(made)
            return
        }
        stream = made
    }

    private func stopOnQueue() {
        pending?.cancel()
        pending = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }
    #else
    private func startOnQueue() {
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
            unnamed = true
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

    private func stopOnQueue() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }
    #endif

    private func scheduleCallback() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let named = unnamed ? [] : burst
            burst = []
            unnamed = false
            onChange(named)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }
}
